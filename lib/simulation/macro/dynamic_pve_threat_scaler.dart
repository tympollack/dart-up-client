// =============================================================================
// dynamic_pve_threat_scaler.dart
//
// Pure-Dart Dynamic PvE Threat Scaler computing global hostility, enemy spawn
// rate multipliers, and elite/boss escalation weights from active player and
// spectator counts.
// Zero Flutter or Flame imports.
// =============================================================================

import 'dart:math' as math;

/// Result of evaluating global PvE hostility scaling.
class ThreatScalingSnapshot {
  final int activePlayerCount;
  final int spectatorCount;
  final double hostilityMultiplier;
  final double spawnRateMultiplier;
  final double eliteEscalationChance;

  const ThreatScalingSnapshot({
    required this.activePlayerCount,
    required this.spectatorCount,
    required this.hostilityMultiplier,
    required this.spawnRateMultiplier,
    required this.eliteEscalationChance,
  });
}

/// Scales global PvE hostility and spawn intensity based on active sector
/// population and live SunShade Hub spectator count.
class DynamicPveThreatScaler {
  final double baseHostility;
  final double perActivePlayerScale;
  final double perSpectatorScale;
  final double maxHostilityMultiplier;

  const DynamicPveThreatScaler({
    this.baseHostility = 1.0,
    this.perActivePlayerScale = 0.22,
    this.perSpectatorScale = 0.04,
    this.maxHostilityMultiplier = 6.0,
  });

  /// Computes the global PvE hostility multiplier (`>= baseHostility`).
  double computeHostilityMultiplier({
    required int activePlayerCount,
    required int spectatorCount,
  }) {
    final int players = math.max(1, activePlayerCount);
    final int spectators = math.max(0, spectatorCount);

    final double playerTerm = (players - 1) * perActivePlayerScale;
    // Diminishing-returns square-root boost for huge spectator crowds plus linear base
    final double spectatorTerm =
        (spectators * perSpectatorScale * 0.5) +
        (math.sqrt(spectators) * perSpectatorScale * 1.5);

    return (baseHostility + playerTerm + spectatorTerm)
        .clamp(baseHostility, maxHostilityMultiplier);
  }

  /// Evaluates a full [ThreatScalingSnapshot] for the current sector population.
  ThreatScalingSnapshot evaluate({
    required int activePlayerCount,
    required int spectatorCount,
  }) {
    final hostility = computeHostilityMultiplier(
      activePlayerCount: activePlayerCount,
      spectatorCount: spectatorCount,
    );
    final spawnMultiplier =
        (1.0 + (hostility - baseHostility) * 0.85).clamp(1.0, maxHostilityMultiplier);
    final eliteChance =
        (0.05 + (hostility - baseHostility) * 0.12).clamp(0.05, 0.75);

    return ThreatScalingSnapshot(
      activePlayerCount: math.max(0, activePlayerCount),
      spectatorCount: math.max(0, spectatorCount),
      hostilityMultiplier: hostility,
      spawnRateMultiplier: spawnMultiplier,
      eliteEscalationChance: eliteChance,
    );
  }
}
