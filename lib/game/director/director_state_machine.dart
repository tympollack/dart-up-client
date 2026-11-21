// =============================================================================
// director_state_machine.dart
//
// Automated Multi-Camera Director State Machine for Dart Up! replays and live
// spectator feeds.
//
// Features:
// 1. Dynamic dolly-zoom bounding boxes framing active dogfights, Star Dart
//    ambushes, and warp chases with velocity lead offsets.
// 2. Exponential spring-damped camera pan and zoom transitions.
// 3. Strict 4.0-second minimum shot hold guard (anti-whip cooldown) preventing
//    camera target oscillation unless a `critical_climax` override event fires
//    (hull < 10% critical save or Star Dart capture/ambush).
// 4. Slow-motion climax time-scale modulation (`timeScale = 0.35` on climax).
// =============================================================================

import 'dart:math' as math;

import 'package:sd_client/simulation/telemetry/telemetry_ring_buffer.dart';

/// Camera framing modes selected by [DirectorStateMachine].
enum DirectorCameraMode {
  /// Wide sector overview when action is dispersed.
  sectorOverview,

  /// Tight dynamic framing around an active multi-ship dogfight.
  dogfightCluster,

  /// High-priority framing around a crippled or tethered Star Dart ambush.
  starDartAmbush,

  /// Directional framing with strong velocity lead offset for a Subwarp/FTL chase.
  warpChase,

  /// Dramatic close-up framing triggered by a `critical_climax` event.
  criticalClimaxCloseUp,
}

/// Reason a camera cut occurred.
enum DirectorCutReason {
  initialLock,
  scheduledCooldownExpired,
  criticalClimaxHullSave,
  criticalClimaxStarDartCapture,
}

/// Snapshot of a tracked entity passed into [DirectorStateMachine.evaluateFrame].
class DirectorEntityTarget {
  final int entityId;
  final double x;
  final double y;
  final double vx;
  final double vy;
  final double hull;
  final double maxHull;
  final bool isStarDartBoss;
  final bool isStarDartTetheredOrCaptured;
  final bool isInWarpChase;
  final double recentCombatDamage;

  const DirectorEntityTarget({
    required this.entityId,
    required this.x,
    required this.y,
    required this.vx,
    required this.vy,
    this.hull = 100.0,
    this.maxHull = 100.0,
    this.isStarDartBoss = false,
    this.isStarDartTetheredOrCaptured = false,
    this.isInWarpChase = false,
    this.recentCombatDamage = 0.0,
  });

  double get hullFraction =>
      maxHull > 0 ? (hull / maxHull).clamp(0.0, 1.0) : 1.0;
}

/// World-space bounding box framed by the Director camera.
class DirectorBoundingBox {
  final double left;
  final double top;
  final double right;
  final double bottom;

  const DirectorBoundingBox({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  double get width => math.max(1.0, right - left);
  double get height => math.max(1.0, bottom - top);
  double get centerX => (left + right) * 0.5;
  double get centerY => (top + bottom) * 0.5;
}

/// Record of a camera target switch emitted by [DirectorStateMachine].
class DirectorCutEvent {
  final double timestamp;
  final int previousPrimaryEntityId;
  final int newPrimaryEntityId;
  final double shotHoldDurationSeconds;
  final DirectorCameraMode mode;
  final DirectorCutReason reason;
  final bool isCriticalClimaxOverride;

  const DirectorCutEvent({
    required this.timestamp,
    required this.previousPrimaryEntityId,
    required this.newPrimaryEntityId,
    required this.shotHoldDurationSeconds,
    required this.mode,
    required this.reason,
    required this.isCriticalClimaxOverride,
  });
}

/// Computed camera transform for a single frame.
class DirectorCameraFrame {
  final double timestamp;
  final int primaryEntityId;
  final int? secondaryEntityId;
  final DirectorCameraMode mode;
  final DirectorBoundingBox framingBox;
  final double cameraX;
  final double cameraY;
  final double velocityLeadOffsetX;
  final double velocityLeadOffsetY;
  final double zoom;
  final double timeScale;
  final double currentShotElapsedSeconds;

  const DirectorCameraFrame({
    required this.timestamp,
    required this.primaryEntityId,
    this.secondaryEntityId,
    required this.mode,
    required this.framingBox,
    required this.cameraX,
    required this.cameraY,
    required this.velocityLeadOffsetX,
    required this.velocityLeadOffsetY,
    required this.zoom,
    required this.timeScale,
    required this.currentShotElapsedSeconds,
  });
}

/// Configuration tunables for [DirectorStateMachine].
class DirectorConfig {
  /// Mandatory minimum hold time (`4.0s`) between non-climax camera cuts.
  final double minShotHoldSeconds;

  /// Seconds ahead to project entity velocity for camera lead offset.
  final double velocityLeadTimeSeconds;

  /// Maximum world-space distance for velocity lead projection.
  final double maxVelocityLeadDistance;

  /// Exponential position damping factor (higher = snappier pan).
  final double positionDampingLambda;

  /// Exponential zoom damping factor (higher = snappier dolly-zoom).
  final double zoomDampingLambda;

  /// Reference viewport width in world units at `zoom = 1.0`.
  final double referenceViewportWidth;

  /// Reference viewport height in world units at `zoom = 1.0`.
  final double referenceViewportHeight;

  /// Padding added around framed entities when computing the dolly-zoom bounding box.
  final double framingPaddingWorldUnits;

  /// Minimum allowed camera zoom (wide shot).
  final double minZoom;

  /// Maximum allowed camera zoom (tight close-up).
  final double maxZoom;

  /// Hull fraction threshold (`< 0.10` = `< 10%`) that qualifies a survival
  /// combat moment as a `critical_climax` override.
  final double criticalSaveHullThreshold;

  /// Slow-motion time scale applied during a `critical_climax` window.
  final double climaxSlowMotionTimeScale;

  /// Duration of slow-motion dilation when a climax triggers.
  final double climaxSlowMotionDurationSeconds;

  const DirectorConfig({
    this.minShotHoldSeconds = 4.0,
    this.velocityLeadTimeSeconds = 0.65,
    this.maxVelocityLeadDistance = 320.0,
    this.positionDampingLambda = 4.5,
    this.zoomDampingLambda = 3.2,
    this.referenceViewportWidth = 1920.0,
    this.referenceViewportHeight = 1080.0,
    this.framingPaddingWorldUnits = 240.0,
    this.minZoom = 0.45,
    this.maxZoom = 2.25,
    this.criticalSaveHullThreshold = 0.10,
    this.climaxSlowMotionTimeScale = 0.35,
    this.climaxSlowMotionDurationSeconds = 1.75,
  });
}

/// Automated Multi-Camera Director State Machine.
class DirectorStateMachine {
  DirectorStateMachine({
    this.config = const DirectorConfig(),
  });

  final DirectorConfig config;

  int _primaryEntityId = -1;
  int? _secondaryEntityId;
  DirectorCameraMode _mode = DirectorCameraMode.sectorOverview;

  double _lastCutTimestamp = 0.0;
  double _simulationTime = 0.0;
  bool _hasInitialLock = false;

  double _smoothedCameraX = 0.0;
  double _smoothedCameraY = 0.0;
  double _smoothedZoom = 1.0;

  double _climaxSlowMoRemaining = 0.0;
  final Set<int> _triggeredCriticalSaveEntities = <int>{};
  bool _triggeredStarDartCaptureClimax = false;

  final List<DirectorCutEvent> _cutHistory = <DirectorCutEvent>[];

  int get primaryEntityId => _primaryEntityId;
  int? get secondaryEntityId => _secondaryEntityId;
  DirectorCameraMode get mode => _mode;
  double get smoothedCameraX => _smoothedCameraX;
  double get smoothedCameraY => _smoothedCameraY;
  double get smoothedZoom => _smoothedZoom;
  double get lastCutTimestamp => _lastCutTimestamp;
  double get currentShotHoldSeconds =>
      _hasInitialLock ? math.max(0.0, _simulationTime - _lastCutTimestamp) : 0.0;

  List<DirectorCutEvent> get cutHistory => List.unmodifiable(_cutHistory);

  void reset() {
    _primaryEntityId = -1;
    _secondaryEntityId = null;
    _mode = DirectorCameraMode.sectorOverview;
    _lastCutTimestamp = 0.0;
    _simulationTime = 0.0;
    _hasInitialLock = false;
    _smoothedCameraX = 0.0;
    _smoothedCameraY = 0.0;
    _smoothedZoom = 1.0;
    _climaxSlowMoRemaining = 0.0;
    _triggeredCriticalSaveEntities.clear();
    _triggeredStarDartCaptureClimax = false;
    _cutHistory.clear();
  }

  /// Evaluates a single frame of live or replay entities and returns the
  /// smoothed [DirectorCameraFrame].
  ///
  /// Enforces the mandatory `4.0s` anti-whip shot hold guard unless a
  /// `critical_climax` event (hull `< 10%` save or Star Dart capture) fires.
  DirectorCameraFrame evaluateFrame({
    required double dt,
    required double timestamp,
    required List<DirectorEntityTarget> entities,
    bool forceCriticalClimaxHullSave = false,
    bool forceCriticalClimaxStarDartCapture = false,
    int? climaxTargetEntityId,
  }) {
    _simulationTime = timestamp;
    if (_climaxSlowMoRemaining > 0) {
      _climaxSlowMoRemaining = math.max(0.0, _climaxSlowMoRemaining - dt);
    }

    if (entities.isEmpty) {
      return DirectorCameraFrame(
        timestamp: timestamp,
        primaryEntityId: _primaryEntityId,
        secondaryEntityId: _secondaryEntityId,
        mode: _mode,
        framingBox: const DirectorBoundingBox(
          left: -500,
          top: -500,
          right: 500,
          bottom: 500,
        ),
        cameraX: _smoothedCameraX,
        cameraY: _smoothedCameraY,
        velocityLeadOffsetX: 0.0,
        velocityLeadOffsetY: 0.0,
        zoom: _smoothedZoom,
        timeScale: 1.0,
        currentShotElapsedSeconds: currentShotHoldSeconds,
      );
    }

    // 1. Check for critical_climax events (hull < 10% save or Star Dart capture)
    DirectorEntityTarget? climaxEntity;
    DirectorCutReason? climaxReason;

    if (forceCriticalClimaxStarDartCapture) {
      climaxEntity = _findEntityById(entities, climaxTargetEntityId) ??
          entities.first;
      climaxReason = DirectorCutReason.criticalClimaxStarDartCapture;
    } else if (forceCriticalClimaxHullSave) {
      climaxEntity = _findEntityById(entities, climaxTargetEntityId) ??
          entities.first;
      climaxReason = DirectorCutReason.criticalClimaxHullSave;
    } else {
      for (final entity in entities) {
        if (entity.isStarDartBoss &&
            entity.isStarDartTetheredOrCaptured &&
            !_triggeredStarDartCaptureClimax) {
          _triggeredStarDartCaptureClimax = true;
          climaxEntity = entity;
          climaxReason = DirectorCutReason.criticalClimaxStarDartCapture;
          break;
        }
        if (entity.hull > 0 &&
            entity.hullFraction < config.criticalSaveHullThreshold &&
            !_triggeredCriticalSaveEntities.contains(entity.entityId)) {
          _triggeredCriticalSaveEntities.add(entity.entityId);
          climaxEntity = entity;
          climaxReason = DirectorCutReason.criticalClimaxHullSave;
          break;
        }
        // Reset critical save latch if ship repairs back above 25% hull
        if (entity.hullFraction >= 0.25) {
          _triggeredCriticalSaveEntities.remove(entity.entityId);
        }
      }
    }

    // 2. Score all candidate entities by drama heuristics
    final ({
      DirectorEntityTarget primary,
      DirectorEntityTarget? secondary,
      DirectorCameraMode candidateMode,
    }) bestCandidate = _selectHighestDramaCandidate(entities);

    final bool hadInitialLock = _hasInitialLock;
    final double elapsedSinceLastCut =
        hadInitialLock ? (timestamp - _lastCutTimestamp) : double.infinity;

    // 3. Enforce 4.0s anti-whip guard unless critical_climax fires or initial lock
    if (!hadInitialLock) {
      _hasInitialLock = true;
      if (climaxEntity != null && climaxReason != null) {
        _primaryEntityId = climaxEntity.entityId;
        _secondaryEntityId =
            _findNearestNeighbor(entities, climaxEntity)?.entityId;
        _mode =
            climaxReason == DirectorCutReason.criticalClimaxStarDartCapture
                ? DirectorCameraMode.starDartAmbush
                : DirectorCameraMode.criticalClimaxCloseUp;
        _climaxSlowMoRemaining = config.climaxSlowMotionDurationSeconds;
        _lastCutTimestamp = timestamp;
        _cutHistory.add(
          DirectorCutEvent(
            timestamp: timestamp,
            previousPrimaryEntityId: -1,
            newPrimaryEntityId: _primaryEntityId,
            shotHoldDurationSeconds: 0.0,
            mode: _mode,
            reason: climaxReason,
            isCriticalClimaxOverride: true,
          ),
        );
      } else {
        _primaryEntityId = bestCandidate.primary.entityId;
        _secondaryEntityId = bestCandidate.secondary?.entityId;
        _mode = bestCandidate.candidateMode;
        _lastCutTimestamp = timestamp;
        _cutHistory.add(
          DirectorCutEvent(
            timestamp: timestamp,
            previousPrimaryEntityId: -1,
            newPrimaryEntityId: _primaryEntityId,
            shotHoldDurationSeconds: 0.0,
            mode: _mode,
            reason: DirectorCutReason.initialLock,
            isCriticalClimaxOverride: false,
          ),
        );
      }
    } else if (climaxEntity != null && climaxReason != null) {
      // Critical climax bypasses the 4.0s anti-whip cooldown immediately
      final int prevId = _primaryEntityId;
      _primaryEntityId = climaxEntity.entityId;
      _secondaryEntityId = _findNearestNeighbor(entities, climaxEntity)?.entityId;
      _mode = climaxReason == DirectorCutReason.criticalClimaxStarDartCapture
          ? DirectorCameraMode.starDartAmbush
          : DirectorCameraMode.criticalClimaxCloseUp;
      _climaxSlowMoRemaining = config.climaxSlowMotionDurationSeconds;

      if (prevId != _primaryEntityId) {
        _cutHistory.add(
          DirectorCutEvent(
            timestamp: timestamp,
            previousPrimaryEntityId: prevId,
            newPrimaryEntityId: _primaryEntityId,
            shotHoldDurationSeconds: math.max(0.0, elapsedSinceLastCut),
            mode: _mode,
            reason: climaxReason,
            isCriticalClimaxOverride: true,
          ),
        );
        _lastCutTimestamp = timestamp;
      }
    } else if (elapsedSinceLastCut >= config.minShotHoldSeconds) {
      // Normal cut allowed only when elapsed hold time >= 4.0s
      if (bestCandidate.primary.entityId != _primaryEntityId) {
        final int prevId = _primaryEntityId;
        _primaryEntityId = bestCandidate.primary.entityId;
        _secondaryEntityId = bestCandidate.secondary?.entityId;
        _mode = bestCandidate.candidateMode;
        _cutHistory.add(
          DirectorCutEvent(
            timestamp: timestamp,
            previousPrimaryEntityId: prevId,
            newPrimaryEntityId: _primaryEntityId,
            shotHoldDurationSeconds: elapsedSinceLastCut,
            mode: _mode,
            reason: DirectorCutReason.scheduledCooldownExpired,
            isCriticalClimaxOverride: false,
          ),
        );
        _lastCutTimestamp = timestamp;
      } else {
        _secondaryEntityId = bestCandidate.secondary?.entityId;
        _mode = bestCandidate.candidateMode;
      }
    }

    // Resolve current locked primary & secondary entities
    final DirectorEntityTarget lockedPrimary =
        _findEntityById(entities, _primaryEntityId) ?? entities.first;
    final DirectorEntityTarget? lockedSecondary =
        _findEntityById(entities, _secondaryEntityId) ??
            _findNearestNeighbor(entities, lockedPrimary);

    // 4. Compute velocity lead offset and dynamic dolly-zoom bounding box
    final double leadMultiplier =
        _mode == DirectorCameraMode.warpChase ? 1.45 : 1.0;
    double rawLeadX =
        lockedPrimary.vx * config.velocityLeadTimeSeconds * leadMultiplier;
    double rawLeadY =
        lockedPrimary.vy * config.velocityLeadTimeSeconds * leadMultiplier;
    final double leadMag = math.sqrt(rawLeadX * rawLeadX + rawLeadY * rawLeadY);
    if (leadMag > config.maxVelocityLeadDistance && leadMag > 0) {
      final double scale = config.maxVelocityLeadDistance / leadMag;
      rawLeadX *= scale;
      rawLeadY *= scale;
    }

    final DirectorBoundingBox framingBox = _computeFramingBoundingBox(
      primary: lockedPrimary,
      secondary: lockedSecondary,
      leadOffsetX: rawLeadX,
      leadOffsetY: rawLeadY,
    );

    final double desiredZoom = _computeDesiredZoom(framingBox);

    // 5. Exponential damping for smooth pan and dolly-zoom (zero jitter)
    if (!hadInitialLock) {
      _smoothedCameraX = framingBox.centerX;
      _smoothedCameraY = framingBox.centerY;
      _smoothedZoom = desiredZoom;
    } else {
      final double posAlpha =
          1.0 - math.exp(-config.positionDampingLambda * math.max(0.001, dt));
      final double zoomAlpha =
          1.0 - math.exp(-config.zoomDampingLambda * math.max(0.001, dt));

      _smoothedCameraX += (framingBox.centerX - _smoothedCameraX) * posAlpha;
      _smoothedCameraY += (framingBox.centerY - _smoothedCameraY) * posAlpha;
      _smoothedZoom += (desiredZoom - _smoothedZoom) * zoomAlpha;
    }

    final double timeScale = _climaxSlowMoRemaining > 0
        ? config.climaxSlowMotionTimeScale
        : 1.0;

    return DirectorCameraFrame(
      timestamp: timestamp,
      primaryEntityId: lockedPrimary.entityId,
      secondaryEntityId: lockedSecondary?.entityId,
      mode: _mode,
      framingBox: framingBox,
      cameraX: _smoothedCameraX,
      cameraY: _smoothedCameraY,
      velocityLeadOffsetX: rawLeadX,
      velocityLeadOffsetY: rawLeadY,
      zoom: _smoothedZoom,
      timeScale: timeScale,
      currentShotElapsedSeconds: math.max(0.0, timestamp - _lastCutTimestamp),
    );
  }

  /// Steps the Director across an entire recorded [TelemetryRingBuffer] and
  /// returns all generated camera frames.
  List<DirectorCameraFrame> simulateFromRingBuffer(
    TelemetryRingBuffer ringBuffer, {
    int starDartEntityId = 99,
  }) {
    reset();
    final int tickCount = ringBuffer.length;
    if (tickCount == 0) return const <DirectorCameraFrame>[];

    final List<DirectorCameraFrame> frames = <DirectorCameraFrame>[];
    final TelemetryEntityCursor entityCursor = TelemetryEntityCursor();
    final TelemetryEventCursor eventCursor = TelemetryEventCursor();

    // Index events by tickNumber for fast lookup during replay simulation
    final Map<int, List<({
      TelemetryEventType type,
      int actorId,
      int targetId,
      double magnitude,
      int flags,
    })>> eventsByTick = <int, List<({
      TelemetryEventType type,
      int actorId,
      int targetId,
      double magnitude,
      int flags,
    })>>{};

    for (int evIdx = 0; evIdx < ringBuffer.retainedEventCount; evIdx++) {
      ringBuffer.readRetainedEventAt(
        chronologicalEventIndex: evIdx,
        outCursor: eventCursor,
      );
      eventsByTick.putIfAbsent(eventCursor.tickNumber, () => []).add((
        type: eventCursor.type,
        actorId: eventCursor.actorEntityId,
        targetId: eventCursor.targetEntityId,
        magnitude: eventCursor.magnitude,
        flags: eventCursor.metadataFlags,
      ));
    }

    double prevTime = 0.0;
    for (int t = 0; t < tickCount; t++) {
      final int slot = ringBuffer.ringSlotForChronologicalIndex(t);
      final int tickNum = ringBuffer.tickNumbers[slot];
      final double timestamp = ringBuffer.tickTimestamps[slot];
      final double dt = t == 0
          ? ringBuffer.sampleIntervalSeconds
          : math.max(0.001, timestamp - prevTime);
      prevTime = timestamp;

      final tickEvents = eventsByTick[tickNum] ?? const [];
      final Map<int, double> combatDamageByEntity = <int, double>{};
      final Set<int> warpChaseEntities = <int>{};
      bool starDartCaptureEvent = false;
      bool criticalSaveEvent = false;
      int? climaxEntityId;

      for (final ev in tickEvents) {
        if (ev.type == TelemetryEventType.weaponHitscan ||
            ev.type == TelemetryEventType.weaponMissile) {
          combatDamageByEntity[ev.actorId] =
              (combatDamageByEntity[ev.actorId] ?? 0.0) + ev.magnitude.abs();
          combatDamageByEntity[ev.targetId] =
              (combatDamageByEntity[ev.targetId] ?? 0.0) + ev.magnitude.abs();
        } else if (ev.type == TelemetryEventType.warpWakeEmission) {
          warpChaseEntities.add(ev.actorId);
        } else if (ev.type == TelemetryEventType.hullDelta && ev.flags == 1) {
          criticalSaveEvent = true;
          climaxEntityId = ev.targetId;
        } else if (ev.type == TelemetryEventType.allianceToggle &&
            ev.flags == 2) {
          // starDartSteal / capture
          starDartCaptureEvent = true;
          climaxEntityId = ev.targetId == starDartEntityId
              ? starDartEntityId
              : (ev.actorId == starDartEntityId
                  ? starDartEntityId
                  : ev.targetId);
        }
      }

      final int entityCount = ringBuffer.tickEntityCounts[slot];
      final List<DirectorEntityTarget> targets = <DirectorEntityTarget>[];

      for (int e = 0; e < entityCount; e++) {
        ringBuffer.readEntityAt(
          chronologicalTickIndex: t,
          entitySlot: e,
          outCursor: entityCursor,
        );
        final int id = entityCursor.entityId;
        targets.add(
          DirectorEntityTarget(
            entityId: id,
            x: entityCursor.x,
            y: entityCursor.y,
            vx: entityCursor.vx,
            vy: entityCursor.vy,
            hull: entityCursor.hull,
            maxHull: id == starDartEntityId ? 500.0 : 100.0,
            isStarDartBoss: id == starDartEntityId,
            isStarDartTetheredOrCaptured:
                id == starDartEntityId && starDartCaptureEvent,
            isInWarpChase: warpChaseEntities.contains(id),
            recentCombatDamage: combatDamageByEntity[id] ?? 0.0,
          ),
        );
      }

      frames.add(
        evaluateFrame(
          dt: dt,
          timestamp: timestamp,
          entities: targets,
          forceCriticalClimaxHullSave: criticalSaveEvent,
          forceCriticalClimaxStarDartCapture: starDartCaptureEvent,
          climaxTargetEntityId: climaxEntityId,
        ),
      );
    }

    return frames;
  }

  // ---------------------------------------------------------------------------
  // Internal Heuristic Helpers
  // ---------------------------------------------------------------------------

  ({
    DirectorEntityTarget primary,
    DirectorEntityTarget? secondary,
    DirectorCameraMode candidateMode,
  }) _selectHighestDramaCandidate(List<DirectorEntityTarget> entities) {
    DirectorEntityTarget bestPrimary = entities.first;
    DirectorEntityTarget? bestSecondary;
    DirectorCameraMode bestMode = DirectorCameraMode.sectorOverview;
    double bestScore = -1.0;

    for (final entity in entities) {
      final double speed =
          math.sqrt(entity.vx * entity.vx + entity.vy * entity.vy);
      final DirectorEntityTarget? neighbor =
          _findNearestNeighbor(entities, entity);
      double proximityScore = 0.0;
      if (neighbor != null) {
        final double dx = neighbor.x - entity.x;
        final double dy = neighbor.y - entity.y;
        final double dist = math.sqrt(dx * dx + dy * dy);
        if (dist < 900.0) {
          proximityScore = (900.0 - dist) * 0.15;
        }
      }

      double score =
          entity.recentCombatDamage * 4.0 + speed * 0.25 + proximityScore;
      DirectorCameraMode mode = DirectorCameraMode.dogfightCluster;

      if (entity.isStarDartBoss || entity.isStarDartTetheredOrCaptured) {
        score += 300.0;
        mode = DirectorCameraMode.starDartAmbush;
      } else if (entity.isInWarpChase || speed > 280.0) {
        score += 140.0;
        mode = DirectorCameraMode.warpChase;
      } else if (entity.recentCombatDamage <= 0 && proximityScore < 20.0) {
        mode = DirectorCameraMode.sectorOverview;
      }

      if (score > bestScore) {
        bestScore = score;
        bestPrimary = entity;
        bestSecondary = neighbor;
        bestMode = mode;
      }
    }

    return (
      primary: bestPrimary,
      secondary: bestSecondary,
      candidateMode: bestMode,
    );
  }

  DirectorEntityTarget? _findEntityById(
    List<DirectorEntityTarget> entities,
    int? entityId,
  ) {
    if (entityId == null || entityId < 0) return null;
    for (final e in entities) {
      if (e.entityId == entityId) return e;
    }
    return null;
  }

  DirectorEntityTarget? _findNearestNeighbor(
    List<DirectorEntityTarget> entities,
    DirectorEntityTarget anchor,
  ) {
    DirectorEntityTarget? nearest;
    double bestDistSq = double.infinity;
    for (final other in entities) {
      if (other.entityId == anchor.entityId) continue;
      final double dx = other.x - anchor.x;
      final double dy = other.y - anchor.y;
      final double distSq = dx * dx + dy * dy;
      if (distSq < bestDistSq) {
        bestDistSq = distSq;
        nearest = other;
      }
    }
    return nearest;
  }

  DirectorBoundingBox _computeFramingBoundingBox({
    required DirectorEntityTarget primary,
    required DirectorEntityTarget? secondary,
    required double leadOffsetX,
    required double leadOffsetY,
  }) {
    final double focalX = primary.x + leadOffsetX;
    final double focalY = primary.y + leadOffsetY;

    double minX = math.min(primary.x, focalX);
    double maxX = math.max(primary.x, focalX);
    double minY = math.min(primary.y, focalY);
    double maxY = math.max(primary.y, focalY);

    if (secondary != null &&
        _mode != DirectorCameraMode.criticalClimaxCloseUp) {
      final double dx = secondary.x - primary.x;
      final double dy = secondary.y - primary.y;
      // Include secondary fighter/boss in framing box if within engagement range
      if (dx * dx + dy * dy <= 1400.0 * 1400.0) {
        minX = math.min(minX, secondary.x);
        maxX = math.max(maxX, secondary.x);
        minY = math.min(minY, secondary.y);
        maxY = math.max(maxY, secondary.y);
      }
    }

    final double pad = _mode == DirectorCameraMode.criticalClimaxCloseUp
        ? config.framingPaddingWorldUnits * 0.55
        : config.framingPaddingWorldUnits;

    return DirectorBoundingBox(
      left: minX - pad,
      top: minY - pad,
      right: maxX + pad,
      bottom: maxY + pad,
    );
  }

  double _computeDesiredZoom(DirectorBoundingBox box) {
    final double zoomX = config.referenceViewportWidth / box.width;
    final double zoomY = config.referenceViewportHeight / box.height;
    final double rawZoom = math.min(zoomX, zoomY);
    return rawZoom.clamp(config.minZoom, config.maxZoom);
  }
}
