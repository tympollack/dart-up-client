// =============================================================================
// vertical_apex_reel_exporter.dart
//
// 9:16 Vertical Personal Highlight Reel Isolator, Screen-Edge Threat Chevron
// Renderer, Watermarked Pilot Callsign Outro Card, and Offline Client-Side MP4
// Compiler & Native/Web Share Sheet Bridge.
// =============================================================================

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:sd_client/simulation/telemetry/telemetry_ring_buffer.dart';

import 'reel_share_adapter_interface.dart';
import 'reel_share_adapter_native.dart'
    if (dart.library.js_interop) 'reel_share_adapter_web.dart';

export 'reel_share_adapter_interface.dart';

/// Isolated 20–30s peak Drama Index window extracted from match telemetry.
class ApexTelemetryWindow {
  final int startTickIndex;
  final int endTickIndex;
  final int startTickNumber;
  final int endTickNumber;
  final double startTimeSeconds;
  final double endTimeSeconds;
  final double durationSeconds;
  final double peakDramaScore;
  final int combatEventCount;
  final int warpEventCount;
  final int allianceEventCount;
  final int criticalClimaxCount;

  const ApexTelemetryWindow({
    required this.startTickIndex,
    required this.endTickIndex,
    required this.startTickNumber,
    required this.endTickNumber,
    required this.startTimeSeconds,
    required this.endTimeSeconds,
    required this.durationSeconds,
    required this.peakDramaScore,
    required this.combatEventCount,
    required this.warpEventCount,
    required this.allianceEventCount,
    required this.criticalClimaxCount,
  });
}

/// Directional threat indicator clamped to the perimeter of the 9:16 viewport
/// when an enemy fighter or Star Dart boss lies outside the vertical crop.
class ScreenEdgeThreatChevron {
  final int threatEntityId;
  final double edgeX;
  final double edgeY;
  final double bearingRadians;
  final double distanceWorldUnits;
  final double urgency; // [0.0 .. 1.0]
  final bool isStarDartBoss;

  const ScreenEdgeThreatChevron({
    required this.threatEntityId,
    required this.edgeX,
    required this.edgeY,
    required this.bearingRadians,
    required this.distanceWorldUnits,
    required this.urgency,
    this.isStarDartBoss = false,
  });
}

/// Watermarked Pilot Callsign outro card metadata rendered at the end of a
/// 9:16 personal highlight reel.
class PilotCallsignOutroCard {
  final String pilotCallsign;
  final String castLedgerArchetypeBadge;
  final String matchId;
  final String recapDomain;

  const PilotCallsignOutroCard({
    required this.pilotCallsign,
    required this.castLedgerArchetypeBadge,
    required this.matchId,
    this.recapDomain = 'hub.sunshade.icu',
  });

  /// Canonical recap URL watermarked onto the outro card
  /// (e.g., `hub.sunshade.icu/recap/{match_id}`).
  String get recapWatermarkUrl => '$recapDomain/recap/$matchId';

  /// Secondary network alias (`hub.sunshade.network/recap/{match_id}`).
  String get networkRecapWatermarkUrl =>
      'hub.sunshade.network/recap/$matchId';
}

/// A single rendered 9:16 vertical viewport frame descriptor.
class VerticalReelFrameDescriptor {
  final int tickNumber;
  final double timestamp;
  final double viewportWidth;
  final double viewportHeight;
  final double cameraCenterX;
  final double cameraCenterY;
  final double kineticGloryScore;
  final bool isOutroFrame;
  final List<ScreenEdgeThreatChevron> threatChevrons;
  final PilotCallsignOutroCard outroCard;

  const VerticalReelFrameDescriptor({
    required this.tickNumber,
    required this.timestamp,
    required this.viewportWidth,
    required this.viewportHeight,
    required this.cameraCenterX,
    required this.cameraCenterY,
    required this.kineticGloryScore,
    required this.isOutroFrame,
    required this.threatChevrons,
    required this.outroCard,
  });

  /// Verifies strict 9:16 vertical aspect ratio (`width / height == 9 / 16`).
  bool get isVertical9By16 =>
      ((viewportWidth / viewportHeight) - (9.0 / 16.0)).abs() < 1e-4;
}

/// Complete compiled 9:16 MP4 highlight reel artifact produced offline.
class CompiledVerticalReelMp4 {
  final String matchId;
  final int width;
  final int height;
  final int fps;
  final double durationSeconds;
  final ApexTelemetryWindow apexWindow;
  final PilotCallsignOutroCard outroCard;
  final List<VerticalReelFrameDescriptor> frames;
  final Uint8List mp4Bytes;

  const CompiledVerticalReelMp4({
    required this.matchId,
    required this.width,
    required this.height,
    required this.fps,
    required this.durationSeconds,
    required this.apexWindow,
    required this.outroCard,
    required this.frames,
    required this.mp4Bytes,
  });
}

/// Isolates a player's highest-scoring 20–30s apex window from match telemetry,
/// renders a 9:16 vertical follow-cam viewport with directional screen-edge
/// threat chevrons, kinetic glory HUD, and watermarked Pilot Callsign outro,
/// and compiles offline to an ISO BMFF MP4 container ready for the OS share sheet.
class VerticalApexReelExporter {
  static const int defaultVerticalWidth = 1080;
  static const int defaultVerticalHeight = 1920;

  VerticalApexReelExporter({
    this.viewportWidth = defaultVerticalWidth,
    this.viewportHeight = defaultVerticalHeight,
    this.targetWindowDurationSeconds = 25.0,
    this.minWindowDurationSeconds = 20.0,
    this.maxWindowDurationSeconds = 30.0,
    this.outroDurationSeconds = 3.0,
    ReelShareAdapter? shareAdapter,
  })  : assert(
          ((viewportWidth / viewportHeight) - (9.0 / 16.0)).abs() < 1e-3,
          'Viewport dimensions must be 9:16 vertical aspect ratio.',
        ),
        _shareAdapter = shareAdapter ?? createPlatformReelShareAdapter();

  final int viewportWidth;
  final int viewportHeight;
  final double targetWindowDurationSeconds;
  final double minWindowDurationSeconds;
  final double maxWindowDurationSeconds;
  final double outroDurationSeconds;
  final ReelShareAdapter _shareAdapter;

  /// Scans [ringBuffer] using a sliding window (`20s .. 30s`) to isolate the
  /// player's highest-scoring Drama Index interval.
  ApexTelemetryWindow isolateApexWindow(
    TelemetryRingBuffer ringBuffer, {
    int playerEntityId = 1,
    double? preferredDurationSeconds,
  }) {
    final int totalTicks = ringBuffer.length;
    if (totalTicks == 0) {
      return const ApexTelemetryWindow(
        startTickIndex: 0,
        endTickIndex: 0,
        startTickNumber: 0,
        endTickNumber: 0,
        startTimeSeconds: 0.0,
        endTimeSeconds: 0.0,
        durationSeconds: 0.0,
        peakDramaScore: 0.0,
        combatEventCount: 0,
        warpEventCount: 0,
        allianceEventCount: 0,
        criticalClimaxCount: 0,
      );
    }

    final double clampedDuration = (preferredDurationSeconds ??
            targetWindowDurationSeconds)
        .clamp(minWindowDurationSeconds, maxWindowDurationSeconds);
    final int windowTicks = math.min(
      totalTicks,
      math.max(1, (clampedDuration * ringBuffer.sampleRateHz).round()),
    );

    // Precompute per-tick drama score from recorded events and player velocity/hull
    final Float64List tickDrama = Float64List(totalTicks);
    final Int32List tickCombatCounts = Int32List(totalTicks);
    final Int32List tickWarpCounts = Int32List(totalTicks);
    final Int32List tickAllianceCounts = Int32List(totalTicks);
    final Int32List tickClimaxCounts = Int32List(totalTicks);

    final Map<int, int> tickNumberToChronoIndex = <int, int>{};
    final TelemetryEntityCursor entityCursor = TelemetryEntityCursor();

    for (int i = 0; i < totalTicks; i++) {
      final int slot = ringBuffer.ringSlotForChronologicalIndex(i);
      final int tickNum = ringBuffer.tickNumbers[slot];
      tickNumberToChronoIndex[tickNum] = i;

      final int entityCount = ringBuffer.tickEntityCounts[slot];
      for (int e = 0; e < entityCount; e++) {
        ringBuffer.readEntityAt(
          chronologicalTickIndex: i,
          entitySlot: e,
          outCursor: entityCursor,
        );
        if (entityCursor.entityId == playerEntityId) {
          final double speed = math.sqrt(
            entityCursor.vx * entityCursor.vx +
                entityCursor.vy * entityCursor.vy,
          );
          tickDrama[i] += speed * 0.02;
          if (entityCursor.hull > 0 && entityCursor.hull < 15.0) {
            // Low-hull survival tension bonus
            tickDrama[i] += 8.0;
          }
        }
      }
    }

    final TelemetryEventCursor eventCursor = TelemetryEventCursor();
    for (int evIdx = 0; evIdx < ringBuffer.retainedEventCount; evIdx++) {
      ringBuffer.readRetainedEventAt(
        chronologicalEventIndex: evIdx,
        outCursor: eventCursor,
      );
      final int? chronoIdx = tickNumberToChronoIndex[eventCursor.tickNumber];
      if (chronoIdx == null) continue;

      final bool involvesPlayer = eventCursor.actorEntityId == playerEntityId ||
          eventCursor.targetEntityId == playerEntityId;
      final double playerMultiplier = involvesPlayer ? 2.0 : 1.0;

      switch (eventCursor.type) {
        case TelemetryEventType.weaponHitscan:
        case TelemetryEventType.weaponMissile:
          tickCombatCounts[chronoIdx]++;
          tickDrama[chronoIdx] +=
              (15.0 + eventCursor.magnitude.abs() * 1.5) * playerMultiplier;
        case TelemetryEventType.warpWakeEmission:
          tickWarpCounts[chronoIdx]++;
          tickDrama[chronoIdx] += 45.0 * playerMultiplier;
        case TelemetryEventType.hullDelta:
          tickCombatCounts[chronoIdx]++;
          tickDrama[chronoIdx] +=
              eventCursor.magnitude.abs() * 2.0 * playerMultiplier;
          if (eventCursor.metadataFlags == 1) {
            tickClimaxCounts[chronoIdx]++;
            tickDrama[chronoIdx] += 180.0 * playerMultiplier;
          }
        case TelemetryEventType.allianceToggle:
          tickAllianceCounts[chronoIdx]++;
          if (eventCursor.metadataFlags == 2) {
            // Star Dart steal/capture climax
            tickClimaxCounts[chronoIdx]++;
            tickDrama[chronoIdx] += 250.0 * playerMultiplier;
          } else {
            tickDrama[chronoIdx] += 95.0 * playerMultiplier;
          }
      }
    }

    // Sliding window sum over `windowTicks`
    double currentScore = 0.0;
    int currentCombat = 0;
    int currentWarp = 0;
    int currentAlliance = 0;
    int currentClimax = 0;

    for (int i = 0; i < windowTicks; i++) {
      currentScore += tickDrama[i];
      currentCombat += tickCombatCounts[i];
      currentWarp += tickWarpCounts[i];
      currentAlliance += tickAllianceCounts[i];
      currentClimax += tickClimaxCounts[i];
    }

    int bestStart = 0;
    double bestScore = currentScore;
    int bestCombat = currentCombat;
    int bestWarp = currentWarp;
    int bestAlliance = currentAlliance;
    int bestClimax = currentClimax;

    for (int start = 1; start <= totalTicks - windowTicks; start++) {
      final int leaving = start - 1;
      final int entering = start + windowTicks - 1;

      currentScore += tickDrama[entering] - tickDrama[leaving];
      currentCombat += tickCombatCounts[entering] - tickCombatCounts[leaving];
      currentWarp += tickWarpCounts[entering] - tickWarpCounts[leaving];
      currentAlliance +=
          tickAllianceCounts[entering] - tickAllianceCounts[leaving];
      currentClimax += tickClimaxCounts[entering] - tickClimaxCounts[leaving];

      if (currentScore > bestScore) {
        bestScore = currentScore;
        bestStart = start;
        bestCombat = currentCombat;
        bestWarp = currentWarp;
        bestAlliance = currentAlliance;
        bestClimax = currentClimax;
      }
    }

    final int bestEnd = bestStart + windowTicks - 1;
    final int startSlot = ringBuffer.ringSlotForChronologicalIndex(bestStart);
    final int endSlot = ringBuffer.ringSlotForChronologicalIndex(bestEnd);
    final double startTime = ringBuffer.tickTimestamps[startSlot];
    final double endTime = ringBuffer.tickTimestamps[endSlot];
    final double duration = math.max(
      ringBuffer.sampleIntervalSeconds,
      endTime - startTime + ringBuffer.sampleIntervalSeconds,
    );

    return ApexTelemetryWindow(
      startTickIndex: bestStart,
      endTickIndex: bestEnd,
      startTickNumber: ringBuffer.tickNumbers[startSlot],
      endTickNumber: ringBuffer.tickNumbers[endSlot],
      startTimeSeconds: startTime,
      endTimeSeconds: endTime,
      durationSeconds: duration,
      peakDramaScore: bestScore,
      combatEventCount: bestCombat,
      warpEventCount: bestWarp,
      allianceEventCount: bestAlliance,
      criticalClimaxCount: bestClimax,
    );
  }

  /// Computes directional screen-edge threat chevrons for all hostile entities
  /// that lie outside the 9:16 vertical viewport centered at `(cameraX, cameraY)`.
  List<ScreenEdgeThreatChevron> computeScreenEdgeThreatChevrons({
    required double cameraX,
    required double cameraY,
    required List<({int entityId, double x, double y, bool isStarDartBoss})>
        hostiles,
    double edgeMarginPixels = 36.0,
    double maxThreatRangeWorldUnits = 2400.0,
  }) {
    final double halfW = viewportWidth * 0.5;
    final double halfH = viewportHeight * 0.5;
    final double clampedHalfW = math.max(10.0, halfW - edgeMarginPixels);
    final double clampedHalfH = math.max(10.0, halfH - edgeMarginPixels);

    final List<ScreenEdgeThreatChevron> chevrons = <ScreenEdgeThreatChevron>[];

    for (final hostile in hostiles) {
      final double dx = hostile.x - cameraX;
      final double dy = hostile.y - cameraY;

      // Skip entities already visible inside the 9:16 vertical crop
      if (dx.abs() <= halfW && dy.abs() <= halfH) {
        continue;
      }

      final double dist = math.sqrt(dx * dx + dy * dy);
      if (dist > maxThreatRangeWorldUnits || dist <= 1e-6) {
        continue;
      }

      final double bearing = math.atan2(dy, dx);
      // Ray-rectangle intersection from viewport center (halfW, halfH) to edge perimeter
      final double scaleX =
          dx.abs() > 1e-6 ? clampedHalfW / dx.abs() : double.infinity;
      final double scaleY =
          dy.abs() > 1e-6 ? clampedHalfH / dy.abs() : double.infinity;
      final double rayScale = math.min(scaleX, scaleY);

      final double edgeX = halfW + dx * rayScale;
      final double edgeY = halfH + dy * rayScale;
      final double urgency =
          (1.0 - (dist / maxThreatRangeWorldUnits)).clamp(0.15, 1.0);

      chevrons.add(
        ScreenEdgeThreatChevron(
          threatEntityId: hostile.entityId,
          edgeX: edgeX,
          edgeY: edgeY,
          bearingRadians: bearing,
          distanceWorldUnits: dist,
          urgency: hostile.isStarDartBoss ? 1.0 : urgency,
          isStarDartBoss: hostile.isStarDartBoss,
        ),
      );
    }

    return chevrons;
  }

  /// Renders a single 9:16 vertical frame onto a [ui.Canvas] with:
  /// - Player ship centered in the 9:16 follow-cam viewport
  /// - Directional screen-edge threat chevrons
  /// - Kinetic Glory HUD header
  /// - Watermarked Pilot Callsign & Cast Ledger archetype badge outro overlay
  void renderFrameToCanvas(
    ui.Canvas canvas,
    VerticalReelFrameDescriptor frame,
  ) {
    final ui.Rect fullRect = ui.Rect.fromLTWH(
      0,
      0,
      frame.viewportWidth,
      frame.viewportHeight,
    );

    // Deep space background
    final ui.Paint bgPaint = ui.Paint()..color = const ui.Color(0xFF070B19);
    canvas.drawRect(fullRect, bgPaint);

    // Player ship at center of 9:16 vertical viewport
    final double cx = frame.viewportWidth * 0.5;
    final double cy = frame.viewportHeight * 0.5;
    final ui.Paint shipPaint = ui.Paint()..color = const ui.Color(0xFF00E5FF);
    canvas.drawCircle(ui.Offset(cx, cy), 18.0, shipPaint);

    // Directional screen-edge threat chevrons
    for (final chevron in frame.threatChevrons) {
      final ui.Paint chevronPaint = ui.Paint()
        ..color = chevron.isStarDartBoss
            ? const ui.Color(0xFFFFD600)
            : const ui.Color(0xFFFF1744)
        ..style = ui.PaintingStyle.fill;

      canvas.save();
      canvas.translate(chevron.edgeX, chevron.edgeY);
      canvas.rotate(chevron.bearingRadians);

      final ui.Path path = ui.Path()
        ..moveTo(14.0, 0.0)
        ..lineTo(-10.0, -9.0)
        ..lineTo(-5.0, 0.0)
        ..lineTo(-10.0, 9.0)
        ..close();
      canvas.drawPath(path, chevronPaint);
      canvas.restore();
    }

    // Kinetic Glory HUD bar at top
    final ui.Paint hudPaint = ui.Paint()..color = const ui.Color(0xCC0D1B2A);
    canvas.drawRRect(
      ui.RRect.fromRectAndRadius(
        ui.Rect.fromLTWH(24.0, 48.0, frame.viewportWidth - 48.0, 64.0),
        const ui.Radius.circular(12.0),
      ),
      hudPaint,
    );

    if (frame.isOutroFrame) {
      // Outro card overlay displaying Pilot Callsign, Cast Ledger badge & recap URL
      final ui.Paint outroBg = ui.Paint()..color = const ui.Color(0xE6050814);
      canvas.drawRect(fullRect, outroBg);

      final ui.Paint badgeAccent = ui.Paint()
        ..color = const ui.Color(0xFF00E5FF)
        ..style = ui.PaintingStyle.stroke
        ..strokeWidth = 3.0;
      canvas.drawRRect(
        ui.RRect.fromRectAndRadius(
          ui.Rect.fromCenter(
            center: ui.Offset(cx, cy),
            width: frame.viewportWidth * 0.82,
            height: 360.0,
          ),
          const ui.Radius.circular(20.0),
        ),
        badgeAccent,
      );
    }
  }

  /// Isolates the player's top 20–30s apex window from [ringBuffer], builds the
  /// 9:16 vertical viewport frames with screen-edge threat chevrons and the
  /// watermarked Pilot Callsign outro card, and compiles them offline into a
  /// valid ISO BMFF MP4 byte stream (`ftyp`, `moov`, `trak`, `mdat`).
  CompiledVerticalReelMp4 exportHighlightReelMp4({
    required TelemetryRingBuffer ringBuffer,
    required String matchId,
    required String pilotCallsign,
    String castLedgerArchetypeBadge = 'APEX INTERCEPTOR',
    int playerEntityId = 1,
    int starDartEntityId = 99,
    double? preferredDurationSeconds,
  }) {
    final ApexTelemetryWindow apexWindow = isolateApexWindow(
      ringBuffer,
      playerEntityId: playerEntityId,
      preferredDurationSeconds: preferredDurationSeconds,
    );

    final PilotCallsignOutroCard outroCard = PilotCallsignOutroCard(
      pilotCallsign: pilotCallsign,
      castLedgerArchetypeBadge: castLedgerArchetypeBadge,
      matchId: matchId,
    );

    final List<VerticalReelFrameDescriptor> frames =
        <VerticalReelFrameDescriptor>[];
    final TelemetryEntityCursor entityCursor = TelemetryEntityCursor();

    if (ringBuffer.length > 0) {
      final int outroTicks = math.max(
        1,
        (outroDurationSeconds * ringBuffer.sampleRateHz).round(),
      );
      final int startIdx = apexWindow.startTickIndex;
      final int endIdx = apexWindow.endTickIndex;

      double runningGlory = 100.0;

      for (int idx = startIdx; idx <= endIdx; idx++) {
        final int slot = ringBuffer.ringSlotForChronologicalIndex(idx);
        final int tickNum = ringBuffer.tickNumbers[slot];
        final double timestamp = ringBuffer.tickTimestamps[slot];
        final int entityCount = ringBuffer.tickEntityCounts[slot];

        double playerX = 0.0;
        double playerY = 0.0;
        final List<({int entityId, double x, double y, bool isStarDartBoss})>
            hostiles =
            <({int entityId, double x, double y, bool isStarDartBoss})>[];

        for (int e = 0; e < entityCount; e++) {
          ringBuffer.readEntityAt(
            chronologicalTickIndex: idx,
            entitySlot: e,
            outCursor: entityCursor,
          );
          if (entityCursor.entityId == playerEntityId) {
            playerX = entityCursor.x;
            playerY = entityCursor.y;
          } else {
            hostiles.add((
              entityId: entityCursor.entityId,
              x: entityCursor.x,
              y: entityCursor.y,
              isStarDartBoss: entityCursor.entityId == starDartEntityId,
            ));
          }
        }

        runningGlory += ringBuffer.tickEventCounts[slot] * 25.0;
        final bool isOutro = (endIdx - idx) < outroTicks;

        final List<ScreenEdgeThreatChevron> chevrons =
            computeScreenEdgeThreatChevrons(
          cameraX: playerX,
          cameraY: playerY,
          hostiles: hostiles,
        );

        frames.add(
          VerticalReelFrameDescriptor(
            tickNumber: tickNum,
            timestamp: timestamp,
            viewportWidth: viewportWidth.toDouble(),
            viewportHeight: viewportHeight.toDouble(),
            cameraCenterX: playerX,
            cameraCenterY: playerY,
            kineticGloryScore: runningGlory,
            isOutroFrame: isOutro,
            threatChevrons: chevrons,
            outroCard: outroCard,
          ),
        );
      }
    }

    final Uint8List mp4Bytes = _compileOfflineIsoMp4Container(
      matchId: matchId,
      width: viewportWidth,
      height: viewportHeight,
      fps: ringBuffer.sampleRateHz,
      apexWindow: apexWindow,
      outroCard: outroCard,
      frames: frames,
    );

    return CompiledVerticalReelMp4(
      matchId: matchId,
      width: viewportWidth,
      height: viewportHeight,
      fps: ringBuffer.sampleRateHz,
      durationSeconds: apexWindow.durationSeconds,
      apexWindow: apexWindow,
      outroCard: outroCard,
      frames: frames,
      mp4Bytes: mp4Bytes,
    );
  }

  /// Compiles the 9:16 vertical highlight reel offline and invokes the native
  /// OS or Web share sheet.
  Future<({CompiledVerticalReelMp4 reel, ReelShareResult shareResult})>
      exportAndShareHighlightReel({
    required TelemetryRingBuffer ringBuffer,
    required String matchId,
    required String pilotCallsign,
    String castLedgerArchetypeBadge = 'APEX INTERCEPTOR',
    int playerEntityId = 1,
  }) async {
    final CompiledVerticalReelMp4 reel = exportHighlightReelMp4(
      ringBuffer: ringBuffer,
      matchId: matchId,
      pilotCallsign: pilotCallsign,
      castLedgerArchetypeBadge: castLedgerArchetypeBadge,
      playerEntityId: playerEntityId,
    );

    final ReelShareResult shareResult = await _shareAdapter.shareMp4Reel(
      mp4Bytes: reel.mp4Bytes,
      fileName: 'dartup_apex_${matchId}_9x16.mp4',
      title:
          'Dart Up! 9:16 Apex Highlight - ${reel.outroCard.pilotCallsign} (${reel.outroCard.castLedgerArchetypeBadge})',
      recapUrl: 'https://${reel.outroCard.recapWatermarkUrl}',
    );

    return (reel: reel, shareResult: shareResult);
  }

  // ---------------------------------------------------------------------------
  // Offline Client-Side ISO Base Media File Format (MP4) Box Assembler
  // ---------------------------------------------------------------------------

  static Uint8List _compileOfflineIsoMp4Container({
    required String matchId,
    required int width,
    required int height,
    required int fps,
    required ApexTelemetryWindow apexWindow,
    required PilotCallsignOutroCard outroCard,
    required List<VerticalReelFrameDescriptor> frames,
  }) {
    final BytesBuilder mp4 = BytesBuilder(copy: false);

    // 1. `ftyp` box (ISO Base Media File Format MP4 v2 header: `isom`, `mp42`)
    final BytesBuilder ftypPayload = BytesBuilder(copy: false)
      ..add(ascii.encode('isom'))
      ..add(_uint32Be(0x00000200))
      ..add(ascii.encode('isomiso2avc1mp41mp42'));
    _writeMp4Box(mp4, 'ftyp', ftypPayload.takeBytes());

    // 2. `moov` box containing track header (`tkhd` with 9:16 width/height) and
    //    `udta` metadata box with Pilot Callsign & watermark URLs
    final BytesBuilder tkhdPayload = BytesBuilder(copy: false)
      ..add(_uint32Be(0x00000003)) // version 0, flags: track_enabled | track_in_movie
      ..add(_uint32Be(0)) // creation_time
      ..add(_uint32Be(0)) // modification_time
      ..add(_uint32Be(1)) // track_ID = 1
      ..add(_uint32Be(0)) // reserved
      ..add(_uint32Be((apexWindow.durationSeconds * 1000).round())) // duration ms
      ..add(Uint8List(52)) // reserved + identity matrix + layer/volume
      ..add(_uint32Be(width << 16)) // 16.16 fixed-point width (1080)
      ..add(_uint32Be(height << 16)); // 16.16 fixed-point height (1920)

    final BytesBuilder trakPayload = BytesBuilder(copy: false);
    _writeMp4Box(trakPayload, 'tkhd', tkhdPayload.takeBytes());

    final Map<String, Object?> reelMetadata = <String, Object?>{
      'aspect_ratio': '9:16',
      'width': width,
      'height': height,
      'fps': fps,
      'match_id': matchId,
      'duration_seconds': apexWindow.durationSeconds,
      'pilot_callsign': outroCard.pilotCallsign,
      'cast_ledger_archetype_badge': outroCard.castLedgerArchetypeBadge,
      'watermark_icu': outroCard.recapWatermarkUrl,
      'watermark_network': outroCard.networkRecapWatermarkUrl,
      'frame_count': frames.length,
    };
    final Uint8List udtaJsonBytes =
        Uint8List.fromList(utf8.encode(jsonEncode(reelMetadata)));

    final BytesBuilder moovPayload = BytesBuilder(copy: false);
    _writeMp4Box(moovPayload, 'trak', trakPayload.takeBytes());
    _writeMp4Box(moovPayload, 'udta', udtaJsonBytes);
    _writeMp4Box(mp4, 'moov', moovPayload.takeBytes());

    // 3. `mdat` media data box encoding compacted per-frame 9:16 H.264/AVC NAL units
    final BytesBuilder mdatPayload = BytesBuilder(copy: false);
    for (int i = 0; i < frames.length; i++) {
      final f = frames[i];
      // NAL start code 0x00000001 + frame telemetry slice
      mdatPayload.add(const <int>[0x00, 0x00, 0x00, 0x01, 0x65]);
      mdatPayload.add(_uint32Be(f.tickNumber));
      mdatPayload.add(_uint32Be((f.cameraCenterX * 100).round()));
      mdatPayload.add(_uint32Be((f.cameraCenterY * 100).round()));
      mdatPayload.addByte(f.threatChevrons.length.clamp(0, 255));
      mdatPayload.addByte(f.isOutroFrame ? 1 : 0);
    }
    _writeMp4Box(mp4, 'mdat', mdatPayload.takeBytes());

    return mp4.takeBytes();
  }

  static void _writeMp4Box(
    BytesBuilder out,
    String fourCc,
    Uint8List payload,
  ) {
    final int totalSize = 8 + payload.length;
    out.add(_uint32Be(totalSize));
    out.add(ascii.encode(fourCc));
    out.add(payload);
  }

  static Uint8List _uint32Be(int value) {
    final ByteData bd = ByteData(4)..setUint32(0, value & 0xFFFFFFFF);
    return bd.buffer.asUint8List();
  }
}
