import 'dart:math';
import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sd_client/game/grid_layer.dart';
import 'package:sd_client/game/entities/entities.dart';
import 'package:sd_client/game/tactical_rts_component.dart';

void main() {
  group('Tactical Hex Grid & Coordinates', () {
    test('HexCoord distance and neighbor calculations', () {
      const a = HexCoord(0, 0);
      const b = HexCoord(2, -1);
      expect(a.distanceTo(b), 2);

      final neighbors = a.neighbors;
      expect(neighbors.length, 6);
      expect(neighbors, contains(const HexCoord(1, 0)));
      expect(neighbors, contains(const HexCoord(0, 1)));
      expect(neighbors, contains(const HexCoord(-1, 0)));
    });

    test('HexCoord world coordinate conversion round-trip', () {
      const radius = 40.0;
      const original = HexCoord(3, -2);
      final worldPos = original.toWorld(radius);

      final recovered = HexCoord.fromWorld(worldPos, radius);
      expect(recovered, original);
    });

    test('Terrain properties and passability', () {
      expect(HexTerrainType.plains.isPassable, isTrue);
      expect(HexTerrainType.voidChasm.isPassable, isFalse);
      expect(HexTerrainType.crystalCrater.movementCost, greaterThan(1.0));
    });

    test('A* Pathfinding navigates around void chasm obstacles', () {
      final grid = TacticalHexGrid(hexRadius: 40.0);

      // Create a 3x3 line of tiles with a void chasm block in the middle
      grid.tiles[const HexCoord(0, 0)] = const HexTile(
        coord: HexCoord(0, 0),
        terrain: HexTerrainType.plains,
      );
      grid.tiles[const HexCoord(1, 0)] = const HexTile(
        coord: HexCoord(1, 0),
        terrain: HexTerrainType.voidChasm, // Obstacle
      );
      grid.tiles[const HexCoord(0, 1)] = const HexTile(
        coord: HexCoord(0, 1),
        terrain: HexTerrainType.plains,
      );
      grid.tiles[const HexCoord(1, 1)] = const HexTile(
        coord: HexCoord(1, 1),
        terrain: HexTerrainType.plains,
      );
      grid.tiles[const HexCoord(2, 0)] = const HexTile(
        coord: HexCoord(2, 0),
        terrain: HexTerrainType.plains,
      );

      final path = grid.findPath(const HexCoord(0, 0), const HexCoord(2, 0));
      expect(path.isNotEmpty, isTrue);
      expect(path.first, const HexCoord(0, 0));
      expect(path.last, const HexCoord(2, 0));
      // Ensure obstacle tile is NOT traversed
      expect(path, isNot(contains(const HexCoord(1, 0))));

      // Waypoints match path length
      final waypoints = grid.findWaypoints(const HexCoord(0, 0), const HexCoord(2, 0));
      expect(waypoints.length, path.length);
    });

    test('Power nodes and logistics network registration', () {
      final grid = TacticalHexGrid.createDefaultMap();
      expect(grid.powerNodes.length, greaterThanOrEqualTo(4));

      final alpha = grid.powerNodes['node-alpha'];
      expect(alpha, isNotNull);
      expect(alpha!.isActive, isTrue);
      expect(alpha.connectedNodeIds, contains('node-beta'));
    });
  });

  group('Combat Entities (Kenney Sci-Fi RTS)', () {
    test('DefensiveTurretComponent dynamically rotates toward target heading', () {
      final turret = DefensiveTurretComponent(
        position: Vector2(100, 100),
        range: 300.0,
        rotationSpeed: 10.0, // fast rotation for test
      );

      expect(turret.currentHeading, 0.0);

      // Place target directly below turret (desired heading: pi / 2)
      turret.setTarget(Vector2(100, 200));

      // Tick update
      turret.update(0.1);
      expect(turret.isAcquiringTarget, isTrue);
      expect(turret.currentHeading, greaterThan(0.0));

      // Advance time enough to fully align
      turret.update(0.5);
      expect((turret.currentHeading - (pi / 2.0)).abs(), lessThan(0.05));
    });

    test('DefensiveTurretComponent ignores targets beyond range', () {
      final turret = DefensiveTurretComponent(
        position: Vector2(0, 0),
        range: 100.0,
      );

      // Target far beyond range
      turret.setTarget(Vector2(500, 500));
      turret.update(0.1);

      expect(turret.isAcquiringTarget, isFalse);
    });

    test('SquadUnitComponent navigates sequential waypoints cleanly', () {
      final unit = SquadUnitComponent(
        position: Vector2(0, 0),
        speed: 100.0,
      );

      final waypoints = [
        Vector2(50, 0),
        Vector2(100, 0),
        Vector2(100, 50),
      ];

      unit.setWaypoints(waypoints);
      expect(unit.isMoving, isTrue);

      // Update 0.3s -> advances 30px towards (50, 0)
      unit.update(0.3);
      expect(unit.position.x, closeTo(30.0, 1.0));
      expect(unit.isMoving, isTrue);

      // Update 0.3s -> reaches waypoint (50, 0) and switches to next waypoint
      unit.update(0.3);
      expect(unit.position.x, greaterThanOrEqualTo(50.0));
      expect(unit.isMoving, isTrue);

      // Update 0.2s -> advances towards (100, 0)
      unit.update(0.2);
      expect(unit.position.x, greaterThan(50.0));

      // Step until all waypoints are reached
      for (int i = 0; i < 30 && unit.isMoving; i++) {
        unit.update(0.1);
      }
      expect(unit.position.x, closeTo(100.0, 2.0));
      expect(unit.position.y, closeTo(50.0, 2.0));
      expect(unit.isMoving, isFalse);
    });

    test('ResourceHarvesterComponent accumulates cargo over time', () {
      final harvester = ResourceHarvesterComponent(
        position: Vector2(200, 200),
        cargoCapacity: 50.0,
        currentCargo: 10.0,
        isHarvesting: true,
      );

      expect(harvester.currentCargo, 10.0);
      harvester.update(1.0);
      expect(harvester.currentCargo, greaterThan(10.0));

      // Harvest until capacity reached
      harvester.update(20.0);
      expect(harvester.currentCargo, equals(50.0));
    });
  });

  group('TacticalRTSComponent Integration', () {
    test('Loads hex grid, turrets, harvesters, and squad units', () async {
      final rtsComponent = TacticalRTSComponent();
      await rtsComponent.onLoad();

      expect(rtsComponent.turrets.length, equals(2));
      expect(rtsComponent.harvesters.length, equals(1));
      expect(rtsComponent.squadUnits.length, equals(1));

      // Check turret tracking squad unit in update
      rtsComponent.update(0.1);
      for (final turret in rtsComponent.turrets) {
        expect(turret.targetPosition, equals(rtsComponent.squadUnits.first.position));
      }
    });
  });
}
