import 'dart:math';
import 'package:flame/components.dart';
import 'package:flutter/material.dart';

/// Axial and cube coordinate representation for tactical hex grids.
class HexCoord {
  final int q;
  final int r;

  const HexCoord(this.q, this.r);

  int get s => -q - r;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is HexCoord && runtimeType == other.runtimeType && q == other.q && r == other.r;

  @override
  int get hashCode => Object.hash(q, r);

  @override
  String toString() => 'HexCoord($q, $r)';

  /// Distance in hex steps
  int distanceTo(HexCoord other) {
    return ((q - other.q).abs() + (r - other.r).abs() + (s - other.s).abs()) ~/ 2;
  }

  /// 6 axial neighbor directions
  static const List<HexCoord> directions = [
    HexCoord(1, 0),
    HexCoord(1, -1),
    HexCoord(0, -1),
    HexCoord(-1, 0),
    HexCoord(-1, 1),
    HexCoord(0, 1),
  ];

  HexCoord neighbor(int dirIndex) {
    final d = directions[dirIndex % 6];
    return HexCoord(q + d.q, r + d.r);
  }

  List<HexCoord> get neighbors => [
        for (int i = 0; i < 6; i++) neighbor(i),
      ];

  /// Flat-topped hex to world coordinate conversion
  Vector2 toWorld(double hexRadius) {
    final double x = hexRadius * 1.5 * q;
    final double y = hexRadius * sqrt(3.0) * (r + q / 2.0);
    return Vector2(x, y);
  }

  /// Convert world position back to nearest hex coordinate
  static HexCoord fromWorld(Vector2 worldPos, double hexRadius) {
    final double qFrac = (2.0 / 3.0 * worldPos.x) / hexRadius;
    final double rFrac = (-1.0 / 3.0 * worldPos.x + sqrt(3.0) / 3.0 * worldPos.y) / hexRadius;
    final double sFrac = -qFrac - rFrac;

    int qRound = qFrac.round();
    int rRound = rFrac.round();
    int sRound = sFrac.round();

    final double qDiff = (qRound - qFrac).abs();
    final double rDiff = (rRound - rFrac).abs();
    final double sDiff = (sRound - sFrac).abs();

    if (qDiff > rDiff && qDiff > sDiff) {
      qRound = -rRound - sRound;
    } else if (rDiff > sDiff) {
      rRound = -qRound - sRound;
    }

    return HexCoord(qRound, rRound);
  }
}

/// Tactical terrain types matching Kenney Sci-Fi and isometric themes
enum HexTerrainType {
  plains,
  crystalCrater,
  volcanicRidge,
  voidChasm,
  energyWell,
}

extension HexTerrainProps on HexTerrainType {
  bool get isPassable => this != HexTerrainType.voidChasm;

  double get movementCost {
    switch (this) {
      case HexTerrainType.plains:
        return 1.0;
      case HexTerrainType.crystalCrater:
        return 1.4;
      case HexTerrainType.volcanicRidge:
        return 2.0;
      case HexTerrainType.voidChasm:
        return double.infinity;
      case HexTerrainType.energyWell:
        return 1.0;
    }
  }

  Color get fillColor {
    switch (this) {
      case HexTerrainType.plains:
        return const Color(0xFF131A29);
      case HexTerrainType.crystalCrater:
        return const Color(0xFF0C243C);
      case HexTerrainType.volcanicRidge:
        return const Color(0xFF2E130D);
      case HexTerrainType.voidChasm:
        return const Color(0xFF08080C);
      case HexTerrainType.energyWell:
        return const Color(0xFF0B2D26);
    }
  }

  Color get strokeColor {
    switch (this) {
      case HexTerrainType.plains:
        return const Color(0xFF2A3A54);
      case HexTerrainType.crystalCrater:
        return const Color(0xFF00E5FF);
      case HexTerrainType.volcanicRidge:
        return const Color(0xFFFF5722);
      case HexTerrainType.voidChasm:
        return const Color(0xFF6B21A8);
      case HexTerrainType.energyWell:
        return const Color(0xFF10B981);
    }
  }
}

/// Single tile in tactical grid
class HexTile {
  final HexCoord coord;
  final HexTerrainType terrain;

  const HexTile({
    required this.coord,
    required this.terrain,
  });

  bool get isPassable => terrain.isPassable;
}

/// Power / Logistics node for energetic grid tethers
class PowerNode {
  final String id;
  final HexCoord coord;
  bool isActive;
  double energyLevel;
  final List<String> connectedNodeIds;

  PowerNode({
    required this.id,
    required this.coord,
    this.isActive = true,
    this.energyLevel = 1.0,
    List<String>? connectedNodeIds,
  }) : connectedNodeIds = connectedNodeIds ?? [];
}

/// Tactical hex grid manager and pathfinding engine
class TacticalHexGrid {
  final Map<HexCoord, HexTile> tiles = {};
  final Map<String, PowerNode> powerNodes = {};
  final double hexRadius;

  TacticalHexGrid({
    this.hexRadius = 40.0,
  });

  /// Populates a default tactical map around the origin
  static TacticalHexGrid createDefaultMap({int radius = 5, double hexRadius = 40.0}) {
    final grid = TacticalHexGrid(hexRadius: hexRadius);

    for (int q = -radius; q <= radius; q++) {
      final int r1 = max(-radius, -q - radius);
      final int r2 = min(radius, -q + radius);
      for (int r = r1; r <= r2; r++) {
        final coord = HexCoord(q, r);
        HexTerrainType terrain = HexTerrainType.plains;

        // Procedural terrain decoration
        if ((q.abs() == 2 && r.abs() == 1) || (q == 0 && r == 3)) {
          terrain = HexTerrainType.crystalCrater;
        } else if ((q == -3 && r == 1) || (q == 2 && r == -3)) {
          terrain = HexTerrainType.volcanicRidge;
        } else if ((q == 1 && r == 1) || (q == -2 && r == -1)) {
          terrain = HexTerrainType.voidChasm; // Obstacles for pathfinding
        } else if (q == 0 && r == 0) {
          terrain = HexTerrainType.energyWell;
        }

        grid.tiles[coord] = HexTile(coord: coord, terrain: terrain);
      }
    }

    // Add baseline power network nodes
    final nodeA = PowerNode(id: 'node-alpha', coord: const HexCoord(0, 0), isActive: true);
    final nodeB = PowerNode(id: 'node-beta', coord: const HexCoord(2, 0), isActive: true);
    final nodeC = PowerNode(id: 'node-gamma', coord: const HexCoord(0, 2), isActive: true);
    final nodeD = PowerNode(id: 'node-delta', coord: const HexCoord(-2, 2), isActive: true);

    nodeA.connectedNodeIds.addAll(['node-beta', 'node-gamma']);
    nodeB.connectedNodeIds.addAll(['node-alpha', 'node-gamma']);
    nodeC.connectedNodeIds.addAll(['node-alpha', 'node-beta', 'node-delta']);
    nodeD.connectedNodeIds.add('node-gamma');

    grid.registerPowerNode(nodeA);
    grid.registerPowerNode(nodeB);
    grid.registerPowerNode(nodeC);
    grid.registerPowerNode(nodeD);

    return grid;
  }

  void registerPowerNode(PowerNode node) {
    powerNodes[node.id] = node;
  }

  /// A* Pathfinding across hex grid returning sequential tile coordinates
  List<HexCoord> findPath(HexCoord start, HexCoord goal) {
    if (!tiles.containsKey(start) || !tiles.containsKey(goal)) return [];
    if (!tiles[start]!.isPassable || !tiles[goal]!.isPassable) return [];
    if (start == goal) return [start];

    final frontier = <_PathNode>[];
    final Map<HexCoord, HexCoord> cameFrom = {};
    final Map<HexCoord, double> gScore = {start: 0.0};

    _insertFrontier(frontier, _PathNode(start, 0.0, start.distanceTo(goal).toDouble()));

    while (frontier.isNotEmpty) {
      final current = frontier.removeLast().coord;

      if (current == goal) {
        // Reconstruct path
        final path = <HexCoord>[current];
        HexCoord? curr = current;
        while (cameFrom.containsKey(curr)) {
          curr = cameFrom[curr]!;
          path.add(curr);
        }
        return path.reversed.toList();
      }

      for (final next in current.neighbors) {
        final tile = tiles[next];
        if (tile == null || !tile.isPassable) continue;

        final tentativeG = gScore[current]! + tile.terrain.movementCost;

        if (!gScore.containsKey(next) || tentativeG < gScore[next]!) {
          cameFrom[next] = current;
          gScore[next] = tentativeG;
          final fScore = tentativeG + next.distanceTo(goal) * 1.0;
          _insertFrontier(frontier, _PathNode(next, tentativeG, fScore));
        }
      }
    }

    return []; // No path found
  }

  static void _insertFrontier(List<_PathNode> list, _PathNode node) {
    int low = 0;
    int high = list.length;
    while (low < high) {
      final mid = (low + high) >> 1;
      // Store descending so removeLast() pops the lowest fScore in O(1)
      if (list[mid].fScore >= node.fScore) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    list.insert(low, node);
  }

  /// Path converted to world coordinate waypoints
  List<Vector2> findWaypoints(HexCoord start, HexCoord goal) {
    final hexPath = findPath(start, goal);
    return hexPath.map((c) => c.toWorld(hexRadius)).toList();
  }
}

class _PathNode {
  final HexCoord coord;
  final double gScore;
  final double fScore;

  _PathNode(this.coord, this.gScore, this.fScore);
}

/// Flame Component rendering the tactical hex grid and energetic tether lines
class HexGridComponent extends PositionComponent {
  final TacticalHexGrid grid;
  double _animationTimer = 0.0;

  HexGridComponent({
    required this.grid,
  });

  @override
  void update(double dt) {
    super.update(dt);
    _animationTimer += dt;
  }

  @override
  void render(Canvas canvas) {
    super.render(canvas);

    final double r = grid.hexRadius;

    // 1. Draw Hex Tiles
    for (final tile in grid.tiles.values) {
      final center = tile.coord.toWorld(r);
      _drawHexTile(canvas, center, r, tile);
    }

    // 2. Draw Logistics Tether Lines connecting active power nodes
    _drawLogisticsTethers(canvas, r);

    // 3. Draw Power Nodes
    _drawPowerNodes(canvas, r);
  }

  void _drawHexTile(Canvas canvas, Vector2 center, double radius, HexTile tile) {
    final path = Path();
    for (int i = 0; i < 6; i++) {
      final angle = (pi / 3.0) * i;
      final x = center.x + radius * cos(angle);
      final y = center.y + radius * sin(angle);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    path.close();

    // Base terrain fill
    final fillPaint = Paint()
      ..color = tile.terrain.fillColor
      ..style = PaintingStyle.fill;
    canvas.drawPath(path, fillPaint);

    // Beveled internal stroke
    final innerPath = Path();
    final innerR = radius * 0.88;
    for (int i = 0; i < 6; i++) {
      final angle = (pi / 3.0) * i;
      final x = center.x + innerR * cos(angle);
      final y = center.y + innerR * sin(angle);
      if (i == 0) {
        innerPath.moveTo(x, y);
      } else {
        innerPath.lineTo(x, y);
      }
    }
    innerPath.close();

    final innerPaint = Paint()
      ..color = tile.terrain.strokeColor.withValues(alpha: 0.25)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawPath(innerPath, innerPaint);

    // Outer grid border
    final strokePaint = Paint()
      ..color = tile.terrain.strokeColor.withValues(alpha: 0.6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    canvas.drawPath(path, strokePaint);

    // Terrain specific center iconography / features
    if (tile.terrain == HexTerrainType.crystalCrater) {
      final crystalPaint = Paint()
        ..color = const Color(0xFF00F0FF)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(Offset(center.x, center.y), 4.0, crystalPaint);
    } else if (tile.terrain == HexTerrainType.volcanicRidge) {
      final ventPaint = Paint()
        ..color = const Color(0xFFFF5722)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0;
      canvas.drawLine(
        Offset(center.x - 6, center.y - 4),
        Offset(center.x + 6, center.y + 4),
        ventPaint,
      );
    } else if (tile.terrain == HexTerrainType.voidChasm) {
      final voidPaint = Paint()
        ..color = const Color(0xFF7C3AED).withValues(alpha: 0.4)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0;
      canvas.drawCircle(Offset(center.x, center.y), 10.0, voidPaint);
    }
  }

  void _drawLogisticsTethers(Canvas canvas, double hexRadius) {
    final drawnPairs = <String>{};

    for (final node in grid.powerNodes.values) {
      if (!node.isActive) continue;

      final startPos = node.coord.toWorld(hexRadius);

      for (final targetId in node.connectedNodeIds) {
        final targetNode = grid.powerNodes[targetId];
        if (targetNode == null || !targetNode.isActive) continue;

        // Avoid drawing lines twice in both directions
        final pairKey = node.id.compareTo(targetId) < 0
            ? '${node.id}_$targetId'
            : '${targetId}_${node.id}';
        if (drawnPairs.contains(pairKey)) continue;
        drawnPairs.add(pairKey);

        final endPos = targetNode.coord.toWorld(hexRadius);

        // Background glow tether
        final glowPaint = Paint()
          ..color = const Color(0xFF00E5FF).withValues(alpha: 0.35)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 5.0
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3.0);
        canvas.drawLine(
          Offset(startPos.x, startPos.y),
          Offset(endPos.x, endPos.y),
          glowPaint,
        );

        // Core electric laser beam
        final corePaint = Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5;
        canvas.drawLine(
          Offset(startPos.x, startPos.y),
          Offset(endPos.x, endPos.y),
          corePaint,
        );

        // Animated pulse packet traveling along tether
        final double pulseProgress = (_animationTimer * 0.8) % 1.0;
        final double pulseX = startPos.x + (endPos.x - startPos.x) * pulseProgress;
        final double pulseY = startPos.y + (endPos.y - startPos.y) * pulseProgress;

        final pulsePaint = Paint()
          ..color = const Color(0xFF00F0FF)
          ..style = PaintingStyle.fill;
        canvas.drawCircle(Offset(pulseX, pulseY), 3.5, pulsePaint);
      }
    }
  }

  void _drawPowerNodes(Canvas canvas, double hexRadius) {
    for (final node in grid.powerNodes.values) {
      final pos = node.coord.toWorld(hexRadius);
      final center = Offset(pos.x, pos.y);

      // Node base halo
      final haloPaint = Paint()
        ..color = (node.isActive ? const Color(0xFF00E5FF) : const Color(0xFF64748B))
            .withValues(alpha: 0.3)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(center, 12.0, haloPaint);

      // Node pylon hexagon
      final pylonPath = Path();
      const double pylonR = 8.0;
      for (int i = 0; i < 6; i++) {
        final angle = (pi / 3.0) * i;
        final x = pos.x + pylonR * cos(angle);
        final y = pos.y + pylonR * sin(angle);
        if (i == 0) {
          pylonPath.moveTo(x, y);
        } else {
          pylonPath.lineTo(x, y);
        }
      }
      pylonPath.close();

      final pylonPaint = Paint()
        ..color = const Color(0xFF0F172A)
        ..style = PaintingStyle.fill;
      canvas.drawPath(pylonPath, pylonPaint);

      final pylonStroke = Paint()
        ..color = node.isActive ? const Color(0xFF00F0FF) : const Color(0xFF64748B)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0;
      canvas.drawPath(pylonPath, pylonStroke);

      // Central energetic core
      final coreColor = node.isActive ? const Color(0xFFE0F2FE) : const Color(0xFF94A3B8);
      final corePaint = Paint()
        ..color = coreColor
        ..style = PaintingStyle.fill;
      canvas.drawCircle(center, 3.0, corePaint);
    }
  }
}
