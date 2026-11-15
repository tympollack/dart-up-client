import 'package:flutter_test/flutter_test.dart';
import 'package:sd_client/simulation/swarm/swarm_simulation.dart';

void main() {
  group('TASK-DARTUP-BOIDS-ENGINE: BoidsFlockingSolver', () {
    test('500+ swarm entities update in <2ms per tick on average', () {
      const bounds = ArenaBounds(left: 0, top: 0, width: 2000, height: 2000);
      final solver = BoidsFlockingSolver(
        unitCount: 600,
        bounds: bounds,
        seed: 42,
      );

      // Warm up JIT
      for (int i = 0; i < 25; i++) {
        solver.update(1 / 60);
      }

      const measuredTicks = 60;
      final sw = Stopwatch()..start();
      for (int i = 0; i < measuredTicks; i++) {
        solver.update(1 / 60);
      }
      sw.stop();

      final avgMsPerTick = sw.elapsedMicroseconds / 1000.0 / measuredTicks;
      expect(avgMsPerTick, lessThan(2.0));
    });

    test('Cohesion, alignment, and separation steering vectors behave deterministically', () {
      const bounds = ArenaBounds(left: 0, top: 0, width: 1000, height: 1000);
      final solver = BoidsFlockingSolver(
        unitCount: 2,
        bounds: bounds,
        config: BoidsConfig(
          perceptionRadius: 80.0,
          separationRadius: 25.0,
          boundaryMargin: 0.0,
        ),
      )..clearTarget();

      // Place two units within separationRadius (10 units apart on X)
      solver.setUnitState(0, x: 500, y: 500, vx: 10, vy: 0);
      solver.setUnitState(1, x: 510, y: 500, vx: 10, vy: 0);
      solver.rebuildSpatialGrid();

      final sepSteer0 = solver.computeSteeringFor(0);
      final sepSteer1 = solver.computeSteeringFor(1);
      // Unit 0 should be pushed left (-X), unit 1 pushed right (+X)
      expect(sepSteer0.x, lessThan(0));
      expect(sepSteer1.x, greaterThan(0));

      // Place two units outside separationRadius but inside perceptionRadius (50 units apart)
      solver.setUnitState(0, x: 500, y: 500, vx: 0, vy: 20);
      solver.setUnitState(1, x: 550, y: 500, vx: 0, vy: 100);
      solver.rebuildSpatialGrid();

      final cohAlignSteer0 = solver.computeSteeringFor(0);
      // Cohesion pulls unit 0 toward unit 1 (+X), alignment pulls unit 0 toward +Y
      expect(cohAlignSteer0.x, greaterThan(0));
      expect(cohAlignSteer0.y, greaterThan(0));
    });

    test('Boundary avoidance steers units inward when inside boundaryMargin', () {
      const bounds = ArenaBounds(left: 0, top: 0, width: 1000, height: 1000);
      final solver = BoidsFlockingSolver(
        unitCount: 1,
        bounds: bounds,
        config: BoidsConfig(boundaryMargin: 100.0),
      )..clearTarget();

      // Near left and top edges
      final topLeftSteer = solver.computeBoundaryAvoidance(15, 20, -50, -50);
      expect(topLeftSteer.x, greaterThan(0));
      expect(topLeftSteer.y, greaterThan(0));

      // Near right and bottom edges
      final bottomRightSteer =
          solver.computeBoundaryAvoidance(985, 990, 50, 50);
      expect(bottomRightSteer.x, lessThan(0));
      expect(bottomRightSteer.y, lessThan(0));

      // Center of arena -> zero boundary force
      final centerSteer = solver.computeBoundaryAvoidance(500, 500, 10, 10);
      expect(centerSteer.x, equals(0));
      expect(centerSteer.y, equals(0));
    });
  });

  group('TASK-DARTUP-BOIDS-ENGINE: PlayerInteractionModel Tier 0 vs Tier 1+', () {
    test('Tier 0 requires manual tap/drag lock and respects focusTimeMultiplier & interactionRadius', () {
      final modifiers = InteractionUpgradeModifiers(
        baseInteractionRadius: 100.0,
        interactionRadiusMultiplier: 1.0,
        baseFocusTimeSeconds: 2.0,
        focusTimeMultiplier: 1.0,
        roboticsTier: 0,
        autoAttackUnlocked: true, // Even if flag is true, Tier 0 never auto-locks
      );

      final completed = <InteractionResolution>[];
      final model = PlayerInteractionModel(
        modifiers: modifiers,
        onInteractionCompleted: completed.add,
      );

      final targetFar = InteractionTarget(
        id: 'node-far',
        x: 150,
        y: 0,
        type: InteractionType.harvest,
      );

      // Tier 0 update does not auto-lock
      model.update(1.0, shipX: 0, shipY: 0, candidates: [targetFar]);
      expect(model.state, equals(InteractionState.idle));

      // Manual tap at (0, 0) fails because targetFar is at 150 > 100 radius
      expect(
        model.beginManualInteraction(
          pointerX: 0,
          pointerY: 0,
          candidates: [targetFar],
        ),
        isFalse,
      );

      // Upgrade interactionRadiusMultiplier to 2.0 -> effective radius = 200
      modifiers.interactionRadiusMultiplier = 2.0;
      // Upgrade focusTimeMultiplier to 0.5 -> effective focus duration = 1.0s
      modifiers.focusTimeMultiplier = 0.5;

      expect(
        model.beginManualInteraction(
          pointerX: 0,
          pointerY: 0,
          candidates: [targetFar],
        ),
        isTrue,
      );
      expect(model.state, equals(InteractionState.manualFocusing));
      expect(model.requiredFocusDuration, closeTo(1.0, 1e-6));

      model.update(0.5, shipX: 0, shipY: 0, candidates: [targetFar]);
      expect(model.focusProgress, closeTo(0.5, 1e-6));
      expect(completed, isEmpty);

      model.update(0.5, shipX: 0, shipY: 0, candidates: [targetFar]);
      expect(model.state, equals(InteractionState.idle));
      expect(completed.length, equals(1));
      expect(completed.first.wasAutomated, isFalse);
      expect(completed.first.target.id, equals('node-far'));
      expect(targetFar.isResolved, isTrue);
    });

    test('Tier 1+ autonomous robotics automatically acquires unlocked targets by priority', () {
      final modifiers = InteractionUpgradeModifiers(
        baseInteractionRadius: 200.0,
        baseFocusTimeSeconds: 1.0,
        roboticsTier: 1,
        autoAttackUnlocked: true,
        autoRepairUnlocked: false,
        autoHarvestUnlocked: true,
      );

      final model = PlayerInteractionModel(modifiers: modifiers);

      final repairTarget = InteractionTarget(
        id: 'repair-1',
        x: 30,
        y: 0,
        type: InteractionType.repair,
        priority: 10, // Highest priority, but autoRepairUnlocked is false!
      );
      final harvestTarget = InteractionTarget(
        id: 'harvest-1',
        x: 50,
        y: 0,
        type: InteractionType.harvest,
        priority: 2,
      );
      final attackTarget = InteractionTarget(
        id: 'attack-1',
        x: 80,
        y: 0,
        type: InteractionType.attack,
        priority: 5,
      );

      final candidates = [repairTarget, harvestTarget, attackTarget];

      // First tick acquires attackTarget (highest priority among unlocked types)
      model.update(0.4, shipX: 0, shipY: 0, candidates: candidates);
      expect(model.state, equals(InteractionState.autoFocusing));
      expect(model.lockedTarget?.id, equals('attack-1'));

      // Complete attackTarget focus
      model.update(0.7, shipX: 0, shipY: 0, candidates: candidates);
      expect(attackTarget.isResolved, isTrue);
      expect(model.completedHistory.length, equals(1));
      expect(model.completedHistory.first.wasAutomated, isTrue);

      // Next tick automatically acquires harvestTarget
      model.update(0.5, shipX: 0, shipY: 0, candidates: candidates);
      expect(model.state, equals(InteractionState.autoFocusing));
      expect(model.lockedTarget?.id, equals('harvest-1'));
    });
  });
}
