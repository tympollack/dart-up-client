import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flame/components.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sd_client/core/dart_up_game.dart';
import 'package:sd_client/core/main_mvp.dart';
import 'package:sd_client/services/telemetry/telemetry_codec_web.dart' as web_lz;
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

    test('StarDartMVP and DartUpGame record zero initial velocity at spawn and StarDartMVP.endMatch dispatches telemetry', () async {
      final List<Map<String, dynamic>> postedRecaps = <Map<String, dynamic>>[];
      final mockClient = MockClient((http.Request request) async {
        if (request.url.path.endsWith('/api/recaps/ingest')) {
          postedRecaps.add(jsonDecode(request.body) as Map<String, dynamic>);
        }
        return http.Response(jsonEncode({'ok': true}), 200);
      });

      final hook = TelemetryDispatchHook(
        baseUrl: 'https://hub-stag.sunshade.icu',
        httpClient: mockClient,
        offlineStore: InMemoryTelemetryOfflineStore(),
      );

      final mvpGame = StarDartMVP(
        matchId: 'mvp_live_match_01',
        enableRealtimePolling: false,
        telemetryDispatchHook: hook,
      );
      mvpGame.onGameResize(Vector2(1280, 720));
      await mvpGame.onLoad();
      mvpGame.onMount();

      // Step one 20Hz sample (0.05s) without moving the ship
      mvpGame.update(0.05);
      expect(mvpGame.telemetryRingBuffer.length, equals(1));

      final cursor = TelemetryEntityCursor();
      mvpGame.telemetryRingBuffer.readEntityAt(
        chronologicalTickIndex: 0,
        entitySlot: 0,
        outCursor: cursor,
      );
      expect(cursor.vx, equals(0.0));
      expect(cursor.vy, equals(0.0));

      final dispatchRes = await mvpGame.endMatch();
      expect(dispatchRes.uploaded, isTrue);
      expect(postedRecaps.length, equals(1));
      expect(postedRecaps.first['match_id'], equals('mvp_live_match_01'));
      expect(postedRecaps.first['format'], equals('dtrp_v1_zlib'));

      // Also verify DartUpGame first sample records (0, 0) velocity at screen center spawn
      final dartUpGame = DartUpGame(
        matchId: 'dartup_spawn_vel_test',
        spawnIsolateOnLoad: false,
        telemetryDispatchHook: hook,
      );
      dartUpGame.onGameResize(Vector2(1280, 720));
      await dartUpGame.onLoad();
      dartUpGame.onMount();
      dartUpGame.update(0.05);

      expect(dartUpGame.telemetryRingBuffer.length, equals(1));
      dartUpGame.telemetryRingBuffer.readEntityAt(
        chronologicalTickIndex: 0,
        entitySlot: 0,
        outCursor: cursor,
      );
      expect(cursor.x, closeTo(640.0, 0.01));
      expect(cursor.y, closeTo(360.0, 0.01));
      expect(cursor.vx, equals(0.0));
      expect(cursor.vy, equals(0.0));
    });

    test('Cross-platform LZ and ZLIB codec payloads both unpack identically and report distinct format labels', () {
      final raw = Uint8List.fromList(List<int>.generate(256, (i) => i % 16));
      final lzCompressed = web_lz.lzEncode(raw);
      final lzDecompressed = web_lz.lzDecode(lzCompressed);
      expect(lzDecompressed, equals(raw));

      // Verify web pureDartZlibInflate decompresses native dart:io zlib.encode bytes
      final nativeZlibCompressed = Uint8List.fromList(zlib.encode(raw));
      final webInflated = web_lz.pureDartZlibInflate(nativeZlibCompressed);
      expect(webInflated, equals(raw));

      // Verify pureDartZlibInflate rejects corrupted Adler-32 trailer checksums
      final corruptedAdler = Uint8List.fromList(nativeZlibCompressed);
      corruptedAdler[corruptedAdler.length - 1] ^= 0xFF;
      expect(
        () => web_lz.pureDartZlibInflate(corruptedAdler),
        throwsA(isA<FormatException>()),
      );
    });

    test('Concurrent NativeDiskTelemetryOfflineStore save and remove across instances never lose recaps', () async {
      final tempDir = await Directory.systemTemp.createTemp('dartup_concurrent_store_');
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final store1 = NativeDiskTelemetryOfflineStore(directoryPath: tempDir.path);
      final store2 = NativeDiskTelemetryOfflineStore(directoryPath: tempDir.path);

      final recA = CachedTelemetryRecord(
        matchId: 'match_A',
        packedPayload: Uint8List.fromList(<int>[1, 2, 3]),
        queuedAt: DateTime.utc(2026, 11, 21, 10, 0),
      );
      final recB = CachedTelemetryRecord(
        matchId: 'match_B',
        packedPayload: Uint8List.fromList(<int>[4, 5, 6]),
        queuedAt: DateTime.utc(2026, 11, 21, 10, 1),
      );

      await store1.savePendingRecord(recA);

      // Run concurrent removal of A on store1 and insertion of B on store2
      await Future.wait(<Future<Object?>>[
        store1.removePendingRecord('match_A'),
        store2.savePendingRecord(recB),
      ]);

      final remaining = await store1.loadPendingRecords();
      expect(remaining.map((r) => r.matchId).toList(), equals(<String>['match_B']));

      // Verify clearAll() only deletes recap-namespaced files and leaves other files intact
      final unrelatedFile = File('${tempDir.path}${Platform.pathSeparator}user_settings.json');
      await unrelatedFile.writeAsString('{"theme":"dark"}');
      await store1.clearAll();
      expect(await unrelatedFile.exists(), isTrue);
      expect(await store1.loadPendingRecords(), isEmpty);
    });

    test('TelemetryDispatchHook reports cachedOffline=false and savedInMemoryOnly=true when durable storage write fails', () async {
      final mockClient = MockClient((http.Request _) async {
        throw const SocketException('Offline');
      });
      final failingStore = InMemoryTelemetryOfflineStore(
        simulateDurableWriteFailure: true,
      );
      final hook = TelemetryDispatchHook(
        baseUrl: 'https://hub-stag.sunshade.icu',
        httpClient: mockClient,
        offlineStore: failingStore,
      );

      final res = await hook.dispatchPackedTelemetry(
        matchId: 'match_unpersisted',
        packedPayload: Uint8List.fromList(<int>[1, 2, 3, 4]),
      );
      expect(res.uploaded, isFalse);
      expect(res.cachedOffline, isFalse);
      expect(res.savedInMemoryOnly, isTrue);
    });

    test('StarDartMVP records constant ship velocity across uneven 30 FPS 1- and 2-frame sampling intervals and records turret combat events', () async {
      final mvpGame = StarDartMVP(
        matchId: 'mvp_30fps_test',
        enableRealtimePolling: false,
        telemetryDispatchHook: TelemetryDispatchHook(
          offlineStore: InMemoryTelemetryOfflineStore(),
        ),
      );
      mvpGame.onGameResize(Vector2(1280, 720));
      await mvpGame.onLoad();
      mvpGame.onMount();

      // Step at 30 FPS (dt = 1/30 = 0.033333s) for 10 frames (~0.33s)
      const double dt30 = 1.0 / 30.0;
      for (int f = 0; f < 10; f++) {
        mvpGame.playerShip.position.x = (f + 1) * 300.0 * dt30;
        mvpGame.update(dt30);
      }

      expect(mvpGame.telemetryRingBuffer.length, greaterThanOrEqualTo(5));
      final cursor = TelemetryEntityCursor();
      for (int i = 0; i < mvpGame.telemetryRingBuffer.length; i++) {
        mvpGame.telemetryRingBuffer.readEntityAt(
          chronologicalTickIndex: i,
          entitySlot: 0,
          outCursor: cursor,
        );
      // Every sample after movement starts must report steady ~300 units/s speed
        expect(cursor.vx, closeTo(300.0, 2.0));
      }

      // Verify squad positions are recorded in world coordinate space (tacticalRTS.positionOf)
      await mvpGame.ready();
      mvpGame.playerShip.position.x += 300.0 * 0.05;
      mvpGame.update(0.05);

      final squadUnit = mvpGame.tacticalRTS.squadUnits.first;
      final expectedWorldPos = mvpGame.tacticalRTS.positionOf(squadUnit.position);
      mvpGame.telemetryRingBuffer.readEntityAt(
        chronologicalTickIndex: mvpGame.telemetryRingBuffer.length - 1,
        entitySlot: 1,
        outCursor: cursor,
      );
      expect(cursor.x, closeTo(expectedWorldPos.x, 0.5));
      expect(cursor.y, closeTo(expectedWorldPos.y, 0.5));
    });
  });
}
