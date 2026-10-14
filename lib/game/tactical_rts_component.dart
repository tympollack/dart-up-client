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
        super(anchor: Anchor.center);

  @override
  Future<void> onLoad() async {
    await super.onLoad();

    // 1. Grid terrain & logistics tethers
    gridComponent = HexGridComponent(grid: grid);
    await add(gridComponent);

    // 2. Defensive Turret Platforms at strategic choke points (Friendly Faction: Cyan)
    final turret1 = DefensiveTurretComponent(
      position: const HexCoord(1, 0).toWorld(grid.hexRadius),
      range: 240.0,
      factionColor: const Color(0xFF00E5FF),
    );
    final turret2 = DefensiveTurretComponent(
      position: const HexCoord(-1, 1).toWorld(grid.hexRadius),
      range: 240.0,
      factionColor: const Color(0xFF00E5FF),
    );
    turrets.addAll([turret1, turret2]);
    await addAll(turrets);

    // 3. Resource Harvester at crystal crater
    final harvester = ResourceHarvesterComponent(
      position: const HexCoord(0, 3).toWorld(grid.hexRadius),
      cargoCapacity: 150.0,
      currentCargo: 40.0,
      isHarvesting: true,
    );
    harvesters.add(harvester);
    await add(harvester);

    // 4. Friendly Squad Unit (SunShade Cyan)
    final startCoord = const HexCoord(-3, 0);
    final goalCoord = const HexCoord(3, -1);

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
    final enemyCoord = const HexCoord(2, -2);
    final enemyPatrolGoal = const HexCoord(0, 1);

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
    Vector2 worldPoint = event.localPosition;
    final game = findGame();
    if (game != null) {
      worldPoint = game.camera.globalToLocal(event.canvasPosition);
    }

    final targetHex = HexCoord.fromWorld(worldPoint, grid.hexRadius);
    commandMoveTo(targetHex);
  }
}
