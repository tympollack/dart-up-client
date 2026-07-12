// =============================================================================
// combat_vfx_component.dart
//
// Pure render component, with one deliberate exception: it DOES own a
// small amount of state -- a short-lived list of "currently fading
// strikes." This is purely a rendering-lifecycle concern (how long has
// this laser flash been on screen, how transparent should it be right
// now), not game logic: CombatManager already resolved the hit, decided
// who got hurt, and fired the event. All this component decides is how
// to animate something that already happened.
//
// Wire this up by passing `combatVFXComponent.recordHit` as
// CombatManager's `onDamageDealt` callback -- see dart_up_game.dart.
// =============================================================================

import 'dart:ui';

import 'package:flame/components.dart';

import 'package:sd_client/combat/combat_manager.dart';

class _ActiveStrike {
  _ActiveStrike({
    required this.sourceX,
    required this.sourceY,
    required this.targetX,
    required this.targetY,
    required this.source,
    required this.totalDuration,
  }) : timeRemaining = totalDuration;

  final double sourceX;
  final double sourceY;
  final double targetX;
  final double targetY;
  final CombatHitSource source;
  final double totalDuration;
  double timeRemaining;
}

class CombatVFXComponent extends PositionComponent {
  CombatVFXComponent({this.fadeDuration = 0.15});

  /// How long a strike's line takes to fade out completely, in seconds.
  final double fadeDuration;

  final List<_ActiveStrike> _strikes = [];

  static const Color _enemyOnShipColor = Color(0xFFFF3B3B); // red
  static const Color _pointDefenseColor = Color(0xFF4FFFB0); // green
  static const Color _shipTurretColor = Color(0xFF4FB3FF); // blue

  /// Pass this directly as CombatManager's onDamageDealt callback. Just
  /// stores the strike data and starts its fade timer -- no combat logic,
  /// the hit already happened by the time this is called.
  void recordHit(CombatHitEvent event) {
    _strikes.add(_ActiveStrike(
      sourceX: event.sourceX,
      sourceY: event.sourceY,
      targetX: event.targetX,
      targetY: event.targetY,
      source: event.source,
      totalDuration: fadeDuration,
    ));
  }

  @override
  void update(double dt) {
    super.update(dt);
    for (int i = _strikes.length - 1; i >= 0; i--) {
      _strikes[i].timeRemaining -= dt;
      if (_strikes[i].timeRemaining <= 0) {
        _strikes.removeAt(i);
      }
    }
  }

  @override
  void render(Canvas canvas) {
    for (final _ActiveStrike strike in _strikes) {
      final double t = (strike.timeRemaining / strike.totalDuration).clamp(0.0, 1.0);
      final Paint paint = Paint()
        ..color = _colorFor(strike.source).withOpacity(t)
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round;

      canvas.drawLine(
        Offset(strike.sourceX, strike.sourceY),
        Offset(strike.targetX, strike.targetY),
        paint,
      );
    }
  }

  Color _colorFor(CombatHitSource source) {
    switch (source) {
      case CombatHitSource.enemyFighterOnShip:
        return _enemyOnShipColor;
      case CombatHitSource.dronePointDefense:
        return _pointDefenseColor;
      case CombatHitSource.shipTurret:
        return _shipTurretColor;
    }
  }
}
