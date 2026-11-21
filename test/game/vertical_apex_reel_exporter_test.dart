import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:sd_client/game/reels/reel_share_adapter_native.dart';
import 'package:sd_client/game/reels/vertical_apex_reel_exporter.dart';
import 'package:sd_client/simulation/telemetry/telemetry_ring_buffer.dart';

void main() {
  group('TASK-DARTUP-VERTICAL-REEL-MP4: 9:16 Vertical Apex Reel Isolator, Pilot Callsign HUD & MP4 Export', () {
    test('Isolates the player highest-scoring 20-30s peak Drama Index window from a 5-minute match', () {
      const int fiveMinuteTicks = 5 * 60 * 20; // 6,000 ticks at 20Hz
      final buffer = TelemetryRingBuffer(
        capacityTicks: fiveMinuteTicks,
        maxEntitiesPerTick: 4,
        eventCapacity: 4096,
      );

      for (int tick = 0; tick < fiveMinuteTicks; tick++) {
        final double t = tick * 0.05;
        buffer.beginTick(tickNumber: tick, timestamp: t);

        // Player ship (entity 1) and off-screen enemies (entity 2 and Star Dart 99)
        buffer.recordEntityState(
          entityId: 1,
          x: tick * 0.5,
          y: 0.0,
          vx: 10.0,
          vy: 0.0,
          hull: (tick >= 2400 && tick <= 2800) ? 8.0 : 95.0,
        );
        buffer.recordEntityState(
          entityId: 2,
          x: tick * 0.5 + 1400.0, // Off-screen right (outside 1080x1920 half-width 540)
          y: 350.0,
          vx: -25.0,
          vy: 0.0,
          hull: 60.0,
        );
        buffer.recordEntityState(
          entityId: 99,
          x: tick * 0.5,
          y: -1500.0, // Off-screen top (outside 1080x1920 half-height 960)
          vx: 0.0,
          vy: 15.0,
          hull: 300.0,
        );

        // Inject intense combat climax window between t = 120s .. 140s (ticks 2400 .. 2800)
        if (tick >= 2400 && tick <= 2800) {
          if (tick % 4 == 0) {
            buffer.recordWeaponEvent(
              attackerId: 1,
              targetId: 2,
              sourceX: tick * 0.5,
              sourceY: 0.0,
              targetX: tick * 0.5 + 300.0,
              targetY: 100.0,
              damage: 28.0,
            );
          }
          if (tick == 2550) {
            buffer.recordHullDelta(
              entityId: 1,
              sourceEntityId: 2,
              x: tick * 0.5,
              y: 0.0,
              deltaHull: -45.0,
              remainingHull: 7.5,
              isCriticalSave: true,
            );
          }
          if (tick == 2650) {
            buffer.recordAllianceToggle(
              actorPlayerId: 1,
              targetPlayerId: 99,
              sectorX: tick * 0.5,
              sectorY: 0.0,
              intentTypeCode: 2, // Star Dart steal/capture
              magnitude: 100.0,
            );
          }
        }
      }

      final exporter = VerticalApexReelExporter(
        targetWindowDurationSeconds: 25.0,
      );
      final apex = exporter.isolateApexWindow(buffer, playerEntityId: 1);

      // Duration must be strictly in the 20-30s range (25.0s = 500 ticks)
      expect(apex.durationSeconds, inInclusiveRange(20.0, 30.0));
      // The isolated window must overlap the intense climax interval [2400 .. 2800]
      expect(apex.startTickNumber, lessThanOrEqualTo(2450));
      expect(apex.endTickNumber, greaterThanOrEqualTo(2750));
      expect(apex.combatEventCount, greaterThan(50));
      expect(apex.criticalClimaxCount, equals(2));
    });

    test('Renders 9:16 vertical viewport centered on player ship with directional screen-edge threat chevrons, Pilot Callsign outro card, and compiles valid offline MP4 to share sheet', () async {
      final tempDir = await Directory.systemTemp.createTemp('dartup_reel_test_');
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final buffer = TelemetryRingBuffer(
        capacityTicks: 600, // 30s at 20Hz
        maxEntitiesPerTick: 4,
        eventCapacity: 512,
      );

      for (int tick = 0; tick < 500; tick++) {
        buffer.beginTick(tickNumber: tick, timestamp: tick * 0.05);
        // Player at (250, -100)
        buffer.recordEntityState(
          entityId: 1,
          x: 250.0,
          y: -100.0,
          vx: 15.0,
          vy: 5.0,
          hull: 88.0,
        );
        // Hostile fighter outside the 9:16 crop (dx = +900 > 540)
        buffer.recordEntityState(
          entityId: 2,
          x: 1150.0,
          y: -100.0,
          vx: -30.0,
          vy: 0.0,
          hull: 75.0,
        );
        // Star Dart boss outside the 9:16 crop (dy = +1200 > 960)
        buffer.recordEntityState(
          entityId: 99,
          x: 250.0,
          y: 1100.0,
          vx: 0.0,
          vy: -20.0,
          hull: 400.0,
        );
      }

      final shareAdapter = NativeReelShareAdapter(
        customOutputDir: tempDir.path,
        invokeOsLauncher: false,
      );
      final exporter = VerticalApexReelExporter(
        shareAdapter: shareAdapter,
      );

      final ({CompiledVerticalReelMp4 reel, ReelShareResult shareResult})
          exported = await exporter.exportAndShareHighlightReel(
        ringBuffer: buffer,
        matchId: 'match_apex_916',
        pilotCallsign: 'CMDR_VANGUARD',
        castLedgerArchetypeBadge: 'VOID CORSAIR',
      );

      final reel = exported.reel;
      expect(reel.width, equals(1080));
      expect(reel.height, equals(1920));
      expect(reel.durationSeconds, inInclusiveRange(20.0, 30.0));
      expect(reel.frames, isNotEmpty);

      // Every frame is centered on the player ship in strict 9:16 aspect ratio
      final firstFrame = reel.frames.first;
      expect(firstFrame.isVertical9By16, isTrue);
      expect(firstFrame.cameraCenterX, closeTo(250.0, 0.01));
      expect(firstFrame.cameraCenterY, closeTo(-100.0, 0.01));

      // Verify screen-edge threat chevrons point toward off-screen enemies
      expect(firstFrame.threatChevrons.length, equals(2));
      final bossChevron = firstFrame.threatChevrons
          .firstWhere((c) => c.isStarDartBoss);
      expect(bossChevron.urgency, equals(1.0));

      // Verify watermarked Pilot Callsign outro card metadata
      expect(reel.outroCard.pilotCallsign, equals('CMDR_VANGUARD'));
      expect(reel.outroCard.castLedgerArchetypeBadge, equals('VOID CORSAIR'));
      expect(
        reel.outroCard.recapWatermarkUrl,
        equals('hub.sunshade.icu/recap/match_apex_916'),
      );
      expect(
        reel.outroCard.networkRecapWatermarkUrl,
        equals('hub.sunshade.network/recap/match_apex_916'),
      );
      expect(reel.frames.last.isOutroFrame, isTrue);

      // Verify canvas rendering executes cleanly for both gameplay and outro frames
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      exporter.renderFrameToCanvas(canvas, firstFrame);
      exporter.renderFrameToCanvas(canvas, reel.frames.last);
      final picture = recorder.endRecording();
      picture.dispose();

      // Verify offline MP4 container structure (`ftyp`, `moov`, `mvhd`, `trak`,
      // `mdia`, `minf`, `stbl`, `stsd`, `avc1`, `avcC`, `stts`, `stsc`, `stsz`, `stco`, `mdat`)
      final mp4Text = latin1.decode(reel.mp4Bytes);
      expect(mp4Text, contains('ftypisom'));
      expect(mp4Text, contains('moov'));
      expect(mp4Text, contains('mvhd'));
      expect(mp4Text, contains('trak'));
      expect(mp4Text, contains('tkhd'));
      expect(mp4Text, contains('mdia'));
      expect(mp4Text, contains('hdlr'));
      expect(mp4Text, contains('minf'));
      expect(mp4Text, contains('stbl'));
      expect(mp4Text, contains('stsd'));
      expect(mp4Text, contains('avc1'));
      expect(mp4Text, contains('avcC'));
      expect(mp4Text, contains('stts'));
      expect(mp4Text, contains('stsc'));
      expect(mp4Text, contains('stsz'));
      expect(mp4Text, contains('stco'));
      expect(mp4Text, contains('mdat'));
      expect(mp4Text, contains('CMDR_VANGUARD'));
      expect(mp4Text, contains('hub.sunshade.icu/recap/match_apex_916'));

      // Verify native share adapter persisted the MP4 clip and reported status
      expect(exported.shareResult.shared, isTrue);
      expect(
        exported.shareResult.status,
        equals(ReelShareStatus.savedOrDownloadedFallback),
      );
      expect(exported.shareResult.savedFilePath, isNotNull);
      final savedFile = File(exported.shareResult.savedFilePath!);
      expect(await savedFile.exists(), isTrue);
      expect(await savedFile.length(), equals(reel.mp4Bytes.length));

      // Probe and decode the exported MP4 video track to verify dimensions,
      // duration, sample table offsets, and decoded I_PCM luma planes
      final probed = VerticalApexReelExporter.probeAndDecodeMp4VideoTrack(
        reel.mp4Bytes,
      );
      expect(probed.width, equals(1080));
      expect(probed.height, equals(1920));
      expect(probed.sampleCount, equals(reel.frames.length));
      expect(probed.durationSeconds, closeTo(reel.durationSeconds, 0.05));
      expect(probed.videoSamples.first.first, equals(0x65)); // H.264 IDR slice
      expect(probed.decodedLumaPlanes.length, equals(reel.frames.length));
      expect(probed.decodedLumaPlanes.first[8 * 16 + 8], equals(235)); // Player ship center luma core
    });
  });
}
