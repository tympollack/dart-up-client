// =============================================================================
// drone_swarm_economy.dart
//
// Pure-Dart "Deploy, hack, extract, and refit-recharge" resource economy for a
// finite drone fleet.
// Zero Flutter or Flame imports.
//
// Constraints:
// - Strictly no spatial zones, buildings, or pathfinding logic for refitting.
// - `needsRefit` is handled strictly as a data-level flag and a configurable
//   timing penalty (`refitRemainingSeconds`) inside the existing docking flow.
// =============================================================================

import 'dart:math' as math;
import 'dart:typed_data';

/// Per-drone spatial/movement mode while in the Deployed pool.
class DroneMode {
  /// Active operational drone under player command.
  static const int seeking = 0;

  /// Recalled: steering back toward the player ship's live coordinates.
  static const int returning = 1;

  /// Left behind in deep space after an emergency warp.
  static const int stranded = 2;

  /// Hijacked/hacked drone extracting back toward the player ship with
  /// damaged-thruster wobble and `needsRefit = true`.
  static const int hacked = 3;
}

/// Pure-Dart state machine for the Drone Extraction & Refit lifecycle.
enum DroneExtractionState {
  idle,
  tethering,
  extracting,
  dockedRefitting,
  operational,
}

/// Domain event categories emitted during the drone extraction & refit lifecycle.
enum DroneExtractionEventType {
  extractionStarted,
  refitStarted,
  refitCompleted,
  extractionInterrupted,
}

/// Structured domain event emitted on extraction start, refit start/completion,
/// or extraction interruption.
class DroneExtractionEvent {
  final DroneExtractionEventType type;
  final int droneId;
  final DroneExtractionState state;
  final bool needsRefit;
  final double refitRemainingSeconds;
  final double timestamp;
  final String? reason;

  const DroneExtractionEvent({
    required this.type,
    required this.droneId,
    required this.state,
    required this.needsRefit,
    required this.refitRemainingSeconds,
    required this.timestamp,
    this.reason,
  });

  @override
  String toString() =>
      'DroneExtractionEvent($type, id: $droneId, state: $state, '
      'needsRefit: $needsRefit, refitRemaining: ${refitRemainingSeconds.toStringAsFixed(2)}s)';
}

/// Tunables that tech upgrades mutate at runtime.
class DeploymentConfig {
  int batchSize;
  double cooldownSeconds;
  double rechargeSeconds;
  double launchSpeed;
  double launchSpreadRadians;
  double arrivalRadius;
  double wobbleJitterPerSecond;
  double wobbleRestoringRate;
  double wobbleMaxAngle;
  double hackedSpeedMultiplier;

  /// Multiplier applied to [rechargeSeconds] when a drone docks with
  /// `needsRefit == true`.
  double refitRechargeMultiplier;

  /// Short initial tether lock window before a hacked drone begins moving.
  /// Defaults to 0.0 so existing immediate-extraction callers work seamlessly,
  /// or can be set > 0 to observe the `tethering -> extracting` transition.
  double tetherDurationSeconds;

  /// Per-drone offensive DPS output when operational.
  double baseOffensiveOutputPerSecond;

  /// Per-drone resource harvest rate when operational.
  double baseHarvestOutputPerSecond;

  DeploymentConfig({
    this.batchSize = 1,
    this.cooldownSeconds = 0.4,
    this.rechargeSeconds = 4.0,
    this.launchSpeed = 140.0,
    this.launchSpreadRadians = 0.35,
    this.arrivalRadius = 18.0,
    this.wobbleJitterPerSecond = 6.0,
    this.wobbleRestoringRate = 1.5,
    this.wobbleMaxAngle = math.pi / 3,
    this.hackedSpeedMultiplier = 0.7,
    this.refitRechargeMultiplier = 2.0,
    this.tetherDurationSeconds = 0.0,
    this.baseOffensiveOutputPerSecond = 8.0,
    this.baseHarvestOutputPerSecond = 5.0,
  });

  /// Total refit duration in seconds for a hacked drone docking with `needsRefit`.
  double get refitDurationSeconds => rechargeSeconds * refitRechargeMultiplier;
}

/// Snapshot of a docked drone currently undergoing refit or recharge.
class DockedRefitSlot {
  final int droneId;
  bool needsRefit;
  DroneExtractionState extractionState;
  double refitRemainingSeconds;

  DockedRefitSlot({
    required this.droneId,
    required this.needsRefit,
    required this.extractionState,
    required this.refitRemainingSeconds,
  });

  bool get isOperational =>
      !needsRefit &&
      extractionState == DroneExtractionState.operational &&
      refitRemainingSeconds <= 0.0;
}

/// Owns the entire drone fleet's state machine. Allocates every array once,
/// at `maxFleetSize`, and never resizes them.
class DroneSwarmEconomy {
  DroneSwarmEconomy({
    required this.maxFleetSize,
    int? startingFleetSize,
    DeploymentConfig? config,
    int initialHealth = 100,
    this.onExtractionEvent,
    int? seed,
  })  : config = config ?? DeploymentConfig(),
        _maxHealth = initialHealth,
        _rng = seed != null ? math.Random(seed) : math.Random() {
    posX = Float32List(maxFleetSize);
    posY = Float32List(maxFleetSize);
    velX = Float32List(maxFleetSize);
    velY = Float32List(maxFleetSize);
    mode = Uint8List(maxFleetSize);
    health = Int16List(maxFleetSize);
    wobbleAngle = Float32List(maxFleetSize);
    needsRefit = Uint8List(maxFleetSize);
    droneIds = Int32List(maxFleetSize);
    tetherRemaining = Float32List(maxFleetSize);
    extractionStateIndex = Uint8List(maxFleetSize);

    rechargeReadyAt = Float64List(maxFleetSize);
    rechargingRemainingSeconds = Float64List(maxFleetSize);
    rechargingNeedsRefit = Uint8List(maxFleetSize);
    rechargingDroneIds = Int32List(maxFleetSize);

    availableCount = (startingFleetSize ?? maxFleetSize).clamp(0, maxFleetSize);
  }

  final int maxFleetSize;
  final DeploymentConfig config;
  final int _maxHealth;
  final math.Random _rng;

  /// Optional callback invoked whenever a [DroneExtractionEvent] occurs.
  final void Function(DroneExtractionEvent event)? onExtractionEvent;

  final List<DroneExtractionEvent> _extractionEvents = [];

  /// Immutable view of all emitted extraction/refit domain events.
  List<DroneExtractionEvent> get extractionEvents =>
      List.unmodifiable(_extractionEvents);

  int _nextDroneId = 1;

  // ---- Deployed pool: dense SoA, indices [0, deployedCount) ----
  late final Float32List posX;
  late final Float32List posY;
  late final Float32List velX;
  late final Float32List velY;
  late final Uint8List mode;
  late final Int16List health;
  late final Float32List wobbleAngle;

  /// Pure data-level flag: 0 = false, 1 = true.
  /// Set to 1 when a drone is acquired via hacking; read at dock-time to
  /// enforce `refitRemainingSeconds` penalty and suspend offensive/harvest
  /// output until refit completes.
  late final Uint8List needsRefit;

  late final Int32List droneIds;
  late final Float32List tetherRemaining;
  late final Uint8List extractionStateIndex;
  int deployedCount = 0;

  // ---- Available pool: pure count of operational drones ready to launch ----
  int availableCount = 0;

  // ---- Recharging / Docked Refitting pool: dense, unordered timers ----
  late final Float64List rechargeReadyAt;
  late final Float64List rechargingRemainingSeconds;
  late final Uint8List rechargingNeedsRefit;
  late final Int32List rechargingDroneIds;
  int rechargingCount = 0;

  // ---- Bookkeeping ----
  int permanentlyLostCount = 0;
  int completedRefitCount = 0;
  double _deployCooldownRemaining = 0;
  double _clockSeconds = 0;

  double get simulationClockSeconds => _clockSeconds;

  int get totalLivingFleet => availableCount + deployedCount + rechargingCount;
  bool get canDeploy => _deployCooldownRemaining <= 0 && availableCount > 0;

  /// Number of docked drones currently in [DroneExtractionState.dockedRefitting]
  /// with `needsRefit == true` and `refitRemainingSeconds > 0`.
  int get dockedRefittingCount {
    int count = 0;
    for (int i = 0; i < rechargingCount; i++) {
      if (rechargingNeedsRefit[i] == 1 && rechargingRemainingSeconds[i] > 0) {
        count++;
      }
    }
    return count;
  }

  /// Highest remaining refit time (seconds) among currently docked refitting
  /// drones, or 0.0 if none are refitting.
  double get refitRemainingSeconds {
    double maxRem = 0.0;
    for (int i = 0; i < rechargingCount; i++) {
      if (rechargingNeedsRefit[i] == 1 &&
          rechargingRemainingSeconds[i] > maxRem) {
        maxRem = rechargingRemainingSeconds[i];
      }
    }
    return maxRem;
  }

  /// Returns the [DroneExtractionState] of a deployed drone at [deployedIndex].
  DroneExtractionState extractionStateAt(int deployedIndex) =>
      DroneExtractionState.values[extractionStateIndex[deployedIndex]];

  /// Returns whether a deployed drone has `needsRefit == true`.
  bool isNeedsRefit(int deployedIndex) => needsRefit[deployedIndex] == 1;

  /// Returns true if and only if the deployed drone at [deployedIndex] is
  /// operational, seeking, and NOT flagged with `needsRefit`.
  /// Stolen/hacked drones cannot fire or harvest until their docked refit
  /// timer reaches 0 and they are redeployed as operational.
  bool canDroneFireOrHarvest(int deployedIndex) {
    if (deployedIndex < 0 || deployedIndex >= deployedCount) return false;
    if (needsRefit[deployedIndex] != 0) return false;
    if (mode[deployedIndex] != DroneMode.seeking) return false;
    return extractionStateAt(deployedIndex) == DroneExtractionState.operational;
  }

  /// Offensive output (DPS) for a deployed drone at [deployedIndex].
  /// Always 0.0 while `needsRefit == true` or non-operational.
  double offensiveOutputForDeployed(int deployedIndex) =>
      canDroneFireOrHarvest(deployedIndex)
          ? config.baseOffensiveOutputPerSecond
          : 0.0;

  /// Harvesting output (resources/s) for a deployed drone at [deployedIndex].
  /// Always 0.0 while `needsRefit == true` or non-operational.
  double harvestOutputForDeployed(int deployedIndex) =>
      canDroneFireOrHarvest(deployedIndex)
          ? config.baseHarvestOutputPerSecond
          : 0.0;

  /// Total fleet offensive output across all currently deployed operational drones.
  double get totalActiveOffensiveOutput {
    double sum = 0.0;
    for (int i = 0; i < deployedCount; i++) {
      if (canDroneFireOrHarvest(i)) {
        sum += config.baseOffensiveOutputPerSecond;
      }
    }
    return sum;
  }

  /// Total fleet harvesting output across all currently deployed operational drones.
  double get totalActiveHarvestOutput {
    double sum = 0.0;
    for (int i = 0; i < deployedCount; i++) {
      if (canDroneFireOrHarvest(i)) {
        sum += config.baseHarvestOutputPerSecond;
      }
    }
    return sum;
  }

  // ---------------------------------------------------------------------------
  // DEPLOY (Addition)
  // ---------------------------------------------------------------------------

  int tryDeploy({
    required double shipX,
    required double shipY,
    required double targetX,
    required double targetY,
  }) {
    if (_deployCooldownRemaining > 0) return 0;
    if (availableCount <= 0) return 0;

    final int freeSlots = maxFleetSize - deployedCount;
    if (freeSlots <= 0) return 0;

    final int n = math.min(config.batchSize, math.min(availableCount, freeSlots));
    for (int k = 0; k < n; k++) {
      _spawnOne(shipX, shipY, targetX, targetY);
    }
    availableCount -= n;
    _deployCooldownRemaining = config.cooldownSeconds;
    return n;
  }

  void _spawnOne(double shipX, double shipY, double targetX, double targetY) {
    final int i = deployedCount;

    posX[i] = shipX;
    posY[i] = shipY;

    final double dx = targetX - shipX;
    final double dy = targetY - shipY;
    double angle = math.atan2(dy, dx);
    angle += (_rng.nextDouble() * 2 - 1) * config.launchSpreadRadians;

    velX[i] = math.cos(angle) * config.launchSpeed;
    velY[i] = math.sin(angle) * config.launchSpeed;

    mode[i] = DroneMode.seeking;
    health[i] = _maxHealth;
    wobbleAngle[i] = 0;
    needsRefit[i] = 0;
    droneIds[i] = _nextDroneId++;
    tetherRemaining[i] = 0.0;
    extractionStateIndex[i] = DroneExtractionState.operational.index;

    deployedCount++;
  }

  /// Spawns a derelict/stranded enemy drone directly at `(x, y)` for heist/hack
  /// scenarios without consuming from the player's own `availableCount`.
  /// Returns `-1` if the fleet buffers (`totalLivingFleet >= maxFleetSize`) are at capacity.
  int spawnStrandedEnemyDrone(double x, double y, {int? healthOverride}) {
    if (totalLivingFleet >= maxFleetSize || deployedCount >= maxFleetSize) {
      return -1;
    }
    final int i = deployedCount;
    posX[i] = x;
    posY[i] = y;
    velX[i] = 0.0;
    velY[i] = 0.0;
    mode[i] = DroneMode.stranded;
    health[i] = healthOverride ?? _maxHealth;
    wobbleAngle[i] = 0.0;
    needsRefit[i] = 1;
    droneIds[i] = _nextDroneId++;
    tetherRemaining[i] = 0.0;
    extractionStateIndex[i] = DroneExtractionState.idle.index;
    deployedCount++;
    return i;
  }

  /// Adds reserve drones directly to [availableCount] up to [maxFleetSize],
  /// e.g. from friendly audience supply crate drops. Returns the number of drones added.
  int replenishReserves(int count) {
    if (count <= 0) return 0;
    final int room = math.max(0, maxFleetSize - totalLivingFleet);
    final int toAdd = math.min(count, room);
    availableCount += toAdd;
    return toAdd;
  }

  // ---------------------------------------------------------------------------
  // RECALL (begin Return)
  // ---------------------------------------------------------------------------

  void recallAll() {
    for (int i = 0; i < deployedCount; i++) {
      if (mode[i] == DroneMode.seeking) {
        mode[i] = DroneMode.returning;
      }
    }
  }

  void recallOne(int deployedIndex) {
    if (mode[deployedIndex] == DroneMode.seeking) {
      mode[deployedIndex] = DroneMode.returning;
    }
  }

  // ---------------------------------------------------------------------------
  // HEIST, EXTRACTION & ESCAPE
  // ---------------------------------------------------------------------------

  void teleportSeekingDronesTo(double x, double y) {
    for (int i = 0; i < deployedCount; i++) {
      if (mode[i] == DroneMode.seeking) {
        posX[i] = x;
        posY[i] = y;
        velX[i] = 0;
        velY[i] = 0;
      }
    }
  }

  /// Emergency warp: any drone still mid-flight home (`returning` or `hacked`)
  /// is left behind as `stranded`. Hacked drones in extraction emit an
  /// `extractionInterrupted` domain event.
  int strandUnreturnedDrones() {
    int strandedNow = 0;
    for (int i = 0; i < deployedCount; i++) {
      if (mode[i] == DroneMode.returning || mode[i] == DroneMode.hacked) {
        final bool wasExtracting = mode[i] == DroneMode.hacked;
        mode[i] = DroneMode.stranded;
        velX[i] = 0;
        velY[i] = 0;
        tetherRemaining[i] = 0;
        extractionStateIndex[i] = DroneExtractionState.idle.index;
        strandedNow++;

        if (wasExtracting) {
          _emitEvent(
            type: DroneExtractionEventType.extractionInterrupted,
            droneId: droneIds[i],
            state: DroneExtractionState.idle,
            needsRefit: needsRefit[i] == 1,
            refitRemainingSeconds: 0.0,
            reason: 'emergency_warp_stranded',
          );
        }
      }
    }
    return strandedNow;
  }

  int countAtRiskOfStranding() {
    int count = 0;
    for (int i = 0; i < deployedCount; i++) {
      if (mode[i] == DroneMode.returning || mode[i] == DroneMode.hacked) {
        count++;
      }
    }
    return count;
  }

  /// Hacks all `stranded` drones within `hackRadius` of `(hackX, hackY)`.
  /// Sets `needsRefit = true` (`1`), transitions them into the extraction
  /// phase (`tethering` if `config.tetherDurationSeconds > 0`, otherwise
  /// directly `extracting`), and emits `extractionStarted` domain events.
  int hackStrandedDrones(double hackX, double hackY, double hackRadius) {
    final double radiusSq = hackRadius * hackRadius;
    int hackedNow = 0;

    for (int i = 0; i < deployedCount; i++) {
      if (mode[i] != DroneMode.stranded) continue;

      final double dx = posX[i] - hackX;
      final double dy = posY[i] - hackY;
      if (dx * dx + dy * dy > radiusSq) continue;

      mode[i] = DroneMode.hacked;
      wobbleAngle[i] = (_rng.nextDouble() * 2 - 1) * config.wobbleMaxAngle;
      needsRefit[i] = 1;
      tetherRemaining[i] = config.tetherDurationSeconds;

      final initialState = config.tetherDurationSeconds > 0
          ? DroneExtractionState.tethering
          : DroneExtractionState.extracting;
      extractionStateIndex[i] = initialState.index;
      hackedNow++;

      _emitEvent(
        type: DroneExtractionEventType.extractionStarted,
        droneId: droneIds[i],
        state: initialState,
        needsRefit: true,
        refitRemainingSeconds: config.refitDurationSeconds,
      );
    }

    return hackedNow;
  }

  /// Interrupts an in-progress extraction on a specific deployed drone index,
  /// returning it to `stranded` (`DroneExtractionState.idle`) and emitting
  /// `extractionInterrupted`.
  bool interruptExtraction(int deployedIndex, {String reason = 'interrupted'}) {
    if (deployedIndex < 0 || deployedIndex >= deployedCount) return false;
    if (mode[deployedIndex] != DroneMode.hacked) return false;

    mode[deployedIndex] = DroneMode.stranded;
    velX[deployedIndex] = 0.0;
    velY[deployedIndex] = 0.0;
    tetherRemaining[deployedIndex] = 0.0;
    extractionStateIndex[deployedIndex] = DroneExtractionState.idle.index;

    _emitEvent(
      type: DroneExtractionEventType.extractionInterrupted,
      droneId: droneIds[deployedIndex],
      state: DroneExtractionState.idle,
      needsRefit: needsRefit[deployedIndex] == 1,
      refitRemainingSeconds: 0.0,
      reason: reason,
    );
    return true;
  }

  // ---------------------------------------------------------------------------
  // COMBAT LOSS
  // ---------------------------------------------------------------------------

  bool applyDamage(int deployedIndex, int amount) {
    health[deployedIndex] -= amount;
    if (health[deployedIndex] <= 0) {
      destroyDeployed(deployedIndex);
      return true;
    }
    return false;
  }

  void destroyDeployed(int deployedIndex) {
    if (mode[deployedIndex] == DroneMode.hacked) {
      _emitEvent(
        type: DroneExtractionEventType.extractionInterrupted,
        droneId: droneIds[deployedIndex],
        state: DroneExtractionState.idle,
        needsRefit: needsRefit[deployedIndex] == 1,
        refitRemainingSeconds: 0.0,
        reason: 'destroyed_in_combat',
      );
    }
    _swapRemoveDeployed(deployedIndex);
    permanentlyLostCount++;
  }

  // ---------------------------------------------------------------------------
  // PER-FRAME UPDATE
  // ---------------------------------------------------------------------------

  void update(double dt, {required double shipX, required double shipY}) {
    if (_deployCooldownRemaining > 0) {
      _deployCooldownRemaining -= dt;
    }

    final double arrivalRadiusSq = config.arrivalRadius * config.arrivalRadius;

    for (int i = deployedCount - 1; i >= 0; i--) {
      final int m = mode[i];

      if (m == DroneMode.stranded) continue;
      if (m != DroneMode.returning && m != DroneMode.hacked) continue;

      double moveDt = dt;
      if (m == DroneMode.hacked && tetherRemaining[i] > 0) {
        tetherRemaining[i] -= dt;
        if (tetherRemaining[i] > 0) {
          extractionStateIndex[i] = DroneExtractionState.tethering.index;
          continue;
        }
        moveDt = -tetherRemaining[i];
        tetherRemaining[i] = 0.0;
        extractionStateIndex[i] = DroneExtractionState.extracting.index;
        if (moveDt <= 0.0) continue;
      }

      final double dx = shipX - posX[i];
      final double dy = shipY - posY[i];
      final double distSq = dx * dx + dy * dy;

      if (distSq <= arrivalRadiusSq) {
        _dock(i);
        continue;
      }

      double headingAngle = math.atan2(dy, dx);
      double speed = config.launchSpeed;

      if (m == DroneMode.hacked) {
        extractionStateIndex[i] = DroneExtractionState.extracting.index;
        double w = wobbleAngle[i];
        w += (_rng.nextDouble() * 2 - 1) *
            config.wobbleJitterPerSecond *
            moveDt;
        w -= w * config.wobbleRestoringRate * moveDt;
        if (w > config.wobbleMaxAngle) {
          w = config.wobbleMaxAngle;
        } else if (w < -config.wobbleMaxAngle) {
          w = -config.wobbleMaxAngle;
        }
        wobbleAngle[i] = w;

        headingAngle += w;
        speed *= config.hackedSpeedMultiplier;
      }

      velX[i] = math.cos(headingAngle) * speed;
      velY[i] = math.sin(headingAngle) * speed;
      posX[i] += velX[i] * moveDt;
      posY[i] += velY[i] * moveDt;
    }

    // Advance clock and tick recharge / refit timers
    _clockSeconds += dt;
    for (int i = rechargingCount - 1; i >= 0; i--) {
      rechargingRemainingSeconds[i] =
          math.max(0.0, rechargeReadyAt[i] - _clockSeconds);
      if (_clockSeconds + 1e-9 >= rechargeReadyAt[i]) {
        final bool wasRefit = rechargingNeedsRefit[i] == 1;
        final int completedDroneId = rechargingDroneIds[i];
        _swapRemoveRecharging(i);
        availableCount++;

        if (wasRefit) {
          completedRefitCount++;
          _emitEvent(
            type: DroneExtractionEventType.refitCompleted,
            droneId: completedDroneId,
            state: DroneExtractionState.operational,
            needsRefit: false,
            refitRemainingSeconds: 0.0,
          );
        }
      }
    }
  }

  void _dock(int deployedIndex) {
    final bool requiresRefit = needsRefit[deployedIndex] == 1;
    final int dId = droneIds[deployedIndex];
    double duration = config.rechargeSeconds;
    if (requiresRefit) {
      duration *= config.refitRechargeMultiplier;
    }

    final int slot = rechargingCount;
    rechargeReadyAt[slot] = _clockSeconds + duration;
    rechargingRemainingSeconds[slot] = duration;
    rechargingNeedsRefit[slot] = requiresRefit ? 1 : 0;
    rechargingDroneIds[slot] = dId;
    rechargingCount++;

    _swapRemoveDeployed(deployedIndex);

    if (requiresRefit) {
      _emitEvent(
        type: DroneExtractionEventType.refitStarted,
        droneId: dId,
        state: DroneExtractionState.dockedRefitting,
        needsRefit: true,
        refitRemainingSeconds: duration,
      );
    }
  }

  void _emitEvent({
    required DroneExtractionEventType type,
    required int droneId,
    required DroneExtractionState state,
    required bool needsRefit,
    required double refitRemainingSeconds,
    String? reason,
  }) {
    final event = DroneExtractionEvent(
      type: type,
      droneId: droneId,
      state: state,
      needsRefit: needsRefit,
      refitRemainingSeconds: refitRemainingSeconds,
      timestamp: _clockSeconds,
      reason: reason,
    );
    _extractionEvents.add(event);
    onExtractionEvent?.call(event);
  }

  void _swapRemoveDeployed(int index) {
    final int last = deployedCount - 1;
    if (index != last) {
      posX[index] = posX[last];
      posY[index] = posY[last];
      velX[index] = velX[last];
      velY[index] = velY[last];
      mode[index] = mode[last];
      health[index] = health[last];
      wobbleAngle[index] = wobbleAngle[last];
      needsRefit[index] = needsRefit[last];
      droneIds[index] = droneIds[last];
      tetherRemaining[index] = tetherRemaining[last];
      extractionStateIndex[index] = extractionStateIndex[last];
    }
    deployedCount--;
  }

  void _swapRemoveRecharging(int index) {
    final int last = rechargingCount - 1;
    if (index != last) {
      rechargeReadyAt[index] = rechargeReadyAt[last];
      rechargingRemainingSeconds[index] = rechargingRemainingSeconds[last];
      rechargingNeedsRefit[index] = rechargingNeedsRefit[last];
      rechargingDroneIds[index] = rechargingDroneIds[last];
    }
    rechargingCount--;
  }
}
