import 'dart:math';
import 'package:flame/components.dart';
import 'package:flutter/material.dart';

/// Combat Squad Unit matching Kenney Sci-Fi RTS specifications.
/// Navigates cleanly through waypoints produced by grid pathfinding.
class SquadUnitComponent extends PositionComponent {
  final double speed; // pixels per second
  final double turnRate; // radians per second
  final Color factionColor;
  final String unitName;

  List<Vector2> waypoints = [];
  int _currentWaypointIndex = 0;
  double heading = 0.0;
  bool isMoving = false;
  double health = 100.0;
  double maxHealth = 100.0;
  double _exhaustTimer = 0.0;

  SquadUnitComponent({
    required Vector2 position,
    this.speed = 110.0,
    this.turnRate = 5.0,
    this.factionColor = const Color(0xFF00E5FF),
    this.unitName = 'Scout Rover',
  }) : super(
          position: position,
          size: Vector2(36, 36),
          anchor: Anchor.center,
        );

  /// Assign a new sequence of waypoints for path navigation
  void setWaypoints(List<Vector2> newWaypoints) {
    waypoints = List.from(newWaypoints);
    _currentWaypointIndex = 0;
    isMoving = waypoints.isNotEmpty;
  }

  /// Add a single waypoint to current navigation queue
  void addWaypoint(Vector2 point) {
    waypoints.add(point);
    if (!isMoving) isMoving = true;
  }

  /// Clear all waypoints and stop in place
  void stop() {
    waypoints.clear();
    _currentWaypointIndex = 0;
    isMoving = false;
  }

  @override
  void update(double dt) {
    super.update(dt);
    _exhaustTimer += dt;

    if (!isMoving || _currentWaypointIndex >= waypoints.length) {
      isMoving = false;
      return;
    }

    final targetPoint = waypoints[_currentWaypointIndex];
    final toTarget = targetPoint - position;
    final dist = toTarget.length;

    final direction = toTarget.normalized();
    final double moveStep = speed * dt;
    const double arrivalThreshold = 4.0;

    // Check waypoint arrival threshold or step overshoot
    if (dist <= moveStep || dist <= arrivalThreshold) {
      position.setFrom(targetPoint);
      _currentWaypointIndex++;
      if (_currentWaypointIndex >= waypoints.length) {
        isMoving = false;
        return;
      }
    } else {
      // Advance position
      position += direction * moveStep;
    }

    final double desiredHeading = atan2(direction.y, direction.x);

    // Smooth heading steering
    double diff = (desiredHeading - heading) % (2.0 * pi);
    if (diff > pi) diff -= 2.0 * pi;
    if (diff < -pi) diff += 2.0 * pi;

    final double turnStep = turnRate * dt;
    if (diff.abs() <= turnStep) {
      heading = desiredHeading;
    } else {
      heading += diff.sign * turnStep;
    }
  }

  @override
  void render(Canvas canvas) {
    super.render(canvas);

    final double halfW = size.x / 2.0;
    final double halfH = size.y / 2.0;

    canvas.save();
    canvas.translate(halfW, halfH);
    canvas.rotate(heading);

    // 1. Dual Heavy Treads / Skids (Kenney RTS tank chassis)
    final treadPaint = Paint()
      ..color = const Color(0xFF0F172A)
      ..style = PaintingStyle.fill;
    final treadStroke = Paint()
      ..color = const Color(0xFF334155)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    // Left Tread
    const double treadL = 30.0;
    const double treadW = 6.0;
    const double treadOffset = 11.0;

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(-treadL / 2, -treadOffset - treadW / 2, treadL, treadW),
        const Radius.circular(2.0),
      ),
      treadPaint,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(-treadL / 2, -treadOffset - treadW / 2, treadL, treadW),
        const Radius.circular(2.0),
      ),
      treadStroke,
    );

    // Right Tread
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(-treadL / 2, treadOffset - treadW / 2, treadL, treadW),
        const Radius.circular(2.0),
      ),
      treadPaint,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(-treadL / 2, treadOffset - treadW / 2, treadL, treadW),
        const Radius.circular(2.0),
      ),
      treadStroke,
    );

    // 2. Armored Hull
    final hullPath = Path()
      ..moveTo(14, 0) // Nose tip
      ..lineTo(6, -9)
      ..lineTo(-12, -9)
      ..lineTo(-12, 9)
      ..lineTo(6, 9)
      ..close();

    final hullFill = Paint()
      ..color = const Color(0xFF1E293B)
      ..style = PaintingStyle.fill;
    canvas.drawPath(hullPath, hullFill);

    final hullStroke = Paint()
      ..color = const Color(0xFF64748B)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawPath(hullPath, hullStroke);

    // 3. Faction Color Trim & Cockpit Canopy
    final factionPaint = Paint()
      ..color = factionColor
      ..style = PaintingStyle.fill;
    canvas.drawRect(
      const Rect.fromLTWH(-8, -4, 4, 8),
      factionPaint,
    );

    // Cyan / Glowing Cockpit Dome
    final cockpitPaint = Paint()
      ..color = factionColor.withValues(alpha: 0.9)
      ..style = PaintingStyle.fill;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(0, -3.5, 7, 7),
        const Radius.circular(2.0),
      ),
      cockpitPaint,
    );

    // 4. Thruster Exhaust Plume when moving
    if (isMoving) {
      final plumePaint = Paint()
        ..color = factionColor.withValues(alpha: 0.6 + 0.3 * sin(_exhaustTimer * 20.0))
        ..style = PaintingStyle.fill;
      canvas.drawCircle(const Offset(-15, 0), 3.0, plumePaint);
    }

    canvas.restore();

    // 5. Health Bar overhead (Unrotated in screen space)
    final barW = size.x;
    const barH = 3.0;
    const barY = -6.0;

    // Background track
    final trackPaint = Paint()
      ..color = const Color(0xFF0F172A)
      ..style = PaintingStyle.fill;
    canvas.drawRect(Rect.fromLTWH(0, barY, barW, barH), trackPaint);

    // Fill ratio
    final healthRatio = (health / maxHealth).clamp(0.0, 1.0);
    final healthPaint = Paint()
      ..color = healthRatio > 0.4 ? const Color(0xFF10B981) : const Color(0xFFEF4444)
      ..style = PaintingStyle.fill;
    canvas.drawRect(Rect.fromLTWH(0, barY, barW * healthRatio, barH), healthPaint);
  }
}
