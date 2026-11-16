// =============================================================================
// tracking_spectrum.dart
//
// Pure-Dart Information Spectrum sensor tracking and active ECM spoofing model.
// Zero Flutter or Flame imports.
//
// Models:
// 1. WarpDriveType (`subwarp` vs `ftl`) and distinct WarpWake energy decay curves:
//    - `ftl`: high-intensity concentrated spatial tear (`baseEnergySignature`
//      high, fast exponential decay).
//    - `subwarp`: directional exhaust trail vector (`baseEnergySignature`
//      moderate, slow hybrid linear/exponential decay).
// 2. Non-binary Information Spectrum tracking (`signalStrength` in [0.0, 1.0]):
//    - High Signal (>= 0.65): exact target coordinates/vector + high pulseIntensity.
//    - Degraded Signal (0.20 .. < 0.65): ZoneOfProbability (center + uncertainty
//      radius inversely proportional to signalStrength) + low pulseIntensity.
//    - Lost Trace (< 0.20): null / Blind (undetectable).
// 3. Active ECM Spoofing:
//    - Fleeing ships expend ECM charge to emit `SpoofedWarpWake` false trails
//      with decaying confidence weights.
// =============================================================================

import 'dart:math' as math;

/// Drive propulsion archetype used for a warp transit.
enum WarpDriveType {
  /// Physical, high-speed grid traversal with computed transitTime and flight
  /// vector. Leaves a directional exhaust trail with moderate initial signature
  /// and slow decay.
  subwarp,

  /// Instantaneous blind jump where exit scatter scales with shipDecay and
  /// `(1.0 - navComputerHealth)`. Spawns a high-intensity concentrated spatial
  /// tear with fast exponential decay.
  ftl,
}

/// Residual energy signature left behind when a ship initiates a warp or
/// traverses a sector.
class WarpWake {
  final double x;
  final double y;
  final double timestamp;
  final double shipEcm;
  final WarpDriveType driveType;

  /// Initial energy signature in `[0.0, 1.0]` at `timeSinceJump == 0`.
  final double baseEnergySignature;

  /// Rate constant governing how fast this wake decays over time.
  final double decayRate;

  /// Optional directional exhaust vector (normalized) for `subwarp` trails,
  /// or jump vector for high-signal readings.
  final double? vectorX;
  final double? vectorY;

  /// Optional destination/exit coordinates associated with the wake.
  final double? targetX;
  final double? targetY;

  const WarpWake({
    required this.x,
    required this.y,
    required this.timestamp,
    required this.shipEcm,
    this.driveType = WarpDriveType.ftl,
    double? baseEnergySignature,
    double? baseSignalStrength,
    double? decayRate,
    this.vectorX,
    this.vectorY,
    this.targetX,
    this.targetY,
  })  : baseEnergySignature = baseEnergySignature ??
            baseSignalStrength ??
            (driveType == WarpDriveType.ftl ? 0.95 : 0.70),
        decayRate =
            decayRate ?? (driveType == WarpDriveType.ftl ? 0.25 : 0.05);

  /// Alias for backward compatibility with legacy callers reading `baseSignalStrength`.
  double get baseSignalStrength => baseEnergySignature;

  /// Whether this wake is an artificial ECM decoy.
  bool get isSpoofed => false;

  /// Computes remaining wake energy at [timeSinceJump] seconds after creation.
  /// - `ftl`: high initial signature with fast exponential decay.
  /// - `subwarp`: moderate initial signature with slower hybrid linear/exponential decay.
  double currentEnergy(double timeSinceJump) {
    final double dt = math.max(0.0, timeSinceJump);
    final double base = baseEnergySignature.clamp(0.0, 1.0);
    if (dt == 0.0) return base;

    if (driveType == WarpDriveType.ftl) {
      // Fast exponential decay for concentrated spatial tears
      return (base * math.exp(-decayRate * dt)).clamp(0.0, 1.0);
    } else {
      // Slower hybrid linear + exponential decay for directional subwarp trails
      final double expPart = base * math.exp(-decayRate * 0.45 * dt);
      final double linearPart = decayRate * 0.30 * dt;
      return (expPart - linearPart).clamp(0.0, 1.0);
    }
  }
}

/// False-trail wake emitted when a fleeing ship expends active ECM charge.
class SpoofedWarpWake extends WarpWake {
  /// Monotonically increasing sequence identifier assigned at generation time.
  final int sequenceId;

  /// Initial confidence weight (`0.0 .. 1.0`) representing how convincing
  /// the false trail appears to enemy sensors at creation.
  final double initialConfidenceWeight;

  /// Exponential decay rate of the decoy's confidence weight over time.
  final double confidenceDecayRate;

  const SpoofedWarpWake({
    required super.x,
    required super.y,
    required super.timestamp,
    required super.shipEcm,
    this.sequenceId = 0,
    super.driveType = WarpDriveType.subwarp,
    super.baseEnergySignature = 0.80,
    super.decayRate = 0.12,
    super.vectorX,
    super.vectorY,
    super.targetX,
    super.targetY,
    this.initialConfidenceWeight = 0.85,
    this.confidenceDecayRate = 0.18,
  });

  @override
  bool get isSpoofed => true;

  /// Decaying confidence weight in `[0.0, 1.0]` at [timeSinceJump] seconds.
  double confidenceAt(double timeSinceJump) {
    final double dt = math.max(0.0, timeSinceJump);
    return (initialConfidenceWeight * math.exp(-confidenceDecayRate * dt))
        .clamp(0.0, 1.0);
  }

  @override
  double currentEnergy(double timeSinceJump) {
    return (super.currentEnergy(timeSinceJump) * confidenceAt(timeSinceJump))
        .clamp(0.0, 1.0);
  }
}

/// Uncertainty circle returned when a sensor sweep achieves a degraded signal
/// (`0.20 <= signalStrength < 0.65`).
class ZoneOfProbability {
  final double centerX;
  final double centerY;
  final double uncertaintyRadius;

  const ZoneOfProbability({
    required this.centerX,
    required this.centerY,
    required this.uncertaintyRadius,
  });
}

/// Sensor hardware configuration for a hunting or scanning ship.
class SensorModule {
  /// 0 = no sensors installed (always Blind). 1+ = active sensor suite.
  final int tier;

  /// Hunter detection tech rating (`0.0 -> 1.0+`).
  final double trackingTech;

  const SensorModule({
    this.tier = 0,
    this.trackingTech = 0.0,
  });

  static const SensorModule none = SensorModule(tier: 0, trackingTech: 0.0);
}

enum TrackingOutcome { blind, pinpoint, zone }

/// Result of evaluating a [WarpWake] on the Information Spectrum.
class TrackingResult {
  final TrackingOutcome outcome;

  /// Clamped signal strength in `[0.0, 1.0]`.
  final double signalStrength;

  /// Populated when `outcome == TrackingOutcome.pinpoint`. Normalized direction
  /// vector from reader toward the target/wake.
  final double? directionX;
  final double? directionY;

  /// Exact target/wake coordinates, populated only at high signal (`>= 0.65`).
  final double? targetX;
  final double? targetY;

  /// UI pulse intensity (`0.0 .. 1.0`): high at pinpoint lock, low in degraded zone.
  final double? pulseIntensity;

  /// Populated when `outcome == TrackingOutcome.zone` (`0.20 <= signal < 0.65`).
  final double? zoneOfProbabilityRadius;
  final ZoneOfProbability? zoneOfProbability;

  /// Whether this tracking result originated from a [SpoofedWarpWake] decoy.
  final bool isSpoofedTrail;

  /// Confidence weight (`0.0 .. 1.0`) of the trace.
  final double confidenceWeight;

  const TrackingResult._({
    required this.outcome,
    required this.signalStrength,
    this.directionX,
    this.directionY,
    this.targetX,
    this.targetY,
    this.pulseIntensity,
    this.zoneOfProbabilityRadius,
    this.zoneOfProbability,
    this.isSpoofedTrail = false,
    this.confidenceWeight = 1.0,
  });

  factory TrackingResult.blind({double signalStrength = 0.0}) =>
      TrackingResult._(
        outcome: TrackingOutcome.blind,
        signalStrength: signalStrength,
        confidenceWeight: 0.0,
      );

  factory TrackingResult.pinpoint({
    required double signalStrength,
    required double directionX,
    required double directionY,
    required double pulseIntensity,
    double? targetX,
    double? targetY,
    bool isSpoofedTrail = false,
    double confidenceWeight = 1.0,
  }) =>
      TrackingResult._(
        outcome: TrackingOutcome.pinpoint,
        signalStrength: signalStrength,
        directionX: directionX,
        directionY: directionY,
        targetX: targetX,
        targetY: targetY,
        pulseIntensity: pulseIntensity,
        isSpoofedTrail: isSpoofedTrail,
        confidenceWeight: confidenceWeight,
      );

  factory TrackingResult.zone({
    required double signalStrength,
    required double zoneOfProbabilityRadius,
    ZoneOfProbability? zoneOfProbability,
    double? pulseIntensity,
    bool isSpoofedTrail = false,
    double confidenceWeight = 1.0,
  }) =>
      TrackingResult._(
        outcome: TrackingOutcome.zone,
        signalStrength: signalStrength,
        zoneOfProbabilityRadius: zoneOfProbabilityRadius,
        zoneOfProbability: zoneOfProbability,
        pulseIntensity: pulseIntensity ?? (signalStrength * 0.4),
        isSpoofedTrail: isSpoofedTrail,
        confidenceWeight: confidenceWeight,
      );
}

/// Computes raw `signalStrength` in `[0.0, 1.0]` from `(hunterDetectionTech - fleeingEcm)`,
/// attenuated by `wake.currentEnergy(timeSinceJump)` and nearby `NebulaNode`
/// `obscurityMultiplier`.
double computeSpectrumSignalStrength({
  required WarpWake wake,
  required double hunterDetectionTech,
  required double timeSinceJump,
  double obscurityMultiplier = 1.0,
  double? signalDecayPerSecond,
}) {
  final double dt = math.max(0.0, timeSinceJump);
  final double baseEnergy = signalDecayPerSecond != null
      ? (wake.baseEnergySignature - signalDecayPerSecond * dt).clamp(0.0, 1.0)
      : wake.currentEnergy(dt);
  final double energy = wake is SpoofedWarpWake && signalDecayPerSecond != null
      ? (baseEnergy * wake.confidenceAt(dt)).clamp(0.0, 1.0)
      : baseEnergy;
  if (energy <= 0.0) return 0.0;

  // Contest function of (hunterDetectionTech - fleeingEcm):
  // Equal tech & ECM yields 1.0x baseline; positive delta boosts signal,
  // negative delta (strong ECM) attenuates signal.
  final double delta = hunterDetectionTech - wake.shipEcm;
  final double techVsEcmFactor = (1.0 + delta * 0.75).clamp(0.0, 1.5);

  return (energy * techVsEcmFactor * obscurityMultiplier.clamp(0.0, 1.0))
      .clamp(0.0, 1.0);
}

/// Evaluates a [WarpWake] along the Information Spectrum:
/// - High Signal (`>= 0.65`): returns [TrackingResult.pinpoint] with exact
///   target vector/coordinates and high `pulseIntensity`.
/// - Degraded Signal (`0.20 .. < 0.65`): returns [TrackingResult.zone] with a
///   [ZoneOfProbability] whose radius is inversely proportional to `signalStrength`,
///   and low `pulseIntensity`.
/// - Lost Trace (`< 0.20`): returns `null` (undetectable).
TrackingResult? evaluateWakeTrace({
  required WarpWake wake,
  required double hunterDetectionTech,
  required double timeSinceJump,
  required double readerX,
  required double readerY,
  int sensorTier = 1,
  double obscurityMultiplier = 1.0,
  double? signalDecayPerSecond,
  double highSignalThreshold = 0.65,
  double lostTraceThreshold = 0.20,
  double baseUncertaintyScale = 1200.0,
}) {
  if (sensorTier <= 0) return null;

  final double signalStrength = computeSpectrumSignalStrength(
    wake: wake,
    hunterDetectionTech: hunterDetectionTech,
    timeSinceJump: timeSinceJump,
    obscurityMultiplier: obscurityMultiplier,
    signalDecayPerSecond: signalDecayPerSecond,
  );

  if (signalStrength < lostTraceThreshold) {
    return null;
  }

  final bool spoofed = wake is SpoofedWarpWake;
  final double confidence =
      wake is SpoofedWarpWake ? wake.confidenceAt(timeSinceJump) : 1.0;

  final double exactX = wake.targetX ?? wake.x;
  final double exactY = wake.targetY ?? wake.y;

  if (signalStrength >= highSignalThreshold) {
    final double dx = exactX - readerX;
    final double dy = exactY - readerY;
    final double dist = math.sqrt(dx * dx + dy * dy);
    final double dirX =
        dist > 0 ? dx / dist : (wake.vectorX ?? 0.0);
    final double dirY =
        dist > 0 ? dy / dist : (wake.vectorY ?? 1.0);

    return TrackingResult.pinpoint(
      signalStrength: signalStrength,
      directionX: dirX,
      directionY: dirY,
      targetX: exactX,
      targetY: exactY,
      pulseIntensity: signalStrength,
      isSpoofedTrail: spoofed,
      confidenceWeight: confidence,
    );
  }

  // Degraded Signal (0.20 <= signalStrength < 0.65):
  // Uncertainty radius is inversely proportional to signalStrength.
  final double radius = baseUncertaintyScale / signalStrength;
  final zone = ZoneOfProbability(
    centerX: wake.x,
    centerY: wake.y,
    uncertaintyRadius: radius,
  );

  return TrackingResult.zone(
    signalStrength: signalStrength,
    zoneOfProbabilityRadius: radius,
    zoneOfProbability: zone,
    pulseIntensity: signalStrength * 0.35,
    isSpoofedTrail: spoofed,
    confidenceWeight: confidence,
  );
}

/// Backward-compatible wrapper around [evaluateWakeTrace] returning
/// [TrackingResult.blind] instead of `null` when trace is lost (`< 0.20`)
/// or when `sensor.tier <= 0`.
TrackingResult readWake({
  required WarpWake wake,
  required SensorModule sensor,
  required double timeSinceJump,
  required double readerX,
  required double readerY,
  double? signalDecayPerSecond,
  double pinpointThreshold = 0.65,
  double lostTraceThreshold = 0.20,
  double obscurityMultiplier = 1.0,
}) {
  if (sensor.tier <= 0) {
    return TrackingResult.blind();
  }

  final result = evaluateWakeTrace(
    wake: wake,
    hunterDetectionTech: sensor.trackingTech,
    timeSinceJump: timeSinceJump,
    readerX: readerX,
    readerY: readerY,
    sensorTier: sensor.tier,
    obscurityMultiplier: obscurityMultiplier,
    signalDecayPerSecond: signalDecayPerSecond,
    highSignalThreshold: pinpointThreshold,
    lostTraceThreshold: lostTraceThreshold,
  );

  return result ?? TrackingResult.blind();
}
