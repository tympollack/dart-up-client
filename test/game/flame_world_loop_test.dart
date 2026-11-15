import 'dart:ui' as ui;

import 'package:flame/components.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sd_client/celestial/celestial_node_manager.dart';
import 'package:sd_client/combat/fighter_roster.dart';
import 'package:sd_client/game/dart_up_game.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TASK-DARTUP-FLAME-WORLD-LOOP: DartUpGame & Celestial/Enemy Renderers', () {
    test('DartUpGame instantiates and ticks CelestialNodeManager, EnemyDirector, and CombatManager', () async {
      final game = DartUpGame(spawnIsolateOnLoad: false);
      game.onGameResize(Vector2(1280, 720));
      await game.onLoad();
      game.onMount();

      expect(game.nodeManager.nodes.length, greaterThanOrEqualTo(2));
      expect(game.enemyDirector.squadCount, equals(2));

      // Place ship near squad 0 at (900, 900) so EnemyDirector engages and spawns fighters
      game.shipComponent.setBasePosition(Vector2(880, 880));
      game.update(0.05);

      expect(game.enemyFighterRoster.activeCount, greaterThan(0));
      // CombatManager initializes newly spawned fighter health (40.0) and may also resolve a ship turret shot (-10.0) in the same tick
      expect(game.combatManager.enemyHealth[0], greaterThan(0.0));
      expect(game.combatManager.enemyHealth[0], lessThanOrEqualTo(game.combatManager.defaultEnemyFighterHealth));
    });

    test('CelestialNodeComponent renders PlanetNode and NebulaNode without mutating state', () {
      final manager = CelestialNodeManager();
      const planet = PlanetNode(
        id: 'p1',
        x: 200,
        y: 300,
        interactionRadius: 180,
        factionAlignment: 'sunshade',
        richnessMultiplier: 1.5,
      );
      const nebula = NebulaNode(
        id: 'n1',
        x: -150,
        y: 100,
        interactionRadius: 320,
        obscurityMultiplier: 0.3,
      );
      manager.registerNode(planet);
      manager.registerNode(nebula);

      final component = CelestialNodeComponent(nodeManager: manager);
      expect(component.renderedNodeCount, equals(2));

      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);

      // Render 60 frames and ensure zero state mutation
      for (int i = 0; i < 60; i++) {
        component.render(canvas);
      }
      final picture = recorder.endRecording();
      picture.dispose();

      expect(manager.nodes.length, equals(2));
      expect(manager.findById('p1')?.x, equals(200));
      expect(manager.findById('n1')?.interactionRadius, equals(320));
    });

    test('EnemyFighterRenderComponent renders directional hulls toward target coordinates with zero state mutation', () {
      final roster = FighterRoster(maxFighterCount: 16);
      final idx = roster.spawnFighter(100, 100, targetX: 200, targetY: 100);
      final idx2 = roster.spawnFighter(50, 50, targetX: 50, targetY: 150);

      final renderer = EnemyFighterRenderComponent(
        enemyFighterRoster: roster,
        radius: 10.0,
      );

      expect(renderer.headingForFighter(idx), closeTo(0.0, 1e-5));
      expect(renderer.headingForFighter(idx2), closeTo(1.5707963, 1e-4));

      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      for (int i = 0; i < 60; i++) {
        renderer.render(canvas);
      }
      final picture = recorder.endRecording();
      picture.dispose();

      // Verify zero mutation of fighter positions or activeCount
      expect(roster.activeCount, equals(2));
      expect(roster.posX[idx], equals(100));
      expect(roster.posY[idx], equals(100));
      expect(roster.targetX[idx], equals(200));
      expect(roster.targetY[idx], equals(100));
    });
  });
}
