import 'dart:math';
import 'package:flame/components.dart';
import 'package:flutter/material.dart';

/// Defensive combat turret matching Kenney Sci-Fi RTS specifications.
/// Dynamically tracks and rotates toward target unit coordinates.
class DefensiveTurretComponent extends PositionComponent {
  final double range;
  final double rotationSpeed; // radians per second
  final Color factionColor;

  Vector2? targetPosition;
  double currentHeading = 0.0;
  bool isAcquiringTarget = false;
  double _energyPulseTimer = 0.0;

  DefensiveTurretComponent({
    required Vector2 position,
    this.range = 220.0,
    this.rotationSpeed = 3.5,
    this.factionColor = const Color(0xFF00E5FF),
  }) : super(
          position: position,
          size: Vector2(44, 44),
          anchor: Anchor.center,
        );

  /// Point the turret toward a specific world target coordinate
  void setTarget(Vector2? target) {
    targetPosition = target;
  }

  @override
  void update(double dt) {
    super.update(dt);
    _energyPulseTimer += dt;

    if (targetPosition != null) {
      final toTarget = targetPosition! - position;
      final dist = toTarget.length;

      if (dist <= range) {
        isAcquiringTarget = true;
        final double desiredHeading = atan2(toTarget.y, toTarget.x);

        // Normalize angle difference to [-pi, pi]
        double diff = (desiredHeading - currentHeading) % (2.0 * pi);
        if (diff > pi) diff -= 2.0 * pi;
        if (diff < -pi) diff += 2.0 * pi;

        final double step = rotationSpeed * dt;
        if (diff.abs() <= step) {
          currentHeading = desiredHeading;
        } else {
          currentHeading += diff.sign * step;
        }
      } else {
        isAcquiringTarget = false;
      }
    } else {
      isAcquiringTarget = false;
      // Idle slow scanning rotation
      currentHeading += 0.4 * dt;
    }
  }

  @override
  void render(Canvas canvas) {
    super.render(canvas);

    final double halfW = size.x / 2.0;
    final double halfH = size.y / 2.0;

    // 1. Base Platform (Static octagonal chassis)
    final basePath = Path();
    const int sides = 8;
    for (int i = 0; i < sides; i++) {
      final angle = (pi / 4.0) * i;
      final x = halfW + halfW * 0.9 * cos(angle);
      final y = halfH + halfH * 0.9 * sin(angle);
      if (i == 0) {
        basePath.moveTo(x, y);
      } else {
        basePath.lineTo(x, y);
      }
    }
    basePath.close();

    // Heavy dark armored base
    final baseFill = Paint()
      ..color = const Color(0xFF1E293B)
      ..style = PaintingStyle.fill;
    canvas.drawPath(basePath, baseFill);

    final baseStroke = Paint()
      ..color = const Color(0xFF475569)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    canvas.drawPath(basePath, baseStroke);

    // Hazard rivets on base corners
    final rivetPaint = Paint()
      ..color = factionColor.withValues(alpha: 0.7)
      ..style = PaintingStyle.fill;
    for (int i = 0; i < 4; i++) {
      final angle = (pi / 2.0) * i + (pi / 4.0);
      final rx = halfW + halfW * 0.65 * cos(angle);
      final ry = halfH + halfH * 0.65 * sin(angle);
      canvas.drawCircle(Offset(rx, ry), 2.0, rivetPaint);
    }

    // 2. Rotating Turret Head & Barrels
    canvas.save();
    canvas.translate(halfW, halfH);
    canvas.rotate(currentHeading);

    // Twin Plasma Cannon Barrels
    final barrelPaint = Paint()
      ..color = const Color(0xFF0F172A)
      ..style = PaintingStyle.fill;
    final barrelStroke = Paint()
      ..color = factionColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    // Barrel 1 (Top)
    const barrelL = 20.0;
    const barrelW = 4.0;
    const barrelSpread = 5.0;

    canvas.drawRect(
      const Rect.fromLTWH(0, -barrelSpread - barrelW / 2, barrelL, barrelW),
      barrelPaint,
    );
    canvas.drawRect(
      const Rect.fromLTWH(0, -barrelSpread - barrelW / 2, barrelL, barrelW),
      barrelStroke,
    );

    // Barrel 2 (Bottom)
    canvas.drawRect(
      const Rect.fromLTWH(0, barrelSpread - barrelW / 2, barrelL, barrelW),
      barrelPaint,
    );
    canvas.drawRect(
      const Rect.fromLTWH(0, barrelSpread - barrelW / 2, barrelL, barrelW),
      barrelStroke,
    );

    // Turret Dome / Cap
    final domePaint = Paint()
      ..color = const Color(0xFF334155)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset.zero, 11.0, domePaint);

    final domeStroke = Paint()
      ..color = const Color(0xFF94A3B8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawCircle(Offset.zero, 11.0, domeStroke);

    // Energy Core Center
    final corePaint = Paint()
      ..color = factionColor
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset.zero, 4.5, corePaint);

    // Active targeting laser sight when target locked
    if (isAcquiringTarget) {
      final laserPaint = Paint()
        ..color = factionColor.withValues(alpha: 0.6 + 0.3 * sin(_energyPulseTimer * 10.0))
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2;
      canvas.drawLine(
        Offset.zero,
        const Offset(180, 0),
        laserPaint,
      );

      // Target reticle pip at laser end
      final reticlePaint = Paint()
        ..color = Colors.white
        ..style = PaintingStyle.fill;
      canvas.drawCircle(const Offset(180, 0), 2.5, reticlePaint);
    }

    canvas.restore();
  }
}
