import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sd_client/services/telemetry/telemetry_dispatch_hook.dart';
import 'package:sd_client/services/telemetry/telemetry_event_packer.dart';
import 'package:sd_client/services/telemetry/telemetry_storage_native.dart';
import 'package:sd_client/simulation/telemetry/telemetry_ring_buffer.dart';

void main() {
  group('TASK-DARTUP-TELEMETRY-PACKER: Delta-Encoded Telemetry Serializer (<120 KB) & Offline Cache', () {
    test('Standard 10-minute match (12,000 ticks at 20Hz) serializes under 120 KB and round-trips with identical entity coordinates and event timestamps', () {
      const int tenMinTicks = 12000; // 10 minutes * 60s * 20Hz
      final buffer = TelemetryRingBuffer(
        capacityTicks: tenMinTicks,
        maxEntitiesPerTick: 4,
        eventCapacity: 4096,
      );

      // Populate realistic 10-minute match trajectories and combat/warp/ledger events
      double p1X = 0.0, p1Y = 0.0, p1Vx = 45.0, p1Vy = 30.0, p1Hull = 100.0;
      double p2X = 1200.0, p2Y = -800.0, p2Vx = -35.0, p2Vy = 25.0, p2Hull = 100.0;
      double bossX = 500.0, bossY = 500.0, bossVx = 10.0, bossVy = -15.0, bossHull = 500.0;

      for (int tick = 0; tick < tenMinTicks; tick++) {
        final double t = tick * 0.05;
        buffer.beginTick(tickNumber: tick, timestamp: t);

        // Smooth orbital / dogfight acceleration changes every few seconds
        if (tick % 40 == 0) {
          final double phase = tick * 0.01;
          p1Vx = 45.0 * math.cos(phase);
          p1Vy = 30.0 * math.sin(phase);
          p2Vx = -35.0 * math.sin(phase);
          p2Vy = 25.0 * math.cos(phase);
        }

        p1X += p1Vx * 0.05;
        p1Y += p1Vy * 0.05;
        p2X += p2Vx * 0.05;
        p2Y += p2Vy * 0.05;
        bossX += bossVx * 0.05;
        bossY += bossVy * 0.05;

        buffer.recordEntityState(
          entityId: 1,
          x: p1X,
          y: p1Y,
          vx: p1Vx,
          vy: p1Vy,
          hull: p1Hull,
        );
        buffer.recordEntityState(
          entityId: 2,
          x: p2X,
          y: p2Y,
          vx: p2Vx,
          vy: p2Vy,
          hull: p2Hull,
        );
        buffer.recordEntityState(
          entityId: 99,
          x: bossX,
          y: bossY,
          vx: bossVx,
          vy: bossVy,
          hull: bossHull,
        );

        if (tick % 100 == 0) {
          buffer.recordWeaponEvent(
            attackerId: 1,
            targetId: 2,
            sourceX: p1X,
            sourceY: p1Y,
            targetX: p2X,
            targetY: p2Y,
            damage: 10.0,
          );
        }
        if (tick % 600 == 0) {
          buffer.recordWarpWakeEmission(
            shipEntityId: 1,
            originX: p1X,
            originY: p1Y,
            targetX: bossX,
            targetY: bossY,
            energySignature: 0.90,
            driveTypeCode: 1,
          );
        }
        if (tick == 3000) {
          buffer.recordAllianceToggle(
            actorPlayerId: 1,
            targetPlayerId: 2,
            sectorX: p1X,
            sectorY: p1Y,
            intentTypeCode: 1,
            magnitude: 50.0,
          );
        }
      }

      final Uint8List packed = TelemetryEventPacker.pack(
        buffer,
        matchId: 'match_10min_benchmark',
      );

      // Must serialize under 120 KB (122,880 bytes)
      expect(packed.length, lessThan(kMaxSerializedMatchBytes));

      // Round-trip unpack verification
      final TelemetryReplayArchive unpacked = TelemetryEventPacker.unpack(packed);
      expect(unpacked.matchId, equals('match_10min_benchmark'));
      expect(unpacked.sampleRateHz, equals(20));
      expect(unpacked.ticks.length, equals(tenMinTicks));
      expect(unpacked.events.length, equals(buffer.retainedEventCount));

      final entityCursor = TelemetryEntityCursor();
      for (int t = 0; t < tenMinTicks; t += 17) {
        final unpackedTick = unpacked.ticks[t];
        final int ringSlot = buffer.ringSlotForChronologicalIndex(t);
        expect(unpackedTick.tickNumber, equals(buffer.tickNumbers[ringSlot]));
        expect(
          unpackedTick.timestamp,
          closeTo(buffer.tickTimestamps[ringSlot], 1e-4),
        );

        for (int e = 0; e < unpackedTick.entities.length; e++) {
          buffer.readEntityAt(
            chronologicalTickIndex: t,
            entitySlot: e,
            outCursor: entityCursor,
          );
          final sample = unpackedTick.entities[e];
          expect(sample.entityId, equals(entityCursor.entityId));
          expect(sample.quantizedX, equals(entityCursor.quantizedX));
          expect(sample.quantizedY, equals(entityCursor.quantizedY));
          expect(sample.quantizedVx, equals(entityCursor.quantizedVx));
          expect(sample.quantizedVy, equals(entityCursor.quantizedVy));
          expect(sample.quantizedHull, equals(entityCursor.quantizedHull));
        }
      }

      final eventCursor = TelemetryEventCursor();
      for (int i = 0; i < unpacked.events.length; i++) {
        buffer.readRetainedEventAt(
          chronologicalEventIndex: i,
          outCursor: eventCursor,
        );
        final ev = unpacked.events[i];
        expect(ev.tickNumber, equals(eventCursor.tickNumber));
        expect(ev.timestamp, closeTo(eventCursor.timestamp, 1e-4));
        expect(ev.type, equals(eventCursor.type));
        expect(ev.actorEntityId, equals(eventCursor.actorEntityId));
        expect(ev.targetEntityId, equals(eventCursor.targetEntityId));
        expect(ev.quantizedSourceX, equals(eventCursor.quantizedSourceX));
        expect(ev.quantizedSourceY, equals(eventCursor.quantizedSourceY));
        expect(ev.quantizedTargetX, equals(eventCursor.quantizedTargetX));
        expect(ev.quantizedTargetY, equals(eventCursor.quantizedTargetY));
        expect(ev.quantizedMagnitude, equals(eventCursor.quantizedMagnitude));
        expect(ev.metadataFlags, equals(eventCursor.metadataFlags));
      }
    });

    test('TelemetryDispatchHook caches failed uploads to disk/offline store and flushes on next app launch', () async {
      final tempDir = await Directory.systemTemp.createTemp('dartup_telemetry_test_');
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final diskStore = NativeDiskTelemetryOfflineStore(
        directoryPath: tempDir.path,
      );

      final ringBuffer = TelemetryRingBuffer(
        capacityTicks: 20,
        maxEntitiesPerTick: 2,
        eventCapacity: 16,
      );
      for (int t = 0; t < 10; t++) {
        ringBuffer.beginTick(tickNumber: t, timestamp: t * 0.05);
        ringBuffer.recordEntityState(
          entityId: 1,
          x: t * 12.0,
          y: t * -4.0,
          vx: 12.0,
          vy: -4.0,
          hull: 100.0,
        );
      }

      bool networkOnline = false;
      final List<Map<String, dynamic>> receivedPayloads = <Map<String, dynamic>>[];

      final mockClient = MockClient((http.Request request) async {
        if (!networkOnline) {
          throw const SocketException('Simulated offline failure');
        }
        final decoded = jsonDecode(request.body) as Map<String, dynamic>;
        receivedPayloads.add(decoded);
        return http.Response(
          jsonEncode({'ok': true, 'match_id': decoded['match_id']}),
          200,
        );
      });

      final hookSession1 = TelemetryDispatchHook(
        baseUrl: 'https://hub-stag.sunshade.icu',
        httpClient: mockClient,
        offlineStore: diskStore,
        accessTokenProvider: () => 'test-jwt-token',
      );

      // 1. Dispatch while offline -> fails and persists to disk cache
      final failResult = await hookSession1.dispatchMatchTelemetry(
        matchId: 'match_offline_101',
        ringBuffer: ringBuffer,
      );
      expect(failResult.uploaded, isFalse);
      expect(failResult.cachedOffline, isTrue);

      final pendingOnDisk = await diskStore.loadPendingRecords();
      expect(pendingOnDisk.length, equals(1));
      expect(pendingOnDisk.first.matchId, equals('match_offline_101'));

      // 2. Simulate next app launch with network restored -> flushPendingQueue()
      networkOnline = true;
      final hookSession2 = TelemetryDispatchHook(
        baseUrl: 'https://hub-stag.sunshade.icu',
        httpClient: mockClient,
        offlineStore: NativeDiskTelemetryOfflineStore(
          directoryPath: tempDir.path,
        ),
        accessTokenProvider: () => 'test-jwt-token',
      );

      final flushResults = await hookSession2.flushPendingQueue();
      expect(flushResults.length, equals(1));
      expect(flushResults.first.uploaded, isTrue);
      expect(flushResults.first.cachedOffline, isFalse);
      expect(receivedPayloads.length, equals(1));
      expect(receivedPayloads.first['match_id'], equals('match_offline_101'));

      // Verify offline queue is now empty after flush
      final remainingAfterFlush = await diskStore.loadPendingRecords();
      expect(remainingAfterFlush, isEmpty);
    });
  });
}
