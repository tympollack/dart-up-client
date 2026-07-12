// =============================================================================
// combat_manager.dart
//
// Pure Dart, engine-agnostic. Hitscan combat resolution -- no projectile
// objects, no physical bullet travel. Every "attack" is resolved as an
// instantaneous distance/cooldown/hit-roll check within a single
// update(dt) call; Flame only ever finds out about it after the fact,
// through onDamageDealt, to draw whatever instant-travel VFX it wants.
//
// SYNCHRONIZATION NOTE -- read this before touching enemyHealth or
// enemyAttackCooldown: those two arrays are NOT owned by FighterRoster,
// but they MUST stay index-aligned with it, because FighterRoster's own
// swap-remove (destroyFighter()) has no idea these parallel arrays exist
// and cannot keep them in sync on its own. This file handles both
// directions of that problem itself:
//   - On removal: _destroyEnemyFighter() mirrors FighterRoster's own
//     swap on enemyHealth/enemyAttackCooldown using the same index/last
//     pair, BEFORE calling enemyFighterRoster.destroyFighter() (which
//     does the equivalent swap on posX/posY/etc. and then shrinks
//     activeCount). Get the order of these two swaps right and they stay
//     in lockstep; get it wrong and slot `index` ends up holding mixed
//     data from two different fighters.
//   - On spawn: FighterRoster.spawnFighter() always appends at the END
//     of the active range (index = activeCount, then activeCount++) --
//     it never reuses a gap. So at the top of update(), comparing
//     enemyFighterRoster.activeCount against what it was at the end of
//     the previous tick tells us exactly which indices are brand new
//     this tick, and we initialize their health/cooldown there. No
//     explicit "I just spawned a fighter" call is needed from
//     EnemyDirector -- this is detected automatically, but it depends
//     entirely on FighterRoster never changing that append-only-at-the-
//     end spawn behavior.
// =============================================================================

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:sd_client/swarm/drone_swarm_economy.dart';
import 'package:sd_client/combat/fighter_roster.dart';
import 'package:sd_client/player/ship_warp_controller.dart';

/// Tunables for player-drone point-defense (the "swarm shield"). Mutable,
/// same bundling pattern as everywhere else in this project.
class PointDefenseConfig {
  /// "Immediate radius" around each seeking drone that chips enemy
  /// fighters passing through it.
  double radius;
  /// Damage per second, PER overlapping drone -- a fighter surrounded by
  /// 5 drones takes 5x the chip damage of one surrounded by 1. This is
  /// what makes swarm size matter for defense, not just offense.
  double chipDamagePerSecond;

  PointDefenseConfig({
    this.radius = 40.0,
    this.chipDamagePerSecond = 8.0,
  });
}

/// Tunables for enemy fighters' attacks on the player ship.
class EnemyWeaponConfig {
  double weaponRange;
  double cooldownSeconds;
  /// 0 -> 1.
  double hitChance;
  double damage;

  EnemyWeaponConfig({
    this.weaponRange = 220.0,
    this.cooldownSeconds = 1.5,
    this.hitChance = 0.6,
    this.damage = 6.0,
  });
}

/// Tunables for the player ship's own auto-turret. Deliberately just a
/// mutable bundle of numbers: "modular" here means ship-tier progression
/// (T0 solo pilot -> T5 capital ship) is just swapping in bigger numbers
/// through this same config, not a different code path per tier.
class ShipTurretConfig {
  double range;
  double cooldownSeconds;
  double hitChance;
  double damage;

  ShipTurretConfig({
    this.range = 300.0,
    this.cooldownSeconds = 0.8,
    this.hitChance = 0.75,
    this.damage = 10.0,
  });
}

enum CombatHitSource { enemyFighterOnShip, dronePointDefense, shipTurret }

/// Bundled into onDamageDealt -- a small enrichment over the literal
/// four-coordinate ask (damage amount + source tag), same convention as
/// every other result class in this project (HackResult,
/// WarpCompleteResult, FighterStrandingResult).
class CombatHitEvent {
  final double sourceX;
  final double sourceY;
  final double targetX;
  final double targetY;
  final double damage;
  final CombatHitSource source;

  const CombatHitEvent({
    required this.sourceX,
    required this.sourceY,
    required this.targetX,
    required this.targetY,
    required this.damage,
    required this.source,
  });
}

class CombatManager {
  CombatManager({
    required this.economy,
    required this.enemyFighterRoster,
    required this.playerShipController,
    PointDefenseConfig? pointDefenseConfig,
    EnemyWeaponConfig? enemyWeaponConfig,
    ShipTurretConfig? shipTurretConfig,
    this.defaultEnemyFighterHealth = 40.0,
    this.onDamageDealt,
  })  : pointDefenseConfig = pointDefenseConfig ?? PointDefenseConfig(),
        enemyWeaponConfig = enemyWeaponConfig ?? EnemyWeaponConfig(),
        shipTurretConfig = shipTurretConfig ?? ShipTurretConfig() {
    final int cap = enemyFighterRoster.maxFighterCount;
    enemyHealth = Float32List(cap);
    enemyAttackCooldown = Float32List(cap);
  }

  /// Player's own drones -- read-only from this file's perspective,
  /// used only to find `seeking`-mode drones for point-defense.
  final DroneSwarmEconomy economy;
  /// The Director's OWN roster (pass in `director.enemyFighterRoster`,
  /// not the Director itself -- this file has no need to know what an
  /// EnemyDirector is).
  final FighterRoster enemyFighterRoster;
  final ShipWarpController playerShipController;

  final PointDefenseConfig pointDefenseConfig;
  final EnemyWeaponConfig enemyWeaponConfig;
  final ShipTurretConfig shipTurretConfig;

  /// Starting health for a newly-detected enemy fighter. See the
  /// auto-spawn-detection note in the file header.
  double defaultEnemyFighterHealth;

  /// Fires once per successful hit, from ANY source. Flame listens here
  /// to draw instant laser flashes/impact sprites -- no physical
  /// projectile ever exists for it to track.
  final void Function(CombatHitEvent event)? onDamageDealt;

  final math.Random _rng = math.Random();

  /// Parallel to enemyFighterRoster's own arrays. MUST stay index-
  /// aligned with it -- see the file header before modifying anything
  /// that touches these.
  late final Float32List enemyHealth;
  late final Float32List enemyAttackCooldown;

  int _previousEnemyActiveCount = 0;
  double _shipTurretCooldown = 0;

  // ---------------------------------------------------------------------------
  // Per-frame update
  // ---------------------------------------------------------------------------

  void update(double dt, {required double playerX, required double playerY}) {
    _initializeNewlySpawnedFighters();

    _resolveEnemyFighterAttacks(dt, playerX, playerY);
    _resolveSwarmPointDefense(dt);
    _resolveShipTurret(dt, playerX, playerY);

    // Resync AFTER this tick's deaths, so next tick's spawn-detection
    // compares against the true post-death count, not a stale
    // pre-death one. See the file header for why this matters.
    _previousEnemyActiveCount = enemyFighterRoster.activeCount;
  }

  void _initializeNewlySpawnedFighters() {
    final int currentActiveCount = enemyFighterRoster.activeCount;
    for (int i = _previousEnemyActiveCount; i < currentActiveCount; i++) {
      enemyHealth[i] = defaultEnemyFighterHealth;
      enemyAttackCooldown[i] = 0;
    }
  }

  // ---------------------------------------------------------------------------
  // Rule 3: enemy fighters attacking the player ship
  // ---------------------------------------------------------------------------

  void _resolveEnemyFighterAttacks(double dt, double playerX, double playerY) {
    final double rangeSq = enemyWeaponConfig.weaponRange * enemyWeaponConfig.weaponRange;

    for (int i = 0; i < enemyFighterRoster.activeCount; i++) {
      if (enemyAttackCooldown[i] > 0) {
        enemyAttackCooldown[i] -= dt;
      }

      final double dx = playerX - enemyFighterRoster.posX[i];
      final double dy = playerY - enemyFighterRoster.posY[i];
      if (dx * dx + dy * dy > rangeSq) continue;
      if (enemyAttackCooldown[i] > 0) continue;

      enemyAttackCooldown[i] = enemyWeaponConfig.cooldownSeconds;

      if (_rng.nextDouble() >= enemyWeaponConfig.hitChance) continue; // miss

      playerShipController.applyIncomingDamage(enemyWeaponConfig.damage);

      _fireDamageEvent(
        sourceX: enemyFighterRoster.posX[i],
        sourceY: enemyFighterRoster.posY[i],
        targetX: playerX,
        targetY: playerY,
        damage: enemyWeaponConfig.damage,
        source: CombatHitSource.enemyFighterOnShip,
      );

      // Rule 3: shields (shipEnergy) bottoming out flags the hull
      // critical. This is a policy decision made HERE, not inside
      // ShipWarpController.applyIncomingDamage() -- that method just
      // moves the number.
      if (playerShipController.shipEnergy <= 0) {
        playerShipController.setHullCritical(true);
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Rule 4: swarm point-defense
  // ---------------------------------------------------------------------------

  void _resolveSwarmPointDefense(double dt) {
    final double radiusSq = pointDefenseConfig.radius * pointDefenseConfig.radius;

    // Backwards, so a fighter that dies mid-pass (swap-remove) never
    // disturbs an index we haven't processed yet this pass.
    for (int e = enemyFighterRoster.activeCount - 1; e >= 0; e--) {
      final double ex = enemyFighterRoster.posX[e];
      final double ey = enemyFighterRoster.posY[e];

      // O(activeEnemyFighters x deployedDrones) -- at these scales
      // (tens of fighters, up to a few hundred drones) this is a few
      // thousand checks per tick at worst, trivial on mobile. The
      // spatial hash in swarm_isolate.dart exists because THAT loop is
      // O(1500^2) territory; this one never gets close.
      int overlappingDrones = 0;
      for (int d = 0; d < economy.deployedCount; d++) {
        if (economy.mode[d] != DroneMode.seeking) continue;
        final double dx = economy.posX[d] - ex;
        final double dy = economy.posY[d] - ey;
        if (dx * dx + dy * dy <= radiusSq) {
          overlappingDrones++;
        }
      }

      if (overlappingDrones == 0) continue;

      final double damage =
          pointDefenseConfig.chipDamagePerSecond * overlappingDrones * dt;
      enemyHealth[e] -= damage;

      // There's no single "source" drone for a swarm effect -- using the
      // fighter's own position for both source and target is the
      // sensible approximation for "being chipped away from all sides."
      _fireDamageEvent(
        sourceX: ex,
        sourceY: ey,
        targetX: ex,
        targetY: ey,
        damage: damage,
        source: CombatHitSource.dronePointDefense,
      );

      if (enemyHealth[e] <= 0) {
        _destroyEnemyFighter(e);
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Rule 5: player ship auto-turret
  // ---------------------------------------------------------------------------

  void _resolveShipTurret(double dt, double playerX, double playerY) {
    if (_shipTurretCooldown > 0) {
      _shipTurretCooldown -= dt;
      return;
    }

    final int nearest = _findNearestEnemyFighter(playerX, playerY, shipTurretConfig.range);
    if (nearest < 0) return;

    _shipTurretCooldown = shipTurretConfig.cooldownSeconds;

    if (_rng.nextDouble() >= shipTurretConfig.hitChance) return; // miss

    enemyHealth[nearest] -= shipTurretConfig.damage;

    _fireDamageEvent(
      sourceX: playerX,
      sourceY: playerY,
      targetX: enemyFighterRoster.posX[nearest],
      targetY: enemyFighterRoster.posY[nearest],
      damage: shipTurretConfig.damage,
      source: CombatHitSource.shipTurret,
    );

    if (enemyHealth[nearest] <= 0) {
      _destroyEnemyFighter(nearest);
    }
  }

  int _findNearestEnemyFighter(double x, double y, double maxRange) {
    final double maxRangeSq = maxRange * maxRange;
    int nearestIndex = -1;
    double nearestDistSq = double.infinity;

    for (int i = 0; i < enemyFighterRoster.activeCount; i++) {
      final double dx = enemyFighterRoster.posX[i] - x;
      final double dy = enemyFighterRoster.posY[i] - y;
      final double distSq = dx * dx + dy * dy;
      if (distSq <= maxRangeSq && distSq < nearestDistSq) {
        nearestDistSq = distSq;
        nearestIndex = i;
      }
    }
    return nearestIndex;
  }

  // ---------------------------------------------------------------------------
  // Removal -- see the file header before changing this.
  // ---------------------------------------------------------------------------

  void _destroyEnemyFighter(int index) {
    final int last = enemyFighterRoster.activeCount - 1;
    if (index != last) {
      enemyHealth[index] = enemyHealth[last];
      enemyAttackCooldown[index] = enemyAttackCooldown[last];
    }
    // This call performs FighterRoster's OWN swap on posX/posY/etc. using
    // the same index/last pair, then shrinks activeCount. Doing our swap
    // above FIRST, with activeCount still at its pre-removal value, is
    // what keeps both swaps using the same "last" -- reorder these two
    // steps and slot `index` ends up with mismatched data.
    enemyFighterRoster.destroyFighter(index);
  }

  void _fireDamageEvent({
    required double sourceX,
    required double sourceY,
    required double targetX,
    required double targetY,
    required double damage,
    required CombatHitSource source,
  }) {
    onDamageDealt?.call(CombatHitEvent(
      sourceX: sourceX,
      sourceY: sourceY,
      targetX: targetX,
      targetY: targetY,
      damage: damage,
      source: source,
    ));
  }
}
