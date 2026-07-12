// =============================================================================
// player_ship_component.dart
//
// Pure render + reactive-effect component. Reads ShipWarpController and
// nothing else -- no countdown logic, no state-transition logic lives here.
// update() only ever *reacts* to numbers the controller already computed
// (spoolProgress, warpState); it never computes a spool duration or
// decides when a warp fires.
// =============================================================================

import 'dart:math' as math;
import 'dart:ui';

import 'package:flame/components.dart';

import 'package:sd_client/player/ship_warp_controller.dart';

class PlayerShipComponent extends PositionComponent {
  PlayerShipComponent({
    required this.warpController,
    required Vector2 size,
    Vector2? position,
    this.shakeAmplitude = 6.0,
    this.arrivalShakeAmplitude = 10.0,
    this.flashDuration = 0.4,
  }) : super(size: size, position: position, anchor: Anchor.center) {
    _basePosition = (position ?? Vector2.zero()).clone();
  }

  final ShipWarpController warpController;

  /// Max shake offset in pixels, reached right as the spool completes.
  final double shakeAmplitude;
  /// Max shake offset in pixels at the *start* of the Arriving window,
  /// tapering to 0 by the time it ends. Defaults higher than
  /// shakeAmplitude -- "dropping out of hyperspace" reads as a harder
  /// jolt than the spool-up tension shake.
  final double arrivalShakeAmplitude;
  /// How long the warp flash takes to fade out, in seconds.
  final double flashDuration;

  final math.Random _rng = math.Random();
  late Vector2 _basePosition;

  WarpState _lastObservedState = WarpState.idle;
  bool _flashing = false;
  double _flashElapsed = 0;

  final Paint _hullPaint = Paint()..color = const Color(0xFF6FD8FF);

  /// The ship's true gameplay position, unaffected by the cosmetic shake.
  /// Feed THIS into DroneSwarmEconomy.update(shipX, shipY) -- never the
  /// shaking `position` -- so a visual effect can't leak into gameplay
  /// math (arrival-radius checks, etc.). This is the same principle as
  /// keeping rendering math out of the controllers, just mirrored: don't
  /// let rendering jitter back into gameplay math either.
  Vector2 get basePosition => _basePosition;

  /// Call this whenever your actual movement/control code repositions the
  /// ship. Keeps the shake jittering around the right point instead of a
  /// stale base.
  void setBasePosition(Vector2 newPosition) {
    _basePosition = newPosition.clone();
  }

  @override
  void update(double dt) {
    super.update(dt);

    final WarpState state = warpController.warpState;

    if (state == WarpState.spooling) {
      // spoolProgress is already 0->1, already normalized by the
      // controller -- this only maps it to a pixel offset, it doesn't
      // recompute the countdown itself.
      final double intensity = shakeAmplitude * warpController.spoolProgress;
      final double offsetX = (_rng.nextDouble() * 2 - 1) * intensity;
      final double offsetY = (_rng.nextDouble() * 2 - 1) * intensity;
      position.setValues(
        _basePosition.x + offsetX,
        _basePosition.y + offsetY,
      );
    } else if (state == WarpState.arriving) {
      // arrivalProgress is already 0->1, already normalized -- tapering
      // (1.0 - progress) gives a shake that's violent right at arrival
      // and settles out by the time the window ends, i.e. "decelerating."
      final double intensity =
          arrivalShakeAmplitude * (1.0 - warpController.arrivalProgress);
      final double offsetX = (_rng.nextDouble() * 2 - 1) * intensity;
      final double offsetY = (_rng.nextDouble() * 2 - 1) * intensity;
      position.setValues(
        _basePosition.x + offsetX,
        _basePosition.y + offsetY,
      );
    } else {
      position.setFrom(_basePosition);
    }

    // Edge-detect the ->Arriving transition so the flash fires exactly
    // once. NOTE: this used to watch for WarpState.warping, but that
    // state is no longer observably "sticky" -- ShipWarpController now
    // falls straight through Warping into the real, auto-ticking
    // Arriving state within a single synchronous call, so a polling
    // render loop never actually catches `warpState == warping`.
    // Arriving is the correct, and better-fitting, place for this: it's
    // the real visual window the 2-second deceleration is meant to fill.
    if (state == WarpState.arriving &&
        _lastObservedState != WarpState.arriving) {
      _flashing = true;
      _flashElapsed = 0;
    }
    _lastObservedState = state;

    if (_flashing) {
      _flashElapsed += dt;
      if (_flashElapsed >= flashDuration) {
        _flashing = false;
      }
    }
  }

  @override
  void render(Canvas canvas) {
    // Placeholder hull -- swap in a child SpriteComponent once you have
    // real art. The shake/flash logic above doesn't care how the hull
    // itself is drawn.
    final Rect bounds = Rect.fromLTWH(0, 0, size.x, size.y);
    canvas.drawRect(bounds, _hullPaint);

    if (_flashing) {
      final double t = (_flashElapsed / flashDuration).clamp(0.0, 1.0);
      final double opacity = 1.0 - t;
      canvas.drawRect(bounds, Paint()..color = Color.fromRGBO(255, 255, 255, opacity));
    }
  }
}
