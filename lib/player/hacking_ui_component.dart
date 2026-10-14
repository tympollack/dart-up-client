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

import 'dart:ui';

import 'package:flame/components.dart';

import 'package:sd_client/player/hacking_controller.dart';

class HackingUIComponent extends PositionComponent {
  HackingUIComponent({required this.controller});

  final HackingController controller;

  final Color _ringColor = const Color(0xFF00FFC8);

  @override
  void render(Canvas canvas) {
    final HackVisualState vis = controller.visualState;
    if (!vis.isActive) return;

    final Offset center = Offset(vis.x, vis.y);
    // `power` is already the exponential 0->1 ramp computed by the
    // controller -- this only maps it onto alpha/blur, it doesn't shape
    // the curve itself.
    final double power = vis.power.clamp(0.0, 1.0);

    // Soft glow underneath, intensity bound straight to `power`.
    final Paint glowPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 14.0
      ..color = _ringColor.withValues(alpha: (0.15 + power * 0.55).clamp(0.0, 1.0))
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10.0);
    canvas.drawCircle(center, vis.radius, glowPaint);

    // Crisp ring on top -- radius is the literal, linearly-shrinking
    // value read straight from the controller, not re-derived here.
    final Paint ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0
      ..color = _ringColor.withValues(alpha: (0.5 + power * 0.5).clamp(0.0, 1.0));
    canvas.drawCircle(center, vis.radius, ringPaint);
  }
}
