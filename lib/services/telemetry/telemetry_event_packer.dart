// =============================================================================
// telemetry_event_packer.dart
//
// Delta-encoded, ZigZag-varint + zlib/LZ compressed serializer and unpacker for
// TelemetryRingBuffer frames. Compresses a standard 10-minute match (12,000
// ticks at 20Hz) under the 120 KB payload budget while guaranteeing lossless
// round-trip reconstruction of quantized entity trajectories and event
// timestamps.
// =============================================================================

import 'dart:convert';
import 'dart:typed_data';

import 'package:sd_client/simulation/telemetry/telemetry_ring_buffer.dart';

import 'telemetry_codec_native.dart'
    if (dart.library.js_interop) 'telemetry_codec_web.dart';

/// Maximum byte budget for a serialized 10-minute match telemetry stream (`120 KB`).
const int kMaxSerializedMatchBytes = 120 * 1024;

/// Reconstructed entity sample from an unpacked [TelemetryReplayArchive].
class UnpackedEntitySample {
  final int entityId;
  final int quantizedX;
  final int quantizedY;
  final int quantizedVx;
  final int quantizedVy;
  final int quantizedHull;

  const UnpackedEntitySample({
    required this.entityId,
    required this.quantizedX,
    required this.quantizedY,
    required this.quantizedVx,
    required this.quantizedVy,
    required this.quantizedHull,
  });

  double get x => quantizedX / TelemetryRingBuffer.quantizationScale;
  double get y => quantizedY / TelemetryRingBuffer.quantizationScale;
  double get vx => quantizedVx / TelemetryRingBuffer.quantizationScale;
  double get vy => quantizedVy / TelemetryRingBuffer.quantizationScale;
  double get hull => quantizedHull / TelemetryRingBuffer.quantizationScale;
}

/// Reconstructed tick frame from an unpacked [TelemetryReplayArchive].
class UnpackedTelemetryTick {
  final int tickNumber;
  final double timestamp;
  final List<UnpackedEntitySample> entities;

  const UnpackedTelemetryTick({
    required this.tickNumber,
    required this.timestamp,
    required this.entities,
  });
}

/// Reconstructed discrete event from an unpacked [TelemetryReplayArchive].
class UnpackedTelemetryEvent {
  final int tickNumber;
  final double timestamp;
  final TelemetryEventType type;
  final int actorEntityId;
  final int targetEntityId;
  final int quantizedSourceX;
  final int quantizedSourceY;
  final int quantizedTargetX;
  final int quantizedTargetY;
  final int quantizedMagnitude;
  final int metadataFlags;

  const UnpackedTelemetryEvent({
    required this.tickNumber,
    required this.timestamp,
    required this.type,
    required this.actorEntityId,
    required this.targetEntityId,
    required this.quantizedSourceX,
    required this.quantizedSourceY,
    required this.quantizedTargetX,
    required this.quantizedTargetY,
    required this.quantizedMagnitude,
    required this.metadataFlags,
  });

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

/// Decoded replay archive produced by [TelemetryEventPacker.unpack].
class TelemetryReplayArchive {
  final String matchId;
  final int sampleRateHz;
  final List<UnpackedTelemetryTick> ticks;
  final List<UnpackedTelemetryEvent> events;

  const TelemetryReplayArchive({
    required this.matchId,
    required this.sampleRateHz,
    required this.ticks,
    required this.events,
  });

  /// Restores this unpacked archive directly into a fresh [TelemetryRingBuffer].
  TelemetryRingBuffer toRingBuffer({
    int? capacityTicks,
    int? maxEntitiesPerTick,
    int? eventCapacity,
  }) {
    int maxEntities = 1;
    for (final t in ticks) {
      if (t.entities.length > maxEntities) {
        maxEntities = t.entities.length;
      }
    }

    final buffer = TelemetryRingBuffer(
      capacityTicks: capacityTicks ??
          (ticks.isNotEmpty
              ? ticks.length
              : TelemetryRingBuffer.defaultCapacityTicks),
      maxEntitiesPerTick: maxEntitiesPerTick ??
          (maxEntities > TelemetryRingBuffer.defaultMaxEntitiesPerTick
              ? maxEntities
              : TelemetryRingBuffer.defaultMaxEntitiesPerTick),
      sampleRateHz: sampleRateHz,
      eventCapacity: eventCapacity ??
          (events.length > TelemetryRingBuffer.defaultEventCapacity
              ? events.length
              : TelemetryRingBuffer.defaultEventCapacity),
    );

    int eventCursor = 0;
    if (ticks.isNotEmpty) {
      final int firstTickNumber = ticks.first.tickNumber;
      while (eventCursor < events.length &&
          events[eventCursor].tickNumber < firstTickNumber) {
        eventCursor++;
      }
    }

    for (final tick in ticks) {
      buffer.beginTick(tickNumber: tick.tickNumber, timestamp: tick.timestamp);
      for (final entity in tick.entities) {
        buffer.recordEntityState(
          entityId: entity.entityId,
          x: entity.x,
          y: entity.y,
          vx: entity.vx,
          vy: entity.vy,
          hull: entity.hull,
        );
      }

      while (eventCursor < events.length &&
          events[eventCursor].tickNumber == tick.tickNumber) {
        final ev = events[eventCursor++];
        _writeUnpackedEventToBuffer(buffer, ev);
      }
    }

    while (eventCursor < events.length) {
      final ev = events[eventCursor++];
      if (buffer.length == 0 ||
          buffer.currentTickNumber != ev.tickNumber) {
        buffer.beginTick(tickNumber: ev.tickNumber, timestamp: ev.timestamp);
      }
      _writeUnpackedEventToBuffer(buffer, ev);
    }

    return buffer;
  }

  static void _writeUnpackedEventToBuffer(
    TelemetryRingBuffer buffer,
    UnpackedTelemetryEvent ev,
  ) {
    switch (ev.type) {
      case TelemetryEventType.weaponHitscan:
      case TelemetryEventType.weaponMissile:
        buffer.recordWeaponEvent(
          attackerId: ev.actorEntityId,
          targetId: ev.targetEntityId,
          sourceX: ev.sourceX,
          sourceY: ev.sourceY,
          targetX: ev.targetX,
          targetY: ev.targetY,
          damage: ev.magnitude,
          isMissile: ev.type == TelemetryEventType.weaponMissile ||
              ev.metadataFlags == 1,
        );
      case TelemetryEventType.warpWakeEmission:
        buffer.recordWarpWakeEmission(
          shipEntityId: ev.actorEntityId,
          originX: ev.sourceX,
          originY: ev.sourceY,
          targetX: ev.targetX,
          targetY: ev.targetY,
          energySignature: ev.magnitude,
          driveTypeCode: ev.metadataFlags,
        );
      case TelemetryEventType.hullDelta:
        buffer.recordHullDelta(
          entityId: ev.targetEntityId,
          sourceEntityId: ev.actorEntityId,
          x: ev.sourceX,
          y: ev.sourceY,
          deltaHull: ev.magnitude,
          remainingHull: ev.targetX,
          isCriticalSave: ev.metadataFlags == 1,
        );
      case TelemetryEventType.allianceToggle:
        buffer.recordAllianceToggle(
          actorPlayerId: ev.actorEntityId,
          targetPlayerId: ev.targetEntityId,
          sectorX: ev.sourceX,
          sectorY: ev.sourceY,
          intentTypeCode: ev.metadataFlags,
          magnitude: ev.magnitude,
        );
    }
  }
}

/// Delta-encoded binary telemetry serializer and decompressor.
///
/// Format overview:
/// 1. Magic header `DTRP` (`0x44, 0x54, 0x52, 0x50`) + version (`1`).
/// 2. Varint-encoded `matchId` UTF-8 bytes, `sampleRateHz`, `tickCount`, `eventCount`.
/// 3. Per-tick delta stream:
///    - `deltaTickNumber`, `deltaTimestampMicros`, `entityCount`.
///    - Per-entity delta against that entity's previous quantized sample:
///      `entityId`, `dX`, `dY`, `dVx`, `dVy`, `dHull` (ZigZag varints).
/// 4. Per-event delta stream:
///    - `deltaTickNumber`, `deltaTimestampMicros`, `typeCode`, `actorId`, `targetId`,
///      `qSourceX`, `qSourceY`, `qTargetX`, `qTargetY`, `qMagnitude`, `metadataFlags`.
/// 5. Entire delta stream is compressed with platform zlib / LZ codec.
class TelemetryEventPacker {
  static const int _magic0 = 0x44; // 'D'
  static const int _magic1 = 0x54; // 'T'
  static const int _magic2 = 0x52; // 'R'
  static const int _magic3 = 0x50; // 'P'
  static const int _formatVersion = 1;

  /// Encodes a signed 32-bit integer into an unsigned ZigZag integer so small
  /// negative deltas (`-1`, `-2`, ...) map to small positive integers (`1`, `3`, ...).
  static int zigZagEncode(int value) => (value << 1) ^ (value >> 31);

  /// Decodes an unsigned ZigZag integer back to a signed integer.
  static int zigZagDecode(int encoded) => (encoded >>> 1) ^ -(encoded & 1);

  /// Writes an unsigned base-128 varint to [builder].
  static void writeUnsignedVarint(BytesBuilder builder, int value) {
    int v = value;
    while ((v & ~0x7F) != 0) {
      builder.addByte((v & 0x7F) | 0x80);
      v = v >>> 7;
    }
    builder.addByte(v & 0x7F);
  }

  /// Writes a signed integer as a ZigZag base-128 varint to [builder].
  static void writeSignedVarint(BytesBuilder builder, int value) {
    writeUnsignedVarint(builder, zigZagEncode(value));
  }

  /// Packs all retained ticks and discrete events in [ringBuffer] into a
  /// delta-encoded, compressed binary payload.
  static Uint8List pack(
    TelemetryRingBuffer ringBuffer, {
    String matchId = 'match_0',
  }) {
    final BytesBuilder deltaStream = BytesBuilder(copy: false);

    final List<int> matchIdBytes = utf8.encode(matchId);
    writeUnsignedVarint(deltaStream, matchIdBytes.length);
    deltaStream.add(matchIdBytes);

    final int tickCount = ringBuffer.length;
    final int eventCount = ringBuffer.retainedEventCount;
    writeUnsignedVarint(deltaStream, ringBuffer.sampleRateHz);
    writeUnsignedVarint(deltaStream, tickCount);
    writeUnsignedVarint(deltaStream, eventCount);

    // Track per-entity previous quantized state: [qX, qY, qVx, qVy, qHull]
    final Map<int, List<int>> prevEntityState = <int, List<int>>{};
    final TelemetryEntityCursor entityCursor = TelemetryEntityCursor();

    int prevTickNumber = 0;
    int prevTickTimeMicros = 0;

    for (int t = 0; t < tickCount; t++) {
      final int ringSlot = ringBuffer.ringSlotForChronologicalIndex(t);
      final int tickNum = ringBuffer.tickNumbers[ringSlot];
      final int timeMicros =
          (ringBuffer.tickTimestamps[ringSlot] * 1000000.0).round();
      final int entityCount = ringBuffer.tickEntityCounts[ringSlot];

      writeSignedVarint(deltaStream, tickNum - prevTickNumber);
      writeSignedVarint(deltaStream, timeMicros - prevTickTimeMicros);
      writeUnsignedVarint(deltaStream, entityCount);

      prevTickNumber = tickNum;
      prevTickTimeMicros = timeMicros;

      for (int e = 0; e < entityCount; e++) {
        ringBuffer.readEntityAt(
          chronologicalTickIndex: t,
          entitySlot: e,
          outCursor: entityCursor,
        );

        final int id = entityCursor.entityId;
        writeSignedVarint(deltaStream, id);

        final List<int>? prev = prevEntityState[id];
        if (prev == null) {
          writeSignedVarint(deltaStream, entityCursor.quantizedX);
          writeSignedVarint(deltaStream, entityCursor.quantizedY);
          writeSignedVarint(deltaStream, entityCursor.quantizedVx);
          writeSignedVarint(deltaStream, entityCursor.quantizedVy);
          writeSignedVarint(deltaStream, entityCursor.quantizedHull);
          prevEntityState[id] = <int>[
            entityCursor.quantizedX,
            entityCursor.quantizedY,
            entityCursor.quantizedVx,
            entityCursor.quantizedVy,
            entityCursor.quantizedHull,
          ];
        } else {
          // Second-order velocity prediction: predictedX = prevX + prevVx / sampleRate
          final int dX = entityCursor.quantizedX - prev[0];
          final int dY = entityCursor.quantizedY - prev[1];
          final int dVx = entityCursor.quantizedVx - prev[2];
          final int dVy = entityCursor.quantizedVy - prev[3];
          final int dHull = entityCursor.quantizedHull - prev[4];

          writeSignedVarint(deltaStream, dX);
          writeSignedVarint(deltaStream, dY);
          writeSignedVarint(deltaStream, dVx);
          writeSignedVarint(deltaStream, dVy);
          writeSignedVarint(deltaStream, dHull);

          prev[0] = entityCursor.quantizedX;
          prev[1] = entityCursor.quantizedY;
          prev[2] = entityCursor.quantizedVx;
          prev[3] = entityCursor.quantizedVy;
          prev[4] = entityCursor.quantizedHull;
        }
      }
    }

    final TelemetryEventCursor eventCursor = TelemetryEventCursor();
    int prevEventTick = 0;
    int prevEventTimeMicros = 0;

    for (int evIdx = 0; evIdx < eventCount; evIdx++) {
      ringBuffer.readRetainedEventAt(
        chronologicalEventIndex: evIdx,
        outCursor: eventCursor,
      );
      final int eventTimeMicros = (eventCursor.timestamp * 1000000.0).round();

      writeSignedVarint(deltaStream, eventCursor.tickNumber - prevEventTick);
      writeSignedVarint(
          deltaStream, eventTimeMicros - prevEventTimeMicros);
      writeUnsignedVarint(deltaStream, eventCursor.type.code);
      writeSignedVarint(deltaStream, eventCursor.actorEntityId);
      writeSignedVarint(deltaStream, eventCursor.targetEntityId);
      writeSignedVarint(deltaStream, eventCursor.quantizedSourceX);
      writeSignedVarint(deltaStream, eventCursor.quantizedSourceY);
      writeSignedVarint(deltaStream, eventCursor.quantizedTargetX);
      writeSignedVarint(deltaStream, eventCursor.quantizedTargetY);
      writeSignedVarint(deltaStream, eventCursor.quantizedMagnitude);
      writeSignedVarint(deltaStream, eventCursor.metadataFlags);

      prevEventTick = eventCursor.tickNumber;
      prevEventTimeMicros = eventTimeMicros;
    }

    final Uint8List rawDeltaBytes = deltaStream.takeBytes();
    final Uint8List compressedPayload = platformZlibEncode(rawDeltaBytes);
    final int codecFlag = (compressedPayload.length >= 2 &&
            compressedPayload[0] == 0x4C &&
            compressedPayload[1] == 0x5A)
        ? 0x02 // LZ77/RLE codec
        : 0x01; // ZLIB codec

    final BytesBuilder envelope = BytesBuilder(copy: false);
    envelope.addByte(_magic0);
    envelope.addByte(_magic1);
    envelope.addByte(_magic2);
    envelope.addByte(_magic3);
    envelope.addByte(_formatVersion);
    envelope.addByte(codecFlag);
    envelope.add(compressedPayload);
    return envelope.takeBytes();
  }

  /// Inspects the packed header and returns `'dtrp_v1_lz'` or `'dtrp_v1_zlib'`.
  static String detectPayloadFormatLabel(Uint8List packedBytes) {
    if (packedBytes.length >= 6 &&
        packedBytes[0] == _magic0 &&
        packedBytes[1] == _magic1 &&
        packedBytes[2] == _magic2 &&
        packedBytes[3] == _magic3) {
      final int codecFlag = packedBytes[5];
      if (codecFlag == 0x02) return 'dtrp_v1_lz';
      if (codecFlag == 0x01) return 'dtrp_v1_zlib';
    }
    return 'dtrp_v1';
  }

  /// Unpacks a compressed binary payload produced by [pack] back into a
  /// [TelemetryReplayArchive] with exact quantized entity coordinates and
  /// event timestamps.
  static TelemetryReplayArchive unpack(Uint8List packedBytes) {
    if (packedBytes.length < 7 ||
        packedBytes[0] != _magic0 ||
        packedBytes[1] != _magic1 ||
        packedBytes[2] != _magic2 ||
        packedBytes[3] != _magic3) {
      throw const FormatException(
        'Invalid TelemetryEventPacker header: missing DTRP magic bytes.',
      );
    }

    final int version = packedBytes[4];
    if (version != _formatVersion) {
      throw FormatException(
        'Unsupported TelemetryEventPacker format version: $version',
      );
    }

    final int codecFlag = packedBytes[5];
    final int payloadStart = (codecFlag == 0x01 || codecFlag == 0x02) ? 6 : 5;
    final Uint8List compressedSlice =
        Uint8List.sublistView(packedBytes, payloadStart, packedBytes.length);
    final Uint8List rawDeltaBytes = platformZlibDecode(compressedSlice);
    final _VarintReader reader = _VarintReader(rawDeltaBytes);

    final int matchIdLen = reader.readUnsignedVarint();
    final String matchId = utf8.decode(reader.readBytes(matchIdLen));
    final int sampleRateHz = reader.readUnsignedVarint();
    final int tickCount = reader.readUnsignedVarint();
    final int eventCount = reader.readUnsignedVarint();

    final Map<int, List<int>> prevEntityState = <int, List<int>>{};
    final List<UnpackedTelemetryTick> ticks =
        List<UnpackedTelemetryTick>.filled(
      tickCount,
      const UnpackedTelemetryTick(tickNumber: 0, timestamp: 0, entities: []),
      growable: false,
    );

    int prevTickNumber = 0;
    int prevTickTimeMicros = 0;

    for (int t = 0; t < tickCount; t++) {
      final int tickNumber = prevTickNumber + reader.readSignedVarint();
      final int timeMicros = prevTickTimeMicros + reader.readSignedVarint();
      final int entityCount = reader.readUnsignedVarint();

      prevTickNumber = tickNumber;
      prevTickTimeMicros = timeMicros;

      // Read through Float32 round-trip so timestamp matches Float32List exactly
      final double timestamp = _float32Round(timeMicros / 1000000.0);

      final List<UnpackedEntitySample> entities =
          List<UnpackedEntitySample>.filled(
        entityCount,
        const UnpackedEntitySample(
          entityId: 0,
          quantizedX: 0,
          quantizedY: 0,
          quantizedVx: 0,
          quantizedVy: 0,
          quantizedHull: 0,
        ),
        growable: false,
      );

      for (int e = 0; e < entityCount; e++) {
        final int entityId = reader.readSignedVarint();
        final int dX = reader.readSignedVarint();
        final int dY = reader.readSignedVarint();
        final int dVx = reader.readSignedVarint();
        final int dVy = reader.readSignedVarint();
        final int dHull = reader.readSignedVarint();

        final List<int>? prev = prevEntityState[entityId];
        final int qX;
        final int qY;
        final int qVx;
        final int qVy;
        final int qHull;

        if (prev == null) {
          qX = dX;
          qY = dY;
          qVx = dVx;
          qVy = dVy;
          qHull = dHull;
          prevEntityState[entityId] = <int>[qX, qY, qVx, qVy, qHull];
        } else {
          qX = prev[0] + dX;
          qY = prev[1] + dY;
          qVx = prev[2] + dVx;
          qVy = prev[3] + dVy;
          qHull = prev[4] + dHull;
          prev[0] = qX;
          prev[1] = qY;
          prev[2] = qVx;
          prev[3] = qVy;
          prev[4] = qHull;
        }

        entities[e] = UnpackedEntitySample(
          entityId: entityId,
          quantizedX: qX,
          quantizedY: qY,
          quantizedVx: qVx,
          quantizedVy: qVy,
          quantizedHull: qHull,
        );
      }

      ticks[t] = UnpackedTelemetryTick(
        tickNumber: tickNumber,
        timestamp: timestamp,
        entities: entities,
      );
    }

    final List<UnpackedTelemetryEvent> events =
        List<UnpackedTelemetryEvent>.filled(
      eventCount,
      const UnpackedTelemetryEvent(
        tickNumber: 0,
        timestamp: 0,
        type: TelemetryEventType.weaponHitscan,
        actorEntityId: 0,
        targetEntityId: 0,
        quantizedSourceX: 0,
        quantizedSourceY: 0,
        quantizedTargetX: 0,
        quantizedTargetY: 0,
        quantizedMagnitude: 0,
        metadataFlags: 0,
      ),
      growable: false,
    );

    int prevEventTick = 0;
    int prevEventTimeMicros = 0;

    for (int evIdx = 0; evIdx < eventCount; evIdx++) {
      final int tickNumber = prevEventTick + reader.readSignedVarint();
      final int timeMicros = prevEventTimeMicros + reader.readSignedVarint();
      final int typeCode = reader.readUnsignedVarint();
      final int actorId = reader.readSignedVarint();
      final int targetId = reader.readSignedVarint();
      final int qSourceX = reader.readSignedVarint();
      final int qSourceY = reader.readSignedVarint();
      final int qTargetX = reader.readSignedVarint();
      final int qTargetY = reader.readSignedVarint();
      final int qMagnitude = reader.readSignedVarint();
      final int metadataFlags = reader.readSignedVarint();

      prevEventTick = tickNumber;
      prevEventTimeMicros = timeMicros;

      events[evIdx] = UnpackedTelemetryEvent(
        tickNumber: tickNumber,
        timestamp: _float32Round(timeMicros / 1000000.0),
        type: TelemetryEventType.fromCode(typeCode),
        actorEntityId: actorId,
        targetEntityId: targetId,
        quantizedSourceX: qSourceX,
        quantizedSourceY: qSourceY,
        quantizedTargetX: qTargetX,
        quantizedTargetY: qTargetY,
        quantizedMagnitude: qMagnitude,
        metadataFlags: metadataFlags,
      );
    }

    return TelemetryReplayArchive(
      matchId: matchId,
      sampleRateHz: sampleRateHz,
      ticks: ticks,
      events: events,
    );
  }

  static final Float32List _scratchF32 = Float32List(1);
  static double _float32Round(double value) {
    _scratchF32[0] = value;
    return _scratchF32[0];
  }
}

class _VarintReader {
  _VarintReader(this._bytes);
  final Uint8List _bytes;
  int _offset = 0;

  int readUnsignedVarint() {
    int result = 0;
    int shift = 0;
    while (_offset < _bytes.length) {
      final int b = _bytes[_offset++];
      result |= (b & 0x7F) << shift;
      if ((b & 0x80) == 0) {
        return result;
      }
      shift += 7;
    }
    throw const FormatException('Unexpected EOF while reading varint.');
  }

  int readSignedVarint() =>
      TelemetryEventPacker.zigZagDecode(readUnsignedVarint());

  Uint8List readBytes(int count) {
    if (_offset + count > _bytes.length) {
      throw const FormatException('Unexpected EOF while reading byte slice.');
    }
    final Uint8List slice =
        Uint8List.sublistView(_bytes, _offset, _offset + count);
    _offset += count;
    return slice;
  }
}
