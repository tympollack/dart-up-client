// =============================================================================
// cast_ledger_emitter.dart
//
// Pure-Dart Cast Ledger emitter producing structured `ActionIntentDelta`
// records for high-drama sector events: alliances formed, betrayals, Star Dart
// steals, and bounty triggers.
// Zero Flutter or Flame imports.
// =============================================================================

/// Categories of high-value narrative/diplomatic actions recorded in the Cast Ledger.
enum ActionIntentType {
  allianceFormed,
  betrayal,
  starDartSteal,
  bountyTriggered,
}

/// Structured Action-Intent Delta record for telemetry and SunShade Hub Cast Ledger sync.
class ActionIntentDelta {
  final int sequenceId;
  final ActionIntentType type;
  final String actorPlayerId;
  final String? targetPlayerId;
  final double timestamp;
  final double sectorX;
  final double sectorY;
  final Map<String, Object?> payload;

  const ActionIntentDelta({
    required this.sequenceId,
    required this.type,
    required this.actorPlayerId,
    required this.timestamp,
    required this.sectorX,
    required this.sectorY,
    this.targetPlayerId,
    this.payload = const {},
  });

  Map<String, Object?> toJson() => {
        'sequenceId': sequenceId,
        'type': type.name,
        'actorPlayerId': actorPlayerId,
        'targetPlayerId': targetPlayerId,
        'timestamp': timestamp,
        'sectorX': sectorX,
        'sectorY': sectorY,
        'payload': payload,
      };
}

/// Pure-Dart emitter and buffer for Cast Ledger [ActionIntentDelta] events.
class CastLedgerEmitter {
  CastLedgerEmitter({this.onDeltaEmitted});

  final void Function(ActionIntentDelta delta)? onDeltaEmitted;

  int _nextSequenceId = 1;
  final List<ActionIntentDelta> _ledger = [];

  List<ActionIntentDelta> get ledger => List.unmodifiable(_ledger);

  ActionIntentDelta emitAllianceFormed({
    required String initiatorPlayerId,
    required String partnerPlayerId,
    required double timestamp,
    double sectorX = 0.0,
    double sectorY = 0.0,
    String? pactName,
  }) {
    return _emit(
      type: ActionIntentType.allianceFormed,
      actorPlayerId: initiatorPlayerId,
      targetPlayerId: partnerPlayerId,
      timestamp: timestamp,
      sectorX: sectorX,
      sectorY: sectorY,
      payload: {
        'pactName': ?pactName,
      },
    );
  }

  ActionIntentDelta emitBetrayal({
    required String betrayerPlayerId,
    required String victimPlayerId,
    required double timestamp,
    double sectorX = 0.0,
    double sectorY = 0.0,
    double damageDealt = 0.0,
  }) {
    return _emit(
      type: ActionIntentType.betrayal,
      actorPlayerId: betrayerPlayerId,
      targetPlayerId: victimPlayerId,
      timestamp: timestamp,
      sectorX: sectorX,
      sectorY: sectorY,
      payload: {'damageDealt': damageDealt},
    );
  }

  ActionIntentDelta emitStarDartSteal({
    required String thiefPlayerId,
    required String previousTetherPlayerId,
    required String bossId,
    required double timestamp,
    required double sectorX,
    required double sectorY,
  }) {
    return _emit(
      type: ActionIntentType.starDartSteal,
      actorPlayerId: thiefPlayerId,
      targetPlayerId: previousTetherPlayerId,
      timestamp: timestamp,
      sectorX: sectorX,
      sectorY: sectorY,
      payload: {'bossId': bossId},
    );
  }

  ActionIntentDelta emitBountyTriggered({
    required String targetPlayerId,
    required int bountyCredits,
    required String reason,
    required double timestamp,
    String issuerId = 'sector-authority',
    double sectorX = 0.0,
    double sectorY = 0.0,
  }) {
    return _emit(
      type: ActionIntentType.bountyTriggered,
      actorPlayerId: issuerId,
      targetPlayerId: targetPlayerId,
      timestamp: timestamp,
      sectorX: sectorX,
      sectorY: sectorY,
      payload: {
        'bountyCredits': bountyCredits,
        'reason': reason,
      },
    );
  }

  ActionIntentDelta _emit({
    required ActionIntentType type,
    required String actorPlayerId,
    required double timestamp,
    required double sectorX,
    required double sectorY,
    String? targetPlayerId,
    Map<String, Object?> payload = const {},
  }) {
    final delta = ActionIntentDelta(
      sequenceId: _nextSequenceId++,
      type: type,
      actorPlayerId: actorPlayerId,
      targetPlayerId: targetPlayerId,
      timestamp: timestamp,
      sectorX: sectorX,
      sectorY: sectorY,
      payload: Map.unmodifiable(payload),
    );
    _ledger.add(delta);
    onDeltaEmitted?.call(delta);
    return delta;
  }
}
