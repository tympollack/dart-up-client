// =============================================================================
// celestial_node_component.dart
//
// Pure render component. Iterates CelestialNodeManager.nodes every frame
// and draws them -- no caching, no update() override, since the node
// list changes rarely (registerNode/unregisterNode) and is small (a
// local sector's worth, not swarm-scale). No physics, no logic: this
// only reads x/y/interactionRadius/obscurityMultiplier, values that are
// already final by the time this file ever sees them.
// =============================================================================

import 'dart:ui';

import 'package:flame/components.dart';

import 'package:sd_client/celestial/celestial_node_manager.dart';

class CelestialNodeComponent extends PositionComponent {
  CelestialNodeComponent({required this.nodeManager});

  final CelestialNodeManager nodeManager;

  static const Color _planetColor = Color(0xFF4FA8FF);
  static const Color _nebulaColor = Color(0xFF8A4FFF);

  @override
  void render(Canvas canvas) {
    for (final CelestialNode node in nodeManager.nodes) {
      if (node is NebulaNode) {
        _renderNebula(canvas, node);
      } else if (node is PlanetNode) {
        _renderPlanet(canvas, node);
      }
    }
  }

  void _renderPlanet(Canvas canvas, PlanetNode node) {
    final Offset center = Offset(node.x, node.y);

    // Solid body, deliberately smaller than interactionRadius -- the
    // radius is the docking range, not the planet's visual size.
    final Paint bodyPaint = Paint()..color = _planetColor;
    canvas.drawCircle(center, node.interactionRadius * 0.25, bodyPaint);

    // Faint ring showing the actual interaction/docking radius, so it's
    // visually obvious how close you need to be.
    final Paint ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = _planetColor.withOpacity(0.25);
    canvas.drawCircle(center, node.interactionRadius, ringPaint);
  }

  void _renderNebula(Canvas canvas, NebulaNode node) {
    final Offset center = Offset(node.x, node.y);

    // Larger, translucent, differently-colored fill -- the obscurity
    // zone itself, sized to the full interactionRadius (this IS the
    // zone, not a docking ring around a small body).
    final Paint fillPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = _nebulaColor.withOpacity(0.18);
    canvas.drawCircle(center, node.interactionRadius, fillPaint);

    final Paint borderPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..color = _nebulaColor.withOpacity(0.4);
    canvas.drawCircle(center, node.interactionRadius, borderPaint);
  }
}
