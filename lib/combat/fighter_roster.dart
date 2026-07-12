// =============================================================================
// fighter_roster.dart
//
// Minimal SoA tracker for active Fighters -- piloted combat units that,
// unlike Drones, never freeze when left behind by an emergency warp.
// Mirrors the swap-remove / dense-array conventions in
// drone_swarm_economy.dart, scoped down to exactly what the warp/stranding
// interaction needs: a position per fighter and an autonomous-behavior
// flag. Actual fighter combat AI, movement, and pathfinding stay out of
// this file entirely -- this only assigns the flag; your boids/combat
// layer is what reads it and decides how, say, a LastStand fighter
// actually behaves (max aggro weight, etc.).
// =============================================================================

import 'dart:math' as math;
import 'dart:typed_data';

/// Autonomous behavior a Fighter adopts the moment it's left behind by an
/// emergency warp. Pilots/AI keep acting independently -- fighters never
/// freeze the way drones do.
class FighterAutonomousState {
  /// Still under direct player command.
  static const int piloted = 0;
  /// Attempts to calculate a delayed micro-jump to catch up with the ship.
  static const int rendezvous = 1;
  /// Pure evasive survival -- staying alive outranks every other goal.
  static const int scramble = 2;
  /// Fights to the death, pulling aggro to cover the player's escape.
  static const int lastStand = 3;
}

/// Optional per-fighter bias toward each autonomous state, e.g. driven by
/// a captain's traits. These are weights, not probabilities that need to
/// sum to 1 -- equal values (the default) mean an equal chance of each of
/// the three states.
class FighterTraits {
  final double rendezvousBias;
  final double scrambleBias;
  final double lastStandBias;

  const FighterTraits({
    this.rendezvousBias = 1.0,
    this.scrambleBias = 1.0,
    this.lastStandBias = 1.0,
  });
}

/// Per-category counts from a single stranding event, for UI feedback --
/// mirrors how DroneSwarmEconomy's methods return counts rather than void.
class FighterStrandingResult {
  final int rendezvousCount;
  final int scrambleCount;
  final int lastStandCount;

  const FighterStrandingResult({
    required this.rendezvousCount,
    required this.scrambleCount,
    required this.lastStandCount,
  });

  int get total => rendezvousCount + scrambleCount + lastStandCount;
}

class FighterRoster {
  FighterRoster({required this.maxFighterCount}) {
    posX = Float32List(maxFighterCount);
    posY = Float32List(maxFighterCount);
    autonomousState = Uint8List(maxFighterCount);
    rendezvousBias = Float32List(maxFighterCount);
    scrambleBias = Float32List(maxFighterCount);
    lastStandBias = Float32List(maxFighterCount);
    targetX = Float32List(maxFighterCount);
    targetY = Float32List(maxFighterCount);
  }

  final int maxFighterCount;
  final math.Random _rng = math.Random();

  late final Float32List posX;
  late final Float32List posY;
  /// FighterAutonomousState.* -- piloted until a warp strands the fighter.
  late final Uint8List autonomousState;
  late final Float32List rendezvousBias;
  late final Float32List scrambleBias;
  late final Float32List lastStandBias;
  /// Generic "where is this fighter currently trying to go" coordinate.
  /// Not owner-specific -- used by a player fighter's Rendezvous behavior
  /// (heading back toward the ship) just as much as by an enemy combatant
  /// spawned mid-combat (heading toward the player). Whoever spawns or
  /// directs a fighter is responsible for keeping this current; this
  /// class only stores it.
  late final Float32List targetX;
  late final Float32List targetY;
  int activeCount = 0;

  /// Registers a fighter as active (e.g. when it launches). Returns its
  /// slot index. If targetX/targetY aren't given, the fighter's initial
  /// target defaults to its own spawn position (i.e. "go nowhere yet").
  int spawnFighter(
    double x,
    double y, {
    FighterTraits traits = const FighterTraits(),
    double? targetX,
    double? targetY,
  }) {
    final int i = activeCount;
    posX[i] = x;
    posY[i] = y;
    autonomousState[i] = FighterAutonomousState.piloted;
    rendezvousBias[i] = traits.rendezvousBias;
    scrambleBias[i] = traits.scrambleBias;
    lastStandBias[i] = traits.lastStandBias;
    this.targetX[i] = targetX ?? x;
    this.targetY[i] = targetY ?? y;
    activeCount++;
    return i;
  }

  /// Updates a single fighter's target. Whoever owns this fighter's
  /// behavior (boids/combat layer, or a director like enemy_director.dart)
  /// calls this whenever the target should change.
  void setTarget(int index, double x, double y) {
    targetX[index] = x;
    targetY[index] = y;
  }

  /// Retargets every currently-active fighter to the same point in one
  /// call -- the common case for a roster that exists purely to chase a
  /// single point (e.g. an enemy-only roster where every fighter's whole
  /// purpose is hunting the player).
  void retargetAllTo(double x, double y) {
    for (int i = 0; i < activeCount; i++) {
      targetX[i] = x;
      targetY[i] = y;
    }
  }

  /// Combat loss hook, mirroring DroneSwarmEconomy.destroyDeployed().
  void destroyFighter(int index) {
    _swapRemove(index);
  }

  /// Instantly relocates every currently-`piloted` fighter to (x, y) --
  /// the fighter-roster equivalent of
  /// DroneSwarmEconomy.teleportSeekingDronesTo(). Fighters already
  /// stranded into an autonomous state are untouched -- they were left
  /// behind, they don't jump with the ship.
  void teleportPilotedFightersTo(double x, double y) {
    for (int i = 0; i < activeCount; i++) {
      if (autonomousState[i] == FighterAutonomousState.piloted) {
        posX[i] = x;
        posY[i] = y;
      }
    }
  }

  void _swapRemove(int index) {
    final int last = activeCount - 1;
    if (index != last) {
      posX[index] = posX[last];
      posY[index] = posY[last];
      autonomousState[index] = autonomousState[last];
      rendezvousBias[index] = rendezvousBias[last];
      scrambleBias[index] = scrambleBias[last];
      lastStandBias[index] = lastStandBias[last];
      targetX[index] = targetX[last];
      targetY[index] = targetY[last];
    }
    activeCount--;
  }

  /// Called the instant the ship warps. Every fighter still `piloted`
  /// rolls into one of the three autonomous states, weighted by its
  /// traits. Unlike drones, fighters are NEVER removed from this roster
  /// here -- they keep existing and simulating, they just stop taking
  /// direct orders. Returns per-category counts for UI feedback.
  FighterStrandingResult strandActiveFighters() {
    int rendezvousCount = 0;
    int scrambleCount = 0;
    int lastStandCount = 0;

    for (int i = 0; i < activeCount; i++) {
      if (autonomousState[i] != FighterAutonomousState.piloted) continue;

      final double rBias = rendezvousBias[i];
      final double sBias = scrambleBias[i];
      final double total = rBias + sBias + lastStandBias[i];

      // Degenerate case (all biases zeroed out): fall back to an even
      // three-way split instead of dividing by zero.
      final bool degenerate = total <= 0;
      final double roll = _rng.nextDouble() * (degenerate ? 3.0 : total);
      final double rCut = degenerate ? 1.0 : rBias;
      final double sCut = degenerate ? 2.0 : rBias + sBias;

      if (roll < rCut) {
        autonomousState[i] = FighterAutonomousState.rendezvous;
        rendezvousCount++;
      } else if (roll < sCut) {
        autonomousState[i] = FighterAutonomousState.scramble;
        scrambleCount++;
      } else {
        autonomousState[i] = FighterAutonomousState.lastStand;
        lastStandCount++;
      }
    }

    return FighterStrandingResult(
      rendezvousCount: rendezvousCount,
      scrambleCount: scrambleCount,
      lastStandCount: lastStandCount,
    );
  }

  /// Indices (into this roster's own dense arrays) currently in `state`.
  /// Recomputed on demand rather than cached: stranding is a rare event
  /// and active fighter counts are small (squadrons, not swarms), so this
  /// is cheap enough to call straight from a UI binding without needing
  /// its own change-tracking.
  List<int> indicesInState(int state) {
    final List<int> result = [];
    for (int i = 0; i < activeCount; i++) {
      if (autonomousState[i] == state) result.add(i);
    }
    return result;
  }
}
