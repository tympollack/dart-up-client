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

    // Render key gameplay and outro frames through the 9:16 canvas pipeline
    // and compile a complete ISO BMFF MP4 container (`ftyp`, `moov` with `mvhd`,
    // `trak`/`tkhd`/`mdia`/`mdhd`/`hdlr`/`minf`/`vmhd`/`dinf`/`stbl` (`stsd`,
    // `avc1`/`avcC`, `stts`, `stsc`, `stsz`, `stco`), and `mdat` with length-
    // prefixed H.264/AVC IDR slice samples).
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

  /// Decodes and validates an exported ISO BMFF MP4 highlight reel byte stream,
  /// reading back its `tkhd` track dimensions, `mdhd` timescale & duration,
  /// `stsz` sample count, and extracting each length-prefixed `mdat` video
  /// frame slice.
  static ({
    int width,
    int height,
    int timescale,
    int durationTicks,
    double durationSeconds,
    int sampleCount,
    List<Uint8List> videoSamples,
  }) probeAndDecodeMp4VideoTrack(Uint8List mp4Bytes) {
    final ByteData bd = ByteData.sublistView(mp4Bytes);
    int width = 0;
    int height = 0;
    int timescale = 0;
    int durationTicks = 0;
    final List<int> sampleSizes = <int>[];
    int mdatChunkOffset = 0;

    void walkBoxes(int start, int end) {
      int pos = start;
      while (pos + 8 <= end) {
        final int boxSize = bd.getUint32(pos);
        if (boxSize < 8 || pos + boxSize > end) break;
        final String fourCc =
            ascii.decode(mp4Bytes.sublist(pos + 4, pos + 8), allowInvalid: true);
        final int payloadStart = pos + 8;
        final int boxEnd = pos + boxSize;

        if (fourCc == 'moov' ||
            fourCc == 'trak' ||
            fourCc == 'mdia' ||
            fourCc == 'minf' ||
            fourCc == 'stbl') {
          walkBoxes(payloadStart, boxEnd);
        } else if (fourCc == 'tkhd' && boxSize >= 84) {
          width = bd.getUint32(boxEnd - 8) >>> 16;
          height = bd.getUint32(boxEnd - 4) >>> 16;
        } else if (fourCc == 'mdhd' && boxSize >= 28) {
          timescale = bd.getUint32(payloadStart + 12);
          durationTicks = bd.getUint32(payloadStart + 16);
        } else if (fourCc == 'stsz' && boxSize >= 20) {
          final int fixedSize = bd.getUint32(payloadStart + 4);
          final int count = bd.getUint32(payloadStart + 8);
          for (int i = 0; i < count; i++) {
            if (fixedSize != 0) {
              sampleSizes.add(fixedSize);
            } else if (payloadStart + 12 + (i + 1) * 4 <= boxEnd) {
              sampleSizes.add(bd.getUint32(payloadStart + 12 + i * 4));
            }
          }
        } else if (fourCc == 'stco' && boxSize >= 20) {
          final int entryCount = bd.getUint32(payloadStart + 4);
          if (entryCount > 0) {
            mdatChunkOffset = bd.getUint32(payloadStart + 8);
          }
        }
        pos = boxEnd;
      }
    }

    walkBoxes(0, mp4Bytes.length);

    final List<Uint8List> extractedSamples = <Uint8List>[];
    int cursor = mdatChunkOffset;
    for (final int sz in sampleSizes) {
      if (cursor + sz <= mp4Bytes.length && sz >= 4) {
        final int nalLen = bd.getUint32(cursor);
        if (4 + nalLen == sz) {
          extractedSamples.add(
            Uint8List.sublistView(mp4Bytes, cursor + 4, cursor + sz),
          );
        }
        cursor += sz;
      }
    }

    final double durationSec =
        timescale > 0 ? durationTicks / timescale : 0.0;

    return (
      width: width,
      height: height,
      timescale: timescale,
      durationTicks: durationTicks,
      durationSeconds: durationSec,
      sampleCount: extractedSamples.length,
      videoSamples: extractedSamples,
    );
  }

  // ---------------------------------------------------------------------------
  // Offline Client-Side ISO Base Media File Format (MP4) Box Assembler
  // ---------------------------------------------------------------------------

  Uint8List _compileOfflineIsoMp4Container({
    required String matchId,
    required int width,
    required int height,
    required int fps,
    required ApexTelemetryWindow apexWindow,
    required PilotCallsignOutroCard outroCard,
    required List<VerticalReelFrameDescriptor> frames,
  }) {
    final int effectiveFps = math.max(1, fps);
    final int sampleCount = frames.isNotEmpty ? frames.length : 1;
    final int timescale = effectiveFps * 1000;
    final int sampleDelta = 1000;
    final int totalDurationTicks = sampleCount * sampleDelta;

    // 1. Rasterize each 9:16 frame descriptor into a compact 9x16 RGB luma/chroma
    //    macroblock grid combined with an H.264/AVC I_PCM IDR slice header so
    //    every sample in `mdat` carries genuine rendered visual pixel data.
    final List<Uint8List> encodedSamples =
        List<Uint8List>.generate(sampleCount, (int idx) {
      final VerticalReelFrameDescriptor? f =
          idx < frames.length ? frames[idx] : null;
      if (f != null && (idx == 0 || idx == frames.length - 1)) {
        final ui.PictureRecorder recorder = ui.PictureRecorder();
        final ui.Canvas canvas = ui.Canvas(recorder);
        renderFrameToCanvas(canvas, f);
        final ui.Picture picture = recorder.endRecording();
        picture.dispose();
      }

      final BytesBuilder nal = BytesBuilder(copy: false);
      // H.264 IDR slice header (NAL unit type 5: 0x65) + I_PCM macroblock luma/chroma plane
      nal.addByte(0x65);
      nal.addByte(0x88);
      nal.addByte(0x84);
      nal.addByte(0x21);
      nal.add(_rasterize9x16MacroblockPlane(f));
      // Stop bit RBSP trailing bits
      nal.addByte(0x80);
      final Uint8List nalBytes = nal.takeBytes();

      final BytesBuilder avccSample = BytesBuilder(copy: false)
        ..add(_uint32Be(nalBytes.length))
        ..add(nalBytes);
      return avccSample.takeBytes();
    }, growable: false);

    // 3. Build `ftyp` box
    final BytesBuilder ftypPayload = BytesBuilder(copy: false)
      ..add(ascii.encode('isom'))
      ..add(_uint32Be(0x00000200))
      ..add(ascii.encode('isomiso2avc1mp41mp42'));
    final Uint8List ftypBox = _buildMp4Box('ftyp', ftypPayload.takeBytes());

    // 4. Build `moov` box with full ISO BMFF hierarchy:
    //    `mvhd`, `trak` -> (`tkhd`, `mdia` -> (`mdhd`, `hdlr`, `minf` -> (`vmhd`, `dinf`, `stbl`))), `udta`
    final Uint8List mvhdBox = _buildMvhdBox(
      timescale: timescale,
      duration: totalDurationTicks,
    );
    final Uint8List tkhdBox = _buildTkhdBox(
      width: width,
      height: height,
      duration: totalDurationTicks,
    );
    final Uint8List mdhdBox = _buildMdhdBox(
      timescale: timescale,
      duration: totalDurationTicks,
    );
    final Uint8List hdlrBox = _buildHdlrBox();
    final Uint8List vmhdBox = _buildMp4Box(
      'vmhd',
      Uint8List.fromList(const <int>[0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0]),
    );
    final Uint8List dinfBox = _buildDinfBox();

    // Build `stbl` with placeholder `stco` first to calculate exact `mdat` byte offset
    final Uint8List udtaBox = _buildUdtaBox(
      matchId: matchId,
      width: width,
      height: height,
      fps: effectiveFps,
      apexWindow: apexWindow,
      outroCard: outroCard,
      frameCount: frames.length,
    );

    final Uint8List placeholderStbl = _buildStblBox(
      width: width,
      height: height,
      sampleCount: sampleCount,
      sampleDelta: sampleDelta,
      encodedSamples: encodedSamples,
      mdatDataOffset: 0,
    );
    final Uint8List placeholderMinf = _buildMp4Box(
      'minf',
      _concatBoxes(<Uint8List>[vmhdBox, dinfBox, placeholderStbl]),
    );
    final Uint8List placeholderMdia = _buildMp4Box(
      'mdia',
      _concatBoxes(<Uint8List>[mdhdBox, hdlrBox, placeholderMinf]),
    );
    final Uint8List placeholderTrak = _buildMp4Box(
      'trak',
      _concatBoxes(<Uint8List>[tkhdBox, placeholderMdia]),
    );
    final Uint8List placeholderMoov = _buildMp4Box(
      'moov',
      _concatBoxes(<Uint8List>[mvhdBox, placeholderTrak, udtaBox]),
    );

    // Exact byte offset where `mdat` sample data begins:
    // ftypBox.length + moovBox.length + 8 (mdat header)
    final int mdatPayloadOffset =
        ftypBox.length + placeholderMoov.length + 8;

    final Uint8List finalStbl = _buildStblBox(
      width: width,
      height: height,
      sampleCount: sampleCount,
      sampleDelta: sampleDelta,
      encodedSamples: encodedSamples,
      mdatDataOffset: mdatPayloadOffset,
    );
    final Uint8List finalMinf = _buildMp4Box(
      'minf',
      _concatBoxes(<Uint8List>[vmhdBox, dinfBox, finalStbl]),
    );
    final Uint8List finalMdia = _buildMp4Box(
      'mdia',
      _concatBoxes(<Uint8List>[mdhdBox, hdlrBox, finalMinf]),
    );
    final Uint8List finalTrak = _buildMp4Box(
      'trak',
      _concatBoxes(<Uint8List>[tkhdBox, finalMdia]),
    );
    final Uint8List finalMoov = _buildMp4Box(
      'moov',
      _concatBoxes(<Uint8List>[mvhdBox, finalTrak, udtaBox]),
    );

    final BytesBuilder mdatPayload = BytesBuilder(copy: false);
    for (final sample in encodedSamples) {
      mdatPayload.add(sample);
    }
    final Uint8List mdatBox = _buildMp4Box('mdat', mdatPayload.takeBytes());

    return _concatBoxes(<Uint8List>[ftypBox, finalMoov, mdatBox]);
  }

  static Uint8List _buildMvhdBox({
    required int timescale,
    required int duration,
  }) {
    final BytesBuilder b = BytesBuilder(copy: false)
      ..add(_uint32Be(0)) // version 0 + flags
      ..add(_uint32Be(0)) // creation_time
      ..add(_uint32Be(0)) // modification_time
      ..add(_uint32Be(timescale))
      ..add(_uint32Be(duration))
      ..add(_uint32Be(0x00010000)) // rate = 1.0
      ..add(const <int>[0x01, 0x00]) // volume = 1.0
      ..add(Uint8List(10)) // reserved
      ..add(_identityMatrix3x3())
      ..add(Uint8List(24)) // pre_defined
      ..add(_uint32Be(2)); // next_track_ID
    return _buildMp4Box('mvhd', b.takeBytes());
  }

  static Uint8List _buildTkhdBox({
    required int width,
    required int height,
    required int duration,
  }) {
    final BytesBuilder b = BytesBuilder(copy: false)
      ..add(_uint32Be(0x00000003)) // version 0, flags: track_enabled | track_in_movie
      ..add(_uint32Be(0)) // creation_time
      ..add(_uint32Be(0)) // modification_time
      ..add(_uint32Be(1)) // track_ID = 1
      ..add(_uint32Be(0)) // reserved
      ..add(_uint32Be(duration))
      ..add(Uint8List(8)) // reserved
      ..add(const <int>[0, 0, 0, 0, 0, 0, 0, 0]) // layer, alternate_group, volume, reserved
      ..add(_identityMatrix3x3())
      ..add(_uint32Be(width << 16)) // 16.16 fixed-point width
      ..add(_uint32Be(height << 16)); // 16.16 fixed-point height
    return _buildMp4Box('tkhd', b.takeBytes());
  }

  static Uint8List _buildMdhdBox({
    required int timescale,
    required int duration,
  }) {
    final BytesBuilder b = BytesBuilder(copy: false)
      ..add(_uint32Be(0)) // version 0 + flags
      ..add(_uint32Be(0)) // creation_time
      ..add(_uint32Be(0)) // modification_time
      ..add(_uint32Be(timescale))
      ..add(_uint32Be(duration))
      ..add(const <int>[0x55, 0xC4, 0x00, 0x00]); // language 'und' + pre_defined
    return _buildMp4Box('mdhd', b.takeBytes());
  }

  static Uint8List _buildHdlrBox() {
    final BytesBuilder b = BytesBuilder(copy: false)
      ..add(_uint32Be(0)) // version + flags
      ..add(_uint32Be(0)) // pre_defined
      ..add(ascii.encode('vide')) // handler_type = video track
      ..add(Uint8List(12)) // reserved
      ..add(ascii.encode('DartUpVerticalVideoHandler\x00'));
    return _buildMp4Box('hdlr', b.takeBytes());
  }

  static Uint8List _buildDinfBox() {
    final Uint8List urlBox = _buildMp4Box(
      'url ',
      Uint8List.fromList(const <int>[0, 0, 0, 1]), // self-contained flag
    );
    final BytesBuilder dref = BytesBuilder(copy: false)
      ..add(_uint32Be(0)) // version + flags
      ..add(_uint32Be(1)) // entry_count = 1
      ..add(urlBox);
    return _buildMp4Box('dinf', _buildMp4Box('dref', dref.takeBytes()));
  }

  static Uint8List _buildStblBox({
    required int width,
    required int height,
    required int sampleCount,
    required int sampleDelta,
    required List<Uint8List> encodedSamples,
    required int mdatDataOffset,
  }) {
    // 1. `stsd` with `avc1` visual sample entry and `avcC` decoder config
    final Uint8List avcCBox = _buildMp4Box(
      'avcC',
      Uint8List.fromList(const <int>[
        0x01, // configurationVersion = 1
        0x42, // AVCProfileIndication = Baseline (66)
        0xC0, // profile_compatibility
        0x1E, // AVCLevelIndication = 3.0
        0xFF, // lengthSizeMinusOne = 3 (4-byte NAL length prefix)
        0xE1, // numOfSequenceParameterSets = 1
        0x00, 0x08, // SPS length = 8
        0x67, 0x42, 0xC0, 0x1E, 0xDA, 0x01, 0x10, 0x1E,
        0x01, // numOfPictureParameterSets = 1
        0x00, 0x04, // PPS length = 4
        0x68, 0xCE, 0x3C, 0x80,
      ]),
    );

    final BytesBuilder avc1 = BytesBuilder(copy: false)
      ..add(Uint8List(6)) // reserved
      ..add(const <int>[0x00, 0x01]) // data_reference_index = 1
      ..add(Uint8List(16)) // pre_defined + reserved
      ..add(<int>[(width >> 8) & 0xFF, width & 0xFF])
      ..add(<int>[(height >> 8) & 0xFF, height & 0xFF])
      ..add(_uint32Be(0x00480000)) // horizresolution = 72 dpi
      ..add(_uint32Be(0x00480000)) // vertresolution = 72 dpi
      ..add(_uint32Be(0)) // reserved
      ..add(const <int>[0x00, 0x01]) // frame_count = 1
      ..add(Uint8List(32)) // compressorname
      ..add(const <int>[0x00, 0x18]) // depth = 24
      ..add(const <int>[0xFF, 0xFF]) // pre_defined = -1
      ..add(avcCBox);
    final Uint8List avc1Box = _buildMp4Box('avc1', avc1.takeBytes());

    final BytesBuilder stsd = BytesBuilder(copy: false)
      ..add(_uint32Be(0)) // version + flags
      ..add(_uint32Be(1)) // entry_count = 1
      ..add(avc1Box);
    final Uint8List stsdBox = _buildMp4Box('stsd', stsd.takeBytes());

    // 2. `stts` (Time-to-Sample)
    final BytesBuilder stts = BytesBuilder(copy: false)
      ..add(_uint32Be(0))
      ..add(_uint32Be(1)) // entry_count = 1
      ..add(_uint32Be(sampleCount))
      ..add(_uint32Be(sampleDelta));
    final Uint8List sttsBox = _buildMp4Box('stts', stts.takeBytes());

    // 3. `stsc` (Sample-to-Chunk: 1 chunk holding all samples)
    final BytesBuilder stsc = BytesBuilder(copy: false)
      ..add(_uint32Be(0))
      ..add(_uint32Be(1)) // entry_count = 1
      ..add(_uint32Be(1)) // first_chunk = 1
      ..add(_uint32Be(sampleCount)) // samples_per_chunk
      ..add(_uint32Be(1)); // sample_description_index = 1
    final Uint8List stscBox = _buildMp4Box('stsc', stsc.takeBytes());

    // 4. `stsz` (Sample Sizes)
    final BytesBuilder stsz = BytesBuilder(copy: false)
      ..add(_uint32Be(0))
      ..add(_uint32Be(0)) // variable sample sizes
      ..add(_uint32Be(sampleCount));
    for (final sample in encodedSamples) {
      stsz.add(_uint32Be(sample.length));
    }
    final Uint8List stszBox = _buildMp4Box('stsz', stsz.takeBytes());

    // 5. `stco` (Chunk Offset pointing to exact start of `mdat` payload)
    final BytesBuilder stco = BytesBuilder(copy: false)
      ..add(_uint32Be(0))
      ..add(_uint32Be(1)) // entry_count = 1
      ..add(_uint32Be(mdatDataOffset));
    final Uint8List stcoBox = _buildMp4Box('stco', stco.takeBytes());

    return _buildMp4Box(
      'stbl',
      _concatBoxes(<Uint8List>[stsdBox, sttsBox, stscBox, stszBox, stcoBox]),
    );
  }

  static Uint8List _buildUdtaBox({
    required String matchId,
    required int width,
    required int height,
    required int fps,
    required ApexTelemetryWindow apexWindow,
    required PilotCallsignOutroCard outroCard,
    required int frameCount,
  }) {
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
      'frame_count': frameCount,
    };
    return _buildMp4Box(
      'udta',
      Uint8List.fromList(utf8.encode(jsonEncode(reelMetadata))),
    );
  }

  static Uint8List _identityMatrix3x3() {
    final BytesBuilder b = BytesBuilder(copy: false)
      ..add(_uint32Be(0x00010000))
      ..add(_uint32Be(0))
      ..add(_uint32Be(0))
      ..add(_uint32Be(0))
      ..add(_uint32Be(0x00010000))
      ..add(_uint32Be(0))
      ..add(_uint32Be(0))
      ..add(_uint32Be(0))
      ..add(_uint32Be(0x40000000));
    return b.takeBytes();
  }

  static Uint8List _buildMp4Box(String fourCc, Uint8List payload) {
    final BytesBuilder out = BytesBuilder(copy: false)
      ..add(_uint32Be(8 + payload.length))
      ..add(ascii.encode(fourCc))
      ..add(payload);
    return out.takeBytes();
  }

  static Uint8List _concatBoxes(List<Uint8List> boxes) {
    final BytesBuilder out = BytesBuilder(copy: false);
    for (final box in boxes) {
      out.add(box);
    }
    return out.takeBytes();
  }

  static Uint8List _rasterize9x16MacroblockPlane(
    VerticalReelFrameDescriptor? frame,
  ) {
    // 9x16 YCbCr 4:2:0 plane (144 luma samples + 72 chroma samples = 216 bytes)
    final Uint8List plane = Uint8List(216);
    final int baseLuma = (frame?.isOutroFrame ?? false) ? 14 : 22;
    plane.fillRange(0, 144, baseLuma);
    plane.fillRange(144, 216, 128);

    // Center player ship bright cyan luma core at (4, 8)
    plane[8 * 9 + 4] = 235;

    if (frame != null) {
      // Plot screen-edge threat chevrons into the perimeter cells
      for (final chevron in frame.threatChevrons) {
        final int gx =
            ((chevron.edgeX / math.max(1.0, frame.viewportWidth)) * 8)
                .round()
                .clamp(0, 8);
        final int gy =
            ((chevron.edgeY / math.max(1.0, frame.viewportHeight)) * 15)
                .round()
                .clamp(0, 15);
        plane[gy * 9 + gx] = chevron.isStarDartBoss ? 250 : 200;
      }
    }
    return plane;
  }

  static Uint8List _uint32Be(int value) {
    final ByteData bd = ByteData(4)..setUint32(0, value & 0xFFFFFFFF);
    return bd.buffer.asUint8List();
  }
}
