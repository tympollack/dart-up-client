import 'package:flutter_test/flutter_test.dart';
import 'package:sd_client/celestial/celestial_node_manager.dart';
import 'package:sd_client/combat/fighter_roster.dart';
import 'package:sd_client/simulation/warp/ship_warp_controller.dart';
import 'package:sd_client/swarm/drone_swarm_economy.dart';

void main() {
  group('TASK-DARTUP-WARP-CONTROLLER: Dual WarpDriveType & WarpWake Generation', () {
    const targetPlanet = PlanetNode(
      id: 'planet-target',
      x: 1200.0,
      y: 0.0,
      interactionRadius: 200.0,
      factionAlignment: 'federation',
    );

    test('FTL blind jump scatter scales with shipDecay and (1.0 - navComputerHealth), and emergency abort sets accuracy to 0.0', () {
      final economy = DroneSwarmEconomy(maxFleetSize: 20);
      final roster = FighterRoster(maxFighterCount: 10);

      WarpCompleteResult? lastResult;
      final controller = ShipWarpController(
        economy: economy,
        fighterRoster: roster,
        seed: 7,
        onWarpComplete: (res) => lastResult = res,
      );

      // 1. Optimal FTL jump (shipDecay = 0.0, navComputerHealth = 1.0, full energy)
      controller.commandWarp(
        targetNode: targetPlanet,
        shipX: 0.0,
        shipY: 0.0,
        driveType: WarpDriveType.ftl,
      );
      controller.update(20.0); // Complete spool
      expect(lastResult, isNotNull);
      expect(lastResult!.arrival.computedAccuracy, closeTo(1.0, 1e-6));
      expect(lastResult!.arrival.scatterDistance, closeTo(0.0, 1e-6));
      expect(lastResult!.wake.driveType, equals(WarpDriveType.ftl));

      // Settle arriving window
      controller.update(2.5);
      expect(controller.isIdle, isTrue);

      // 2. Degraded FTL jump (shipDecay = 0.4, navComputerHealth = 0.5 -> accuracy = 0.6 * 0.5 = 0.30)
      controller.shipDecay = 0.4;
      controller.navComputerHealth = 0.5;
      controller.commandWarp(
        targetNode: targetPlanet,
        shipX: 0.0,
        shipY: 0.0,
        driveType: WarpDriveType.ftl,
      );
      controller.update(20.0);
      expect(lastResult!.arrival.computedAccuracy, closeTo(0.30, 1e-6));
      expect(
        lastResult!.arrival.scatterDistance,
        closeTo(controller.navConfig.ftlMaxScatterDistance * 0.70, 1e-3),
      );

      controller.update(2.5);

      // 3. Emergency FTL abort (microJump mid-spool) -> accuracy = 0.0, maximum emergency scatter
      controller.commandWarp(
        targetNode: targetPlanet,
        shipX: 100.0,
        shipY: -50.0,
        driveType: WarpDriveType.ftl,
      );
      controller.update(3.0); // Partial spool
      expect(controller.microJump(), isTrue);
      expect(lastResult!.arrival.computedAccuracy, equals(0.0));
      expect(
        lastResult!.arrival.scatterDistance,
        closeTo(controller.navConfig.emergencyScatterRadius, 1e-4),
      );
    });

    test('Subwarp physical traversal computes transitTime, flight vector, and supports mid-transit interception and anomaly collisions', () {
      final economy = DroneSwarmEconomy(maxFleetSize: 20);
      final roster = FighterRoster(maxFighterCount: 10);

      WarpCompleteResult? lastResult;
      final controller = ShipWarpController(
        economy: economy,
        fighterRoster: roster,
        navConfig: ShipNavConfig(
          subwarpSpeed: 600.0,
          subwarpJitterFraction: 0.0, // Exact target for deterministic transit math
        ),
        powerConfig: ShipPowerConfig(spoolDuration: 5.0),
        seed: 12,
        onWarpComplete: (res) => lastResult = res,
      );

      // Command Subwarp from (0, 0) to (1200, 0) at 600 u/s -> transitTime = 2.0s
      controller.commandWarp(
        targetNode: targetPlanet,
        shipX: 0.0,
        shipY: 0.0,
        driveType: WarpDriveType.subwarp,
      );
      controller.update(5.0); // Finish spooling, enter Subwarp physical traversal

      expect(controller.isSubwarpInTransit, isTrue);
      expect(controller.isPhysicallyTargetable, isTrue);
      expect(controller.transitTime, closeTo(2.0, 1e-4));
      expect(controller.flightVectorX, closeTo(1.0, 1e-4));
      expect(controller.flightVectorY, closeTo(0.0, 1e-4));
      expect(controller.lastWake?.driveType, equals(WarpDriveType.subwarp));

      // Advance 1.0s -> halfway at (600, 0)
      controller.update(1.0);
      expect(controller.currentShipX, closeTo(600.0, 1e-3));
      expect(controller.currentShipY, closeTo(0.0, 1e-3));
      expect(controller.isSubwarpInTransit, isTrue);

      // Mid-transit interception at (610, 0) with radius 50.0 pulls ship out of Subwarp
      final intercepted = controller.tryInterceptSubwarp(
        interceptorX: 610.0,
        interceptorY: 0.0,
        interceptRadius: 50.0,
      );
      expect(intercepted, isTrue);
      expect(controller.isSubwarpInTransit, isFalse);
      expect(controller.isArriving, isTrue);
      expect(lastResult, isNotNull);
      expect(lastResult!.wasInterceptedMidTransit, isTrue);
      expect(lastResult!.arrival.x, closeTo(600.0, 1e-3));

      // Settle to Idle and test mid-flight SpatialAnomaly collision
      controller.update(2.5);
      controller.registerAnomaly(const SpatialAnomaly(
        id: 'grav-well-1',
        x: 400.0,
        y: 0.0,
        radius: 60.0,
        energyDamage: 30.0,
        decayPenalty: 0.25,
        pullsOutOfSubwarp: true,
      ));

      controller.commandWarp(
        targetNode: targetPlanet,
        shipX: 0.0,
        shipY: 0.0,
        driveType: WarpDriveType.subwarp,
      );
      controller.update(5.0); // Enter Subwarp

      // Step 0.7s -> ship reaches x=420, colliding with anomaly at x=400 (radius 60)
      controller.update(0.7);
      expect(controller.isSubwarpInTransit, isFalse);
      expect(controller.lastCollidedAnomaly?.id, equals('grav-well-1'));
      expect(controller.shipDecay, closeTo(0.25, 1e-4));
      expect(lastResult!.collidedAnomaly?.id, equals('grav-well-1'));

      // Swept segment intersection catches narrow anomalies on fast ticks AND
      // non-pulling anomalies only apply penalty once per transit across multi-ticks
      controller.update(2.5);
      controller.clearAnomalies();
      controller.shipDecay = 0.0;
      controller.registerAnomaly(const SpatialAnomaly(
        id: 'radiation-belt',
        x: 300.0,
        y: 0.0,
        radius: 150.0,
        energyDamage: 15.0,
        decayPenalty: 0.12,
        pullsOutOfSubwarp: false,
      ));
      controller.registerAnomaly(const SpatialAnomaly(
        id: 'thin-snare',
        x: 800.0,
        y: 0.0,
        radius: 10.0,
        energyDamage: 10.0,
        decayPenalty: 0.08,
        pullsOutOfSubwarp: true,
      ));

      controller.commandWarp(
        targetNode: targetPlanet,
        shipX: 0.0,
        shipY: 0.0,
        driveType: WarpDriveType.subwarp,
      );
      controller.update(5.0); // Enter Subwarp

      // Multiple small ticks inside radiation-belt (x=150..450) only apply 0.12 decay once
      controller.update(0.3); // x = 180
      controller.update(0.2); // x = 300
      controller.update(0.2); // x = 420
      expect(controller.shipDecay, closeTo(0.12, 1e-5));
      expect(controller.isSubwarpInTransit, isTrue);

      // Large 1.0s tick jumps from x=420 to x=1020 across thin-snare (x=800, r=10)
      // Swept check catches thin-snare at entry (x = 790) and pulls ship out of Subwarp
      controller.update(1.0);
      expect(controller.isSubwarpInTransit, isFalse);
      expect(controller.lastCollidedAnomaly?.id, equals('thin-snare'));
      expect(controller.shipDecay, closeTo(0.20, 1e-5));
      expect(lastResult!.arrival.x, closeTo(790.0, 1e-3));
    });

    test('FTL and Subwarp WarpWake signatures follow distinct energy decay curves', () {
      const ftlWake = WarpWake(
        x: 0,
        y: 0,
        timestamp: 0,
        shipEcm: 0.2,
        driveType: WarpDriveType.ftl,
        baseEnergySignature: 0.95,
        decayRate: 0.30,
      );

      const subwarpWake = WarpWake(
        x: 0,
        y: 0,
        timestamp: 0,
        shipEcm: 0.2,
        driveType: WarpDriveType.subwarp,
        baseEnergySignature: 0.70,
        decayRate: 0.05,
        vectorX: 1.0,
        vectorY: 0.0,
      );

      // At t=0, FTL has a stronger concentrated signature than Subwarp
      expect(
        ftlWake.currentEnergy(0.0),
        greaterThan(subwarpWake.currentEnergy(0.0)),
      );

      // At t=6.0s, FTL has decayed sharply below the lingering Subwarp trail
      expect(
        ftlWake.currentEnergy(6.0),
        lessThan(subwarpWake.currentEnergy(6.0)),
      );
    });

    test('Spoofed decoys expire and are pruned from spoofedWakes over time', () {
      final economy = DroneSwarmEconomy(maxFleetSize: 10);
      final roster = FighterRoster(maxFighterCount: 4);
      final controller = ShipWarpController(
        economy: economy,
        fighterRoster: roster,
      );

      final spoof = controller.emitSpoofedWake(
        x: 0,
        y: 0,
        fakeTargetX: 500,
        fakeTargetY: 500,
        initialConfidenceWeight: 0.50,
        confidenceDecayRate: 0.50,
      );
      expect(spoof, isNotNull);
      expect(controller.spoofedWakeCount, equals(1));

      // Advance time by 15s -> confidence & energy drop well below 0.20 threshold
      controller.update(15.0);
      expect(controller.spoofedWakeCount, equals(0));
    });
  });
}
