import 'package:flame/components.dart';
import 'package:flame/events.dart';
import 'package:flutter/material.dart';

import 'entities/entities.dart';
import 'grid_layer.dart';

/// Complete tactical RTS game subsystem integrating hex terrain,
/// logistics tether power networks, defensive turrets, harvesters, and squad units.
class TacticalRTSComponent extends PositionComponent with TapCallbacks {
  final TacticalHexGrid grid;
  late final HexGridComponent gridComponent;
  final List<DefensiveTurretComponent> turrets = [];
  final List<SquadUnitComponent> squadUnits = [];
  final List<ResourceHarvesterComponent> harvesters = [];

  TacticalRTSComponent({
    TacticalHexGrid? grid,
  })  : grid = grid ?? TacticalHexGrid.createDefaultMap(),
        super(anchor: Anchor.center) {
    double maxCoordDist = 5.0;
    if (this.grid.tiles.isNotEmpty) {
      maxCoordDist = this.grid.tiles.keys
          .map((c) => (c.q.abs() + c.r.abs() + c.s.abs()) / 2.0)
          .reduce((a, b) => a > b ? a : b);
    }
    final double span = (maxCoordDist + 1) * this.grid.hexRadius * 2.0;
    size = Vector2(span * 2, span * 2);
  }

  @override
  Future<void> onLoad() async {
    await super.onLoad();

    // 1. Grid terrain & logistics tethers
    gridComponent = HexGridComponent(grid: grid);
    await add(gridComponent);

    // Collect passable tiles for coordinate resolution (supports custom/smaller maps)
    final passableTiles =
        grid.tiles.values.where((t) => t.isPassable).map((t) => t.coord).toList();
    if (passableTiles.isEmpty) return;

    HexCoord resolveCoord(HexCoord preferred, [int fallbackIndex = 0]) {
      if (grid.tiles[preferred]?.isPassable == true) {
        return preferred;
      }
      return passableTiles[fallbackIndex % passableTiles.length];
    }

    // 2. Defensive Turret Platforms at strategic choke points (Friendly Faction: Cyan)
    final t1Coord = resolveCoord(const HexCoord(1, 0), 0);
    final t2Coord = resolveCoord(const HexCoord(-1, 1), 1);
    final turret1 = DefensiveTurretComponent(
      position: t1Coord.toWorld(grid.hexRadius),
      range: 240.0,
      factionColor: const Color(0xFF00E5FF),
    );
    final turret2 = DefensiveTurretComponent(
      position: t2Coord.toWorld(grid.hexRadius),
      range: 240.0,
      factionColor: const Color(0xFF00E5FF),
    );
    turrets.addAll([turret1, turret2]);
    await addAll(turrets);

    // 3. Resource Harvester at crystal crater
    final harvesterCoord = resolveCoord(const HexCoord(0, 3), 2);
    final harvester = ResourceHarvesterComponent(
      position: harvesterCoord.toWorld(grid.hexRadius),
      cargoCapacity: 150.0,
      currentCargo: 40.0,
      isHarvesting: true,
    );
    harvesters.add(harvester);
    await add(harvester);

    // 4. Friendly Squad Unit (SunShade Cyan)
    final startCoord = resolveCoord(const HexCoord(-3, 0), 0);
    final goalCoord = resolveCoord(const HexCoord(3, -1), passableTiles.length - 1);

    final friendlySquad = SquadUnitComponent(
      position: startCoord.toWorld(grid.hexRadius),
      speed: 120.0,
      factionColor: const Color(0xFF00E5FF),
      unitName: 'Vanguard Raider',
    );
    final waypoints = grid.findWaypoints(startCoord, goalCoord);
    friendlySquad.setWaypoints(waypoints);
    squadUnits.add(friendlySquad);
    await add(friendlySquad);

    // 5. Hostile Squad Unit (Enemy Crimson) - target for defensive turrets
    final enemyCoord = resolveCoord(const HexCoord(2, -2), passableTiles.length ~/ 2);
    final enemyPatrolGoal =
        resolveCoord(const HexCoord(0, 1), (passableTiles.length ~/ 2) + 1);

    final hostileSquad = SquadUnitComponent(
      position: enemyCoord.toWorld(grid.hexRadius),
      speed: 90.0,
      factionColor: const Color(0xFFEF4444),
      unitName: 'Corsair Marauder',
    );
    final enemyWaypoints = grid.findWaypoints(enemyCoord, enemyPatrolGoal);
    hostileSquad.setWaypoints(enemyWaypoints);
    squadUnits.add(hostileSquad);
    await add(hostileSquad);
  }

  @override
  void update(double dt) {
    super.update(dt);

    // Defensive towers acquire only hostile (opposing-faction) targets within range
    for (final turret in turrets) {
      SquadUnitComponent? bestTarget;
      double closestDist = double.infinity;

      for (final unit in squadUnits) {
        // Only target units belonging to opposing faction
        if (unit.factionColor == turret.factionColor) continue;

        final dist = (unit.position - turret.position).length;
        if (dist <= turret.range && dist < closestDist) {
          closestDist = dist;
          bestTarget = unit;
        }
      }

      // If hostile unit in range, lock on; otherwise clear target to resume idle scanning
      turret.setTarget(bestTarget?.position);
    }
  }

  /// Command friendly squad unit(s) to navigate to target hex coordinate
  void commandMoveTo(HexCoord targetCoord) {
    for (final unit in squadUnits) {
      // Only command friendly units
      if (unit.factionColor == const Color(0xFF00E5FF)) {
        final currentHex = HexCoord.fromWorld(unit.position, grid.hexRadius);
        final waypoints = grid.findWaypoints(currentHex, targetCoord);
        if (waypoints.isNotEmpty) {
          unit.setWaypoints(waypoints);
        }
      }
    }
  }

  @override
  void onTapDown(TapDownEvent event) {
    // Translate tap position into world coordinates respecting camera pan & zoom
    Vector2 worldPoint = event.localPosition - size / 2.0;
    final game = findGame();
    if (game != null) {
      worldPoint = game.camera.globalToLocal(event.canvasPosition);
    }

    final targetHex = HexCoord.fromWorld(worldPoint, grid.hexRadius);
    commandMoveTo(targetHex);
  }
}
