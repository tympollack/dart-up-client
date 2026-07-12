// =============================================================================
// celestial_node_manager.dart
//
// Pure Dart, engine-agnostic. Celestial Nodes are warp destinations:
// planets, nebulae, anything a ship can target with commandWarp(). This
// file only holds their data and a simple registry/lookup -- no
// rendering, no per-node behavior beyond what's needed to ask "is this
// point inside this node's interactionRadius."
//
// Scope note: this models the handful of nodes relevant to a local
// sector/play area, not the galaxy-scale "100,000+ star systems" --
// that's a server-side/persistence concern with its own spatial indexing,
// entirely separate from this client-side registry.
// =============================================================================

abstract class CelestialNode {
  final String id;
  final double x;
  final double y;

  /// How close a ship needs to be to count as "at" this node -- used both
  /// for FTL accuracy checks (did the jump land inside this radius?) and
  /// for currentDockedNode resolution in ship_warp_controller.dart.
  final double interactionRadius;

  const CelestialNode({
    required this.id,
    required this.x,
    required this.y,
    required this.interactionRadius,
  });

  /// Whether (px, py) falls within this node's interactionRadius.
  bool containsPoint(double px, double py) {
    final double dx = px - x;
    final double dy = py - y;
    return dx * dx + dy * dy <= interactionRadius * interactionRadius;
  }
}

/// A planet: an economic destination with faction and richness data.
/// Whatever those drive in your actual economy (trade, missions,
/// territory control) lives outside this file -- these are just the
/// data points a warp/economy system would read.
class PlanetNode extends CelestialNode {
  /// Whoever currently holds this planet. Plain string/id rather than an
  /// enum so you can wire it to whatever faction system you build later
  /// without this file needing to know about it.
  final String factionAlignment;

  /// Multiplier on whatever resource yield/trade value this planet
  /// produces. 1.0 = baseline.
  final double richnessMultiplier;

  const PlanetNode({
    required super.id,
    required super.x,
    required super.y,
    required super.interactionRadius,
    required this.factionAlignment,
    this.richnessMultiplier = 1.0,
  });
}

/// A nebula: a spatial hub whose main gameplay property is dampening
/// detection. obscurityMultiplier is read by whatever system computes
/// tracking (see warp_wake_tracking.dart's readWake) -- this class is
/// just the data, it doesn't apply the dampening itself.
class NebulaNode extends CelestialNode {
  /// 0 -> 1, multiplies signal strength for anything read inside/near
  /// this node. Lower = more obscuring. 1.0 = no effect.
  final double obscurityMultiplier;

  const NebulaNode({
    required super.id,
    required super.x,
    required super.y,
    required super.interactionRadius,
    this.obscurityMultiplier = 0.5,
  });
}

/// Simple registry/lookup for active nodes in the current sector. Linear
/// scans throughout -- appropriate for a handful to a few hundred nodes
/// in a local play area, not a spatial-hash-scale problem.
class CelestialNodeManager {
  final List<CelestialNode> _nodes = [];

  List<CelestialNode> get nodes => List.unmodifiable(_nodes);

  void registerNode(CelestialNode node) {
    _nodes.add(node);
  }

  void unregisterNode(String id) {
    _nodes.removeWhere((node) => node.id == id);
  }

  CelestialNode? findById(String id) {
    for (final node in _nodes) {
      if (node.id == id) return node;
    }
    return null;
  }

  /// The node whose interactionRadius contains (x, y), if any. Used to
  /// resolve currentDockedNode after an arrival settles.
  CelestialNode? findContaining(double x, double y) {
    for (final node in _nodes) {
      if (node.containsPoint(x, y)) return node;
    }
    return null;
  }

  /// The single closest node to (x, y), regardless of radius -- handy for
  /// "nearest node" UI prompts ("nothing in range, closest is 4,200 units
  /// away").
  CelestialNode? findNearest(double x, double y) {
    CelestialNode? nearest;
    double nearestDistSq = double.infinity;
    for (final node in _nodes) {
      final double dx = node.x - x;
      final double dy = node.y - y;
      final double distSq = dx * dx + dy * dy;
      if (distSq < nearestDistSq) {
        nearestDistSq = distSq;
        nearest = node;
      }
    }
    return nearest;
  }
}
