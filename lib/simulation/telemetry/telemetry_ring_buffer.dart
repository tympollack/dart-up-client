// =============================================================================
// telemetry_ring_buffer.dart
//
// Pre-allocated, zero-allocation (0 KB/frame) cyclic telemetry ring buffer for
// 20Hz match recording over a 15-minute window (18,000 ticks).
//
// Zero Flutter or Flame imports.
// =============================================================================

import 'dart:typed_data';

/// Discrete event types recorded inside the fixed-capacity event sub-buffer.
enum TelemetryEventType {
  /// Instantaneous weapon hitscan or turret laser discharge.
  weaponHitscan(1),

  /// Missile / torpedo / drone point-defense projectile event.
  weaponMissile(2),

  /// Subwarp or FTL [WarpWake] departure signature emission.
  warpWakeEmission(3),

  /// Hull or shield delta inflicted on an entity.
  hullDelta(4),

  /// Cast Ledger diplomatic alliance toggle (pact formed, broken, or betrayal).
  allianceToggle(5);

  const TelemetryEventType(this.code);
  final int code;

  static TelemetryEventType fromCode(int code) {
    for (final value in TelemetryEventType.values) {
      if (value.code == code) return value;
    }
    return TelemetryEventType.weaponHitscan;
  }
}

/// Reusable, zero-allocation cursor for reading back a single tick's entity
/// state or discrete event from [TelemetryRingBuffer] without allocating new
/// objects during iteration.
class TelemetryEntityCursor {
  int tickNumber = 0;
  double timestamp = 0.0;
  int entitySlot = 0;
  int entityId = 0;

  /// Quantized position (centi-units: `round(worldCoord * 100)`).
  int quantizedX = 0;
  int quantizedY = 0;

  /// Quantized velocity (centi-units/sec: `round(worldVel * 100)`).
  int quantizedVx = 0;
  int quantizedVy = 0;

  /// Quantized hull (`round(hull * 100)`).
  int quantizedHull = 0;

  double get x => quantizedX / TelemetryRingBuffer.quantizationScale;
  double get y => quantizedY / TelemetryRingBuffer.quantizationScale;
  double get vx => quantizedVx / TelemetryRingBuffer.quantizationScale;
  double get vy => quantizedVy / TelemetryRingBuffer.quantizationScale;
  double get hull => quantizedHull / TelemetryRingBuffer.quantizationScale;
}

/// Reusable, zero-allocation cursor for reading back discrete telemetry events
/// (weapon hitscan/missile, WarpWake emissions, hull deltas, alliance toggles).
class TelemetryEventCursor {
  int tickNumber = 0;
  double timestamp = 0.0;
  TelemetryEventType type = TelemetryEventType.weaponHitscan;
  int actorEntityId = 0;
  int targetEntityId = 0;

  int quantizedSourceX = 0;
  int quantizedSourceY = 0;
  int quantizedTargetX = 0;
  int quantizedTargetY = 0;
  int quantizedMagnitude = 0;
  int metadataFlags = 0;

  double get sourceX =>
      quantizedSourceX / TelemetryRingBuffer.quantizationScale;
  double get sourceY =>
      quantizedSourceY / TelemetryRingBuffer.quantizationScale;
  double get targetX =>
      quantizedTargetX / TelemetryRingBuffer.quantizationScale;
  double get targetY =>
      quantizedTargetY / TelemetryRingBuffer.quantizationScale;
  double get magnitude =>
      quantizedMagnitude / TelemetryRingBuffer.quantizationScale;
}

/// Pre-allocated cyclic telemetry ring buffer sampling a 15-minute match at
/// 20Hz (`18,000` ticks) with `0` heap allocations during the sampling loop.
class TelemetryRingBuffer {
  /// Default 20Hz sampling rate (`0.05s` per tick).
  static const int defaultSampleRateHz = 20;

  /// Default 15-minute match capacity at 20Hz (`15 * 60 * 20 = 18,000` ticks).
  static const int defaultCapacityTicks = 18000;

  /// Default tracked entity slots per tick (player ship, Star Dart boss, active
  /// hunters/squads).
  static const int defaultMaxEntitiesPerTick = 8;

  /// Default capacity for the cyclic discrete event sub-buffer.
  static const int defaultEventCapacity = 32768;

  /// Fixed-point quantization factor (`100.0` = 0.01 world-unit precision).
  static const double quantizationScale = 100.0;

  /// Number of `Int32` fields per entity per tick:
  /// `[0] entityId, [1] qX, [2] qY, [3] qVx, [4] qVy, [5] qHull`.
  static const int entityStride = 6;

  /// Number of `Int32` fields per discrete event:
  /// `[0] tickNumber, [1] eventTypeCode, [2] actorId, [3] targetId,
  ///  [4] qSourceX, [5] qSourceY, [6] qTargetX, [7] qTargetY,
  ///  [8] qMagnitude, [9] metadataFlags`.
  static const int eventIntStride = 10;

  TelemetryRingBuffer({
    this.capacityTicks = defaultCapacityTicks,
    this.maxEntitiesPerTick = defaultMaxEntitiesPerTick,
    this.sampleRateHz = defaultSampleRateHz,
    this.eventCapacity = defaultEventCapacity,
  })  : assert(capacityTicks > 0, 'capacityTicks must be positive'),
        assert(maxEntitiesPerTick > 0, 'maxEntitiesPerTick must be positive'),
        assert(sampleRateHz > 0, 'sampleRateHz must be positive'),
        assert(eventCapacity > 0, 'eventCapacity must be positive'),
        tickNumbers = Int32List(capacityTicks),
        tickTimestamps = Float32List(capacityTicks),
        tickEntityCounts = Int32List(capacityTicks),
        tickEventStartIndices = Int32List(capacityTicks),
        tickEventCounts = Int32List(capacityTicks),
        entityStateIntBuffer = Int32List(
          capacityTicks * maxEntitiesPerTick * entityStride,
        ),
        entityVelocityFloatBuffer = Float32List(
          capacityTicks * maxEntitiesPerTick * 2,
        ),
        eventIntBuffer = Int32List(eventCapacity * eventIntStride),
        eventTimestamps = Float32List(eventCapacity);

  final int capacityTicks;
  final int maxEntitiesPerTick;
  final int sampleRateHz;
  final int eventCapacity;

  /// Pre-allocated per-tick metadata buffers (length: [capacityTicks]).
  final Int32List tickNumbers;
  final Float32List tickTimestamps;
  final Int32List tickEntityCounts;
  final Int32List tickEventStartIndices;
  final Int32List tickEventCounts;

  /// Pre-allocated quantized entity trajectory & hull backing buffer.
  /// Layout per slot `(ringSlot * maxEntitiesPerTick + entityIdx) * entityStride`:
  /// - `+0`: `entityId`
  /// - `+1`: `quantizedX`
  /// - `+2`: `quantizedY`
  /// - `+3`: `quantizedVx`
  /// - `+4`: `quantizedVy`
  /// - `+5`: `quantizedHull`
  final Int32List entityStateIntBuffer;

  /// Pre-allocated `Float32List` backing buffer storing raw float velocities
  /// `(vx, vy)` per entity slot for direct float SIMD/Director consumers.
  final Float32List entityVelocityFloatBuffer;

  /// Pre-allocated cyclic discrete event buffer.
  final Int32List eventIntBuffer;
  final Float32List eventTimestamps;

  int _writeTickCursor = 0;
  int _recordedTickCount = 0;
  int _currentRingSlot = -1;
  int _currentTickNumber = -1;
  double _currentTickTimestamp = 0.0;

  int _writeEventCursor = 0;
  int _recordedEventCount = 0;

  double _sampleAccumulator = 0.0;

  /// Number of ticks currently stored in the ring buffer (up to [capacityTicks]).
  int get length =>
      _recordedTickCount < capacityTicks ? _recordedTickCount : capacityTicks;

  /// Total number of ticks written since match init (may exceed [capacityTicks]
  /// when the cyclic buffer wraps around).
  int get totalTicksRecorded => _recordedTickCount;

  /// Total number of discrete events written since match init.
  int get totalEventsRecorded => _recordedEventCount;

  /// Number of discrete events currently retained in the cyclic event buffer.
  int get retainedEventCount =>
      _recordedEventCount < eventCapacity ? _recordedEventCount : eventCapacity;

  /// Current active ring slot (`0 .. capacityTicks - 1`), or `-1` before first tick.
  int get currentRingSlot => _currentRingSlot;

  /// Logical tick number of the most recently opened tick.
  int get currentTickNumber => _currentTickNumber;

  /// Fixed time interval between 20Hz samples (`0.05s` at 20Hz).
  double get sampleIntervalSeconds => 1.0 / sampleRateHz;

  /// Quantizes a world-space floating-point value into fixed-point centi-units.
  static int quantize(double value) => (value * quantizationScale).round();

  /// Dequantizes a fixed-point centi-unit integer back to world-space double.
  static double dequantize(int quantized) => quantized / quantizationScale;

  /// Resets all cursors to zero without reallocating backing buffers.
  void clear() {
    _writeTickCursor = 0;
    _recordedTickCount = 0;
    _currentRingSlot = -1;
    _currentTickNumber = -1;
    _currentTickTimestamp = 0.0;
    _writeEventCursor = 0;
    _recordedEventCount = 0;
    _sampleAccumulator = 0.0;
  }

  /// Advances the 20Hz sampling accumulator by [dt] and returns `true` when one
  /// or more 20Hz telemetry ticks should be sampled.
  bool advanceSampleClock(double dt) {
    if (dt <= 0) return false;
    _sampleAccumulator += dt;
    final double interval = sampleIntervalSeconds;
    if (_sampleAccumulator >= interval) {
      _sampleAccumulator -= interval;
      if (_sampleAccumulator >= interval) {
        // Clamp excess accumulation to avoid spiral-of-death on background spikes.
        _sampleAccumulator = _sampleAccumulator % interval;
      }
      return true;
    }
    return false;
  }

  // ---------------------------------------------------------------------------
  // Zero-Allocation 20Hz Recording API
  // ---------------------------------------------------------------------------

  /// Opens a new 20Hz telemetry tick in the cyclic ring buffer.
  /// Wrap-around overwrites the oldest slot (`O(1)`, `0` allocations).
  int beginTick({int? tickNumber, required double timestamp}) {
    final int logicalTick = tickNumber ?? _recordedTickCount;
    final int slot = _writeTickCursor;

    _currentRingSlot = slot;
    _currentTickNumber = logicalTick;
    _currentTickTimestamp = timestamp;

    tickNumbers[slot] = logicalTick;
    tickTimestamps[slot] = timestamp;
    tickEntityCounts[slot] = 0;
    tickEventStartIndices[slot] = _recordedEventCount;
    tickEventCounts[slot] = 0;

    _writeTickCursor = (slot + 1) % capacityTicks;
    _recordedTickCount++;
    return slot;
  }

  /// Records quantized entity position, velocity, and hull state into the
  /// current tick's pre-allocated slot. Returns the entity index within the
  /// tick, or `-1` if [maxEntitiesPerTick] is exceeded.
  int recordEntityState({
    required int entityId,
    required double x,
    required double y,
    required double vx,
    required double vy,
    double hull = 100.0,
  }) {
    final int slot = _currentRingSlot;
    if (slot < 0) return -1;

    final int entityIdx = tickEntityCounts[slot];
    if (entityIdx >= maxEntitiesPerTick) return -1;

    final int baseOffset =
        (slot * maxEntitiesPerTick + entityIdx) * entityStride;
    entityStateIntBuffer[baseOffset] = entityId;
    entityStateIntBuffer[baseOffset + 1] = (x * quantizationScale).round();
    entityStateIntBuffer[baseOffset + 2] = (y * quantizationScale).round();
    entityStateIntBuffer[baseOffset + 3] = (vx * quantizationScale).round();
    entityStateIntBuffer[baseOffset + 4] = (vy * quantizationScale).round();
    entityStateIntBuffer[baseOffset + 5] = (hull * quantizationScale).round();

    final int floatOffset = (slot * maxEntitiesPerTick + entityIdx) * 2;
    entityVelocityFloatBuffer[floatOffset] = vx;
    entityVelocityFloatBuffer[floatOffset + 1] = vy;

    tickEntityCounts[slot] = entityIdx + 1;
    return entityIdx;
  }

  /// Records a weapon hitscan or missile discharge event in the current tick.
  void recordWeaponEvent({
    required int attackerId,
    required int targetId,
    required double sourceX,
    required double sourceY,
    required double targetX,
    required double targetY,
    required double damage,
    bool isMissile = false,
  }) {
    _appendEvent(
      typeCode: isMissile
          ? TelemetryEventType.weaponMissile.code
          : TelemetryEventType.weaponHitscan.code,
      actorId: attackerId,
      targetId: targetId,
      sourceX: sourceX,
      sourceY: sourceY,
      targetX: targetX,
      targetY: targetY,
      magnitude: damage,
      metadataFlags: isMissile ? 1 : 0,
    );
  }

  /// Records a Subwarp or FTL [WarpWake] emission event in the current tick.
  /// [driveTypeCode]: `0` = subwarp, `1` = FTL, `2` = spoofed ECM decoy.
  void recordWarpWakeEmission({
    required int shipEntityId,
    required double originX,
    required double originY,
    required double targetX,
    required double targetY,
    required double energySignature,
    int driveTypeCode = 1,
  }) {
    _appendEvent(
      typeCode: TelemetryEventType.warpWakeEmission.code,
      actorId: shipEntityId,
      targetId: 0,
      sourceX: originX,
      sourceY: originY,
      targetX: targetX,
      targetY: targetY,
      magnitude: energySignature,
      metadataFlags: driveTypeCode,
    );
  }

  /// Records a hull or shield delta on [entityId] (negative for damage,
  /// positive for field repair).
  void recordHullDelta({
    required int entityId,
    required int sourceEntityId,
    required double x,
    required double y,
    required double deltaHull,
    required double remainingHull,
    bool isCriticalSave = false,
  }) {
    _appendEvent(
      typeCode: TelemetryEventType.hullDelta.code,
      actorId: sourceEntityId,
      targetId: entityId,
      sourceX: x,
      sourceY: y,
      targetX: remainingHull,
      targetY: 0.0,
      magnitude: deltaHull,
      metadataFlags: isCriticalSave ? 1 : 0,
    );
  }

  /// Records a Cast Ledger alliance toggle (alliance formed, broken, betrayal,
  /// or Star Dart capture/steal) with zero heap allocations.
  /// [intentTypeCode]: `0` = allianceFormed, `1` = betrayal, `2` = starDartSteal,
  /// `3` = bountyTriggered.
  void recordAllianceToggle({
    required int actorPlayerId,
    required int targetPlayerId,
    required double sectorX,
    required double sectorY,
    int intentTypeCode = 0,
    double magnitude = 0.0,
  }) {
    _appendEvent(
      typeCode: TelemetryEventType.allianceToggle.code,
      actorId: actorPlayerId,
      targetId: targetPlayerId,
      sourceX: sectorX,
      sourceY: sectorY,
      targetX: sectorX,
      targetY: sectorY,
      magnitude: magnitude,
      metadataFlags: intentTypeCode,
    );
  }

  void _appendEvent({
    required int typeCode,
    required int actorId,
    required int targetId,
    required double sourceX,
    required double sourceY,
    required double targetX,
    required double targetY,
    required double magnitude,
    required int metadataFlags,
  }) {
    final int tickSlot = _currentRingSlot;
    final int eventSlot = _writeEventCursor;
    final int baseOffset = eventSlot * eventIntStride;

    eventIntBuffer[baseOffset] = _currentTickNumber >= 0 ? _currentTickNumber : 0;
    eventIntBuffer[baseOffset + 1] = typeCode;
    eventIntBuffer[baseOffset + 2] = actorId;
    eventIntBuffer[baseOffset + 3] = targetId;
    eventIntBuffer[baseOffset + 4] = (sourceX * quantizationScale).round();
    eventIntBuffer[baseOffset + 5] = (sourceY * quantizationScale).round();
    eventIntBuffer[baseOffset + 6] = (targetX * quantizationScale).round();
    eventIntBuffer[baseOffset + 7] = (targetY * quantizationScale).round();
    eventIntBuffer[baseOffset + 8] = (magnitude * quantizationScale).round();
    eventIntBuffer[baseOffset + 9] = metadataFlags;
    eventTimestamps[eventSlot] = _currentTickTimestamp;

    if (tickSlot >= 0) {
      tickEventCounts[tickSlot] = tickEventCounts[tickSlot] + 1;
    }

    _writeEventCursor = (eventSlot + 1) % eventCapacity;
    _recordedEventCount++;
  }

  // ---------------------------------------------------------------------------
  // Chronological Read-Back API (Zero-Allocation Cursors)
  // ---------------------------------------------------------------------------

  /// Maps a chronological tick index `0 .. length - 1` (oldest to newest) to
  /// its physical slot in the cyclic ring buffer.
  int ringSlotForChronologicalIndex(int chronologicalIndex) {
    final int count = length;
    if (chronologicalIndex < 0 || chronologicalIndex >= count) {
      throw RangeError.index(chronologicalIndex, this, 'chronologicalIndex');
    }
    if (_recordedTickCount <= capacityTicks) {
      return chronologicalIndex;
    }
    return (_writeTickCursor + chronologicalIndex) % capacityTicks;
  }

  /// Populates [outCursor] with the entity state at [chronologicalTickIndex]
  /// and [entitySlot] without allocating any heap objects.
  bool readEntityAt({
    required int chronologicalTickIndex,
    required int entitySlot,
    required TelemetryEntityCursor outCursor,
  }) {
    final int ringSlot = ringSlotForChronologicalIndex(chronologicalTickIndex);
    final int count = tickEntityCounts[ringSlot];
    if (entitySlot < 0 || entitySlot >= count) return false;

    final int baseOffset =
        (ringSlot * maxEntitiesPerTick + entitySlot) * entityStride;
    outCursor.tickNumber = tickNumbers[ringSlot];
    outCursor.timestamp = tickTimestamps[ringSlot];
    outCursor.entitySlot = entitySlot;
    outCursor.entityId = entityStateIntBuffer[baseOffset];
    outCursor.quantizedX = entityStateIntBuffer[baseOffset + 1];
    outCursor.quantizedY = entityStateIntBuffer[baseOffset + 2];
    outCursor.quantizedVx = entityStateIntBuffer[baseOffset + 3];
    outCursor.quantizedVy = entityStateIntBuffer[baseOffset + 4];
    outCursor.quantizedHull = entityStateIntBuffer[baseOffset + 5];
    return true;
  }

  /// Populates [outCursor] with the [chronologicalEventIndex]-th retained event
  /// (`0 .. retainedEventCount - 1`, oldest to newest) with zero allocations.
  bool readRetainedEventAt({
    required int chronologicalEventIndex,
    required TelemetryEventCursor outCursor,
  }) {
    final int count = retainedEventCount;
    if (chronologicalEventIndex < 0 || chronologicalEventIndex >= count) {
      return false;
    }
    final int eventSlot = _recordedEventCount <= eventCapacity
        ? chronologicalEventIndex
        : (_writeEventCursor + chronologicalEventIndex) % eventCapacity;

    final int baseOffset = eventSlot * eventIntStride;
    outCursor.tickNumber = eventIntBuffer[baseOffset];
    outCursor.timestamp = eventTimestamps[eventSlot];
    outCursor.type = TelemetryEventType.fromCode(eventIntBuffer[baseOffset + 1]);
    outCursor.actorEntityId = eventIntBuffer[baseOffset + 2];
    outCursor.targetEntityId = eventIntBuffer[baseOffset + 3];
    outCursor.quantizedSourceX = eventIntBuffer[baseOffset + 4];
    outCursor.quantizedSourceY = eventIntBuffer[baseOffset + 5];
    outCursor.quantizedTargetX = eventIntBuffer[baseOffset + 6];
    outCursor.quantizedTargetY = eventIntBuffer[baseOffset + 7];
    outCursor.quantizedMagnitude = eventIntBuffer[baseOffset + 8];
    outCursor.metadataFlags = eventIntBuffer[baseOffset + 9];
    return true;
  }
}
