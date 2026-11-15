// =============================================================================
// ship_warp_controller.dart
//
// Pure-Dart, engine-agnostic state machine for the player ship's dual-drive
// warp sequence (Subwarp vs FTL Blind Jump), WarpWake emission, mid-transit
// interception/anomaly hazards, and active ECM spoofing.
// Zero Flutter or Flame imports.
// =============================================================================

import 'dart:math' as math;

import 'package:sd_client/celestial/celestial_node_manager.dart';
import 'package:sd_client/combat/fighter_roster.dart';
import 'package:sd_client/simulation/warp/tracking_spectrum.dart';
import 'package:sd_client/swarm/drone_swarm_economy.dart';

export 'package:sd_client/simulation/warp/tracking_spectrum.dart'
    show WarpDriveType, WarpWake, SpoofedWarpWake;

enum WarpState { idle, spooling, arriving, warping }

/// Mid-flight spatial anomaly hazard that can damage or pull a Subwarp ship
/// out of transit if its physical flight path intersects the anomaly radius.
class SpatialAnomaly {
  final String id;
  final double x;
  final double y;
  final double radius;
  final double energyDamage;
  final double decayPenalty;
  final bool pullsOutOfSubwarp;

  const SpatialAnomaly({
    required this.id,
    required this.x,
    required this.y,
    required this.radius,
    this.energyDamage = 25.0,
    this.decayPenalty = 0.15,
    this.pullsOutOfSubwarp = true,
  });

  bool intersects(double px, double py) {
    final dx = px - x;
    final dy = py - y;
    return dx * dx + dy * dy <= radius * radius;
  }

  /// Returns the earliest intersection parameter `t` in `[0.0, 1.0]` along the
  /// segment `(x0, y0) -> (x1, y1)`, or `null` if the segment does not touch
  /// this anomaly's circle.
  double? firstIntersectionT(double x0, double y0, double x1, double y1) {
    final fx = x0 - x;
    final fy = y0 - y;
    final rSq = radius * radius;
    if (fx * fx + fy * fy <= rSq) {
      return 0.0;
    }

    final dx = x1 - x0;
    final dy = y1 - y0;
    final a = dx * dx + dy * dy;
    if (a <= 1e-12) return null;

    final b = 2.0 * (fx * dx + fy * dy);
    final c = fx * fx + fy * fy - rSq;
    final discriminant = b * b - 4.0 * a * c;
    if (discriminant < 0.0) return null;

    final sqrtDisc = math.sqrt(discriminant);
    final t1 = (-b - sqrtDisc) / (2.0 * a);
    final t2 = (-b + sqrtDisc) / (2.0 * a);

    if (t1 >= 0.0 && t1 <= 1.0) return t1;
    if (t2 >= 0.0 && t2 <= 1.0) return t2;
    return null;
  }
}

/// Tunables for navigation, FTL scatter, Subwarp transit, and WarpWake signatures.
class ShipNavConfig {
  double arrivingDuration;
  double ftlMaxScatterDistance;
  double hullCriticalAccuracyPenalty;
  double emergencyScatterRadius;
  double subwarpJitterFraction;

  /// Speed (world units / second) of physical Subwarp traversal.
  double subwarpSpeed;

  /// Initial energy signature for an FTL departure (high concentrated spatial tear).
  double ftlWakeSignalStrength;

  /// Fast exponential decay rate for FTL spatial tears.
  double ftlWakeDecayRate;

  /// Initial energy signature for a Subwarp departure (moderate directional trail).
  double subwarpWakeSignalStrength;

  /// Slower decay rate for Subwarp directional exhaust trails.
  double subwarpWakeDecayRate;

  ShipNavConfig({
    this.arrivingDuration = 2.0,
    this.ftlMaxScatterDistance = 3000.0,
    this.hullCriticalAccuracyPenalty = 0.4,
    this.emergencyScatterRadius = 6000.0,
    this.subwarpJitterFraction = 0.1,
    this.subwarpSpeed = 1200.0,
    this.ftlWakeSignalStrength = 0.95,
    this.ftlWakeDecayRate = 0.28,
    this.subwarpWakeSignalStrength = 0.70,
    this.subwarpWakeDecayRate = 0.05,
  });
}

/// Tunables for ship power, spool rate, and ECM charge.
class ShipPowerConfig {
  double spoolDuration;
  double maxShipEnergy;
  double criticalEnergyThreshold;
  double criticalSpoolRateMultiplier;
  double energyRegenPerSecond;
  double weaponEnergyCost;
  double shieldEnergyCost;
  double maxEcmCharge;
  double ecmRegenPerSecond;

  ShipPowerConfig({
    this.spoolDuration = 20.0,
    this.maxShipEnergy = 100.0,
    this.criticalEnergyThreshold = 30.0,
    this.criticalSpoolRateMultiplier = 0.5,
    this.energyRegenPerSecond = 4.0,
    this.weaponEnergyCost = 12.0,
    this.shieldEnergyCost = 18.0,
    this.maxEcmCharge = 100.0,
    this.ecmRegenPerSecond = 5.0,
  });
}

/// Where a jump or subwarp transit actually landed vs. where it was aimed.
class ArrivalCoordinates {
  final double x;
  final double y;
  final double scatterDistance;
  final double computedAccuracy;

  const ArrivalCoordinates({
    required this.x,
    required this.y,
    required this.scatterDistance,
    this.computedAccuracy = 1.0,
  });
}

/// Bundled result handed to [ShipWarpController.onWarpComplete].
class WarpCompleteResult {
  final int dronesStranded;
  final FighterStrandingResult fightersStranded;
  final ArrivalCoordinates arrival;
  final WarpWake wake;
  final bool wasInterceptedMidTransit;
  final SpatialAnomaly? collidedAnomaly;

  const WarpCompleteResult({
    required this.dronesStranded,
    required this.fightersStranded,
    required this.arrival,
    required this.wake,
    this.wasInterceptedMidTransit = false,
    this.collidedAnomaly,
  });
}

class ShipWarpController {
  ShipWarpController({
    required this.economy,
    required this.fighterRoster,
    ShipPowerConfig? powerConfig,
    ShipNavConfig? navConfig,
    this.shipEcm = 0.3,
    this.shipDecay = 0.0,
    this.navComputerHealth = 1.0,
    int? seed,
    this.onSpoolStarted,
    this.onMicroJump,
    this.onWarpComplete,
    this.onArrivalSettled,
    this.onSubwarpIntercepted,
  })  : powerConfig = powerConfig ?? ShipPowerConfig(),
        navConfig = navConfig ?? ShipNavConfig(),
        _rng = seed != null ? math.Random(seed) : math.Random() {
    shipEnergy = this.powerConfig.maxShipEnergy;
    ecmCharge = this.powerConfig.maxEcmCharge;
  }

  final DroneSwarmEconomy economy;
  final FighterRoster fighterRoster;
  final ShipPowerConfig powerConfig;
  final ShipNavConfig navConfig;
  final math.Random _rng;

  double shipEnergy = 0;
  double ecmCharge = 0;
  double shipEcm;

  /// Accumulated structural/system wear in `[0.0, 1.0]`. Penalizes FTL accuracy.
  double shipDecay;

  /// Navigation computer integrity in `[0.0, 1.0]`. `(1.0 - navComputerHealth)`
  /// scales FTL blind jump scatter radius.
  double navComputerHealth;

  bool _hullCritical = false;

  final void Function()? onSpoolStarted;
  final void Function()? onMicroJump;
  final void Function(WarpCompleteResult result)? onWarpComplete;
  final void Function()? onArrivalSettled;
  final void Function(double interceptX, double interceptY)?
      onSubwarpIntercepted;

  WarpState _state = WarpState.idle;
  double _spoolRemaining = 0;
  double _arrivingRemaining = 0;

  // ---- Subwarp physical traversal state ----
  bool _inSubwarpTransit = false;
  double _transitTimeTotal = 0;
  double _transitTimeRemaining = 0;
  double _flightVectorX = 0;
  double _flightVectorY = 0;
  double _currentShipX = 0;
  double _currentShipY = 0;
  ArrivalCoordinates? _plannedSubwarpArrival;
  int _pendingStrandedDrones = 0;
  FighterStrandingResult? _pendingStrandedFighters;
  bool _wasInterceptedMidTransit = false;
  SpatialAnomaly? _collidedAnomaly;

  final List<SpatialAnomaly> _anomalies = [];
  final Set<String> _hitAnomalyIdsInCurrentTransit = {};
  final List<SpoofedWarpWake> _spoofedWakes = [];
  SpoofedWarpWake? _lastSpoofedWake;

  CelestialNode? _targetNode;
  WarpDriveType _driveType = WarpDriveType.ftl;
  bool _abortedEarly = false;
  double _departureX = 0;
  double _departureY = 0;

  CelestialNode? _currentDockedNode;
  WarpWake? _lastWake;
  double _simulationTime = 0;

  // ---------------------------------------------------------------------------
  // Read-only state getters
  // ---------------------------------------------------------------------------

  WarpState get warpState => _state;
  WarpDriveType get activeDriveType => _driveType;

  double get currentSpoolTime => _spoolRemaining;
  double get spoolTimer => _spoolRemaining;

  double get spoolProgress {
    if (_state != WarpState.spooling || powerConfig.spoolDuration <= 0) {
      return 0.0;
    }
    return 1.0 - (_spoolRemaining / powerConfig.spoolDuration).clamp(0.0, 1.0);
  }

  double get arrivalTimeRemaining => _arrivingRemaining;

  double get arrivalProgress {
    if (_state != WarpState.arriving || navConfig.arrivingDuration <= 0) {
      return 0.0;
    }
    return 1.0 -
        (_arrivingRemaining / navConfig.arrivingDuration).clamp(0.0, 1.0);
  }

  /// Computed physical transit duration (seconds) for the active/last Subwarp.
  double get transitTime => _transitTimeTotal;
  double get transitTimeRemaining => _transitTimeRemaining;
  double get flightVectorX => _flightVectorX;
  double get flightVectorY => _flightVectorY;
  double get currentShipX => _currentShipX;
  double get currentShipY => _currentShipY;
  bool get isSubwarpInTransit => _inSubwarpTransit;
  bool get wasInterceptedMidTransit => _wasInterceptedMidTransit;
  SpatialAnomaly? get lastCollidedAnomaly => _collidedAnomaly;

  /// During Subwarp physical traversal (as well as Idle/Spooling/Arriving),
  /// the ship remains physically in-grid and targetable.
  bool get isPhysicallyTargetable => true;

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

  CelestialNode? get currentDockedNode => _currentDockedNode;
  WarpWake? get lastWake => _lastWake;
  double get simulationTime => _simulationTime;

  List<SpatialAnomaly> get anomalies => List.unmodifiable(_anomalies);
  List<SpoofedWarpWake> get spoofedWakes => List.unmodifiable(_spoofedWakes);
  SpoofedWarpWake? get lastSpoofedWake => _lastSpoofedWake;
  int get spoofedWakeCount => _spoofedWakes.length;
  SpoofedWarpWake spoofedWakeAt(int index) => _spoofedWakes[index];

  void registerAnomaly(SpatialAnomaly anomaly) {
    _anomalies.add(anomaly);
  }

  void clearAnomalies() {
    _anomalies.clear();
  }

  // ---------------------------------------------------------------------------
  // Active defense & ECM Spoofing hooks
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

  double applyIncomingDamage(double amount) {
    shipEnergy = (shipEnergy - amount).clamp(0.0, powerConfig.maxShipEnergy);
    return shipEnergy;
  }

  void setHullCritical(bool isCritical) {
    _hullCritical = isCritical;
  }

  /// Expends [ecmCost] from [ecmCharge] to emit a [SpoofedWarpWake] false trail
  /// pointing toward `(fakeTargetX, fakeTargetY)` with decaying confidence.
  /// Returns `null` if insufficient ECM charge is available.
  SpoofedWarpWake? emitSpoofedWake({
    required double x,
    required double y,
    required double fakeTargetX,
    required double fakeTargetY,
    double ecmCost = 25.0,
    double initialConfidenceWeight = 0.85,
    double confidenceDecayRate = 0.18,
    WarpDriveType spoofedDriveType = WarpDriveType.subwarp,
  }) {
    if (ecmCharge < ecmCost) return null;
    ecmCharge = (ecmCharge - ecmCost).clamp(0.0, powerConfig.maxEcmCharge);

    final dx = fakeTargetX - x;
    final dy = fakeTargetY - y;
    final dist = math.sqrt(dx * dx + dy * dy);
    final vx = dist > 0 ? dx / dist : 1.0;
    final vy = dist > 0 ? dy / dist : 0.0;

    final spoof = SpoofedWarpWake(
      x: x,
      y: y,
      timestamp: _simulationTime,
      shipEcm: shipEcm,
      driveType: spoofedDriveType,
      baseEnergySignature: spoofedDriveType == WarpDriveType.ftl
          ? navConfig.ftlWakeSignalStrength
          : navConfig.subwarpWakeSignalStrength,
      vectorX: vx,
      vectorY: vy,
      targetX: fakeTargetX,
      targetY: fakeTargetY,
      initialConfidenceWeight: initialConfidenceWeight,
      confidenceDecayRate: confidenceDecayRate,
    );
    _lastSpoofedWake = spoof;
    _spoofedWakes.add(spoof);
    return spoof;
  }

  // ---------------------------------------------------------------------------
  // Navigation & Accuracy
  // ---------------------------------------------------------------------------

  /// Computes FTL accuracy in `[0.0, 1.0]`.
  /// - Emergency abort sets accuracy to `0.0` (maximum random scatter).
  /// - Scales down with `shipDecay` (`0..1`), `(1.0 - navComputerHealth)`,
  ///   low `shipEnergy`, and `_hullCritical`.
  double computeFtlAccuracy() {
    if (_abortedEarly) return 0.0;

    final double energyFactor = powerConfig.maxShipEnergy > 0
        ? (shipEnergy / powerConfig.maxShipEnergy).clamp(0.0, 1.0)
        : 1.0;
    final double navFactor = navComputerHealth.clamp(0.0, 1.0);
    final double decayPenalty = (1.0 - shipDecay.clamp(0.0, 1.0));

    double accuracy = energyFactor * navFactor * decayPenalty;
    if (_hullCritical) {
      accuracy *= navConfig.hullCriticalAccuracyPenalty;
    }
    return accuracy.clamp(0.0, 1.0);
  }

  ArrivalCoordinates calculateArrivalCoordinates(CelestialNode targetNode) {
    if (_abortedEarly) {
      // Emergency abort sets accuracy to 0.0 -> maximum random scatter
      final double angle = _rng.nextDouble() * 2 * math.pi;
      final double distance = navConfig.emergencyScatterRadius;
      return ArrivalCoordinates(
        x: _departureX + math.cos(angle) * distance,
        y: _departureY + math.sin(angle) * distance,
        scatterDistance: distance,
        computedAccuracy: 0.0,
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
        computedAccuracy: 1.0,
      );
    }

    final double accuracyFactor = computeFtlAccuracy();
    final double inaccuracy = 1.0 - accuracyFactor;
    final double scatterDistance = navConfig.ftlMaxScatterDistance * inaccuracy;
    final double angle = _rng.nextDouble() * 2 * math.pi;
    return ArrivalCoordinates(
      x: targetNode.x + math.cos(angle) * scatterDistance,
      y: targetNode.y + math.sin(angle) * scatterDistance,
      scatterDistance: scatterDistance,
      computedAccuracy: accuracyFactor,
    );
  }

  // ---------------------------------------------------------------------------
  // Input & Execution
  // ---------------------------------------------------------------------------

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
    _currentShipX = shipX;
    _currentShipY = shipY;
    _abortedEarly = false;
    _wasInterceptedMidTransit = false;
    _collidedAnomaly = null;
    _hitAnomalyIdsInCurrentTransit.clear();
    _currentDockedNode = null;

    _state = WarpState.spooling;
    _spoolRemaining = powerConfig.spoolDuration;
    onSpoolStarted?.call();
    return true;
  }

  /// Emergency abort / micro-jump mid-spool: sets accuracy to 0.0 and executes
  /// an immediate blind scatter jump.
  bool microJump() {
    if (_state != WarpState.spooling) return false;
    _abortedEarly = true;
    onMicroJump?.call();
    _executeWarp();
    return true;
  }

  /// Attempts to physically intercept a ship currently in Subwarp traversal.
  /// If `(interceptorX, interceptorY)` is within [interceptRadius] of the
  /// ship's live transit coordinates, pulls the ship out of Subwarp immediately.
  bool tryInterceptSubwarp({
    required double interceptorX,
    required double interceptorY,
    required double interceptRadius,
  }) {
    if (!_inSubwarpTransit || _state != WarpState.warping) return false;

    final dx = _currentShipX - interceptorX;
    final dy = _currentShipY - interceptorY;
    if (dx * dx + dy * dy > interceptRadius * interceptRadius) {
      return false;
    }

    _wasInterceptedMidTransit = true;
    onSubwarpIntercepted?.call(_currentShipX, _currentShipY);
    _finishSubwarpAt(_currentShipX, _currentShipY);
    return true;
  }

  void update(double dt) {
    _simulationTime += dt;

    shipEnergy = (shipEnergy + powerConfig.energyRegenPerSecond * dt)
        .clamp(0.0, powerConfig.maxShipEnergy);
    ecmCharge = (ecmCharge + powerConfig.ecmRegenPerSecond * dt)
        .clamp(0.0, powerConfig.maxEcmCharge);

    // Prune expired spoofed wakes whose confidence or energy has dropped below lost-trace threshold (0.20)
    // or when age exceeds max decoy lifetime (60s), keeping memory and sweeps bounded.
    if (_spoofedWakes.isNotEmpty) {
      _spoofedWakes.removeWhere((wake) {
        final double age = math.max(0.0, _simulationTime - wake.timestamp);
        return age > 60.0 ||
            (wake.confidenceAt(age) < 0.20 && wake.currentEnergy(age) < 0.20);
      });
    }

    if (_state == WarpState.spooling) {
      _spoolRemaining -= dt * effectiveSpoolRateMultiplier;
      if (_spoolRemaining <= 0) {
        _executeWarp();
      }
      return;
    }

    if (_inSubwarpTransit && _state == WarpState.warping) {
      _stepSubwarpTransit(dt);
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

  void resetToIdle() {
    _state = WarpState.idle;
    _inSubwarpTransit = false;
    _spoolRemaining = 0;
    _arrivingRemaining = 0;
    _transitTimeRemaining = 0;
  }

  void _executeWarp() {
    final CelestialNode targetNode = _targetNode!;
    final ArrivalCoordinates arrival = calculateArrivalCoordinates(targetNode);

    final double dx = arrival.x - _departureX;
    final double dy = arrival.y - _departureY;
    final double dist = math.sqrt(dx * dx + dy * dy);
    _flightVectorX = dist > 0 ? dx / dist : 1.0;
    _flightVectorY = dist > 0 ? dy / dist : 0.0;

    final bool isSubwarp =
        _driveType == WarpDriveType.subwarp && !_abortedEarly;

    final double wakeSignal = _abortedEarly
        ? navConfig.ftlWakeSignalStrength * 0.5
        : (isSubwarp
            ? navConfig.subwarpWakeSignalStrength
            : navConfig.ftlWakeSignalStrength);

    final double wakeDecay =
        isSubwarp ? navConfig.subwarpWakeDecayRate : navConfig.ftlWakeDecayRate;

    final WarpWake wake = WarpWake(
      x: _departureX,
      y: _departureY,
      timestamp: _simulationTime,
      shipEcm: shipEcm,
      driveType: isSubwarp ? WarpDriveType.subwarp : WarpDriveType.ftl,
      baseEnergySignature: wakeSignal,
      decayRate: wakeDecay,
      vectorX: _flightVectorX,
      vectorY: _flightVectorY,
      targetX: arrival.x,
      targetY: arrival.y,
    );
    _lastWake = wake;

    final int strandedDroneCount = economy.strandUnreturnedDrones();
    final FighterStrandingResult fighterResult =
        fighterRoster.strandActiveFighters();

    _spoolRemaining = 0;

    if (isSubwarp && navConfig.subwarpSpeed > 0 && dist > 0) {
      _inSubwarpTransit = true;
      _state = WarpState.warping;
      _transitTimeTotal = dist / navConfig.subwarpSpeed;
      _transitTimeRemaining = _transitTimeTotal;
      _plannedSubwarpArrival = arrival;
      _pendingStrandedDrones = strandedDroneCount;
      _pendingStrandedFighters = fighterResult;
      return;
    }

    // Instantaneous FTL blind jump (or zero-distance subwarp)
    _completeTranslation(
      arrival: arrival,
      wake: wake,
      strandedDroneCount: strandedDroneCount,
      fighterResult: fighterResult,
    );
  }

  void _stepSubwarpTransit(double dt) {
    final double prevX = _currentShipX;
    final double prevY = _currentShipY;
    final double stepTime = math.min(dt, _transitTimeRemaining);
    final double stepDist = navConfig.subwarpSpeed * stepTime;

    _currentShipX += _flightVectorX * stepDist;
    _currentShipY += _flightVectorY * stepDist;
    _transitTimeRemaining -= stepTime;

    // Swept segment-circle intersection along (prevX, prevY) -> (_currentShipX, _currentShipY)
    // ordered by earliest contact t so fast ticks cannot skip anomalies and
    // non-pulling anomalies only penalize the ship once per transit.
    final List<({SpatialAnomaly anomaly, double t})> hits = [];
    for (final anomaly in _anomalies) {
      if (_hitAnomalyIdsInCurrentTransit.contains(anomaly.id)) continue;
      final t = anomaly.firstIntersectionT(
        prevX,
        prevY,
        _currentShipX,
        _currentShipY,
      );
      if (t != null) {
        hits.add((anomaly: anomaly, t: t));
      }
    }
    hits.sort((a, b) => a.t.compareTo(b.t));

    for (final hit in hits) {
      final anomaly = hit.anomaly;
      _hitAnomalyIdsInCurrentTransit.add(anomaly.id);
      _collidedAnomaly = anomaly;
      applyIncomingDamage(anomaly.energyDamage);
      shipDecay = (shipDecay + anomaly.decayPenalty).clamp(0.0, 1.0);
      if (anomaly.pullsOutOfSubwarp) {
        _wasInterceptedMidTransit = true;
        final hitX = prevX + (_currentShipX - prevX) * hit.t;
        final hitY = prevY + (_currentShipY - prevY) * hit.t;
        _currentShipX = hitX;
        _currentShipY = hitY;
        _finishSubwarpAt(hitX, hitY);
        return;
      }
    }

    if (_transitTimeRemaining <= 0) {
      final planned = _plannedSubwarpArrival!;
      _currentShipX = planned.x;
      _currentShipY = planned.y;
      _finishSubwarpAt(planned.x, planned.y, plannedArrival: planned);
    }
  }

  void _finishSubwarpAt(
    double finalX,
    double finalY, {
    ArrivalCoordinates? plannedArrival,
  }) {
    _inSubwarpTransit = false;
    _transitTimeRemaining = 0;

    final targetNode = _targetNode!;
    final distFromTarget = math.sqrt(
      math.pow(finalX - targetNode.x, 2) + math.pow(finalY - targetNode.y, 2),
    );
    final arrival = plannedArrival ??
        ArrivalCoordinates(
          x: finalX,
          y: finalY,
          scatterDistance: distFromTarget,
          computedAccuracy: _wasInterceptedMidTransit ? 0.0 : 1.0,
        );

    _completeTranslation(
      arrival: arrival,
      wake: _lastWake!,
      strandedDroneCount: _pendingStrandedDrones,
      fighterResult: _pendingStrandedFighters ??
          const FighterStrandingResult(
            rendezvousCount: 0,
            scrambleCount: 0,
            lastStandCount: 0,
          ),
    );
  }

  void _completeTranslation({
    required ArrivalCoordinates arrival,
    required WarpWake wake,
    required int strandedDroneCount,
    required FighterStrandingResult fighterResult,
  }) {
    _currentShipX = arrival.x;
    _currentShipY = arrival.y;

    economy.teleportSeekingDronesTo(arrival.x, arrival.y);
    fighterRoster.teleportPilotedFightersTo(arrival.x, arrival.y);

    final targetNode = _targetNode;
    _currentDockedNode =
        (targetNode != null && targetNode.containsPoint(arrival.x, arrival.y))
            ? targetNode
            : null;

    _state = WarpState.warping;
    onWarpComplete?.call(WarpCompleteResult(
      dronesStranded: strandedDroneCount,
      fightersStranded: fighterResult,
      arrival: arrival,
      wake: wake,
      wasInterceptedMidTransit: _wasInterceptedMidTransit,
      collidedAnomaly: _collidedAnomaly,
    ));

    _state = WarpState.arriving;
    _arrivingRemaining = navConfig.arrivingDuration;
  }
}
