import 'package:flame/components.dart';
import 'package:flame/events.dart';
import 'package:flutter/material.dart';

import 'entities/entities.dart';
import 'grid_layer.dart';

/// Complete tactical RTS game subsystem integrating hex terrain,
/// logistics tether power networks, defensive turrets, harvesters, and squad units.
class TacticalRTSComponent extends Component with TapCallbacks {
  final TacticalHexGrid grid;
  late final HexGridComponent gridComponent;
  final List<DefensiveTurretComponent> turrets = [];
  final List<SquadUnitComponent> squadUnits = [];
  final List<ResourceHarvesterComponent> harvesters = [];

  TacticalRTSComponent({
    TacticalHexGrid? grid,
  }) : grid = grid ?? TacticalHexGrid.createDefaultMap();

  @override
  Future<void> onLoad() async {
    await super.onLoad();

    // 1. Grid terrain & logistics tethers
    gridComponent = HexGridComponent(grid: grid);
    await add(gridComponent);

    // 2. Defensive Turret Platforms at strategic choke points
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

    // 4. Combat Squad Unit navigating tactical waypoints
    final startCoord = const HexCoord(-3, 0);
    final goalCoord = const HexCoord(3, -1);

    final squadUnit = SquadUnitComponent(
      position: startCoord.toWorld(grid.hexRadius),
      speed: 120.0,
      factionColor: const Color(0xFF00E5FF),
      unitName: 'Vanguard Raider',
    );

    // Calculate initial pathfinding waypoints avoiding obstacles
    final waypoints = grid.findWaypoints(startCoord, goalCoord);
    squadUnit.setWaypoints(waypoints);

    squadUnits.add(squadUnit);
    await add(squadUnit);
  }

  @override
  void update(double dt) {
    super.update(dt);

    // Turrets dynamically acquire nearest squad unit heading
    if (squadUnits.isNotEmpty) {
      final targetUnit = squadUnits.first;
      for (final turret in turrets) {
        turret.setTarget(targetUnit.position);
      }
    }
  }

  /// Command active squad unit to navigate to target hex coordinate
  void commandMoveTo(HexCoord targetCoord) {
    if (squadUnits.isEmpty) return;

    final unit = squadUnits.first;
    final currentHex = HexCoord.fromWorld(unit.position, grid.hexRadius);
    final waypoints = grid.findWaypoints(currentHex, targetCoord);

    if (waypoints.isNotEmpty) {
      unit.setWaypoints(waypoints);
    }
  }

  @override
  void onTapDown(TapDownEvent event) {
    // Tap anywhere on canvas to navigate squad unit to nearest hex
    final targetHex = HexCoord.fromWorld(event.canvasPosition, grid.hexRadius);
    commandMoveTo(targetHex);
  }
}
