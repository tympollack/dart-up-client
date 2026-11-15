// =============================================================================
// star_dart_state_machine.dart
//
// Pure-Dart state machine for the capturable Star Dart boss entity, repair-
// tether vulnerability windows, sector-wide 'Dart Up!' ambush chase pings,
// and the server-wide EarthCataclysmProtocol siege escalation.
// Zero Flutter or Flame imports.
// =============================================================================

import 'dart:math' as math;

/// Lifecycle states of the capturable Star Dart boss entity.
enum StarDartBossState {
  /// Roaming the sector with active shields.
  roaming,

  /// Shields depleted; hull is exposed to direct damage.
  shieldBreached,

  /// Hull reduced to zero; adrift as a crippled derelict awaiting repair/capture.
  crippledDerelict,

  /// A player ship is tethered and performing field repair/capture.
  /// The capturing ship is locked into a vulnerable window while a sector-wide
  /// `DartUpChaseAlert` ('Dart Up!') is broadcast to nearby hunters.
  repairCaptureInProgress,

  /// A rival hunter ambushed an in-progress repair capture, breaking the tether.
  contestedAmbush,

  /// Derelict window expired before capture completed; the boss jumped away.
  escapedJump,

  /// Field repair/capture completed; ownership transferred to the capturing player.
  captured,

  /// Deep-sector coordinates breached, triggering the server-wide Earth Cataclysm
  /// Protocol siege alert.
  earthCataclysmAlert,
}

/// Configuration tunables for the Star Dart boss encounter and capture loop.
class StarDartConfig {
  final double maxShields;
  final double maxHull;

  /// Seconds a player must maintain an uninterrupted repair tether to capture
  /// a crippled Star Dart.
  final double captureDurationSeconds;

  /// Seconds a crippled Star Dart stays derelict before executing an emergency
  /// `escapedJump` if not tethered.
  final double derelictEscapeTimeoutSeconds;

  /// Duration (seconds) of the `contestedAmbush` lock-out reset before a new
  /// repair tether can be established (can be 0.0 for immediate seizure).
  final double ambushCooldownSeconds;

  /// Distance from sector origin `(0, 0)` beyond which breaching triggers the
  /// server-wide [EarthCataclysmProtocol].
  final double deepSectorBreachRadius;

  const StarDartConfig({
    this.maxShields = 500.0,
    this.maxHull = 1000.0,
    this.captureDurationSeconds = 15.0,
    this.derelictEscapeTimeoutSeconds = 30.0,
    this.ambushCooldownSeconds = 2.0,
    this.deepSectorBreachRadius = 5000.0,
  });
}

/// Sector-wide broadcast ping emitted the instant a player initiates field
/// repair/capture on a crippled Star Dart.
class DartUpChaseAlert {
  final String bossId;
  final String capturingPlayerId;
  final double x;
  final double y;
  final double captureDurationSeconds;
  final double timestamp;
  final String message;

  const DartUpChaseAlert({
    required this.bossId,
    required this.capturingPlayerId,
    required this.x,
    required this.y,
    required this.captureDurationSeconds,
    required this.timestamp,
    this.message = 'Dart Up! Star Dart repair tether active — ambush window open!',
  });
}

/// Server-wide siege alert payload emitted when deep-sector coordinates are
/// breached.
class EarthCataclysmProtocol {
  final String bossId;
  final String? triggeringPlayerId;
  final double breachX;
  final double breachY;
  final int siegeAlertLevel;
  final double timestamp;

  const EarthCataclysmProtocol({
    required this.bossId,
    required this.breachX,
    required this.breachY,
    required this.siegeAlertLevel,
    required this.timestamp,
    this.triggeringPlayerId,
  });
}

/// Pure-Dart finite state machine governing the Star Dart boss entity.
class StarDartStateMachine {
  StarDartStateMachine({
    this.bossId = 'star-dart-prime',
    StarDartConfig? config,
    double initialX = 0.0,
    double initialY = 0.0,
    this.onStateChanged,
    this.onChaseAlertBroadcast,
    this.onAmbushInterrupted,
    this.onBossCaptured,
    this.onEarthCataclysmTriggered,
  })  : config = config ?? const StarDartConfig(),
        _x = initialX,
        _y = initialY {
    _shields = this.config.maxShields;
    _hull = this.config.maxHull;
    if (math.sqrt(_x * _x + _y * _y) >= this.config.deepSectorBreachRadius) {
      triggerEarthCataclysmProtocol();
    }
  }

  final String bossId;
  final StarDartConfig config;

  final void Function(StarDartBossState previous, StarDartBossState current)?
      onStateChanged;
  final void Function(DartUpChaseAlert alert)? onChaseAlertBroadcast;
  final void Function(String interruptedPlayerId, String ambusherPlayerId)?
      onAmbushInterrupted;
  final void Function(String capturedByPlayerId)? onBossCaptured;
  final void Function(EarthCataclysmProtocol protocol)?
      onEarthCataclysmTriggered;

  StarDartBossState _state = StarDartBossState.roaming;
  double _x;
  double _y;
  late double _shields;
  late double _hull;

  double _simulationTime = 0.0;
  double _captureRemainingSeconds = 0.0;
  double _derelictEscapeRemainingSeconds = 0.0;
  double _ambushCooldownRemaining = 0.0;

  String? _tetheredPlayerId;
  String? _capturedByPlayerId;
  bool _capturingShipVulnerableLock = false;

  bool _earthCataclysmActive = false;
  int _globalSiegeAlertLevel = 0;

  final List<DartUpChaseAlert> _chaseAlerts = [];
  final List<EarthCataclysmProtocol> _cataclysmEvents = [];

  // ---------------------------------------------------------------------------
  // Read-only state
  // ---------------------------------------------------------------------------

  StarDartBossState get state => _state;
  double get x => _x;
  double get y => _y;
  double get shields => _shields;
  double get hull => _hull;
  double get simulationTime => _simulationTime;

  double get captureRemainingSeconds => _captureRemainingSeconds;
  double get derelictEscapeRemainingSeconds => _derelictEscapeRemainingSeconds;
  double get ambushCooldownRemaining => _ambushCooldownRemaining;

  /// Normalized `[0.0, 1.0]` progress of the active repair/capture tether.
  double get captureProgress {
    if (_state != StarDartBossState.repairCaptureInProgress ||
        config.captureDurationSeconds <= 0) {
      return 0.0;
    }
    return (1.0 - (_captureRemainingSeconds / config.captureDurationSeconds))
        .clamp(0.0, 1.0);
  }

  String? get tetheredPlayerId => _tetheredPlayerId;
  String? get capturedByPlayerId => _capturedByPlayerId;

  /// True while a player ship is locked into a vulnerable `repairCaptureInProgress`
  /// tether window.
  bool get isCapturingShipVulnerableLock => _capturingShipVulnerableLock;

  bool get isCrippled =>
      _state == StarDartBossState.crippledDerelict ||
      _state == StarDartBossState.contestedAmbush;
  bool get isRepairTethered =>
      _state == StarDartBossState.repairCaptureInProgress;
  bool get isCaptured => _state == StarDartBossState.captured;
  bool get isEarthCataclysmActive => _earthCataclysmActive;
  int get globalSiegeAlertLevel => _globalSiegeAlertLevel;

  List<DartUpChaseAlert> get chaseAlerts => List.unmodifiable(_chaseAlerts);
  List<EarthCataclysmProtocol> get cataclysmEvents =>
      List.unmodifiable(_cataclysmEvents);

  // ---------------------------------------------------------------------------
  // Movement & Deep-Sector Cataclysm Detection
  // ---------------------------------------------------------------------------

  /// Moves the Star Dart to `(newX, newY)`. If the coordinates breach
  /// [config.deepSectorBreachRadius], triggers the server-wide
  /// [EarthCataclysmProtocol].
  void setPosition(
    double newX,
    double newY, {
    String? triggeringPlayerId,
  }) {
    final prevDist = math.sqrt(_x * _x + _y * _y);
    _x = newX;
    _y = newY;
    final dist = math.sqrt(_x * _x + _y * _y);
    final wasInside = prevDist < config.deepSectorBreachRadius;
    if (dist >= config.deepSectorBreachRadius &&
        (wasInside || !_earthCataclysmActive)) {
      triggerEarthCataclysmProtocol(triggeringPlayerId: triggeringPlayerId);
    }
  }

  /// Triggers or escalates the server-wide [EarthCataclysmProtocol].
  EarthCataclysmProtocol triggerEarthCataclysmProtocol({
    String? triggeringPlayerId,
    bool transitionBossState = true,
  }) {
    _earthCataclysmActive = true;
    _globalSiegeAlertLevel++;

    if (transitionBossState &&
        (_state == StarDartBossState.roaming ||
            _state == StarDartBossState.shieldBreached ||
            _state == StarDartBossState.earthCataclysmAlert)) {
      _transitionTo(StarDartBossState.earthCataclysmAlert);
    }

    final protocol = EarthCataclysmProtocol(
      bossId: bossId,
      triggeringPlayerId: triggeringPlayerId ?? _capturedByPlayerId ?? _tetheredPlayerId,
      breachX: _x,
      breachY: _y,
      siegeAlertLevel: _globalSiegeAlertLevel,
      timestamp: _simulationTime,
    );
    _cataclysmEvents.add(protocol);
    onEarthCataclysmTriggered?.call(protocol);
    return protocol;
  }

  // ---------------------------------------------------------------------------
  // Combat & State Transitions
  // ---------------------------------------------------------------------------

  /// Applies combat damage to the Star Dart while in `roaming`,
  /// `shieldBreached`, or `earthCataclysmAlert`.
  /// Transitions `roaming -> shieldBreached` when shields hit 0, and
  /// `-> crippledDerelict` when hull hits 0.
  bool applyDamage(double amount) {
    if (amount <= 0) return false;
    if (_state != StarDartBossState.roaming &&
        _state != StarDartBossState.shieldBreached &&
        _state != StarDartBossState.earthCataclysmAlert) {
      return false;
    }

    double remaining = amount;
    if (_shields > 0) {
      final absorbed = math.min(_shields, remaining);
      _shields -= absorbed;
      remaining -= absorbed;
      if (_shields <= 0) {
        _shields = 0;
        if (_state == StarDartBossState.roaming) {
          _transitionTo(StarDartBossState.shieldBreached);
        }
      }
    }

    if (remaining > 0 && _hull > 0) {
      _hull = math.max(0.0, _hull - remaining);
      if (_hull <= 0) {
        _hull = 0;
        _derelictEscapeRemainingSeconds = config.derelictEscapeTimeoutSeconds;
        _transitionTo(StarDartBossState.crippledDerelict);
      }
    }

    return true;
  }

  /// Initiates field repair/capture on a crippled Star Dart.
  /// - Valid only from `crippledDerelict` (or `contestedAmbush` once cooldown is 0).
  /// - Locks the capturing player's ship into a vulnerable window.
  /// - Emits a sector-wide [DartUpChaseAlert] ('Dart Up!').
  bool beginRepairCapture(String playerId) {
    if (_state == StarDartBossState.contestedAmbush &&
        _ambushCooldownRemaining <= 0) {
      // Allow re-tethering after ambush cooldown expires
    } else if (_state != StarDartBossState.crippledDerelict) {
      return false;
    }

    _tetheredPlayerId = playerId;
    _capturingShipVulnerableLock = true;
    _captureRemainingSeconds = config.captureDurationSeconds;
    _transitionTo(StarDartBossState.repairCaptureInProgress);

    final alert = DartUpChaseAlert(
      bossId: bossId,
      capturingPlayerId: playerId,
      x: _x,
      y: _y,
      captureDurationSeconds: config.captureDurationSeconds,
      timestamp: _simulationTime,
    );
    _chaseAlerts.add(alert);
    onChaseAlertBroadcast?.call(alert);
    return true;
  }

  /// Interrupts an active `repairCaptureInProgress` when a rival hunter ambushes
  /// the vulnerable capturing ship.
  /// Resets the capture timer, releases the vulnerable lock on the previous
  /// player, and transitions to `contestedAmbush` (or `crippledDerelict` if
  /// `config.ambushCooldownSeconds <= 0`).
  bool triggerAmbushInterruption({required String ambusherPlayerId}) {
    if (_state != StarDartBossState.repairCaptureInProgress) {
      return false;
    }

    final previousPlayer = _tetheredPlayerId ?? 'unknown';
    _tetheredPlayerId = null;
    _capturingShipVulnerableLock = false;
    _captureRemainingSeconds = config.captureDurationSeconds;
    _ambushCooldownRemaining = config.ambushCooldownSeconds;
    _derelictEscapeRemainingSeconds = config.derelictEscapeTimeoutSeconds;

    if (config.ambushCooldownSeconds > 0) {
      _transitionTo(StarDartBossState.contestedAmbush);
    } else {
      _transitionTo(StarDartBossState.crippledDerelict);
    }

    onAmbushInterrupted?.call(previousPlayer, ambusherPlayerId);
    return true;
  }

  /// Advances deterministic capture, ambush cooldown, and derelict escape timers.
  void update(double dt) {
    if (dt <= 0) return;
    _simulationTime += dt;

    if (_state == StarDartBossState.repairCaptureInProgress) {
      _captureRemainingSeconds -= dt;
      if (_captureRemainingSeconds <= 0) {
        _captureRemainingSeconds = 0.0;
        _capturedByPlayerId = _tetheredPlayerId;
        _capturingShipVulnerableLock = false;
        _hull = config.maxHull * 0.5; // Field-repaired operational hull
        _shields = config.maxShields * 0.5;
        _transitionTo(StarDartBossState.captured);
        if (_capturedByPlayerId != null) {
          onBossCaptured?.call(_capturedByPlayerId!);
        }
      }
      return;
    }

    if (_state == StarDartBossState.contestedAmbush) {
      final prevCooldown = _ambushCooldownRemaining;
      _ambushCooldownRemaining -= dt;
      if (_ambushCooldownRemaining <= 0) {
        final leftoverDt = dt - math.max(0.0, prevCooldown);
        _ambushCooldownRemaining = 0.0;
        _transitionTo(StarDartBossState.crippledDerelict);
        if (leftoverDt > 0) {
          _derelictEscapeRemainingSeconds -= leftoverDt;
          if (_derelictEscapeRemainingSeconds <= 0) {
            _derelictEscapeRemainingSeconds = 0.0;
            _transitionTo(StarDartBossState.escapedJump);
          }
        }
      }
      return;
    }

    if (_state == StarDartBossState.crippledDerelict) {
      _derelictEscapeRemainingSeconds -= dt;
      if (_derelictEscapeRemainingSeconds <= 0) {
        _derelictEscapeRemainingSeconds = 0.0;
        _transitionTo(StarDartBossState.escapedJump);
      }
    }
  }

  void _transitionTo(StarDartBossState next) {
    if (_state == next) return;
    final prev = _state;
    _state = next;
    onStateChanged?.call(prev, next);
  }
}
