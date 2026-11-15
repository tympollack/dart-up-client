import 'package:flutter_test/flutter_test.dart';
import 'package:sd_client/simulation/boss/star_dart_state_machine.dart';

void main() {
  group('TASK-DARTUP-BOSS-CAPTURE-FSM: Star Dart Boss Capture State Machine & Ambush Loop', () {
    test('Enforces roaming -> shieldBreached -> crippledDerelict -> repairCaptureInProgress -> captured with DartUpChaseAlert and vulnerable ship lock', () {
      final alerts = <DartUpChaseAlert>[];
      final transitions = <StarDartBossState>[];
      String? capturedWinner;

      final boss = StarDartStateMachine(
        config: const StarDartConfig(
          maxShields: 200.0,
          maxHull: 300.0,
          captureDurationSeconds: 10.0,
          derelictEscapeTimeoutSeconds: 25.0,
          ambushCooldownSeconds: 2.0,
          deepSectorBreachRadius: 5000.0,
        ),
        initialX: 400.0,
        initialY: -250.0,
        onStateChanged: (_, next) => transitions.add(next),
        onChaseAlertBroadcast: alerts.add,
        onBossCaptured: (playerId) => capturedWinner = playerId,
      );

      expect(boss.state, equals(StarDartBossState.roaming));

      // Cannot initiate capture while roaming
      expect(boss.beginRepairCapture('pilot-alpha'), isFalse);

      // Deplete shields -> shieldBreached
      boss.applyDamage(200.0);
      expect(boss.state, equals(StarDartBossState.shieldBreached));
      expect(boss.shields, equals(0.0));
      expect(boss.hull, equals(300.0));

      // Deplete hull -> crippledDerelict
      boss.applyDamage(300.0);
      expect(boss.state, equals(StarDartBossState.crippledDerelict));
      expect(boss.hull, equals(0.0));
      expect(boss.isCrippled, isTrue);

      // Initiate repair/capture tether -> repairCaptureInProgress + DartUpChaseAlert
      expect(boss.beginRepairCapture('pilot-alpha'), isTrue);
      expect(boss.state, equals(StarDartBossState.repairCaptureInProgress));
      expect(boss.isCapturingShipVulnerableLock, isTrue);
      expect(boss.tetheredPlayerId, equals('pilot-alpha'));
      expect(alerts.length, equals(1));
      expect(alerts.first.capturingPlayerId, equals('pilot-alpha'));
      expect(alerts.first.x, equals(400.0));
      expect(alerts.first.y, equals(-250.0));

      // Advance 6.0s -> 60% capture progress
      boss.update(6.0);
      expect(boss.captureProgress, closeTo(0.60, 1e-5));
      expect(boss.captureRemainingSeconds, closeTo(4.0, 1e-5));

      // Rival hunter ambushes at 6.0s -> resets capture timer and releases vulnerable lock
      expect(
        boss.triggerAmbushInterruption(ambusherPlayerId: 'hunter-bravo'),
        isTrue,
      );
      expect(boss.state, equals(StarDartBossState.contestedAmbush));
      expect(boss.isCapturingShipVulnerableLock, isFalse);
      expect(boss.tetheredPlayerId, isNull);
      expect(boss.captureRemainingSeconds, closeTo(10.0, 1e-5));

      // Tick 2.0s ambush cooldown -> returns to crippledDerelict
      boss.update(2.0);
      expect(boss.state, equals(StarDartBossState.crippledDerelict));

      // Hunter-bravo initiates repair capture and holds for full 10.0s
      expect(boss.beginRepairCapture('hunter-bravo'), isTrue);
      expect(alerts.length, equals(2));
      boss.update(10.0);

      expect(boss.state, equals(StarDartBossState.captured));
      expect(boss.isCaptured, isTrue);
      expect(boss.isCapturingShipVulnerableLock, isFalse);
      expect(boss.capturedByPlayerId, equals('hunter-bravo'));
      expect(capturedWinner, equals('hunter-bravo'));
      expect(transitions, containsAllInOrder([
        StarDartBossState.shieldBreached,
        StarDartBossState.crippledDerelict,
        StarDartBossState.repairCaptureInProgress,
        StarDartBossState.contestedAmbush,
        StarDartBossState.crippledDerelict,
        StarDartBossState.repairCaptureInProgress,
        StarDartBossState.captured,
      ]));
    });

    test('Derelict timeout transitions crippled Star Dart to escapedJump, and deep-sector breach triggers EarthCataclysmProtocol', () {
      final cataclysms = <EarthCataclysmProtocol>[];
      final boss = StarDartStateMachine(
        config: const StarDartConfig(
          maxShields: 100.0,
          maxHull: 100.0,
          derelictEscapeTimeoutSeconds: 8.0,
          deepSectorBreachRadius: 4000.0,
        ),
        onEarthCataclysmTriggered: cataclysms.add,
      );

      // Breach deep-sector coordinates (x = 4500 >= 4000)
      boss.setPosition(4500.0, 0.0, triggeringPlayerId: 'vanguard-1');
      expect(boss.isEarthCataclysmActive, isTrue);
      expect(boss.globalSiegeAlertLevel, equals(1));
      expect(boss.state, equals(StarDartBossState.earthCataclysmAlert));
      expect(cataclysms.length, equals(1));

      // Cripple the boss and let derelictEscapeTimeoutSeconds expire without capture
      boss.applyDamage(250.0);
      expect(boss.state, equals(StarDartBossState.crippledDerelict));

      boss.update(8.0);
      expect(boss.state, equals(StarDartBossState.escapedJump));
    });
  });
}
