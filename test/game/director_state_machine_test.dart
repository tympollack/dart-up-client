import 'package:flutter_test/flutter_test.dart';
import 'package:sd_client/game/director/director_state_machine.dart';
import 'package:sd_client/simulation/telemetry/telemetry_ring_buffer.dart';

void main() {
  group('TASK-DARTUP-DIRECTOR-CAM: Automated Director Camera Controller & 4.0s Anti-Whip Heuristics', () {
    test('Simulated 5-minute replay log confirms zero rapid camera oscillation (< 4.0s cuts) and smooth zoom damping', () {
      const int fiveMinuteTicks = 5 * 60 * 20; // 6,000 ticks at 20Hz
      final buffer = TelemetryRingBuffer(
        capacityTicks: fiveMinuteTicks,
        maxEntitiesPerTick: 4,
        eventCapacity: 8192,
      );

      // Simulate rapid back-and-forth dogfights every 0.5 seconds (10 ticks)
      // attempting to bait the camera into rapid whipping between entity 1, 2, and 3
      for (int tick = 0; tick < fiveMinuteTicks; tick++) {
        final double t = tick * 0.05;
        buffer.beginTick(tickNumber: tick, timestamp: t);

        buffer.recordEntityState(
          entityId: 1,
          x: 100.0 + tick * 0.2,
          y: 50.0,
          vx: 40.0,
          vy: 15.0,
          hull: 85.0,
        );
        buffer.recordEntityState(
          entityId: 2,
          x: -700.0 - tick * 0.1,
          y: 400.0,
          vx: -60.0,
          vy: 25.0,
          hull: 90.0,
        );
        buffer.recordEntityState(
          entityId: 3,
          x: 900.0,
          y: -650.0 + tick * 0.15,
          vx: 20.0,
          vy: 80.0,
          hull: 75.0,
        );

        // Alternate heavy weapon bursts every 0.5s (10 ticks) across different sectors
        final int activeSkirmisher = (tick ~/ 10) % 3 + 1;
        buffer.recordWeaponEvent(
          attackerId: activeSkirmisher,
          targetId: (activeSkirmisher % 3) + 1,
          sourceX: activeSkirmisher * 200.0,
          sourceY: activeSkirmisher * -150.0,
          targetX: 0.0,
          targetY: 0.0,
          damage: 35.0,
        );
      }

      final director = DirectorStateMachine();
      final frames = director.simulateFromRingBuffer(buffer);

      expect(frames.length, equals(fiveMinuteTicks));
      expect(director.cutHistory.length, greaterThan(1));

      // Verify every single non-climax cut respected the strict >= 4.0s anti-whip hold guard
      for (int i = 1; i < director.cutHistory.length; i++) {
        final cut = director.cutHistory[i];
        if (!cut.isCriticalClimaxOverride) {
          expect(
            cut.shotHoldDurationSeconds,
            greaterThanOrEqualTo(4.0 - 1e-6),
            reason:
                'Cut #$i at t=${cut.timestamp}s switched before 4.0s hold guard (${cut.shotHoldDurationSeconds}s)',
          );
        }
      }

      // Verify smooth zoom damping (no instantaneous single-tick zoom spikes > 0.25)
      for (int i = 1; i < frames.length; i++) {
        final double zoomDelta = (frames[i].zoom - frames[i - 1].zoom).abs();
        expect(zoomDelta, lessThan(0.25));
      }
    });

    test('critical_climax events (hull < 10% save or Star Dart capture) immediately override the 4.0s cooldown and engage slow-motion timeScale', () {
      final director = DirectorStateMachine();

      // T = 0.0s: Lock onto Entity 1
      final frame0 = director.evaluateFrame(
        dt: 0.05,
        timestamp: 0.0,
        entities: const [
          DirectorEntityTarget(
            entityId: 1,
            x: 0.0,
            y: 0.0,
            vx: 50.0,
            vy: 0.0,
            hull: 90.0,
            recentCombatDamage: 50.0,
          ),
          DirectorEntityTarget(
            entityId: 2,
            x: 1000.0,
            y: 1000.0,
            vx: 20.0,
            vy: 10.0,
            hull: 80.0,
          ),
        ],
      );
      expect(frame0.primaryEntityId, equals(1));

      // T = 1.2s (< 4.0s): Entity 2 has higher normal combat damage, but 4.0s guard blocks the cut
      final frameBlocked = director.evaluateFrame(
        dt: 0.05,
        timestamp: 1.2,
        entities: const [
          DirectorEntityTarget(
            entityId: 1,
            x: 60.0,
            y: 0.0,
            vx: 50.0,
            vy: 0.0,
            hull: 90.0,
          ),
          DirectorEntityTarget(
            entityId: 2,
            x: 1020.0,
            y: 1010.0,
            vx: 20.0,
            vy: 10.0,
            hull: 80.0,
            recentCombatDamage: 120.0,
          ),
        ],
      );
      expect(frameBlocked.primaryEntityId, equals(1));

      // T = 1.5s (< 4.0s): Entity 2 drops to 7% hull (< 10% critical_climax save) -> immediate cut override!
      final frameClimaxHull = director.evaluateFrame(
        dt: 0.05,
        timestamp: 1.5,
        entities: const [
          DirectorEntityTarget(
            entityId: 1,
            x: 75.0,
            y: 0.0,
            vx: 50.0,
            vy: 0.0,
            hull: 90.0,
          ),
          DirectorEntityTarget(
            entityId: 2,
            x: 1030.0,
            y: 1015.0,
            vx: 20.0,
            vy: 10.0,
            hull: 7.0,
            maxHull: 100.0,
          ),
        ],
      );
      expect(frameClimaxHull.primaryEntityId, equals(2));
      expect(frameClimaxHull.mode, equals(DirectorCameraMode.criticalClimaxCloseUp));
      expect(frameClimaxHull.timeScale, lessThan(1.0));
      expect(director.cutHistory.last.isCriticalClimaxOverride, isTrue);
      expect(
        director.cutHistory.last.reason,
        equals(DirectorCutReason.criticalClimaxHullSave),
      );

      // T = 2.4s (< 4.0s after previous cut): Star Dart Boss (Entity 99) is tethered/captured -> immediate cut override!
      final frameClimaxBoss = director.evaluateFrame(
        dt: 0.05,
        timestamp: 2.4,
        entities: const [
          DirectorEntityTarget(
            entityId: 1,
            x: 120.0,
            y: 0.0,
            vx: 50.0,
            vy: 0.0,
            hull: 90.0,
          ),
          DirectorEntityTarget(
            entityId: 2,
            x: 1050.0,
            y: 1025.0,
            vx: 20.0,
            vy: 10.0,
            hull: 7.0,
          ),
          DirectorEntityTarget(
            entityId: 99,
            x: -1500.0,
            y: -1200.0,
            vx: 0.0,
            vy: 0.0,
            hull: 250.0,
            maxHull: 500.0,
            isStarDartBoss: true,
            isStarDartTetheredOrCaptured: true,
          ),
        ],
      );
      expect(frameClimaxBoss.primaryEntityId, equals(99));
      expect(frameClimaxBoss.mode, equals(DirectorCameraMode.starDartAmbush));
      expect(director.cutHistory.last.isCriticalClimaxOverride, isTrue);
      expect(
        director.cutHistory.last.reason,
        equals(DirectorCutReason.criticalClimaxStarDartCapture),
      );
    });

    test('Computes velocity lead offsets and dynamic dolly-zoom bounding boxes for warp chases', () {
      final director = DirectorStateMachine();
      final frame = director.evaluateFrame(
        dt: 0.05,
        timestamp: 0.0,
        entities: const [
          DirectorEntityTarget(
            entityId: 1,
            x: 500.0,
            y: -200.0,
            vx: 300.0,
            vy: -150.0,
            hull: 100.0,
            isInWarpChase: true,
          ),
        ],
      );

      expect(frame.mode, equals(DirectorCameraMode.warpChase));
      expect(frame.velocityLeadOffsetX, greaterThan(100.0));
      expect(frame.velocityLeadOffsetY, lessThan(-50.0));
      // Framing box center shifts ahead of the ship in the direction of velocity
      expect(frame.framingBox.centerX, greaterThan(500.0));
      expect(frame.framingBox.centerY, lessThan(-200.0));
    });
  });
}
