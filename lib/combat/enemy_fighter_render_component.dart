// =============================================================================
// enemy_fighter_render_component.dart
//
// Pure render component. Reads FighterRoster.posX/posY directly for every
// active fighter and draws a fixed, unrotated diamond at that position.
//
// Deliberately NOT oriented toward each fighter's target: that would
// only need a single atan2() of two already-stored coordinates (the same
// category of "repack already-final data for drawing" as
// SwarmRenderComponent's RSTransform conversion), so it would have been
// defensible -- but there's no need to spend that argument when a fixed
// shape reads the position just as clearly and keeps this component
// unambiguously logic-free.
// =============================================================================

import 'dart:ui';

import 'package:flame/components.dart';

import 'package:sd_client/combat/fighter_roster.dart';

class EnemyFighterRenderComponent extends PositionComponent {
  EnemyFighterRenderComponent({
    required this.enemyFighterRoster,
    this.radius = 9.0,
  });

  final FighterRoster enemyFighterRoster;
  final double radius;

  final Paint _paint = Paint()..color = const Color(0xFFFF3B3B);

  @override
  void render(Canvas canvas) {
    for (int i = 0; i < enemyFighterRoster.activeCount; i++) {
      final double x = enemyFighterRoster.posX[i];
      final double y = enemyFighterRoster.posY[i];

      final Path diamond = Path()
        ..moveTo(x, y - radius)
        ..lineTo(x + radius, y)
        ..lineTo(x, y + radius)
        ..lineTo(x - radius, y)
        ..close();

      canvas.drawPath(diamond, _paint);
    }
  }
}
