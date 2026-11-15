// =============================================================================
// anti_turtling_economy.dart
//
// Pure-Dart Anti-Turtling Economy rules computing progression yield from
// `activeTime + facilityCount` and applying steep negative decay multipliers
// when `idleDuration` exceeds the anti-camping threshold.
// Zero Flutter or Flame imports.
// =============================================================================

import 'dart:math' as math;

/// Tunable parameters for the Anti-Turtling Economy ruleset.
class AntiTurtlingConfig {
  /// Baseline progression points earned per second of active play.
  final double activeTimeYieldRate;

  /// Baseline progression points earned per owned facility per evaluation.
  final double facilityYieldRate;

  /// Seconds of continuous inactivity (`idleDuration`) tolerated before
  /// anti-turtling decay penalties engage.
  final double idleThresholdSeconds;

  /// Exponential decay rate per second of excess inactivity beyond
  /// [idleThresholdSeconds].
  final double excessIdleDecayRate;

  /// Additional penalty factor per facility when turtling (`idleDuration > idleThresholdSeconds`),
  /// punishing players who hoard large facility networks while camping.
  final double turtlingFacilityPenaltyPerBuilding;

  /// Minimum floor on the decay multiplier (e.g. `0.05` = 95% yield reduction).
  final double minDecayMultiplier;

  const AntiTurtlingConfig({
    this.activeTimeYieldRate = 2.5,
    this.facilityYieldRate = 12.0,
    this.idleThresholdSeconds = 45.0,
    this.excessIdleDecayRate = 0.04,
    this.turtlingFacilityPenaltyPerBuilding = 0.08,
    this.minDecayMultiplier = 0.05,
  });
}

/// Snapshot of an Anti-Turtling economy evaluation.
class EconomyYieldSnapshot {
  final double baseYield;
  final double decayMultiplier;
  final double effectiveYield;
  final bool isTurtlingPenalized;

  const EconomyYieldSnapshot({
    required this.baseYield,
    required this.decayMultiplier,
    required this.effectiveYield,
    required this.isTurtlingPenalized,
  });
}

/// Pure-Dart Anti-Turtling Economy solver.
class AntiTurtlingEconomy {
  AntiTurtlingEconomy({
    AntiTurtlingConfig? config,
    int initialFacilityCount = 1,
  })  : config = config ?? const AntiTurtlingConfig(),
        facilityCount = initialFacilityCount;

  final AntiTurtlingConfig config;

  double activeTimeSeconds = 0.0;
  double idleDurationSeconds = 0.0;
  int facilityCount;

  /// Records meaningful combat, movement, or objective activity, resetting
  /// [idleDurationSeconds] to zero.
  void recordPlayerAction() {
    idleDurationSeconds = 0.0;
  }

  /// Advances tracked timers by [dt] seconds.
  void update(double dt, {required bool isActivelyEngaged}) {
    if (dt <= 0) return;
    if (isActivelyEngaged) {
      activeTimeSeconds += dt;
      idleDurationSeconds = 0.0;
    } else {
      idleDurationSeconds += dt;
    }
  }

  /// Computes the anti-turtling multiplier in `[config.minDecayMultiplier, 1.0]`.
  /// When `idleDuration > config.idleThresholdSeconds`, applies harsh
  /// exponential decay compounded by `facilityCount`.
  double computeDecayMultiplier({
    double? idleDurationOverride,
    int? facilityCountOverride,
  }) {
    final double idle = math.max(0.0, idleDurationOverride ?? idleDurationSeconds);
    final int facilities = math.max(0, facilityCountOverride ?? facilityCount);

    if (idle <= config.idleThresholdSeconds) {
      return 1.0;
    }

    final double excessIdle = idle - config.idleThresholdSeconds;
    final double compoundRate = config.excessIdleDecayRate *
        (1.0 + facilities * config.turtlingFacilityPenaltyPerBuilding);
    final double multiplier = math.exp(-compoundRate * excessIdle);
    return multiplier.clamp(config.minDecayMultiplier, 1.0);
  }

  /// Computes progression yield from `activeTime + facilityCount` scaled by
  /// the anti-turtling decay multiplier.
  EconomyYieldSnapshot evaluateYield({
    double? activeTimeOverride,
    int? facilityCountOverride,
    double? idleDurationOverride,
  }) {
    final double active = math.max(0.0, activeTimeOverride ?? activeTimeSeconds);
    final int facilities = math.max(0, facilityCountOverride ?? facilityCount);
    final double idle = math.max(0.0, idleDurationOverride ?? idleDurationSeconds);

    final double baseYield = (active * config.activeTimeYieldRate) +
        (facilities * config.facilityYieldRate);
    final double multiplier = computeDecayMultiplier(
      idleDurationOverride: idle,
      facilityCountOverride: facilities,
    );

    return EconomyYieldSnapshot(
      baseYield: baseYield,
      decayMultiplier: multiplier,
      effectiveYield: baseYield * multiplier,
      isTurtlingPenalized: idle > config.idleThresholdSeconds,
    );
  }
}
