// =============================================================================
// warp_wake_tracking.dart
//
// Pure Dart, engine-agnostic. Deliberately decoupled from
// ship_warp_controller.dart: it takes plain doubles (a signal strength
// baked in by whoever created the wake, an ECM rating, an obscurity
// multiplier) rather than importing ship/drive types. Tracking is
// inherently about OTHER entities reading YOUR wake -- this file doesn't
// need to know what a ship, a drive type, or a celestial node even is,
// only what a wake and a sensor are.
//
// No persistent state lives here either: no wake registry, no expiring-
// list management. WarpWake is a value created once per jump by whatever
// owns the ship; readWake() is a pure function called on demand by
// whatever owns the reader (an enemy AI, a player's own sensor UI, etc.).
// If you need a registry of multiple active wakes with expiration later,
// that's a thin wrapper around this, not a change to it.
// =============================================================================

import 'dart:math' as math;

/// A trace left at a ship's departure point the instant it jumps. Purely
/// data -- whatever creates this (e.g. ShipWarpController) is responsible
/// for filling in baseSignalStrength appropriately for its own fictional
/// rules (a Subwarp's lingering trail should probably start higher than
/// an FTL blink-out).
class WarpWake {
  final double x;
  final double y;

  /// Simulation-time timestamp of creation, in whatever time units the
  /// creator's own clock uses. readWake() takes `timeSinceJump` directly
  /// rather than reading any clock itself, so this file stays decoupled
  /// from any particular time source -- compute it as
  /// `myClock.now - wake.timestamp` wherever you call readWake().
  final double timestamp;

  /// 0 -> 1, how strong/legible this wake is at the moment it's created,
  /// before decay, tech, ECM, or obscurity are applied.
  final double baseSignalStrength;

  /// The fleeing ship's Electronic Counter-Measures rating, 0 -> 1+.
  /// Higher = harder for any sensor to get a clean read, regardless of
  /// their tech tier.
  final double shipEcm;

  const WarpWake({
    required this.x,
    required this.y,
    required this.timestamp,
    required this.shipEcm,
    this.baseSignalStrength = 1.0,
  });
}

/// A reader's sensor loadout. Tier 0 = no sensors installed at all --
/// readWake() always returns Blind for tier 0, regardless of anything
/// else. This is the loadout-gating: you cannot get any tracking
/// information without dedicating loadout slots to it.
class SensorModule {
  /// 0 = no sensors. 1+ = installed, with trackingTech scaling how good
  /// the read is.
  final int tier;

  /// 0 -> 1+, how good this sensor suite is at cutting through ECM and
  /// signal decay. Tech upgrades raise this.
  final double trackingTech;

  const SensorModule({
    this.tier = 0,
    this.trackingTech = 0.0,
  });

  static const SensorModule none = SensorModule(tier: 0, trackingTech: 0.0);
}

enum TrackingOutcome { blind, pinpoint, zone }

/// What a reader perceives. Exactly one of (directionX/directionY/
/// pulseIntensity) or (zoneOfProbabilityRadius) is populated, matching
/// `outcome` -- the unused fields are null rather than zero, so your
/// rendering code can't accidentally draw a zone radius of 0 and think
/// that means "tiny zone" instead of "not applicable."
class TrackingResult {
  final TrackingOutcome outcome;

  /// 0 -> 1. Always 0 for Blind.
  final double signalStrength;

  /// Populated only when outcome == pinpoint. Normalized direction
  /// vector from the reader toward the wake.
  final double? directionX;
  final double? directionY;
  /// Populated only when outcome == pinpoint. 0 -> 1, how strong/urgent
  /// the tracking blip should render -- a direct UI hook for glow/pulse
  /// rate, same idea as HackingController.power.
  final double? pulseIntensity;

  /// Populated only when outcome == zone. Radius of the "could be
  /// anywhere in here" uncertainty circle, centered on the wake's actual
  /// position. Your UI should draw the circle, never the true position --
  /// that's the entire point of a low-signal read.
  final double? zoneOfProbabilityRadius;

  const TrackingResult._({
    required this.outcome,
    required this.signalStrength,
    this.directionX,
    this.directionY,
    this.pulseIntensity,
    this.zoneOfProbabilityRadius,
  });

  factory TrackingResult.blind() => const TrackingResult._(
        outcome: TrackingOutcome.blind,
        signalStrength: 0.0,
      );

  factory TrackingResult.pinpoint({
    required double signalStrength,
    required double directionX,
    required double directionY,
    required double pulseIntensity,
  }) =>
      TrackingResult._(
        outcome: TrackingOutcome.pinpoint,
        signalStrength: signalStrength,
        directionX: directionX,
        directionY: directionY,
        pulseIntensity: pulseIntensity,
      );

  factory TrackingResult.zone({
    required double signalStrength,
    required double zoneOfProbabilityRadius,
  }) =>
      TrackingResult._(
        outcome: TrackingOutcome.zone,
        signalStrength: signalStrength,
        zoneOfProbabilityRadius: zoneOfProbabilityRadius,
      );
}

/// Computes what a reader with `sensor` perceives of `wake`,
/// `timeSinceJump` seconds after it was created, from the reader's own
/// position. Pure function -- no side effects, safe to call as often as
/// you like (e.g. every frame for every enemy ship checking every active
/// wake).
TrackingResult readWake({
  required WarpWake wake,
  required SensorModule sensor,
  required double timeSinceJump,
  required double readerX,
  required double readerY,
  double signalDecayPerSecond = 0.05,
  double pinpointThreshold = 0.6,
  /// From NebulaNode.obscurityMultiplier if the wake (or the reader) is
  /// in/near one -- resolve that lookup wherever you call this, this
  /// function doesn't know what a NebulaNode is. 1.0 = no dampening.
  double obscurityMultiplier = 1.0,
}) {
  if (sensor.tier <= 0) {
    return TrackingResult.blind();
  }

  // Tech vs ECM as a contest, not a subtraction: tech >> ECM approaches
  // 1.0, ECM >> tech approaches 0.0, equal forces land at 0.5. The
  // epsilon avoids a divide-by-zero when both are exactly 0.
  const double epsilon = 0.01;
  final double techVsEcm =
      sensor.trackingTech / (sensor.trackingTech + wake.shipEcm + epsilon);

  final double baseQuality =
      (wake.baseSignalStrength * techVsEcm * obscurityMultiplier).clamp(0.0, 1.0);

  final double decay = (signalDecayPerSecond * timeSinceJump).clamp(0.0, 1.0);
  final double signalStrength = (baseQuality - decay).clamp(0.0, 1.0);

  if (signalStrength <= 0.0) {
    return TrackingResult.blind();
  }

  if (signalStrength >= pinpointThreshold) {
    final double dx = wake.x - readerX;
    final double dy = wake.y - readerY;
    final double dist = math.sqrt(dx * dx + dy * dy);
    final double dirX = dist > 0 ? dx / dist : 0.0;
    final double dirY = dist > 0 ? dy / dist : 1.0;
    return TrackingResult.pinpoint(
      signalStrength: signalStrength,
      directionX: dirX,
      directionY: dirY,
      pulseIntensity: signalStrength,
    );
  }

  // Low signal: a wide uncertainty zone that shrinks as signal improves
  // toward pinpointThreshold, rather than snapping straight from "huge
  // circle" to "exact point."
  const double maxZoneRadius = 4000.0; // tune to your world scale
  final double zoneRadius =
      maxZoneRadius * (1.0 - signalStrength / pinpointThreshold);
  return TrackingResult.zone(
    signalStrength: signalStrength,
    zoneOfProbabilityRadius: zoneRadius,
  );
}
