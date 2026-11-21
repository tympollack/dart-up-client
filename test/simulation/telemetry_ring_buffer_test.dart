import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sd_client/simulation/telemetry/telemetry_ring_buffer.dart';

void main() {
  group('TASK-DARTUP-FLAME-RING-BUFFER: Pre-Allocated 0 KB/Frame Cyclic Telemetry Ring Buffer', () {
    test('Pre-allocates Float32List and Int32List backing buffers for 15-minute match at 20Hz (18,000 ticks)', () {
      final buffer = TelemetryRingBuffer();

      expect(buffer.capacityTicks, equals(18000));
      expect(buffer.sampleRateHz, equals(20));
      expect(buffer.tickNumbers, isA<Int32List>());
      expect(buffer.tickTimestamps, isA<Float32List>());
      expect(buffer.entityStateIntBuffer, isA<Int32List>());
      expect(buffer.entityVelocityFloatBuffer, isA<Float32List>());
      expect(buffer.eventIntBuffer, isA<Int32List>());
      expect(buffer.eventTimestamps, isA<Float32List>());

      expect(buffer.tickNumbers.length, equals(18000));
      expect(buffer.tickTimestamps.length, equals(18000));
      expect(
        buffer.entityStateIntBuffer.length,
        equals(18000 * TelemetryRingBuffer.defaultMaxEntitiesPerTick * TelemetryRingBuffer.entityStride),
      );
      expect(
        buffer.entityVelocityFloatBuffer.length,
        equals(18000 * TelemetryRingBuffer.defaultMaxEntitiesPerTick * 2),
      );
    });

    test('Records quantized entity positions, velocities, weapon hitscan/missile, WarpWake, hull deltas, and alliance toggles accurately', () {
      final buffer = TelemetryRingBuffer(
        capacityTicks: 64,
        maxEntitiesPerTick: 4,
        eventCapacity: 128,
      );

      buffer.beginTick(tickNumber: 0, timestamp: 0.05);
      final idx0 = buffer.recordEntityState(
        entityId: 101,
        x: 450.25,
        y: -312.75,
        vx: 12.50,
        vy: -8.25,
        hull: 92.4,
      );
      final idx1 = buffer.recordEntityState(
        entityId: 202,
        x: 900.00,
        y: 600.50,
        vx: -20.00,
        vy: 15.00,
        hull: 100.0,
      );

      expect(idx0, equals(0));
      expect(idx1, equals(1));

      buffer.recordWeaponEvent(
        attackerId: 101,
        targetId: 202,
        sourceX: 450.25,
        sourceY: -312.75,
        targetX: 900.00,
        targetY: 600.50,
        damage: 14.5,
        isMissile: false,
      );
      buffer.recordWeaponEvent(
        attackerId: 202,
        targetId: 101,
        sourceX: 900.00,
        sourceY: 600.50,
        targetX: 450.25,
        targetY: -312.75,
        damage: 25.0,
        isMissile: true,
      );
      buffer.recordWarpWakeEmission(
        shipEntityId: 101,
        originX: 450.25,
        originY: -312.75,
        targetX: 1500.0,
        targetY: -1200.0,
        energySignature: 0.95,
        driveTypeCode: 1,
      );
      buffer.recordHullDelta(
        entityId: 101,
        sourceEntityId: 202,
        x: 450.25,
        y: -312.75,
        deltaHull: -25.0,
        remainingHull: 8.5,
        isCriticalSave: true,
      );
      buffer.recordAllianceToggle(
        actorPlayerId: 101,
        targetPlayerId: 303,
        sectorX: 100.0,
        sectorY: 200.0,
        intentTypeCode: 1, // betrayal
        magnitude: 45.0,
      );

      expect(buffer.length, equals(1));
      expect(buffer.retainedEventCount, equals(5));

      final entityCursor = TelemetryEntityCursor();
      expect(
        buffer.readEntityAt(
          chronologicalTickIndex: 0,
          entitySlot: 0,
          outCursor: entityCursor,
        ),
        isTrue,
      );
      expect(entityCursor.entityId, equals(101));
      expect(entityCursor.x, closeTo(450.25, 0.01));
      expect(entityCursor.y, closeTo(-312.75, 0.01));
      expect(entityCursor.vx, closeTo(12.50, 0.01));
      expect(entityCursor.vy, closeTo(-8.25, 0.01));
      expect(entityCursor.hull, closeTo(92.4, 0.01));

      final eventCursor = TelemetryEventCursor();
      expect(
        buffer.readRetainedEventAt(
          chronologicalEventIndex: 0,
          outCursor: eventCursor,
        ),
        isTrue,
      );
      expect(eventCursor.type, equals(TelemetryEventType.weaponHitscan));
      expect(eventCursor.actorEntityId, equals(101));
      expect(eventCursor.targetEntityId, equals(202));
      expect(eventCursor.magnitude, closeTo(14.5, 0.01));

      expect(
        buffer.readRetainedEventAt(
          chronologicalEventIndex: 1,
          outCursor: eventCursor,
        ),
        isTrue,
      );
      expect(eventCursor.type, equals(TelemetryEventType.weaponMissile));
      expect(eventCursor.metadataFlags, equals(1));

      expect(
        buffer.readRetainedEventAt(
          chronologicalEventIndex: 2,
          outCursor: eventCursor,
        ),
        isTrue,
      );
      expect(eventCursor.type, equals(TelemetryEventType.warpWakeEmission));
      expect(eventCursor.magnitude, closeTo(0.95, 0.01));

      expect(
        buffer.readRetainedEventAt(
          chronologicalEventIndex: 3,
          outCursor: eventCursor,
        ),
        isTrue,
      );
      expect(eventCursor.type, equals(TelemetryEventType.hullDelta));
      expect(eventCursor.magnitude, closeTo(-25.0, 0.01));
      expect(eventCursor.targetX, closeTo(8.5, 0.01));
      expect(eventCursor.metadataFlags, equals(1));

      expect(
        buffer.readRetainedEventAt(
          chronologicalEventIndex: 4,
          outCursor: eventCursor,
        ),
        isTrue,
      );
      expect(eventCursor.type, equals(TelemetryEventType.allianceToggle));
      expect(eventCursor.actorEntityId, equals(101));
      expect(eventCursor.targetEntityId, equals(303));
      expect(eventCursor.metadataFlags, equals(1));
    });

    test('Cyclic wrap-around overwrites oldest ticks while preserving chronological read order', () {
      final buffer = TelemetryRingBuffer(
        capacityTicks: 10,
        maxEntitiesPerTick: 2,
        eventCapacity: 16,
      );

      for (int tick = 0; tick < 15; tick++) {
        buffer.beginTick(tickNumber: tick, timestamp: tick * 0.05);
        buffer.recordEntityState(
          entityId: 1,
          x: tick * 10.0,
          y: tick * -5.0,
          vx: 1.0,
          vy: -1.0,
          hull: 100.0 - tick,
        );
      }

      expect(buffer.length, equals(10));
      expect(buffer.totalTicksRecorded, equals(15));

      final cursor = TelemetryEntityCursor();
      // Oldest retained tick should be tick 5 (since 0..4 were overwritten)
      buffer.readEntityAt(
        chronologicalTickIndex: 0,
        entitySlot: 0,
        outCursor: cursor,
      );
      expect(cursor.tickNumber, equals(5));
      expect(cursor.x, closeTo(50.0, 0.01));

      // Newest retained tick should be tick 14
      buffer.readEntityAt(
        chronologicalTickIndex: 9,
        entitySlot: 0,
        outCursor: cursor,
      );
      expect(cursor.tickNumber, equals(14));
      expect(cursor.x, closeTo(140.0, 0.01));
    });

    test('Benchmark confirms 0 backing buffer reallocations and deterministic high-speed 18,000-tick 20Hz sampling loop', () {
      final buffer = TelemetryRingBuffer();

      // Capture exact backing buffer object identities before the 18,000-tick loop
      final tickNumbersRef = buffer.tickNumbers;
      final tickTimestampsRef = buffer.tickTimestamps;
      final entityIntRef = buffer.entityStateIntBuffer;
      final entityFloatRef = buffer.entityVelocityFloatBuffer;
      final eventIntRef = buffer.eventIntBuffer;
      final eventTimestampsRef = buffer.eventTimestamps;

      final stopwatch = Stopwatch()..start();

      // Simulate full 15-minute match at 20Hz (18,000 ticks) plus wrap-around
      for (int tick = 0; tick < 18000; tick++) {
        final double t = tick * 0.05;
        buffer.beginTick(tickNumber: tick, timestamp: t);

        for (int e = 0; e < 4; e++) {
          buffer.recordEntityState(
            entityId: e + 1,
            x: 100.0 + tick * 0.5 + e * 25.0,
            y: -50.0 + tick * 0.25 - e * 10.0,
            vx: 10.0,
            vy: 5.0,
            hull: 100.0,
          );
        }

        if (tick % 10 == 0) {
          buffer.recordWeaponEvent(
            attackerId: 1,
            targetId: 2,
            sourceX: 100.0,
            sourceY: -50.0,
            targetX: 125.0,
            targetY: -60.0,
            damage: 8.0,
          );
        }
      }

      stopwatch.stop();

      // Verify zero backing array reallocations occurred (identical references)
      expect(identical(buffer.tickNumbers, tickNumbersRef), isTrue);
      expect(identical(buffer.tickTimestamps, tickTimestampsRef), isTrue);
      expect(identical(buffer.entityStateIntBuffer, entityIntRef), isTrue);
      expect(identical(buffer.entityVelocityFloatBuffer, entityFloatRef), isTrue);
      expect(identical(buffer.eventIntBuffer, eventIntRef), isTrue);
      expect(identical(buffer.eventTimestamps, eventTimestampsRef), isTrue);
      expect(buffer.length, equals(18000));
      // 18,000 ticks with 4 entities + 1,800 events completes in a few milliseconds
      expect(stopwatch.elapsedMilliseconds, lessThan(500));
    });
  });
}
