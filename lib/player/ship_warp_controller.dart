// =============================================================================
// ship_warp_controller.dart
//
// Pure Dart, engine-agnostic state machine for the player ship's warp
// sequence: Idle -> Spooling (dynamic countdown) -> Arriving (2s
// deceleration) -> Idle. "Warping" itself is the instantaneous translation
// moment in between -- everything that happens at that instant (stranding,
// nav-accuracy calculation, wake creation, teleporting survivors) happens
// inside one method call, then the controller drops straight into the
// observable Arriving state.
//
// No Flutter/Flame imports. Holds references to DroneSwarmEconomy and
// FighterRoster and delegates per-unit mutation to them, same as before.
//
// WHAT'S NEW IN THIS VERSION:
//   - WarpDriveType (subwarp / ftl) affects nav accuracy and the wake
//     left behind, but NOT the state machine shape -- both drive types
//     go through the same Idle/Spooling/Arriving flow.
//   - calculateArrivalCoordinates(targetNode): FTL accuracy degrades with
//     low shipEnergy and hull-critical status; Subwarp is always
//     accurate; an aborted (micro-jumped) warp ignores the target
//     entirely and scatters around the departure point instead.
//   - A new Arriving state: a real, auto-ticking 2-second window (not a
//     host-controlled sticky flag like the old Warping state was).
//     Survivors -- drones still `seeking`, fighters still `piloted` --
//     get teleported to the new arrival coordinates the instant the jump
//     happens, before Arriving even starts ticking.
//   - Every jump drops a WarpWake at the departure point (see
//     warp_wake_tracking.dart for what happens when something reads it).
//
// Tunables are now split into two config bundles: ShipPowerConfig (energy/
// spool-rate, unchanged from before) and the new ShipNavConfig
// (arrival/accuracy/wake tunables). Same DeploymentConfig-style bundling
// pattern as drone_swarm_economy.dart, just two bundles instead of one
// now that there are two distinct tunable concerns.
// =============================================================================

import 'dart:math' as math;

import 'package:sd_client/swarm/drone_swarm_economy.dart';
import 'package:sd_client/combat/fighter_roster.dart';
import 'package:sd_client/celestial/celestial_node_manager.dart';
import 'package:sd_client/player/warp_wake_tracking.dart';

enum WarpState { idle, spooling, arriving, warping }

enum WarpDriveType {
  /// Physical, high-speed travel. Always accurate regardless of power/
  /// hull condition; leaves a stronger, more legible WarpWake (a
  /// "lingering directional trail").
  subwarp,
  /// Instantaneous translation. Accuracy is gated entirely by shipEnergy
  /// and hull condition; leaves a weaker, more fleeting wake.
  ftl,
}

/// Tunables for the navigation/arrival/wake system. Same bundling pattern
/// as ShipPowerConfig and DeploymentConfig -- mutate at runtime for tech
/// upgrades (better nav computers lower ftlMaxScatterDistance, better
/// stealth coating lowers wake signal strength, etc.).
class ShipNavConfig {
  /// How long the Arriving deceleration window lasts, in seconds.
  double arrivingDuration;
  /// Worst-case FTL scatter distance at zero accuracy -- should be
  /// larger than any node's typical interactionRadius, so a fully
  /// botched jump genuinely lands "way outside" it.
  double ftlMaxScatterDistance;
  /// Extra accuracy penalty multiplier applied on top of the energy-based
  /// factor while the hull is flagged critical. 1.0 = no extra penalty.
  double hullCriticalAccuracyPenalty;
  /// Scatter radius for an aborted (micro-jumped) warp -- deliberately
  /// larger than ftlMaxScatterDistance. This is "lost in deep space,"
  /// not just "missed the landing zone."
  double emergencyScatterRadius;
  /// Subwarp's minimal cosmetic jitter, as a fraction of the target
  /// node's interactionRadius. Subwarp is always "accurate," but landing
  /// on the exact same pixel every time looks robotic.
  double subwarpJitterFraction;
  /// Initial WarpWake.baseSignalStrength for a Subwarp departure
  /// (lingering trail -- easier to read).
  double subwarpWakeSignalStrength;
  /// Initial WarpWake.baseSignalStrength for an FTL departure
  /// (instantaneous blink -- harder to read).
  double ftlWakeSignalStrength;

  ShipNavConfig({
    this.arrivingDuration = 2.0,
    this.ftlMaxScatterDistance = 3000.0,
    this.hullCriticalAccuracyPenalty = 0.4,
    this.emergencyScatterRadius = 6000.0,
    this.subwarpJitterFraction = 0.1,
    this.subwarpWakeSignalStrength = 0.9,
    this.ftlWakeSignalStrength = 0.5,
  });
}

/// Tunables for the power/spool-rate system. Unchanged from the previous
/// version of this file, just renamed from `config` to `powerConfig` now
/// that there are two config bundles.
class ShipPowerConfig {
  double spoolDuration;
  double maxShipEnergy;
  double criticalEnergyThreshold;
  double criticalSpoolRateMultiplier;
  double energyRegenPerSecond;
  double weaponEnergyCost;
  double shieldEnergyCost;

  ShipPowerConfig({
    this.spoolDuration = 20.0,
    this.maxShipEnergy = 100.0,
    this.criticalEnergyThreshold = 30.0,
    this.criticalSpoolRateMultiplier = 0.5,
    this.energyRegenPerSecond = 4.0,
    this.weaponEnergyCost = 12.0,
    this.shieldEnergyCost = 18.0,
  });
}

/// Where a jump actually landed vs. where it was aimed.
class ArrivalCoordinates {
  final double x;
  final double y;
  /// Distance from the intended target (0 for a perfect landing; large
  /// for a botched FTL jump or an aborted micro-jump).
  final double scatterDistance;

  const ArrivalCoordinates({
    required this.x,
    required this.y,
    required this.scatterDistance,
  });
}

/// Bundled result handed to onWarpComplete.
class WarpCompleteResult {
  final int dronesStranded;
  final FighterStrandingResult fightersStranded;
  final ArrivalCoordinates arrival;
  final WarpWake wake;

  const WarpCompleteResult({
    required this.dronesStranded,
    required this.fightersStranded,
    required this.arrival,
    required this.wake,
  });
}

class ShipWarpController {
  ShipWarpController({
    required this.economy,
    required this.fighterRoster,
    ShipPowerConfig? powerConfig,
    ShipNavConfig? navConfig,
    this.shipEcm = 0.3,
    this.onSpoolStarted,
    this.onMicroJump,
    this.onWarpComplete,
    this.onArrivalSettled,
  })  : powerConfig = powerConfig ?? ShipPowerConfig(),
        navConfig = navConfig ?? ShipNavConfig() {
    shipEnergy = this.powerConfig.maxShipEnergy;
  }

  final DroneSwarmEconomy economy;
  final FighterRoster fighterRoster;
  final ShipPowerConfig powerConfig;
  final ShipNavConfig navConfig;

  final math.Random _rng = math.Random();

  /// Current power. Mutable -- drained by consumeEnergyFor*(), regenerated
  /// passively in update(). Set to powerConfig.maxShipEnergy by the
  /// constructor; assign directly if you want a fight to start already
  /// low on power.
  double shipEnergy = 0;

  /// The fleeing ship's loadout-driven ECM rating, 0 -> 1+. Higher makes
  /// every WarpWake this ship drops harder for anyone to read. Plain
  /// mutable field, same as shipEnergy -- wire it to whatever loadout/
  /// equipment system you build.
  double shipEcm;

  bool _hullCritical = false;

  final void Function()? onSpoolStarted;
  final void Function()? onMicroJump;
  /// Fires once, the instant the jump executes (translation + stranding +
  /// wake creation + survivor teleport all already done by the time this
  /// fires).
  final void Function(WarpCompleteResult result)? onWarpComplete;
  /// Fires once, when the 2-second Arriving window finishes on its own
  /// and the controller settles back to Idle.
  final void Function()? onArrivalSettled;

  WarpState _state = WarpState.idle;
  double _spoolRemaining = 0;
  double _arrivingRemaining = 0;

  CelestialNode? _targetNode;
  WarpDriveType _driveType = WarpDriveType.ftl;
  bool _abortedEarly = false;
  double _departureX = 0;
  double _departureY = 0;

  CelestialNode? _currentDockedNode;
  WarpWake? _lastWake;
  double _simulationTime = 0;

  // ---------------------------------------------------------------------------
  // Read-only state for the render loop. No math required on your end.
  // ---------------------------------------------------------------------------

  WarpState get warpState => _state;

  /// Seconds remaining before the spool completes on its own. 0 whenever
  /// not actively spooling. Exposed under both names for compatibility
  /// with the Flame components already built against `spoolTimer`.
  double get currentSpoolTime => _spoolRemaining;
  double get spoolTimer => _spoolRemaining;

  double get spoolProgress {
    if (_state != WarpState.spooling || powerConfig.spoolDuration <= 0) {
      return 0.0;
    }
    return 1.0 - (_spoolRemaining / powerConfig.spoolDuration).clamp(0.0, 1.0);
  }

  /// Seconds remaining in the Arriving deceleration window. 0 whenever
  /// not currently arriving.
  double get arrivalTimeRemaining => _arrivingRemaining;

  /// Normalized 0 -> 1 progress through the Arriving window -- e.g. drive
  /// a decelerating screen-shake off `1.0 - arrivalProgress`.
  double get arrivalProgress {
    if (_state != WarpState.arriving || navConfig.arrivingDuration <= 0) {
      return 0.0;
    }
    return 1.0 -
        (_arrivingRemaining / navConfig.arrivingDuration).clamp(0.0, 1.0);
  }

  bool get isIdle => _state == WarpState.idle;
  bool get isSpooling => _state == WarpState.spooling;
  bool get isArriving => _state == WarpState.arriving;
  bool get isWarping => _state == WarpState.warping;

  bool get isPowerTaxed =>
      shipEnergy < powerConfig.criticalEnergyThreshold || _hullCritical;
  bool get isHullCritical => _hullCritical;
  double get effectiveSpoolRateMultiplier =>
      isPowerTaxed ? powerConfig.criticalSpoolRateMultiplier : 1.0;

  int get dronesAtRisk => economy.countAtRiskOfStranding();

  List<int> get fightersAwaitingRendezvous =>
      fighterRoster.indicesInState(FighterAutonomousState.rendezvous);
  List<int> get fightersScrambling =>
      fighterRoster.indicesInState(FighterAutonomousState.scramble);
  List<int> get fightersInLastStand =>
      fighterRoster.indicesInState(FighterAutonomousState.lastStand);

  /// The node the ship is currently docked at/near, or null if it's
  /// sitting in open space (including "botched FTL jump, way outside any
  /// node's radius" and "emergency abort, target was ignored entirely").
  /// Cleared the moment a new warp is commanded; resolved again the
  /// instant the new jump executes.
  CelestialNode? get currentDockedNode => _currentDockedNode;

  /// The most recent wake this ship left behind, if any. Polling
  /// equivalent of onWarpComplete's `result.wake` -- handy if a UI
  /// element wants to keep showing "your last departure point" rather
  /// than reacting only to the one-shot callback.
  WarpWake? get lastWake => _lastWake;

  /// This controller's own running simulation clock, in seconds, ticking
  /// up every update(dt) call regardless of warpState. WarpWake.timestamp
  /// is stamped from this clock -- anything computing `timeSinceJump` for
  /// readWake() (e.g. enemy_director.dart) should use
  /// `simulationTime - wake.timestamp`, not a wall clock, so it stays in
  /// step with however fast/slow your own game loop is actually running.
  double get simulationTime => _simulationTime;

  // ---------------------------------------------------------------------------
  // Active defense hooks ("the triage") -- unchanged from before.
  // ---------------------------------------------------------------------------

  double consumeEnergyForWeapons([double? amount]) {
    final double cost = amount ?? powerConfig.weaponEnergyCost;
    shipEnergy = (shipEnergy - cost).clamp(0.0, powerConfig.maxShipEnergy);
    return shipEnergy;
  }

  double consumeEnergyForShields([double? amount]) {
    final double cost = amount ?? powerConfig.shieldEnergyCost;
    shipEnergy = (shipEnergy - cost).clamp(0.0, powerConfig.maxShipEnergy);
    return shipEnergy;
  }

  /// Drains shipEnergy from an EXTERNAL source -- enemy weapons fire,
  /// not the player's own choice to spend energy. Kept separate from
  /// consumeEnergyForWeapons/Shields so "I chose to fire" and "I got
  /// hit" stay semantically distinct, even though both just move the
  /// same number. Deliberately does NOT call setHullCritical() itself --
  /// whether/when shields-bottoming-out means hull-critical is a policy
  /// decision left to the caller (see combat_manager.dart).
  double applyIncomingDamage(double amount) {
    shipEnergy = (shipEnergy - amount).clamp(0.0, powerConfig.maxShipEnergy);
    return shipEnergy;
  }

  void setHullCritical(bool isCritical) {
    _hullCritical = isCritical;
  }

  // ---------------------------------------------------------------------------
  // Navigation
  // ---------------------------------------------------------------------------

  /// Computes where the ship will actually end up. Reads the drive type
  /// and abort status from internal state set by commandWarp()/
  /// microJump() -- matching the single-parameter shape you asked for --
  /// rather than taking them as separate arguments.
  ///
  /// - Aborted (micro-jumped): targetNode is ignored entirely; scatters
  ///   randomly and widely around the departure point.
  /// - Subwarp: always accurate -- small cosmetic jitter only, always
  ///   well inside targetNode.interactionRadius.
  /// - FTL: accuracy scales with shipEnergy (and is further penalized if
  ///   the hull is critical) -- optimal power lands safely near the
  ///   node; low power/damage scatters the ship outside its radius.
  ArrivalCoordinates calculateArrivalCoordinates(CelestialNode targetNode) {
    if (_abortedEarly) {
      final double angle = _rng.nextDouble() * 2 * math.pi;
      final double distance = navConfig.emergencyScatterRadius *
          (0.5 + _rng.nextDouble() * 0.5);
      return ArrivalCoordinates(
        x: _departureX + math.cos(angle) * distance,
        y: _departureY + math.sin(angle) * distance,
        scatterDistance: distance,
      );
    }

    if (_driveType == WarpDriveType.subwarp) {
      final double angle = _rng.nextDouble() * 2 * math.pi;
      final double distance = _rng.nextDouble() *
          targetNode.interactionRadius *
          navConfig.subwarpJitterFraction;
      return ArrivalCoordinates(
        x: targetNode.x + math.cos(angle) * distance,
        y: targetNode.y + math.sin(angle) * distance,
        scatterDistance: distance,
      );
    }

    // FTL: accuracyFactor 1.0 = pinpoint, 0.0 = total loss of precision.
    double accuracyFactor =
        (shipEnergy / powerConfig.maxShipEnergy).clamp(0.0, 1.0);
    if (_hullCritical) {
      accuracyFactor *= navConfig.hullCriticalAccuracyPenalty;
    }

    final double scatterDistance =
        navConfig.ftlMaxScatterDistance * (1.0 - accuracyFactor);
    final double angle = _rng.nextDouble() * 2 * math.pi;
    return ArrivalCoordinates(
      x: targetNode.x + math.cos(angle) * scatterDistance,
      y: targetNode.y + math.sin(angle) * scatterDistance,
      scatterDistance: scatterDistance,
    );
  }

  // ---------------------------------------------------------------------------
  // Input
  // ---------------------------------------------------------------------------

  /// Player commands a warp toward targetNode. shipX/shipY is the ship's
  /// position at the moment of casting off -- used as the wake's
  /// departure point and as the center for an emergency-abort scatter, on
  /// the assumption the ship holds roughly still while spooling.
  bool commandWarp({
    required CelestialNode targetNode,
    required double shipX,
    required double shipY,
    WarpDriveType driveType = WarpDriveType.ftl,
  }) {
    if (_state != WarpState.idle) return false;

    _targetNode = targetNode;
    _driveType = driveType;
    _departureX = shipX;
    _departureY = shipY;
    _abortedEarly = false;
    _currentDockedNode = null; // cast off -- no longer docked anywhere

    _state = WarpState.spooling;
    _spoolRemaining = powerConfig.spoolDuration;
    onSpoolStarted?.call();
    return true;
  }

  /// Emergency micro-jump: instantly executes the warp regardless of how
  /// much spool time is left. Only valid mid-spool.
  bool microJump() {
    if (_state != WarpState.spooling) return false;
    _abortedEarly = true;
    onMicroJump?.call();
    _executeWarp();
    return true;
  }

  /// Call once per game-loop tick.
  void update(double dt) {
    _simulationTime += dt;

    shipEnergy = (shipEnergy + powerConfig.energyRegenPerSecond * dt)
        .clamp(0.0, powerConfig.maxShipEnergy);

    if (_state == WarpState.spooling) {
      _spoolRemaining -= dt * effectiveSpoolRateMultiplier;
      if (_spoolRemaining <= 0) {
        _executeWarp();
      }
      return;
    }

    if (_state == WarpState.arriving) {
      _arrivingRemaining -= dt;
      if (_arrivingRemaining <= 0) {
        _arrivingRemaining = 0;
        _state = WarpState.idle;
        onArrivalSettled?.call();
      }
      return;
    }
  }

  /// Manual override: forces the controller back to Idle regardless of
  /// what state it's in. Arriving normally resolves itself automatically
  /// after navConfig.arrivingDuration -- this is only for edge cases
  /// (e.g. you want to cut the deceleration window short for a cutscene).
  void resetToIdle() {
    _state = WarpState.idle;
    _spoolRemaining = 0;
    _arrivingRemaining = 0;
  }

  void _executeWarp() {
    final CelestialNode targetNode = _targetNode!;
    final ArrivalCoordinates arrival = calculateArrivalCoordinates(targetNode);

    final double wakeSignal = _abortedEarly
        ? navConfig.ftlWakeSignalStrength * 0.5 // panicked jump, weak trace
        : (_driveType == WarpDriveType.subwarp
            ? navConfig.subwarpWakeSignalStrength
            : navConfig.ftlWakeSignalStrength);

    final WarpWake wake = WarpWake(
      x: _departureX,
      y: _departureY,
      timestamp: _simulationTime,
      baseSignalStrength: wakeSignal,
      shipEcm: shipEcm,
    );
    _lastWake = wake;

    // Drones freeze (unchanged); fighters roll into an autonomous state
    // instead -- both decisions are made entirely inside their own
    // owning class, not here.
    final int strandedDroneCount = economy.strandUnreturnedDrones();
    final FighterStrandingResult fighterResult =
        fighterRoster.strandActiveFighters();

    // Survivors -- whatever's still `seeking`/`piloted` after stranding --
    // jump with the ship and arrive at the new coordinates instantly.
    economy.teleportSeekingDronesTo(arrival.x, arrival.y);
    fighterRoster.teleportPilotedFightersTo(arrival.x, arrival.y);

    _currentDockedNode =
        targetNode.containsPoint(arrival.x, arrival.y) ? targetNode : null;

    // The instantaneous translation moment. Never observably "stuck" --
    // we fall straight through into the real, auto-ticking Arriving
    // state before this method returns, so a polling render loop will
    // see Spooling -> Arriving on the next read, not Spooling -> Warping
    // forever. React to onWarpComplete (fired right here) for a one-shot
    // "the jump just happened" hook, and to isArriving/arrivalProgress
    // for the visual window that follows it.
    _state = WarpState.warping;
    onWarpComplete?.call(WarpCompleteResult(
      dronesStranded: strandedDroneCount,
      fightersStranded: fighterResult,
      arrival: arrival,
      wake: wake,
    ));

    _spoolRemaining = 0;
    _state = WarpState.arriving;
    _arrivingRemaining = navConfig.arrivingDuration;
  }
}
