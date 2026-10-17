import 'dart:math';
import 'package:flame/components.dart';
import 'package:flutter/material.dart';

/// Heavy Resource Harvester matching Kenney Sci-Fi RTS specifications.
/// Extracts minerals/crystals and stores cargo with visual extraction laser pulses.
class ResourceHarvesterComponent extends PositionComponent {
  final Color factionColor;
  double cargoCapacity;
  double currentCargo;
  bool isHarvesting;
  double _pulseTimer = 0.0;

  ResourceHarvesterComponent({
    required Vector2 position,
    this.factionColor = const Color(0xFFF59E0B), // Industrial Amber
    this.cargoCapacity = 100.0,
    this.currentCargo = 25.0,
    this.isHarvesting = true,
  }) : super(
          position: position,
          size: Vector2(40, 40),
          anchor: Anchor.center,
        );

  @override
  void update(double dt) {
    super.update(dt);
    _pulseTimer += dt;

    if (isHarvesting && currentCargo < cargoCapacity) {
      currentCargo = (currentCargo + 4.0 * dt).clamp(0.0, cargoCapacity);
    }
  }

  @override
  void render(Canvas canvas) {
    super.render(canvas);

    final double halfW = size.x / 2.0;

    // 1. Heavy Tracked Crawler Base
    final trackPaint = Paint()
      ..color = const Color(0xFF0F172A)
      ..style = PaintingStyle.fill;
    final trackStroke = Paint()
      ..color = const Color(0xFF334155)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    // Left track
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(2, 4, 8, 32),
        const Radius.circular(2.0),
      ),
      trackPaint,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(2, 4, 8, 32),
        const Radius.circular(2.0),
      ),
      trackStroke,
    );

    // Right track
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(30, 4, 8, 32),
        const Radius.circular(2.0),
      ),
      trackPaint,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(30, 4, 8, 32),
        const Radius.circular(2.0),
      ),
      trackStroke,
    );

    // 2. Central Processing Hopper & Chasis
    final hopperRect = Rect.fromLTWH(9, 6, 22, 28);
    final hopperPaint = Paint()
      ..color = const Color(0xFF1E293B)
      ..style = PaintingStyle.fill;
    canvas.drawRRect(
      RRect.fromRectAndRadius(hopperRect, const Radius.circular(4.0)),
      hopperPaint,
    );

    final hopperStroke = Paint()
      ..color = const Color(0xFF64748B)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawRRect(
      RRect.fromRectAndRadius(hopperRect, const Radius.circular(4.0)),
      hopperStroke,
    );

    // Industrial Warning Chevron Trim
    final hazardPaint = Paint()
      ..color = factionColor
      ..style = PaintingStyle.fill;
    canvas.drawRect(const Rect.fromLTWH(11, 8, 18, 3), hazardPaint);

    // 3. Cargo Crystals Window
    final cargoRatio = (currentCargo / cargoCapacity).clamp(0.0, 1.0);
    final crystalPaint = Paint()
      ..color = const Color(0xFF00E5FF).withValues(alpha: 0.4 + 0.5 * cargoRatio)
      ..style = PaintingStyle.fill;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(13, 14, 14, 12),
        const Radius.circular(2.0),
      ),
      crystalPaint,
    );

    // 4. Extraction Drill / Laser Beam when harvesting
    if (isHarvesting) {
      final double beamIntensity = 0.5 + 0.5 * sin(_pulseTimer * 8.0);

      // Outer extraction aura
      final auraPaint = Paint()
        ..color = const Color(0xFF00E5FF).withValues(alpha: 0.25 * beamIntensity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 8.0;
      canvas.drawLine(
        Offset(halfW, 34),
        Offset(halfW, 46),
        auraPaint,
      );

      // Core drill laser
      final drillPaint = Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0;
      canvas.drawLine(
        Offset(halfW, 34),
        Offset(halfW, 46),
        drillPaint,
      );

      // Ground impact sparks
      final sparkPaint = Paint()
        ..color = const Color(0xFF00E5FF)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(Offset(halfW, 46), 3.0 * beamIntensity, sparkPaint);
    }
  }
}
