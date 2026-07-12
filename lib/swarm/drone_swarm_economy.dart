// =============================================================================
// drone_swarm_economy.dart
//
// "Deploy and recharge" resource economy for a finite drone fleet.
//
// THE CORE IDEA: your three pools have very different performance needs, so
// they get very different representations:
//
//   - Available   -> just an int. Docked drones are fungible and invisible;
//                    there is nothing to simulate or render, so there is
//                    nothing to store per-drone.
//   - Deployed     -> a dense, contiguous SoA block (the hot path). This is
//                    the only pool the boids/movement/render code ever
//                    touches per-frame, and it is sized once for the whole
//                    game (no allocation churn).
//   - Recharging   -> fungible like Available, but each one needs an
//                    individual cooldown timer, so it's a dense *unordered*
//                    array of "ready at" timestamps -- still no positions.
//
// REMOVAL: combat loss and "reached the ship" both remove a drone from the
// Deployed array mid-frame. Both use swap-remove: copy the last live
// element's data into the removed slot and shrink the count by one. This is
// O(1), leaves zero holes, and requires no "is this slot alive" check
// during iteration -- which is exactly what you want with hundreds of
// drones on a mobile frame budget.
// =============================================================================

import 'dart:math' as math;
import 'dart:typed_data';

/// Per-drone behavioral mode while in the Deployed pool.
class DroneMode {
  /// Flying free / following the cursor / fighting -- your existing boids
  /// + cursor-seek logic drives these.
  static const int seeking = 0;
  /// Recalled: movement code should steer toward the ship's *live* position
  /// instead of the cursor. No per-drone target storage needed -- the ship
  /// moves, so we just re-read its current position every frame.
  static const int returning = 1;
  /// Left behind after an emergency warp interrupted its return trip.
  /// Motionless, no velocity, sits exactly where the warp caught it.
  static const int stranded = 2;
  /// A stranded drone an enemy hacker has taken control of. Seeks the ship
  /// like `returning`, but with damaged-thruster wobble (see `update()`).
  static const int hacked = 3;
}

/// Tunables tech upgrades mutate at runtime. Nothing else in this file
/// needs to change when you add a new upgrade -- just twiddle these.
class DeploymentConfig {
  /// "Multi-spawn" tech: how many drones leave the ship per deploy action.
  int batchSize;
  /// "Rapid-spawn" tech: minimum seconds between deploy actions. Lower = faster.
  double cooldownSeconds;
  /// How long a docked-for-recharge drone takes before rejoining Available.
  double rechargeSeconds;
  /// Initial launch speed when a drone leaves the ship (boids/seek takes
  /// over from there -- this is just the "pop out of the hangar" kick).
  double launchSpeed;
  /// Radians of random spread applied to each drone's launch heading in a
  /// multi-spawn batch, so they fan out instead of stacking exactly.
  double launchSpreadRadians;
  /// How close a returning drone must get to the ship to be considered
  /// "docked" and moved into the recharge queue.
  double arrivalRadius;
  /// Hacked-drone damaged thrusters: how fast the wobble angle randomly
  /// walks, in radians/second. Higher = more erratic.
  double wobbleJitterPerSecond;
  /// Hacked-drone wobble: how strongly the angle is pulled back toward
  /// zero each second. Higher = corrects faster, looks "twitchier" rather
  /// than "drifty." This is what keeps the wobble bounded instead of
  /// spinning the drone off in a random direction forever.
  double wobbleRestoringRate;
  /// Hard clamp on the wobble angle, radians either side of the true
  /// heading toward the ship.
  double wobbleMaxAngle;
  /// Damaged thrusters also push less hard. Multiplies launchSpeed for
  /// hacked drones only.
  double hackedSpeedMultiplier;
  /// Recovery penalty for drones acquired via hacking: their recharge
  /// duration is multiplied by this once they dock (groundwork for a
  /// future Shipyard zone that would waive or reduce it on refit).
  double refitRechargeMultiplier;

  DeploymentConfig({
    this.batchSize = 1,
    this.cooldownSeconds = 0.4,
    this.rechargeSeconds = 4.0,
    this.launchSpeed = 140.0,
    this.launchSpreadRadians = 0.35,
    this.arrivalRadius = 18.0,
    this.wobbleJitterPerSecond = 6.0,
    this.wobbleRestoringRate = 1.5,
    this.wobbleMaxAngle = math.pi / 3,
    this.hackedSpeedMultiplier = 0.7,
    this.refitRechargeMultiplier = 2.0,
  });
}

/// Owns the entire drone fleet's state machine. Allocates every array once,
/// at `maxFleetSize`, and never resizes them -- upgrades change *behavior*
/// (via [DeploymentConfig]), not array sizes.
class DroneSwarmEconomy {
  DroneSwarmEconomy({
    required this.maxFleetSize,
    DeploymentConfig? config,
    int initialHealth = 100,
  })  : config = config ?? DeploymentConfig(),
        _maxHealth = initialHealth {
    posX = Float32List(maxFleetSize);
    posY = Float32List(maxFleetSize);
    velX = Float32List(maxFleetSize);
    velY = Float32List(maxFleetSize);
    mode = Uint8List(maxFleetSize);
    health = Int16List(maxFleetSize);
    wobbleAngle = Float32List(maxFleetSize);
    needsRefit = Uint8List(maxFleetSize); // zero-initialized -> defaults to false

    rechargeReadyAt = Float64List(maxFleetSize);

    availableCount = maxFleetSize;
  }

  final int maxFleetSize;
  final DeploymentConfig config;
  final int _maxHealth;
  final math.Random _rng = math.Random();

  // ---- Deployed pool: dense SoA, indices [0, deployedCount) are always
  // valid and contiguous. This is the array your boids/render code iterates. ----
  late final Float32List posX;
  late final Float32List posY;
  late final Float32List velX;
  late final Float32List velY;
  late final Uint8List mode; // DroneMode.seeking | returning | stranded | hacked
  late final Int16List health; // optional combat hook, see applyDamage()
  late final Float32List wobbleAngle; // hacked-drone damaged-thruster state, radians
  /// Groundwork for a future Shipyard zone. 0 = false, 1 = true (no
  /// behavior of its own yet) -- set true when a drone is acquired via
  /// hacking, read once at dock-time to apply a recharge penalty, and
  /// cleared whenever a slot is reused to launch a fresh drone. No zones,
  /// no routing -- purely a data flag and a timing multiplier for now.
  late final Uint8List needsRefit;
  int deployedCount = 0;

  // ---- Available pool: pure count. ----
  int availableCount = 0;

  // ---- Recharging pool: dense, unordered timers. No positions. ----
  late final Float64List rechargeReadyAt;
  int rechargingCount = 0;

  // ---- Bookkeeping ----
  int permanentlyLostCount = 0;
  double _deployCooldownRemaining = 0;

  /// Invariant you can assert in debug builds:
  /// availableCount + deployedCount + rechargingCount + permanentlyLostCount
  ///   == maxFleetSize
  int get totalLivingFleet => availableCount + deployedCount + rechargingCount;
  bool get canDeploy => _deployCooldownRemaining <= 0 && availableCount > 0;

  // ---------------------------------------------------------------------------
  // DEPLOY (Addition)
  // ---------------------------------------------------------------------------

  /// Attempts to deploy a batch (size = config.batchSize, tech-driven) from
  /// the ship toward (targetX, targetY). Returns how many actually launched
  /// (0 if on cooldown or out of drones; may be less than batchSize if the
  /// fleet is running low).
  int tryDeploy({
    required double shipX,
    required double shipY,
    required double targetX,
    required double targetY,
  }) {
    if (_deployCooldownRemaining > 0) return 0;
    if (availableCount <= 0) return 0;

    final int n = math.min(config.batchSize, availableCount);
    for (int k = 0; k < n; k++) {
      _spawnOne(shipX, shipY, targetX, targetY);
    }
    availableCount -= n;
    _deployCooldownRemaining = config.cooldownSeconds;
    return n;
  }

  void _spawnOne(double shipX, double shipY, double targetX, double targetY) {
    final int i = deployedCount;

    posX[i] = shipX;
    posY[i] = shipY;

    final double dx = targetX - shipX;
    final double dy = targetY - shipY;
    double angle = math.atan2(dy, dx);
    // Fan multi-spawn batches out a little so they don't launch stacked.
    angle += (_rng.nextDouble() * 2 - 1) * config.launchSpreadRadians;

    velX[i] = math.cos(angle) * config.launchSpeed;
    velY[i] = math.sin(angle) * config.launchSpeed;

    mode[i] = DroneMode.seeking;
    health[i] = _maxHealth;
    wobbleAngle[i] = 0;
    needsRefit[i] = 0; // cleared on launch -- whatever slot this is, it's leaving clean

    deployedCount++;
  }

  // ---------------------------------------------------------------------------
  // RECALL (begin Return)
  // ---------------------------------------------------------------------------

  /// Flags every currently-`seeking` drone to head home. No target
  /// position is stored -- `update()` always steers returning drones
  /// toward the ship's *current* coordinates, so this stays correct even
  /// if the ship moves after recall is issued. Drones that are already
  /// `stranded` or `hacked` are deliberately untouched: they're not
  /// under your control anymore, so a fleet-wide recall can't rescue
  /// them. That's the whole point of stranding being a real cost.
  void recallAll() {
    for (int i = 0; i < deployedCount; i++) {
      if (mode[i] == DroneMode.seeking) {
        mode[i] = DroneMode.returning;
      }
    }
  }

  /// Recall a single drone (e.g. low health, or player box-selected a
  /// subset). Same guard as recallAll() -- only affects a drone that's
  /// currently `seeking`.
  void recallOne(int deployedIndex) {
    if (mode[deployedIndex] == DroneMode.seeking) {
      mode[deployedIndex] = DroneMode.returning;
    }
  }

  // ---------------------------------------------------------------------------
  // HEIST & ESCAPE
  // ---------------------------------------------------------------------------

  /// Instantly relocates every currently-`seeking` drone to (x, y) -- used
  /// when the ship itself translates (a warp jump) and its active fleet
  /// needs to arrive with it. Drones in any other mode are untouched: by
  /// the time this runs during a warp, strandUnreturnedDrones() has
  /// already swept `returning`/`hacked` drones into `stranded`, so this
  /// only ever touches genuine survivors. Velocity is zeroed too, so a
  /// teleported drone doesn't keep flying in a direction that was only
  /// ever meaningful relative to the old location.
  void teleportSeekingDronesTo(double x, double y) {
    for (int i = 0; i < deployedCount; i++) {
      if (mode[i] == DroneMode.seeking) {
        posX[i] = x;
        posY[i] = y;
        velX[i] = 0;
        velY[i] = 0;
      }
    }
  }

  /// Emergency warp: any drone still mid-flight home -- your own
  /// `returning` fleet *or* a still-inbound stolen drone -- gets left
  /// behind. They keep their current position, drop to zero velocity,
  /// and sit there (mode == stranded) until something hacks them or
  /// kills them. Drones already docked or still `seeking` are untouched.
  /// Returns how many were newly stranded, for UI feedback.
  int strandUnreturnedDrones() {
    int strandedNow = 0;
    for (int i = 0; i < deployedCount; i++) {
      if (mode[i] == DroneMode.returning || mode[i] == DroneMode.hacked) {
        mode[i] = DroneMode.stranded;
        velX[i] = 0;
        velY[i] = 0;
        strandedNow++;
      }
    }
    return strandedNow;
  }

  /// How many deployed drones would be stranded by strandUnreturnedDrones()
  /// right now -- i.e. still `returning` or `hacked`, not yet docked. Not
  /// required by the stranding logic itself; exposed purely so a UI like
  /// "3 drones still inbound" can be driven without reaching into `mode`
  /// directly.
  int countAtRiskOfStranding() {
    int count = 0;
    for (int i = 0; i < deployedCount; i++) {
      if (mode[i] == DroneMode.returning || mode[i] == DroneMode.hacked) {
        count++;
      }
    }
    return count;
  }

  /// Simulates a successful hack: any `stranded` drone within `hackRadius`
  /// of (hackX, hackY) flips to `hacked` and gets a fresh random wobble
  /// phase, so a batch of drones hacked together don't all glitch in
  /// lockstep. Returns how many were hacked, for UI feedback.
  int hackStrandedDrones(double hackX, double hackY, double hackRadius) {
    final double radiusSq = hackRadius * hackRadius;
    int hackedNow = 0;

    for (int i = 0; i < deployedCount; i++) {
      if (mode[i] != DroneMode.stranded) continue;

      final double dx = posX[i] - hackX;
      final double dy = posY[i] - hackY;
      if (dx * dx + dy * dy > radiusSq) continue;

      mode[i] = DroneMode.hacked;
      wobbleAngle[i] = (_rng.nextDouble() * 2 - 1) * config.wobbleMaxAngle;
      needsRefit[i] = 1;
      hackedNow++;
    }

    return hackedNow;
  }

  // ---------------------------------------------------------------------------
  // COMBAT LOSS (Deletion -- permanent, never re-enters Available)
  // ---------------------------------------------------------------------------

  /// Convenience hook: wire your combat system to call this on hit.
  /// Returns true if the drone died from this hit.
  bool applyDamage(int deployedIndex, int amount) {
    health[deployedIndex] -= amount;
    if (health[deployedIndex] <= 0) {
      destroyDeployed(deployedIndex);
      return true;
    }
    return false;
  }

  /// Direct kill -- use this if your combat system tracks health itself
  /// and just wants to tell the economy "this index is gone."
  void destroyDeployed(int deployedIndex) {
    _swapRemoveDeployed(deployedIndex);
    permanentlyLostCount++;
  }

  // ---------------------------------------------------------------------------
  // PER-FRAME UPDATE
  //
  // Call this once per game-loop tick, AFTER your existing boids/cursor-seek
  // movement has already integrated posX/posY/velX/velY for the Deployed
  // pool (mode == seeking drones should already be driven by your existing
  // flocking code -- this method does not touch their steering).
  //
  // What this method does add to the per-frame movement pass:
  //   - drives `returning` drones toward the ship (cheap seek, no boids
  //     weights needed -- they're going home, not flocking)
  //   - drives `hacked` drones toward the ship too, but with a bounded,
  //     mean-reverting random wobble on their heading (damaged thrusters)
  //   - leaves `stranded` drones alone entirely (zero cost, single branch)
  //   - detects arrival -> docks them (swap-remove + enqueue recharge timer)
  //   - ticks recharge timers -> promotes ready drones back to Available
  //   - ticks the deploy cooldown
  //
  // All four modes are handled in one pass over the same SoA arrays --
  // no extra arrays, no extra passes, just a per-drone branch on `mode`.
  // That's what "cache-friendly" buys you here: wobbleAngle sits in its
  // own contiguous Float32List, only read/written for the `hacked`
  // branch, but it's indexed identically to every other array so there's
  // no pointer-chasing or per-entity object to dereference.
  //
  // Folding the arrival check into the same loop your renderer/boids code
  // already runs over the Deployed array (rather than a second full pass)
  // is the recommended integration if you're hand-rolling the movement step.
  // This standalone version does its own pass for clarity.
  // ---------------------------------------------------------------------------
  void update(double dt, {required double shipX, required double shipY}) {
    if (_deployCooldownRemaining > 0) {
      _deployCooldownRemaining -= dt;
    }

    final double arrivalRadiusSq = config.arrivalRadius * config.arrivalRadius;

    // Iterate backwards: swap-remove during a backward pass is safe because
    // any element swapped into slot `i` was already visited earlier in this
    // same pass (it lived at the tail, which we pass through before we ever
    // reach index i going downward).
    for (int i = deployedCount - 1; i >= 0; i--) {
      final int m = mode[i];

      // Stranded drones are motionless and left exactly where the warp
      // caught them -- nothing to compute, nothing to touch.
      if (m == DroneMode.stranded) continue;
      // `seeking` is owned entirely by your external boids/cursor code.
      if (m != DroneMode.returning && m != DroneMode.hacked) continue;

      final double dx = shipX - posX[i];
      final double dy = shipY - posY[i];
      final double distSq = dx * dx + dy * dy;

      if (distSq <= arrivalRadiusSq) {
        _dock(i);
        continue;
      }

      double headingAngle = math.atan2(dy, dx);
      double speed = config.launchSpeed;

      if (m == DroneMode.hacked) {
        // Damaged-thruster wobble: a bounded, mean-reverting random walk
        // on the heading. The random term makes it unpredictable frame to
        // frame; the restoring term keeps pulling it back toward the true
        // heading instead of letting it spin off forever -- "drift and
        // correct" rather than "drift away."
        double w = wobbleAngle[i];
        w += (_rng.nextDouble() * 2 - 1) * config.wobbleJitterPerSecond * dt;
        w -= w * config.wobbleRestoringRate * dt;
        if (w > config.wobbleMaxAngle) {
          w = config.wobbleMaxAngle;
        } else if (w < -config.wobbleMaxAngle) {
          w = -config.wobbleMaxAngle;
        }
        wobbleAngle[i] = w;

        headingAngle += w;
        speed *= config.hackedSpeedMultiplier;
      }

      velX[i] = math.cos(headingAngle) * speed;
      velY[i] = math.sin(headingAngle) * speed;
      posX[i] += velX[i] * dt;
      posY[i] += velY[i] * dt;
    }

    // Tick recharge timers, promote anyone who's ready.
    final double now = _clockSeconds;
    for (int i = rechargingCount - 1; i >= 0; i--) {
      if (now >= rechargeReadyAt[i]) {
        _swapRemoveRecharging(i);
        availableCount++;
      }
    }
    _clockSeconds += dt;
  }

  double _clockSeconds = 0;

  void _dock(int deployedIndex) {
    double duration = config.rechargeSeconds;
    if (needsRefit[deployedIndex] == 1) {
      // Acquired via hacking -- steeper recovery before it's trustworthy
      // again. Just a multiplier on the existing timer; no separate
      // queue, no shipyard zone, nothing routing-related yet.
      duration *= config.refitRechargeMultiplier;
    }
    rechargeReadyAt[rechargingCount] = _clockSeconds + duration;
    rechargingCount++;
    _swapRemoveDeployed(deployedIndex);
  }

  // ---------------------------------------------------------------------------
  // Swap-remove primitives. O(1), no holes, no per-frame "is alive" checks
  // needed anywhere else in the codebase.
  // ---------------------------------------------------------------------------

  void _swapRemoveDeployed(int index) {
    final int last = deployedCount - 1;
    if (index != last) {
      posX[index] = posX[last];
      posY[index] = posY[last];
      velX[index] = velX[last];
      velY[index] = velY[last];
      mode[index] = mode[last];
      health[index] = health[last];
      wobbleAngle[index] = wobbleAngle[last];
      needsRefit[index] = needsRefit[last];
    }
    deployedCount--;
  }

  void _swapRemoveRecharging(int index) {
    final int last = rechargingCount - 1;
    if (index != last) {
      rechargeReadyAt[index] = rechargeReadyAt[last];
    }
    rechargingCount--;
  }
}
