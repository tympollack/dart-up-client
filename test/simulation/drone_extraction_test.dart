import 'package:flutter_test/flutter_test.dart';
import 'package:sd_client/simulation/economy/drone_swarm_economy.dart';

void main() {
  group('TASK-DARTUP-DRONE-EXTRACTION: Drone Extraction Phase & needsRefit Docking Penalty', () {
    test('Stolen drone transitions idle -> tethering -> extracting -> dockedRefitting -> operational and suspends offensive/harvest output until refitRemainingSeconds == 0', () {
      final events = <DroneExtractionEvent>[];
      final config = DeploymentConfig(
        rechargeSeconds: 4.0,
        refitRechargeMultiplier: 2.5, // 10.0s refit duration
        tetherDurationSeconds: 0.5,
        arrivalRadius: 20.0,
        launchSpeed: 200.0,
        hackedSpeedMultiplier: 1.0,
        wobbleJitterPerSecond: 0.0,
        wobbleMaxAngle: 0.0,
      );

      final economy = DroneSwarmEconomy(
        maxFleetSize: 10,
        config: config,
        onExtractionEvent: events.add,
        seed: 99,
      );

      // Start with 5 player-owned available drones so there's room for stolen drones
      economy.availableCount = 5;

      // Spawn a stranded enemy drone at (100, 0) while ship is at (0, 0)
      final idx = economy.spawnStrandedEnemyDrone(100.0, 0.0);
      expect(idx, equals(0));
      expect(economy.extractionStateAt(idx), equals(DroneExtractionState.idle));
      expect(economy.isNeedsRefit(idx), isTrue);
      expect(economy.canDroneFireOrHarvest(idx), isFalse);
      expect(economy.offensiveOutputForDeployed(idx), equals(0.0));
      expect(economy.harvestOutputForDeployed(idx), equals(0.0));

      // Hack the stranded drone
      final hackedCount = economy.hackStrandedDrones(100.0, 0.0, 50.0);
      expect(hackedCount, equals(1));
      expect(economy.mode[idx], equals(DroneMode.hacked));
      expect(economy.isNeedsRefit(idx), isTrue);
      expect(
        economy.extractionStateAt(idx),
        equals(DroneExtractionState.tethering),
      );
      expect(events.length, equals(1));
      expect(events.first.type, equals(DroneExtractionEventType.extractionStarted));
      expect(events.first.needsRefit, isTrue);

      // Stolen drone still cannot fire or harvest while tethering/extracting
      expect(economy.canDroneFireOrHarvest(idx), isFalse);
      expect(economy.totalActiveOffensiveOutput, equals(0.0));
      expect(economy.totalActiveHarvestOutput, equals(0.0));

      // Tick 0.3s -> still tethering at (100, 0)
      economy.update(0.3, shipX: 0.0, shipY: 0.0);
      expect(
        economy.extractionStateAt(idx),
        equals(DroneExtractionState.tethering),
      );
      expect(economy.posX[idx], closeTo(100.0, 1e-4));

      // Tick 0.3s -> tether finishes, transitions to extracting and moves toward ship (0, 0)
      economy.update(0.3, shipX: 0.0, shipY: 0.0);
      expect(
        economy.extractionStateAt(idx),
        equals(DroneExtractionState.extracting),
      );
      expect(economy.posX[idx], lessThan(100.0));
      expect(economy.canDroneFireOrHarvest(idx), isFalse);

      // Advance until drone reaches arrivalRadius (20.0) of ship at (0, 0)
      for (int step = 0; step < 10 && economy.deployedCount > 0; step++) {
        economy.update(0.1, shipX: 0.0, shipY: 0.0);
      }

      // Drone has docked and entered dockedRefitting with 10.0s timer
      expect(economy.deployedCount, equals(0));
      expect(economy.dockedRefittingCount, equals(1));
      expect(economy.refitRemainingSeconds, closeTo(10.0, 0.2));
      expect(economy.availableCount, equals(5)); // Ownership not yet operational
      expect(
        events.any((e) =>
            e.type == DroneExtractionEventType.refitStarted &&
            e.state == DroneExtractionState.dockedRefitting),
        isTrue,
      );

      // Tick 4.0s (enough for normal rechargeSeconds, NOT enough for refit!)
      economy.update(4.0, shipX: 0.0, shipY: 0.0);
      expect(economy.dockedRefittingCount, equals(1));
      expect(economy.refitRemainingSeconds, closeTo(6.0, 0.2));
      expect(economy.availableCount, equals(5));

      // Tick remaining 6.0s -> refit completes, needsRefit cleared, added to availableCount
      economy.update(6.0, shipX: 0.0, shipY: 0.0);
      expect(economy.dockedRefittingCount, equals(0));
      expect(economy.refitRemainingSeconds, equals(0.0));
      expect(economy.availableCount, equals(6));
      expect(economy.completedRefitCount, equals(1));

      final completionEvent = events.last;
      expect(
        completionEvent.type,
        equals(DroneExtractionEventType.refitCompleted),
      );
      expect(completionEvent.state, equals(DroneExtractionState.operational));
      expect(completionEvent.needsRefit, isFalse);
      expect(completionEvent.refitRemainingSeconds, equals(0.0));

      // Redeploying from available pool launches a clean operational drone
      final launched = economy.tryDeploy(
        shipX: 0.0,
        shipY: 0.0,
        targetX: 200.0,
        targetY: 0.0,
      );
      expect(launched, equals(1));
      expect(economy.isNeedsRefit(0), isFalse);
      expect(
        economy.extractionStateAt(0),
        equals(DroneExtractionState.operational),
      );
      expect(economy.canDroneFireOrHarvest(0), isTrue);
      expect(economy.offensiveOutputForDeployed(0), greaterThan(0.0));
      expect(economy.harvestOutputForDeployed(0), greaterThan(0.0));
    });

    test('Emits extractionInterrupted when a hacked drone is stranded by emergency warp or destroyed in combat', () {
      final events = <DroneExtractionEvent>[];
      final economy = DroneSwarmEconomy(
        maxFleetSize: 10,
        onExtractionEvent: events.add,
      );
      economy.availableCount = 4;

      economy.spawnStrandedEnemyDrone(80.0, 0.0);
      economy.spawnStrandedEnemyDrone(90.0, 0.0);
      expect(economy.hackStrandedDrones(85.0, 0.0, 30.0), equals(2));

      // Interrupt first drone via combat destruction
      final killed = economy.applyDamage(0, 500);
      expect(killed, isTrue);
      expect(
        events.where((e) =>
            e.type == DroneExtractionEventType.extractionInterrupted &&
            e.reason == 'destroyed_in_combat').length,
        equals(1),
      );

      // Interrupt remaining extracting drone via emergency warp stranding
      final stranded = economy.strandUnreturnedDrones();
      expect(stranded, equals(1));
      expect(
        events.where((e) =>
            e.type == DroneExtractionEventType.extractionInterrupted &&
            e.reason == 'emergency_warp_stranded').length,
        equals(1),
      );
    });
  });
}
