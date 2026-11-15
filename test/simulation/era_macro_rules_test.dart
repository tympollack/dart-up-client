import 'package:flutter_test/flutter_test.dart';
import 'package:sd_client/simulation/macro/era_macro_simulation.dart';

void main() {
  group('TASK-DARTUP-ERA-MACRO-RULES: Macro Era Systems', () {
    test('AntiTurtlingEconomy computes progression yield from activeTime + facilityCount and applies harsh decay penalties when idleDuration exceeds threshold', () {
      final economy = AntiTurtlingEconomy(
        config: const AntiTurtlingConfig(
          activeTimeYieldRate: 2.0,
          facilityYieldRate: 10.0,
          idleThresholdSeconds: 30.0,
          excessIdleDecayRate: 0.05,
          turtlingFacilityPenaltyPerBuilding: 0.10,
          minDecayMultiplier: 0.05,
        ),
        initialFacilityCount: 4,
      );

      // Active play for 50s -> zero idle penalty (decayMultiplier == 1.0)
      economy.update(50.0, isActivelyEngaged: true);
      final activeSnap = economy.evaluateYield();
      // baseYield = 50 * 2.0 + 4 * 10.0 = 140.0
      expect(activeSnap.baseYield, closeTo(140.0, 1e-5));
      expect(activeSnap.decayMultiplier, closeTo(1.0, 1e-5));
      expect(activeSnap.effectiveYield, closeTo(140.0, 1e-5));
      expect(activeSnap.isTurtlingPenalized, isFalse);

      // Camp/idle for 60s (> 30s threshold) -> harsh negative multiplier
      economy.update(60.0, isActivelyEngaged: false);
      final turtlingSnap = economy.evaluateYield();
      expect(turtlingSnap.isTurtlingPenalized, isTrue);
      expect(turtlingSnap.decayMultiplier, lessThan(0.25));
      expect(turtlingSnap.effectiveYield, lessThan(turtlingSnap.baseYield * 0.25));

      // Hoarding more facilities while turtling compounds the decay penalty further
      final heavyTurtlerMultiplier = economy.computeDecayMultiplier(
        idleDurationOverride: 60.0,
        facilityCountOverride: 10,
      );
      expect(heavyTurtlerMultiplier, lessThan(turtlingSnap.decayMultiplier));
    });

    test('ProceduralEraTechTree generates identical acyclic 5-discipline DAGs from identical eraSeed', () {
      final treeA = ProceduralEraTechTree.generate(
        eraSeed: 20261115,
        tiersPerDiscipline: 4,
      );
      final treeB = ProceduralEraTechTree.generate(
        eraSeed: 20261115,
        tiersPerDiscipline: 4,
      );
      final treeDifferent = ProceduralEraTechTree.generate(
        eraSeed: 99999999,
        tiersPerDiscipline: 4,
      );

      expect(treeA.equalsTree(treeB), isTrue);
      expect(treeA.equalsTree(treeDifferent), isFalse);
      expect(treeA.isAcyclic(), isTrue);
      expect(treeDifferent.isAcyclic(), isTrue);

      // Verify all 5 core disciplines are present with 4 tiers each (20 nodes total)
      expect(treeA.nodes.length, equals(20));
      for (final discipline in TechDiscipline.values) {
        final discNodes = treeA.nodesForDiscipline(discipline);
        expect(discNodes.length, equals(4));
      }

      // Tier 0 nodes have no prerequisites and can be researched immediately
      final unlocked = <String>{};
      expect(treeA.canResearch('energy_t0', unlocked), isTrue);
      expect(treeA.canResearch('energy_t1', unlocked), isFalse);
    });

    test('DynamicPveThreatScaler scales global hostility and spawn rate multipliers with active players and spectators', () {
      const scaler = DynamicPveThreatScaler();

      final soloNoSpec = scaler.evaluate(
        activePlayerCount: 1,
        spectatorCount: 0,
      );
      final squadWithSpectators = scaler.evaluate(
        activePlayerCount: 6,
        spectatorCount: 25,
      );

      expect(soloNoSpec.hostilityMultiplier, closeTo(1.0, 1e-5));
      expect(
        squadWithSpectators.hostilityMultiplier,
        greaterThan(soloNoSpec.hostilityMultiplier),
      );
      expect(
        squadWithSpectators.spawnRateMultiplier,
        greaterThan(soloNoSpec.spawnRateMultiplier),
      );
      expect(
        squadWithSpectators.eliteEscalationChance,
        greaterThan(soloNoSpec.eliteEscalationChance),
      );
    });

    test('CastLedgerEmitter emits structured ActionIntentDelta records for alliances, betrayals, Star Dart steals, and bounties', () {
      final emitted = <ActionIntentDelta>[];
      final emitter = CastLedgerEmitter(onDeltaEmitted: emitted.add);

      emitter.emitAllianceFormed(
        initiatorPlayerId: 'p1',
        partnerPlayerId: 'p2',
        timestamp: 12.0,
        pactName: 'Orion Pact',
      );
      emitter.emitBetrayal(
        betrayerPlayerId: 'p2',
        victimPlayerId: 'p1',
        timestamp: 45.0,
        damageDealt: 420.0,
      );
      emitter.emitStarDartSteal(
        thiefPlayerId: 'p3',
        previousTetherPlayerId: 'p2',
        bossId: 'star-dart-prime',
        timestamp: 88.0,
        sectorX: 120.0,
        sectorY: -340.0,
      );
      emitter.emitBountyTriggered(
        targetPlayerId: 'p3',
        bountyCredits: 5000,
        reason: 'Grand Theft Star Dart',
        timestamp: 90.0,
      );

      expect(emitted.length, equals(4));
      expect(emitter.ledger.length, equals(4));
      expect(emitted[0].type, equals(ActionIntentType.allianceFormed));
      expect(emitted[1].type, equals(ActionIntentType.betrayal));
      expect(emitted[2].type, equals(ActionIntentType.starDartSteal));
      expect(emitted[3].type, equals(ActionIntentType.bountyTriggered));
      expect(emitted[3].toJson()['payload'], containsPair('bountyCredits', 5000));
    });
  });
}
