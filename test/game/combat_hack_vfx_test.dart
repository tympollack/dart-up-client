import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:sd_client/celestial/celestial_node_manager.dart';
import 'package:sd_client/combat/combat_manager.dart';
import 'package:sd_client/combat/enemy_director.dart';
import 'package:sd_client/combat/fighter_roster.dart';
import 'package:sd_client/game/components/vfx/vfx_components.dart';
import 'package:sd_client/player/hacking_controller.dart';
import 'package:sd_client/player/ship_warp_controller.dart';
import 'package:sd_client/swarm/drone_swarm_economy.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TASK-DARTUP-COMBAT-HACK-VFX: Combat, Swarm, Hacking & WarpWake Visuals', () {
    test('CombatVFXComponent buffers strikes in pre-allocated pool, fades over 0.15s, and cleans up on unmount', () {
      final vfx = CombatVFXComponent(fadeDuration: 0.15, maxStrikes: 16);

      expect(
        vfx.colorForSource(CombatHitSource.enemyFighterOnShip),
        equals(CombatVFXComponent.enemyOnShipColor),
      );
      expect(
        vfx.colorForSource(CombatHitSource.dronePointDefense),
        equals(CombatVFXComponent.pointDefenseColor),
      );
      expect(
        vfx.colorForSource(CombatHitSource.shipTurret),
        equals(CombatVFXComponent.shipTurretColor),
      );

      vfx.recordHit(const CombatHitEvent(
        sourceX: 0,
        sourceY: 0,
        targetX: 100,
        targetY: 50,
        damage: 10,
        source: CombatHitSource.shipTurret,
      ));
      vfx.recordHit(const CombatHitEvent(
        sourceX: 80,
        sourceY: 30,
        targetX: 0,
        targetY: 0,
        damage: 6,
        source: CombatHitSource.enemyFighterOnShip,
      ));

      expect(vfx.activeStrikeCount, equals(2));

      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      vfx.update(0.05);
      vfx.render(canvas);
      expect(vfx.activeStrikeCount, equals(2));

      // Advance past 0.15s fade duration
      vfx.update(0.11);
      expect(vfx.activeStrikeCount, equals(0));

      // Verify clean disposal on unmount
      vfx.recordHit(const CombatHitEvent(
        sourceX: 10,
        sourceY: 10,
        targetX: 20,
        targetY: 20,
        damage: 5,
        source: CombatHitSource.dronePointDefense,
      ));
      expect(vfx.activeStrikeCount, equals(1));
      vfx.onRemove();
      expect(vfx.activeStrikeCount, equals(0));
      recorder.endRecording().dispose();
    });

    test('SwarmRenderComponent batch-renders Boids swarm and needsRefit status indicators', () async {
      final picRecorder = ui.PictureRecorder();
      final picCanvas = ui.Canvas(picRecorder);
      picCanvas.drawCircle(
        const ui.Offset(16, 16),
        10,
        ui.Paint()..color = const ui.Color(0xFF00E5FF),
      );
      final atlasImage = await picRecorder.endRecording().toImage(32, 32);

      final economy = DroneSwarmEconomy(maxFleetSize: 20);
      economy.availableCount = 10;
      economy.tryDeploy(shipX: 0, shipY: 0, targetX: 100, targetY: 100);
      economy.spawnStrandedEnemyDrone(150, 150);
      economy.hackStrandedDrones(150, 150, 50);

      final swarmRenderer = SwarmRenderComponent(
        atlasImage: atlasImage,
        spriteRect: const ui.Rect.fromLTWH(0, 0, 32, 32),
        economy: economy,
      );

      final frameData = Float32List.fromList([
        10.0, 20.0, 0.5, 1.0,
        30.0, 40.0, 1.2, 1.0,
      ]);
      swarmRenderer.updateFrame(frameData, 2);

      expect(swarmRenderer.entityCount, equals(2));
      expect(swarmRenderer.needsRefitDroneCount, equals(1));

      final renderRecorder = ui.PictureRecorder();
      final renderCanvas = ui.Canvas(renderRecorder);
      swarmRenderer.render(renderCanvas);
      renderRecorder.endRecording().dispose();

      swarmRenderer.onRemove();
      expect(swarmRenderer.entityCount, equals(0));
    });

    test('HackingUIComponent renders linear radius ring and exponential power ramp gauge', () {
      final economy = DroneSwarmEconomy(maxFleetSize: 10);
      final hackingController = HackingController(
        economy: economy,
        maxRadius: 200.0,
        minRadius: 20.0,
        hackDuration: 4.0,
      );
      final hackingUI = HackingUIComponent(controller: hackingController);

      hackingController.beginHack(300, 400);
      hackingController.update(2.0); // 50% linear progress

      final vis = hackingController.visualState;
      expect(vis.isActive, isTrue);
      expect(vis.radius, closeTo(110.0, 1e-4));
      expect(vis.power, greaterThan(0.0));
      expect(vis.power, lessThan(vis.progress)); // exponential ramp curves below linear at t=0.5

      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      hackingUI.render(canvas);
      recorder.endRecording().dispose();
    });

    test('WarpWakeRenderComponent renders Subwarp trails, FTL tears, ZoneOfProbability rings, and spool shake', () {
      final economy = DroneSwarmEconomy(maxFleetSize: 20);
      final roster = FighterRoster(maxFighterCount: 10);
      final warpController = ShipWarpController(
        economy: economy,
        fighterRoster: roster,
        seed: 42,
      );
      final nodeManager = CelestialNodeManager();
      const targetPlanet = PlanetNode(
        id: 'dest',
        x: 600,
        y: 0,
        interactionRadius: 150,
        factionAlignment: 'neutral',
      );
      nodeManager.registerNode(targetPlanet);

      final director = EnemyDirector(
        maxSquadCount: 4,
        nodeManager: nodeManager,
        enemyFighterRoster: FighterRoster(maxFighterCount: 12),
        playerShipController: warpController,
        trackingTech: 0.4,
      );
      director.spawnSquad(2000, 2000);

      final wakeRenderer = WarpWakeRenderComponent(
        warpController: warpController,
        enemyDirector: director,
      );

      // Start spooling a Subwarp jump
      warpController.commandWarp(
        targetNode: targetPlanet,
        shipX: 0,
        shipY: 0,
        driveType: WarpDriveType.subwarp,
      );
      warpController.update(10.0); // 50% spool
      expect(wakeRenderer.currentSpoolShakeIntensity, closeTo(0.5, 1e-3));

      // Complete spool so Subwarp wake is emitted
      warpController.update(10.5);
      wakeRenderer.update(0.1);
      expect(wakeRenderer.activeWakeCount, equals(1));

      // Emit an ECM spoofed wake
      warpController.emitSpoofedWake(
        x: 50,
        y: 50,
        fakeTargetX: -500,
        fakeTargetY: 500,
        spoofedDriveType: WarpDriveType.ftl,
      );
      wakeRenderer.update(0.1);
      expect(wakeRenderer.activeWakeCount, equals(2));

      // Trigger EnemyDirector sweep to populate ZoneOfProbability
      director.update(5.0, playerX: warpController.currentShipX, playerY: warpController.currentShipY);

      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      wakeRenderer.render(canvas);
      recorder.endRecording().dispose();

      wakeRenderer.onRemove();
      expect(wakeRenderer.activeWakeCount, equals(0));
    });
  });
}
