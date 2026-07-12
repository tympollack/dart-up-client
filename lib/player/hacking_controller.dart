// =============================================================================
// hacking_controller.dart
//
// Press-and-hold input/UI state machine for the "Heist" mechanic: hold a
// shrinking circle over a cluster of `stranded` drones to hack them.
//
// Unlike drone_swarm_economy.dart, this controller only ever tracks a
// single in-progress hack at a time -- there's no swarm of these, so
// plain fields and a couple of small immutable snapshot objects are the
// right tool here. No SoA needed for a cast of one.
//
// This file depends only on DroneSwarmEconomy.hackStrandedDrones(); it
// knows nothing about rendering or input devices (no Flutter/Flame types),
// so it's trivial to drive from a GestureDetector, a Flame TapCallbacks
// mixin, or anything else you swap in later.
// =============================================================================

import 'dart:math' as math;

import 'package:sd_client/swarm/drone_swarm_economy.dart';

enum HackState {
  /// No hack in progress. Also the resting state right after a hack
  /// completes or aborts -- check `lastOutcome` if you need to know why.
  idle,
  /// Actively holding; radius is shrinking, power is climbing.
  holding,
}

/// Why the controller last left the `holding` state. Exposed so the
/// renderer/audio layer can react to a *moment* (flash, sting, haptic)
/// without polling every frame -- see `onHackSuccess` / `onHackAborted`
/// for the push-based equivalent of the same information.
enum HackOutcome { none, success, aborted }

/// One successful hack's result, handed to `onHackSuccess`.
class HackResult {
  final double x;
  final double y;
  final double radius;
  final int dronesHacked;

  const HackResult({
    required this.x,
    required this.y,
    required this.radius,
    required this.dronesHacked,
  });
}

/// Everything the render loop needs to draw the shrinking circle, bundled
/// into one immutable snapshot so you can pass a single object into your
/// paint/draw call instead of pulling four separate getters every frame.
///
/// Recommended usage in your render step:
/// ```dart
/// final vis = hackingController.visualState;
/// if (vis.isActive) {
///   drawHackCircle(vis.x, vis.y, vis.radius, vis.power);
/// }
/// ```
class HackVisualState {
  final bool isActive;
  final double x;
  final double y;
  final double radius; // linearly shrinking, maxRadius -> minRadius
  final double progress; // linear 0 -> 1 (time-based)
  final double power; // exponential 0 -> 1 (tension-based -- see `power` below)

  const HackVisualState({
    required this.isActive,
    required this.x,
    required this.y,
    required this.radius,
    required this.progress,
    required this.power,
  });
}

class HackingController {
  HackingController({
    required this.economy,
    this.maxRadius = 200.0,
    this.minRadius = 24.0,
    this.hackDuration = 5.0,
    this.exponentialSteepness = 4.0,
    this.onHackSuccess,
    this.onHackAborted,
  });

  final DroneSwarmEconomy economy;

  /// Starting circle radius, and also the radius actually passed to
  /// `economy.hackStrandedDrones()` on completion -- the shrink is a UI
  /// tension effect only, the catch area never changes.
  final double maxRadius;
  /// Circle radius at the instant of completion.
  final double minRadius;
  /// How long the player must hold to succeed, in seconds.
  final double hackDuration;
  /// Steepness (k) of the exponential power curve. Higher = the power
  /// number stays low for longer and then snaps up harder right at the
  /// end. Must be > 0.
  final double exponentialSteepness;

  /// Fires exactly once, the instant a hold completes successfully.
  final void Function(HackResult result)? onHackSuccess;
  /// Fires exactly once, the instant a hold is released early.
  final void Function()? onHackAborted;

  HackState _state = HackState.idle;
  HackOutcome _lastOutcome = HackOutcome.none;
  double _x = 0;
  double _y = 0;
  double _elapsed = 0;

  HackState get state => _state;
  HackOutcome get lastOutcome => _lastOutcome;
  bool get isActive => _state == HackState.holding;

  // ---------------------------------------------------------------------------
  // Continuous values -- safe to read every frame regardless of state.
  // All return their "resting" value (maxRadius / 0) when not holding, so
  // you never need to null-check before reading them.
  // ---------------------------------------------------------------------------

  /// Current circle radius. Linear interpolation from maxRadius to
  /// minRadius over hackDuration -- "steadily shrinks," per spec.
  double get currentRadius {
    if (_state != HackState.holding) return maxRadius;
    return _lerp(maxRadius, minRadius, progress);
  }

  /// Raw linear time progress through the hold, 0 -> 1.
  double get progress {
    if (_state != HackState.holding) return 0.0;
    return (_elapsed / hackDuration).clamp(0.0, 1.0);
  }

  /// "Hacking power" / tension, 0 -> 1, growing *exponentially* rather
  /// than linearly as the circle shrinks. Drive glow intensity, pulse
  /// rate, color shift, audio pitch, screen shake, etc. off this instead
  /// of `progress` for that "it's about to pop" feeling near the end.
  double get power {
    if (_state != HackState.holding) return 0.0;
    final double k = exponentialSteepness > 0 ? exponentialSteepness : 0.0001;
    final double t = progress;
    // Normalized so it's exactly 0 at t=0 and exactly 1 at t=1, regardless
    // of k -- only the *shape* of the ramp changes with steepness.
    return (math.exp(k * t) - 1) / (math.exp(k) - 1);
  }

  /// Bundles the four values above plus position into one snapshot for
  /// the render loop. See the class doc comment for recommended usage.
  HackVisualState get visualState => HackVisualState(
        isActive: isActive,
        x: _x,
        y: _y,
        radius: currentRadius,
        progress: progress,
        power: power,
      );

  // ---------------------------------------------------------------------------
  // Input
  // ---------------------------------------------------------------------------

  /// Call on press-down / tap-start. Starting a new hack while one is
  /// already in progress simply restarts it at the new location -- there's
  /// only ever one hack live at a time.
  void beginHack(double x, double y) {
    _x = x;
    _y = y;
    _elapsed = 0;
    _state = HackState.holding;
  }

  /// Call once per game-loop tick. Safe to call unconditionally every
  /// frame -- it's a no-op whenever the controller isn't holding.
  void update(double dt) {
    if (_state != HackState.holding) return;

    _elapsed += dt;
    if (_elapsed >= hackDuration) {
      _completeHack();
    }
  }

  /// Call on pointer-up / tap-release. If the hold hadn't finished yet,
  /// this aborts it completely: state and all continuous getters
  /// (progress, power) snap back to their resting values immediately --
  /// no partial credit, per spec. A no-op if nothing was in progress
  /// (e.g. the hold already completed this frame).
  void releaseHack() {
    if (_state != HackState.holding) return;

    _state = HackState.idle;
    _lastOutcome = HackOutcome.aborted;
    _elapsed = 0;
    onHackAborted?.call();
  }

  /// Optional manual reset, e.g. if you want to clear `lastOutcome` after
  /// the UI has finished reacting to it.
  void reset() {
    _state = HackState.idle;
    _lastOutcome = HackOutcome.none;
    _elapsed = 0;
  }

  void _completeHack() {
    final int dronesHacked =
        economy.hackStrandedDrones(_x, _y, maxRadius);

    _state = HackState.idle;
    _lastOutcome = HackOutcome.success;
    _elapsed = 0;

    onHackSuccess?.call(HackResult(
      x: _x,
      y: _y,
      radius: maxRadius,
      dronesHacked: dronesHacked,
    ));
  }

  static double _lerp(double a, double b, double t) => a + (b - a) * t;
}
