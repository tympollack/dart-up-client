import 'package:flutter_test/flutter_test.dart';
import 'package:sd_client/celestial/celestial_node_manager.dart';
import 'package:sd_client/combat/fighter_roster.dart';
import 'package:sd_client/simulation/warp/ship_warp_controller.dart';
import 'package:sd_client/simulation/warp/tracking_spectrum.dart';
import 'package:sd_client/swarm/drone_swarm_economy.dart';

void main() {
  group('TASK-DARTUP-TRACE-SPECTRUM: Information Spectrum & Active ECM Spoofing', () {
    const wake = WarpWake(
      x: 500.0,
      y: 300.0,
      timestamp: 10.0,
      shipEcm: 0.30,
      driveType: WarpDriveType.subwarp,
      baseEnergySignature: 0.85,
      decayRate: 0.05,
      vectorX: 0.8,
      vectorY: 0.6,
      targetX: 1500.0,
      targetY: 1050.0,
    );

    test('High Signal (>= 0.65) returns exact target coordinates/vector and high pulseIntensity', () {
      final result = evaluateWakeTrace(
        wake: wake,
        hunterDetectionTech: 0.50,
        timeSinceJump: 1.0,
        readerX: 1500.0,
        readerY: 50.0,
      );

      expect(result, isNotNull);
      expect(result!.outcome, equals(TrackingOutcome.pinpoint));
      expect(result.signalStrength, greaterThanOrEqualTo(0.65));
      expect(result.targetX, equals(1500.0));
      expect(result.targetY, equals(1050.0));
      // Bearing from reader (1500, 50) to exact target (1500, 1050) is (0.0, 1.0)
      expect(result.directionX, closeTo(0.0, 1e-6));
      expect(result.directionY, closeTo(1.0, 1e-6));
      expect(result.pulseIntensity, greaterThanOrEqualTo(0.65));
      expect(result.zoneOfProbability, isNull);
    });

    test('Degraded Signal (0.20 .. 0.64) across Nebula zone returns ZoneOfProbability with radius inversely proportional to signalStrength', () {
      const nebula = NebulaNode(
        id: 'nebula-shroud',
        x: 500.0,
        y: 300.0,
        interactionRadius: 400.0,
        obscurityMultiplier: 0.50,
      );

      final resultHigher = evaluateWakeTrace(
        wake: wake,
        hunterDetectionTech: 0.45,
        timeSinceJump: 2.0,
        readerX: 0.0,
        readerY: 0.0,
        obscurityMultiplier: nebula.obscurityMultiplier,
      );

      final resultLower = evaluateWakeTrace(
        wake: wake,
        hunterDetectionTech: 0.20,
        timeSinceJump: 4.0,
        readerX: 0.0,
        readerY: 0.0,
        obscurityMultiplier: nebula.obscurityMultiplier,
      );

      expect(resultHigher, isNotNull);
      expect(resultLower, isNotNull);
      expect(resultHigher!.outcome, equals(TrackingOutcome.zone));
      expect(resultLower!.outcome, equals(TrackingOutcome.zone));

      expect(resultHigher.signalStrength, inInclusiveRange(0.20, 0.649));
      expect(resultLower.signalStrength, inInclusiveRange(0.20, 0.649));
      expect(resultHigher.signalStrength, greaterThan(resultLower.signalStrength));

      // Uncertainty radius is inversely proportional to signalStrength
      expect(
        resultLower.zoneOfProbability!.uncertaintyRadius,
        greaterThan(resultHigher.zoneOfProbability!.uncertaintyRadius),
      );
      expect(resultHigher.targetX, isNull);
      expect(resultHigher.pulseIntensity, lessThan(0.30));
    });

    test('Lost Trace (< 0.20) returns null from evaluateWakeTrace and Blind from readWake', () {
      final lostResult = evaluateWakeTrace(
        wake: wake,
        hunterDetectionTech: 0.10,
        timeSinceJump: 35.0,
        readerX: 0.0,
        readerY: 0.0,
        obscurityMultiplier: 0.25,
      );
      expect(lostResult, isNull);

      final blindFallback = readWake(
        wake: wake,
        sensor: const SensorModule(tier: 1, trackingTech: 0.10),
        timeSinceJump: 35.0,
        readerX: 0.0,
        readerY: 0.0,
        obscurityMultiplier: 0.25,
      );
      expect(blindFallback.outcome, equals(TrackingOutcome.blind));

      // Explicit signalDecayPerSecond override in readWake forces linear decay
      final rapidDecayOverride = readWake(
        wake: wake,
        sensor: const SensorModule(tier: 1, trackingTech: 0.30),
        timeSinceJump: 2.0,
        readerX: 0.0,
        readerY: 0.0,
        signalDecayPerSecond: 0.40, // 0.85 - 0.80 = 0.05 (< 0.20 lostTraceThreshold)
      );
      expect(rapidDecayOverride.outcome, equals(TrackingOutcome.blind));
    });

    test('Active ECM Spoofing expends ECM charge and emits SpoofedWarpWake false trails with decaying confidence weights', () {
      final economy = DroneSwarmEconomy(maxFleetSize: 10);
      final roster = FighterRoster(maxFighterCount: 5);
      final controller = ShipWarpController(
        economy: economy,
        fighterRoster: roster,
        shipEcm: 0.35,
      );

      final initialEcmCharge = controller.ecmCharge;
      final spoofed = controller.emitSpoofedWake(
        x: 200.0,
        y: 100.0,
        fakeTargetX: -800.0,
        fakeTargetY: 900.0,
        ecmCost: 30.0,
        initialConfidenceWeight: 0.90,
        confidenceDecayRate: 0.25,
      );

      expect(spoofed, isNotNull);
      expect(spoofed!.isSpoofed, isTrue);
      expect(controller.ecmCharge, closeTo(initialEcmCharge - 30.0, 1e-5));
      expect(controller.spoofedWakes.length, equals(1));

      // Confidence decays over time
      final confT0 = spoofed.confidenceAt(0.0);
      final confT4 = spoofed.confidenceAt(4.0);
      final confT12 = spoofed.confidenceAt(12.0);
      expect(confT0, closeTo(0.90, 1e-6));
      expect(confT4, lessThan(confT0));
      expect(confT12, lessThan(confT4));

      // Sensor sweep on fresh spoofed wake sees a convincing false trail initially,
      // which degrades into a lost trace as confidence decays
      final earlyTrace = evaluateWakeTrace(
        wake: spoofed,
        hunterDetectionTech: 0.50,
        timeSinceJump: 0.5,
        readerX: 0.0,
        readerY: 0.0,
      );
      expect(earlyTrace, isNotNull);
      expect(earlyTrace!.isSpoofedTrail, isTrue);
      expect(earlyTrace.confidenceWeight, greaterThan(0.70));

      final decayedTrace = evaluateWakeTrace(
        wake: spoofed,
        hunterDetectionTech: 0.50,
        timeSinceJump: 10.0,
        readerX: 0.0,
        readerY: 0.0,
      );
      expect(decayedTrace, isNull);
    });
  });
}
