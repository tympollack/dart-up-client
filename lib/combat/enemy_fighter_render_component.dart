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

import 'dart:math' as math;
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

  final Paint _hullPaint = Paint()
    ..color = const Color(0xFFFF3B3B)
    ..style = PaintingStyle.fill;
  final Paint _outlinePaint = Paint()
    ..color = const Color(0xFFFF8A8A)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.2;
  final Path _hullPath = Path();

  /// Computes the visual heading (in radians) for fighter `index` toward its
  /// target coordinate without mutating any simulation state.
  double headingForFighter(int index) {
    final double dx =
        enemyFighterRoster.targetX[index] - enemyFighterRoster.posX[index];
    final double dy =
        enemyFighterRoster.targetY[index] - enemyFighterRoster.posY[index];
    if (dx.abs() < 1e-5 && dy.abs() < 1e-5) {
      return 0.0;
    }
    return math.atan2(dy, dx);
  }

  @override
  void render(Canvas canvas) {
    for (int i = 0; i < enemyFighterRoster.activeCount; i++) {
      final double x = enemyFighterRoster.posX[i];
      final double y = enemyFighterRoster.posY[i];
      final double angle = headingForFighter(i);
      final double cosA = math.cos(angle);
      final double sinA = math.sin(angle);

      // Directional dart/diamond hull: nose pointing along (cosA, sinA),
      // swept wings on the flanks, and a recessed tail notch.
      final double noseX = x + cosA * (radius * 1.35);
      final double noseY = y + sinA * (radius * 1.35);
      final double rightWingX =
          x - cosA * (radius * 0.35) - sinA * (radius * 0.85);
      final double rightWingY =
          y - sinA * (radius * 0.35) + cosA * (radius * 0.85);
      final double tailX = x - cosA * (radius * 0.9);
      final double tailY = y - sinA * (radius * 0.9);
      final double leftWingX =
          x - cosA * (radius * 0.35) + sinA * (radius * 0.85);
      final double leftWingY =
          y - sinA * (radius * 0.35) - cosA * (radius * 0.85);

      _hullPath
        ..reset()
        ..moveTo(noseX, noseY)
        ..lineTo(rightWingX, rightWingY)
        ..lineTo(tailX, tailY)
        ..lineTo(leftWingX, leftWingY)
        ..close();

      canvas.drawPath(_hullPath, _hullPaint);
      canvas.drawPath(_hullPath, _outlinePaint);
    }
  }
}
