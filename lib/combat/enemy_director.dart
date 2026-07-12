// =============================================================================
// enemy_director.dart
//
// Pure Dart, engine-agnostic global AI manager. Owns a roster of enemy
// squads (SoA, same conventions as everywhere else in this project) and
// periodically reads the player's ShipWarpController's wake through
// warp_wake_tracking.dart's readWake(). No Flutter/Flame imports.
//
// A note on what "the AI knows": readWake()'s zone/blind/pinpoint split
// exists to control what a UI is allowed to *display* without cheating.
// The Director is not a UI -- it's the simulation's own authority on
// where the wake actually is (it has wake.x/wake.y directly, the same way
// DroneSwarmEconomy has direct access to every drone's real position).
// So "Investigate" doesn't mean the Director is guessing blindly; it
// means the Director deliberately adds randomized imprecision (scaled by
// zoneOfProbabilityRadius) to where it sends a squad, because that radius
// IS the fiction's measure of "how good was this read." A UI bound to the
// same TrackingResult, by contrast, should never be handed wake.x/y at
// all -- only the radius -- which is a decision made by whatever code is
// driving that UI, not by this file.
// =============================================================================

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:sd_client/celestial/celestial_node_manager.dart';
import 'package:sd_client/combat/fighter_roster.dart';
import 'package:sd_client/player/ship_warp_controller.dart';
import 'package:sd_client/player/warp_wake_tracking.dart';

class EnemySquadState {
  /// Wandering between celestial nodes, no current lead.
  static const int patrol = 0;
  /// Vectoring toward a randomized point within the last sweep's
  /// zoneOfProbability.
  static const int investigate = 1;
  /// Locked on -- either a pinpoint sweep or a physical proximity
  /// breach. Fighters have been spawned; the squad now pursues the
  /// player's live position directly.
  static const int engage = 2;
}

/// Tunables. Same DeploymentConfig-style bundling as everywhere else.
class EnemyDirectorConfig {
  /// How often the Director performs a sensor sweep, in seconds.
  double sweepIntervalSeconds;
  /// Physical detection radius, independent of the wake/sensor system --
  /// a squad this close to the player engages regardless of what the
  /// last sweep said.
  double engageProximityRadius;
  double patrolSpeed;
  double investigateSpeed;
  double engageSpeed;
  /// How close a patrolling squad needs to get to its waypoint before
  /// picking a new random node to wander to.
  double patrolArrivalRadius;
  /// Fighters spawned into the enemy roster the instant a squad engages.
  int fightersPerSquadOnEngage;

  EnemyDirectorConfig({
    this.sweepIntervalSeconds = 4.0,
    this.engageProximityRadius = 250.0,
    this.patrolSpeed = 80.0,
    this.investigateSpeed = 120.0,
    this.engageSpeed = 160.0,
    this.patrolArrivalRadius = 50.0,
    this.fightersPerSquadOnEngage = 3,
  });
}

class EnemyDirector {
  EnemyDirector({
    required this.maxSquadCount,
    required this.nodeManager,
    required this.enemyFighterRoster,
    required this.playerShipController,
    this.sensorTechTier = 1,
    this.trackingTech = 1.0,
    EnemyDirectorConfig? config,
    this.onSquadEngaged,
    this.onSweepCompleted,
  }) : config = config ?? EnemyDirectorConfig() {
    posX = Float32List(maxSquadCount);
    posY = Float32List(maxSquadCount);
    targetX = Float32List(maxSquadCount);
    targetY = Float32List(maxSquadCount);
    state = Uint8List(maxSquadCount);
  }

  final int maxSquadCount;
  final CelestialNodeManager nodeManager;
  /// The Director's OWN fighter roster, for enemy combatants. Deliberately
  /// a separate instance from whatever FighterRoster the player's
  /// ShipWarpController owns -- player and enemy fighters should never
  /// share a pool.
  final FighterRoster enemyFighterRoster;
  final ShipWarpController playerShipController;
  final EnemyDirectorConfig config;

  /// 0 = no sensors (always Blind). Mutable -- a "Director escalation"
  /// difficulty curve can raise this over time.
  int sensorTechTier;
  /// Fed into the SensorModule built for each sweep, alongside
  /// sensorTechTier.
  double trackingTech;

  final math.Random _rng = math.Random();

  // ---- Squad state: dense SoA, same conventions as everywhere else. ----
  late final Float32List posX;
  late final Float32List posY;
  late final Float32List targetX;
  late final Float32List targetY;
  /// EnemySquadState.*
  late final Uint8List state;
  int squadCount = 0;

  double _sweepCooldown = 0;
  double _lastPlayerX = 0;
  double _lastPlayerY = 0;
  TrackingResult? _lastSweepResult;

  /// Fires once, the instant a squad transitions into Engage (from
  /// either a pinpoint sweep or a proximity breach) -- the moment
  /// fighters get spawned. Carries the squad's index.
  final void Function(int squadIndex)? onSquadEngaged;
  /// Fires once per completed sweep, regardless of outcome -- hook your
  /// "threat level" UI here rather than polling lastSweepResult if you'd
  /// rather react than poll.
  final void Function(TrackingResult result)? onSweepCompleted;

  /// Polling equivalent of onSweepCompleted -- the most recent sweep's
  /// result, or null if no sweep has run yet (e.g. the player hasn't
  /// jumped, so there's no wake to read at all).
  TrackingResult? get lastSweepResult => _lastSweepResult;

  /// Indices (into this Director's own dense arrays) of squads currently
  /// in `squadState` -- same on-demand pattern as
  /// FighterRoster.indicesInState(), appropriate at this scale (squads,
  /// not swarms).
  List<int> squadsInState(int squadState) {
    final List<int> result = [];
    for (int i = 0; i < squadCount; i++) {
      if (state[i] == squadState) result.add(i);
    }
    return result;
  }

  /// Registers a new squad at (x, y), starting in Patrol with a random
  /// waypoint already assigned. Returns its index.
  int spawnSquad(double x, double y) {
    final int i = squadCount;
    posX[i] = x;
    posY[i] = y;
    state[i] = EnemySquadState.patrol;
    squadCount++;
    _assignNewPatrolWaypoint(i);
    return i;
  }

  /// Combat loss hook, mirroring DroneSwarmEconomy.destroyDeployed() /
  /// FighterRoster.destroyFighter(). Not called by anything in this file
  /// yet -- this is the extension point for whenever you build squad
  /// defeat.
  void destroySquad(int index) {
    final int last = squadCount - 1;
    if (index != last) {
      posX[index] = posX[last];
      posY[index] = posY[last];
      targetX[index] = targetX[last];
      targetY[index] = targetY[last];
      state[index] = state[last];
    }
    squadCount--;
  }

  // ---------------------------------------------------------------------------
  // Per-frame update
  // ---------------------------------------------------------------------------

  void update(double dt, {required double playerX, required double playerY}) {
    _lastPlayerX = playerX;
    _lastPlayerY = playerY;

    _moveSquadsTowardTargets(dt);
    _checkPatrolArrivals();
    _checkProximityBreaches();

    if (enemyFighterRoster.activeCount > 0) {
      // Every fighter in THIS roster exists to hunt the player -- no
      // per-squad bookkeeping needed to know who should retarget.
      enemyFighterRoster.retargetAllTo(_lastPlayerX, _lastPlayerY);
    }

    _sweepCooldown -= dt;
    if (_sweepCooldown <= 0) {
      _performSweep();
      _sweepCooldown = config.sweepIntervalSeconds;
    }
  }

  void _moveSquadsTowardTargets(double dt) {
    for (int i = 0; i < squadCount; i++) {
      final double speed = _speedForState(state[i]);
      final double dx = targetX[i] - posX[i];
      final double dy = targetY[i] - posY[i];
      final double dist = math.sqrt(dx * dx + dy * dy);
      if (dist < 1e-3) continue;
      final double step = math.min(speed * dt, dist);
      posX[i] += dx / dist * step;
      posY[i] += dy / dist * step;
    }
  }

  double _speedForState(int s) {
    switch (s) {
      case EnemySquadState.investigate:
        return config.investigateSpeed;
      case EnemySquadState.engage:
        return config.engageSpeed;
      default:
        return config.patrolSpeed;
    }
  }

  void _checkPatrolArrivals() {
    final double arrivalSq = config.patrolArrivalRadius * config.patrolArrivalRadius;
    for (int i = 0; i < squadCount; i++) {
      if (state[i] != EnemySquadState.patrol) continue;
      final double dx = targetX[i] - posX[i];
      final double dy = targetY[i] - posY[i];
      if (dx * dx + dy * dy <= arrivalSq) {
        _assignNewPatrolWaypoint(i);
      }
    }
  }

  void _assignNewPatrolWaypoint(int i) {
    final List<CelestialNode> nodes = nodeManager.nodes;
    if (nodes.isEmpty) return; // nowhere to wander to -- squad just holds
    final CelestialNode node = nodes[_rng.nextInt(nodes.length)];
    targetX[i] = node.x;
    targetY[i] = node.y;
  }

  /// Physical detection, independent of the wake/sensor system entirely
  /// -- checked every tick, not gated by the sweep interval.
  void _checkProximityBreaches() {
    final double radiusSq = config.engageProximityRadius * config.engageProximityRadius;
    for (int i = 0; i < squadCount; i++) {
      if (state[i] == EnemySquadState.engage) continue;
      final double dx = _lastPlayerX - posX[i];
      final double dy = _lastPlayerY - posY[i];
      if (dx * dx + dy * dy <= radiusSq) {
        targetX[i] = _lastPlayerX;
        targetY[i] = _lastPlayerY;
        _setState(i, EnemySquadState.engage);
      }
    }
  }

  void _setState(int i, int newState) {
    final int previous = state[i];
    state[i] = newState;
    if (newState == EnemySquadState.engage && previous != EnemySquadState.engage) {
      _spawnEngageFighters(i);
      onSquadEngaged?.call(i);
    }
  }

  void _spawnEngageFighters(int squadIndex) {
    for (int k = 0; k < config.fightersPerSquadOnEngage; k++) {
      enemyFighterRoster.spawnFighter(
        posX[squadIndex],
        posY[squadIndex],
        targetX: _lastPlayerX,
        targetY: _lastPlayerY,
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Sensor sweep -- the hunt
  // ---------------------------------------------------------------------------

  /// One global sweep, applied to every non-Engage squad at once
  /// (representing the hunting fleet sharing intel from Director HQ).
  /// Engaged squads ignore further sweeps entirely -- they've already
  /// physically found the player, sensor uncertainty is no longer
  /// relevant to them.
  void _performSweep() {
    final WarpWake? wake = playerShipController.lastWake;
    if (wake == null) return; // the player has never jumped -- nothing to read

    final double timeSinceJump =
        playerShipController.simulationTime - wake.timestamp;
    final SensorModule sensor =
        SensorModule(tier: sensorTechTier, trackingTech: trackingTech);

    // Rule 5: if the player is currently docked at a NebulaNode, its
    // obscurityMultiplier crushes the computed signal directly, via the
    // multiplier readWake() already accepts for exactly this. Resolved
    // fresh every sweep from ground truth (currentDockedNode) rather
    // than by temporarily mutating shipEcm and having to remember to
    // revert it -- this can never get "stuck" boosted.
    final CelestialNode? dockedNode = playerShipController.currentDockedNode;
    final double obscurityMultiplier =
        dockedNode is NebulaNode ? dockedNode.obscurityMultiplier : 1.0;

    final TrackingResult result = readWake(
      wake: wake,
      sensor: sensor,
      timeSinceJump: timeSinceJump,
      readerX: _fleetCentroidX(),
      readerY: _fleetCentroidY(),
      obscurityMultiplier: obscurityMultiplier,
    );

    _lastSweepResult = result;
    onSweepCompleted?.call(result);

    for (int i = 0; i < squadCount; i++) {
      if (state[i] == EnemySquadState.engage) continue;

      switch (result.outcome) {
        case TrackingOutcome.blind:
          if (state[i] == EnemySquadState.investigate) {
            // Trail went cold -- give up and resume patrol.
            _setState(i, EnemySquadState.patrol);
            _assignNewPatrolWaypoint(i);
          }
          break;

        case TrackingOutcome.zone:
          // Use the wake's REAL position (this file has direct access to
          // it, same as any other simulation-owning code) plus a random
          // offset scaled by the zone radius -- the radius IS the
          // fiction's measure of search imprecision, not a reason to
          // withhold the center from the AI itself.
          final double angle = _rng.nextDouble() * 2 * math.pi;
          final double radius = result.zoneOfProbabilityRadius! * _rng.nextDouble();
          targetX[i] = wake.x + math.cos(angle) * radius;
          targetY[i] = wake.y + math.sin(angle) * radius;
          _setState(i, EnemySquadState.investigate);
          break;

        case TrackingOutcome.pinpoint:
          // Strong lock -- go straight for the player's live position,
          // not the (by now possibly stale) departure point.
          targetX[i] = _lastPlayerX;
          targetY[i] = _lastPlayerY;
          _setState(i, EnemySquadState.engage);
          break;
      }
    }
  }

  /// "Reader position" fed into readWake() for this Director-level
  /// sweep. Only affects TrackingResult.directionX/Y, which this file
  /// doesn't actually consume (squad targeting uses real positions
  /// directly, per the class doc) -- it matters only if you bind a UI to
  /// the SAME sweep result and want a directional hint from "the
  /// hunting fleet's" point of view specifically.
  double _fleetCentroidX() {
    if (squadCount == 0) return 0;
    double sum = 0;
    for (int i = 0; i < squadCount; i++) sum += posX[i];
    return sum / squadCount;
  }

  double _fleetCentroidY() {
    if (squadCount == 0) return 0;
    double sum = 0;
    for (int i = 0; i < squadCount; i++) sum += posY[i];
    return sum / squadCount;
  }
}
