// =============================================================================
// warp_wake_render_component.dart
//
// Pure-render + pooled VFX component for WarpWakes, SpoofedWarpWakes,
// Information Spectrum sensor rings (ZoneOfProbability & Pinpoint blips),
// and warp-spool ship shake indicators.
//
// Uses fixed-size SoA buffers for recorded wakes so zero heap allocations occur
// per frame during update() or render().
// =============================================================================

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flame/components.dart';
import 'package:sd_client/combat/enemy_director.dart';
import 'package:sd_client/player/ship_warp_controller.dart';
import 'package:sd_client/player/warp_wake_tracking.dart';

class WarpWakeRenderComponent extends PositionComponent {
  WarpWakeRenderComponent({
    required this.warpController,
    this.enemyDirector,
    this.maxWakes = 64,
    this.subwarpTrailLength = 120.0,
    this.ftlTearBaseRadius = 28.0,
  })  : _wakeX = Float32List(maxWakes),
        _wakeY = Float32List(maxWakes),
        _wakeVecX = Float32List(maxWakes),
        _wakeVecY = Float32List(maxWakes),
        _wakeTimestamp = Float32List(maxWakes),
        _wakeBaseEnergy = Float32List(maxWakes),
        _wakeDecayRate = Float32List(maxWakes),
        _wakeInitialConfidence = Float32List(maxWakes),
        _wakeConfidenceDecayRate = Float32List(maxWakes),
        _wakeDriveType = Uint8List(maxWakes),
        _wakeIsSpoofed = Uint8List(maxWakes);

  final ShipWarpController warpController;
  final EnemyDirector? enemyDirector;
  final int maxWakes;
  final double subwarpTrailLength;
  final double ftlTearBaseRadius;

  final Float32List _wakeX;
  final Float32List _wakeY;
  final Float32List _wakeVecX;
  final Float32List _wakeVecY;
  final Float32List _wakeTimestamp;
  final Float32List _wakeBaseEnergy;
  final Float32List _wakeDecayRate;
  final Float32List _wakeInitialConfidence;
  final Float32List _wakeConfidenceDecayRate;
  final Uint8List _wakeDriveType;
  final Uint8List _wakeIsSpoofed;
  int _activeWakeCount = 0;

  WarpWake? _lastObservedControllerWake;
  SpoofedWarpWake? _lastObservedSpoofedWake;

  static const Color subwarpTrailColor = Color(0xFF00E5FF);
  static const Color ftlTearColor = Color(0xFFD500F9);
  static const Color spoofedWakeColor = Color(0xFFFFD600);
  static const Color zoneRingColor = Color(0xFFFF9100);
  static const Color pinpointBlipColor = Color(0xFFFF1744);
  static const Color spoolTensionColor = Color(0xFF6FD8FF);

  final Paint _subwarpPaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 3.0
    ..strokeCap = StrokeCap.round;

  final Paint _ftlPaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2.5;

  final Paint _zoneFillPaint = Paint()..style = PaintingStyle.fill;
  final Paint _zoneStrokePaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2.0;

  final Paint _spoolPaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2.0;

  /// Number of active wakes currently in the pre-allocated pool.
  int get activeWakeCount => _activeWakeCount;

  /// Current normalized warp-spool shake intensity in `[0.0, 1.0]`.
  double get currentSpoolShakeIntensity {
    if (warpController.warpState == WarpState.spooling) {
      return warpController.spoolProgress.clamp(0.0, 1.0);
    }
    if (warpController.warpState == WarpState.arriving) {
      return (1.0 - warpController.arrivalProgress).clamp(0.0, 1.0);
    }
    return 0.0;
  }

  /// Records a [WarpWake] or [SpoofedWarpWake] into the pre-allocated SoA pool.
  void recordWake(WarpWake wake) {
    final int slot = _activeWakeCount < maxWakes ? _activeWakeCount++ : 0;
    _wakeX[slot] = wake.x;
    _wakeY[slot] = wake.y;
    _wakeVecX[slot] = wake.vectorX ?? 1.0;
    _wakeVecY[slot] = wake.vectorY ?? 0.0;
    _wakeTimestamp[slot] = wake.timestamp;
    _wakeBaseEnergy[slot] = wake.baseEnergySignature;
    _wakeDecayRate[slot] = wake.decayRate;
    if (wake is SpoofedWarpWake) {
      _wakeInitialConfidence[slot] = wake.initialConfidenceWeight;
      _wakeConfidenceDecayRate[slot] = wake.confidenceDecayRate;
      _wakeIsSpoofed[slot] = 1;
    } else {
      _wakeInitialConfidence[slot] = 1.0;
      _wakeConfidenceDecayRate[slot] = 0.0;
      _wakeIsSpoofed[slot] = 0;
    }
    _wakeDriveType[slot] = wake.driveType.index;
  }

  /// Computes the current energy of pooled wake at [index] at simulation time [now].
  double pooledWakeEnergyAt(int index, double now) =>
      _computePooledWakeEnergy(index, now);

  @override
  void update(double dt) {
    super.update(dt);

    // Observe newly emitted primary wakes from ShipWarpController
    final WarpWake? latest = warpController.lastWake;
    if (latest != null && !identical(latest, _lastObservedControllerWake)) {
      _lastObservedControllerWake = latest;
      recordWake(latest);
    }

    // Observe newly emitted ECM spoofed wakes without relying on fragile list indexing
    final SpoofedWarpWake? latestSpoof = warpController.lastSpoofedWake;
    if (latestSpoof != null && !identical(latestSpoof, _lastObservedSpoofedWake)) {
      _lastObservedSpoofedWake = latestSpoof;
      recordWake(latestSpoof);
    }

    // Prune wakes whose energy has decayed below visibility threshold (0.02)
    final double now = warpController.simulationTime;
    for (int i = _activeWakeCount - 1; i >= 0; i--) {
      final double energy = _computePooledWakeEnergy(i, now);
      if (energy < 0.02) {
        _swapRemoveWake(i);
      }
    }
  }

  double _computePooledWakeEnergy(int index, double now) {
    final double dt = math.max(0.0, now - _wakeTimestamp[index]);
    final double base = _wakeBaseEnergy[index].clamp(0.0, 1.0);
    final double rate = _wakeDecayRate[index];

    final double rawEnergy;
    if (dt == 0.0) {
      rawEnergy = base;
    } else if (_wakeDriveType[index] == WarpDriveType.ftl.index) {
      rawEnergy = (base * math.exp(-rate * dt)).clamp(0.0, 1.0);
    } else {
      final double expPart = base * math.exp(-rate * 0.45 * dt);
      final double linearPart = rate * 0.30 * dt;
      rawEnergy = (expPart - linearPart).clamp(0.0, 1.0);
    }

    if (_wakeIsSpoofed[index] == 1) {
      final double confidence = (_wakeInitialConfidence[index] *
              math.exp(-_wakeConfidenceDecayRate[index] * dt))
          .clamp(0.0, 1.0);
      return (rawEnergy * confidence).clamp(0.0, 1.0);
    }
    return rawEnergy;
  }

  void _swapRemoveWake(int index) {
    final int last = _activeWakeCount - 1;
    if (index != last) {
      _wakeX[index] = _wakeX[last];
      _wakeY[index] = _wakeY[last];
      _wakeVecX[index] = _wakeVecX[last];
      _wakeVecY[index] = _wakeVecY[last];
      _wakeTimestamp[index] = _wakeTimestamp[last];
      _wakeBaseEnergy[index] = _wakeBaseEnergy[last];
      _wakeDecayRate[index] = _wakeDecayRate[last];
      _wakeInitialConfidence[index] = _wakeInitialConfidence[last];
      _wakeConfidenceDecayRate[index] = _wakeConfidenceDecayRate[last];
      _wakeDriveType[index] = _wakeDriveType[last];
      _wakeIsSpoofed[index] = _wakeIsSpoofed[last];
    }
    _activeWakeCount--;
  }

  @override
  void render(Canvas canvas) {
    final double now = warpController.simulationTime;

    // 1. Render pooled WarpWakes (Subwarp directional trails & FTL spatial tears)
    for (int i = 0; i < _activeWakeCount; i++) {
      final double energy = _computePooledWakeEnergy(i, now);
      if (energy <= 0.02) continue;

      final double wx = _wakeX[i];
      final double wy = _wakeY[i];
      final bool isSpoofed = _wakeIsSpoofed[i] == 1;

      if (_wakeDriveType[i] == WarpDriveType.subwarp.index) {
        final Color baseColor = isSpoofed ? spoofedWakeColor : subwarpTrailColor;
        _subwarpPaint.color = baseColor.withValues(alpha: energy.clamp(0.0, 1.0));
        final double endX = wx + _wakeVecX[i] * subwarpTrailLength * energy;
        final double endY = wy + _wakeVecY[i] * subwarpTrailLength * energy;
        canvas.drawLine(Offset(wx, wy), Offset(endX, endY), _subwarpPaint);
      } else {
        final Color baseColor = isSpoofed ? spoofedWakeColor : ftlTearColor;
        _ftlPaint.color = baseColor.withValues(alpha: energy.clamp(0.0, 1.0));
        final double tearRadius = ftlTearBaseRadius * (0.5 + 0.5 * energy);
        canvas.drawCircle(Offset(wx, wy), tearRadius, _ftlPaint);
      }
    }

    // 2. Render Information Spectrum sensor rings (ZoneOfProbability or Pinpoint blip)
    final TrackingResult? sweep = enemyDirector?.lastSweepResult;
    if (sweep != null) {
      if (sweep.outcome == TrackingOutcome.zone &&
          sweep.zoneOfProbability != null) {
        final ZoneOfProbability zone = sweep.zoneOfProbability!;
        final double alpha =
            (sweep.pulseIntensity ?? (sweep.signalStrength * 0.35))
                .clamp(0.08, 0.65);
        final Offset center = Offset(zone.centerX, zone.centerY);
        _zoneFillPaint.color =
            zoneRingColor.withValues(alpha: (alpha * 0.25).clamp(0.02, 0.20));
        _zoneStrokePaint.color = zoneRingColor.withValues(alpha: alpha);
        canvas.drawCircle(center, zone.uncertaintyRadius, _zoneFillPaint);
        canvas.drawCircle(center, zone.uncertaintyRadius, _zoneStrokePaint);
      } else if (sweep.outcome == TrackingOutcome.pinpoint &&
          sweep.targetX != null &&
          sweep.targetY != null) {
        final double pulse = (sweep.pulseIntensity ?? sweep.signalStrength)
            .clamp(0.2, 1.0);
        final Offset target = Offset(sweep.targetX!, sweep.targetY!);
        _zoneStrokePaint.color = pinpointBlipColor.withValues(alpha: pulse);
        canvas.drawCircle(target, 22.0 * pulse, _zoneStrokePaint);
      }
    }

    // 3. Render warp-spool tension pulse ring around ship during spooling/arriving
    final double shakeIntensity = currentSpoolShakeIntensity;
    if (shakeIntensity > 0.0) {
      final Offset shipPos = Offset(
        warpController.currentShipX,
        warpController.currentShipY,
      );
      _spoolPaint.color =
          spoolTensionColor.withValues(alpha: (0.25 + 0.65 * shakeIntensity).clamp(0.0, 1.0));
      final double ringRadius = 32.0 + 24.0 * (1.0 - shakeIntensity);
      canvas.drawCircle(shipPos, ringRadius, _spoolPaint);
    }
  }

  @override
  void onRemove() {
    _activeWakeCount = 0;
    _lastObservedControllerWake = null;
    _lastObservedSpoofedWake = null;
    super.onRemove();
  }
}
