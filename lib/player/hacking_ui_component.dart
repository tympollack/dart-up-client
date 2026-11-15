// =============================================================================
// hacking_ui_component.dart
//
// Pure render component for the press-and-hold hack circle. Reads
// HackingController.visualState and draws it -- no progress math, no
// timers, nothing computed here that the controller hasn't already
// computed. No update() override, same reasoning as SwarmRenderComponent:
// there's nothing time-driven for this component to decide, only data to
// read and paint.
// =============================================================================

import 'dart:math' as math;
import 'dart:ui';

import 'package:flame/components.dart';

import 'package:sd_client/player/hacking_controller.dart';

class HackingUIComponent extends PositionComponent {
  HackingUIComponent({required this.controller});

  final HackingController controller;

  static const Color _ringColor = Color(0xFF00FFC8);
  static const Color _powerRampColor = Color(0xFFFF4081);

  final Paint _glowPaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 14.0
    ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10.0);

  final Paint _ringPaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 3.0;

  final Paint _powerArcPaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 5.0
    ..strokeCap = StrokeCap.round;

  @override
  void render(Canvas canvas) {
    final HackVisualState vis = controller.visualState;
    if (!vis.isActive) return;

    final Offset center = Offset(vis.x, vis.y);
    final double power = vis.power.clamp(0.0, 1.0);

    // 1. Soft glow underneath, intensity bound straight to exponential `power`.
    _glowPaint.color =
        _ringColor.withValues(alpha: (0.15 + power * 0.55).clamp(0.0, 1.0));
    canvas.drawCircle(center, vis.radius, _glowPaint);

    // 2. Crisp linear radius ring on top -- radius is the linearly-shrinking
    // value read straight from the controller.
    _ringPaint.color =
        _ringColor.withValues(alpha: (0.5 + power * 0.5).clamp(0.0, 1.0));
    canvas.drawCircle(center, vis.radius, _ringPaint);

    // 3. Exponential power ramp gauge arc around the perimeter.
    if (power > 0.0) {
      final Rect arcRect = Rect.fromCircle(center: center, radius: vis.radius + 8.0);
      _powerArcPaint.color =
          _powerRampColor.withValues(alpha: (0.4 + power * 0.6).clamp(0.0, 1.0));
      canvas.drawArc(
        arcRect,
        -math.pi / 2,
        power * 2 * math.pi,
        false,
        _powerArcPaint,
      );
    }
  }
}
