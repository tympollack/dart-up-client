// =============================================================================
// player_interaction_model.dart
//
// Engine-agnostic, pure-Dart controller modeling Tier 0 manual target locking
// (drag/tap focus timers for attack/repair/harvest) and Tier 1+ autonomous
// robotics dispatch unlocked via player tech flags, with upgrade modifiers
// (interactionRadius, focusTimeMultiplier).
// Zero Flutter or Flame imports.
// =============================================================================

import 'dart:math' as math;

/// Categories of interactive targets in the sector.
enum InteractionType {
  attack,
  repair,
  harvest,
}

/// Current state of the player interaction controller.
enum InteractionState {
  idle,
  manualFocusing,
  autoFocusing,
}

/// A targetable entity in the simulation arena.
class InteractionTarget {
  final String id;
  double x;
  double y;
  final InteractionType type;
  final int priority;
  bool isResolved;

  /// Optional custom base focus duration override for this specific target.
  final double? baseFocusSecondsOverride;

  InteractionTarget({
    required this.id,
    required this.x,
    required this.y,
    required this.type,
    this.priority = 1,
    this.isResolved = false,
    this.baseFocusSecondsOverride,
  });
}

/// Tech flags and upgrade modifiers scaling player interaction capabilities.
class InteractionUpgradeModifiers {
  /// Base radius within which manual taps/drags or Tier 1+ robotics can lock.
  double baseInteractionRadius;

  /// Upgrade multiplier applied to [baseInteractionRadius] (>= 1.0 expands range).
  double interactionRadiusMultiplier;

  /// Base focus time (seconds) required to complete an interaction at 1.0x multiplier.
  double baseFocusTimeSeconds;

  /// Multiplier applied to focus time duration.
  /// Values < 1.0 reduce required focus time (faster locks);
  /// values > 1.0 increase required focus time.
  double focusTimeMultiplier;

  /// Robotics progression tier:
  /// - 0: Manual tap/drag target locking only.
  /// - 1+: Autonomous robotics target acquisition & dispatch enabled.
  int roboticsTier;

  /// Tech flags governing which target types Tier 1+ autonomous robotics can acquire.
  bool autoAttackUnlocked;
  bool autoRepairUnlocked;
  bool autoHarvestUnlocked;

  InteractionUpgradeModifiers({
    this.baseInteractionRadius = 150.0,
    this.interactionRadiusMultiplier = 1.0,
    this.baseFocusTimeSeconds = 2.0,
    this.focusTimeMultiplier = 1.0,
    this.roboticsTier = 0,
    this.autoAttackUnlocked = false,
    this.autoRepairUnlocked = false,
    this.autoHarvestUnlocked = false,
  });

  /// Effective interaction radius after applying upgrade multiplier.
  double get effectiveInteractionRadius =>
      math.max(1.0, baseInteractionRadius * interactionRadiusMultiplier);

  /// Computes effective focus duration for a target (clamped to >= 0.05s).
  double effectiveFocusDurationFor([InteractionTarget? target]) {
    final base = target?.baseFocusSecondsOverride ?? baseFocusTimeSeconds;
    // Higher robotics tiers (Tier 2+) provide an additional 10% speed bonus per tier above 1
    final tierBonus =
        roboticsTier > 1 ? math.pow(0.9, roboticsTier - 1).toDouble() : 1.0;
    return math.max(0.05, base * focusTimeMultiplier * tierBonus);
  }

  /// Checks whether a given [InteractionType] is unlocked for Tier 1+ automation.
  bool isAutoUnlockedFor(InteractionType type) {
    if (roboticsTier < 1) return false;
    switch (type) {
      case InteractionType.attack:
        return autoAttackUnlocked;
      case InteractionType.repair:
        return autoRepairUnlocked;
      case InteractionType.harvest:
        return autoHarvestUnlocked;
    }
  }
}

/// Emitted when a manual or automated interaction finishes focusing.
class InteractionResolution {
  final InteractionTarget target;
  final bool wasAutomated;
  final double durationSeconds;
  final int roboticsTierAtCompletion;

  const InteractionResolution({
    required this.target,
    required this.wasAutomated,
    required this.durationSeconds,
    required this.roboticsTierAtCompletion,
  });
}

/// Pure-Dart controller managing Tier 0 manual drag/tap focus interactions
/// and Tier 1+ autonomous robotics target locking.
class PlayerInteractionModel {
  PlayerInteractionModel({
    InteractionUpgradeModifiers? modifiers,
    this.onTargetLocked,
    this.onInteractionCompleted,
    this.onInteractionCancelled,
  }) : modifiers = modifiers ?? InteractionUpgradeModifiers();

  final InteractionUpgradeModifiers modifiers;

  final void Function(InteractionTarget target, bool isAutomated)?
      onTargetLocked;
  final void Function(InteractionResolution resolution)?
      onInteractionCompleted;
  final void Function(InteractionTarget? previousTarget)?
      onInteractionCancelled;

  InteractionState _state = InteractionState.idle;
  InteractionTarget? _lockedTarget;
  double _focusElapsed = 0.0;
  double _requiredFocusDuration = 0.0;

  final List<InteractionResolution> _completedHistory = [];

  InteractionState get state => _state;
  InteractionTarget? get lockedTarget => _lockedTarget;
  double get focusElapsed => _focusElapsed;
  double get requiredFocusDuration => _requiredFocusDuration;

  /// Normalized progress [0.0, 1.0] of the active focus lock.
  double get focusProgress {
    if (_state == InteractionState.idle || _requiredFocusDuration <= 0) {
      return 0.0;
    }
    return (_focusElapsed / _requiredFocusDuration).clamp(0.0, 1.0);
  }

  List<InteractionResolution> get completedHistory =>
      List.unmodifiable(_completedHistory);

  /// Tier 0 / manual input: player taps or presses down at `(pointerX, pointerY)`.
  /// Searches [candidates] within [modifiers.effectiveInteractionRadius] and
  /// begins focusing on the highest-priority / closest unresolved target.
  bool beginManualInteraction({
    required double pointerX,
    required double pointerY,
    required List<InteractionTarget> candidates,
  }) {
    final target = _findBestTarget(
      originX: pointerX,
      originY: pointerY,
      candidates: candidates,
      requireAutoTechFlag: false,
    );

    if (target == null) {
      cancelInteraction();
      return false;
    }

    _lockTarget(target, automated: false);
    return true;
  }

  /// Tier 0 / manual drag update: verifies the pointer remains within
  /// [modifiers.effectiveInteractionRadius] of the locked target, or switches
  /// to a new target under the drag cursor if nothing was locked.
  void updateManualDrag({
    required double pointerX,
    required double pointerY,
    List<InteractionTarget>? candidates,
  }) {
    if (_state == InteractionState.manualFocusing && _lockedTarget != null) {
      final dx = _lockedTarget!.x - pointerX;
      final dy = _lockedTarget!.y - pointerY;
      final maxR = modifiers.effectiveInteractionRadius;
      if (dx * dx + dy * dy > maxR * maxR) {
        cancelInteraction();
      }
      return;
    }

    if (_state == InteractionState.idle && candidates != null) {
      beginManualInteraction(
        pointerX: pointerX,
        pointerY: pointerY,
        candidates: candidates,
      );
    }
  }

  /// Cancels any active manual or automated focus lock immediately.
  void cancelInteraction() {
    if (_state == InteractionState.idle) return;
    final prev = _lockedTarget;
    _state = InteractionState.idle;
    _lockedTarget = null;
    _focusElapsed = 0.0;
    _requiredFocusDuration = 0.0;
    onInteractionCancelled?.call(prev);
  }

  /// Advances focus timers and, when `modifiers.roboticsTier >= 1`,
  /// automatically acquires and dispatches targets within
  /// [modifiers.effectiveInteractionRadius] of `(shipX, shipY)`.
  void update(
    double dt, {
    required double shipX,
    required double shipY,
    List<InteractionTarget> candidates = const [],
  }) {
    if (dt <= 0) return;

    // If locked target was resolved externally or moved out of range during auto-focus:
    if (_lockedTarget != null && _lockedTarget!.isResolved) {
      cancelInteraction();
    }

    if (_state == InteractionState.autoFocusing && _lockedTarget != null) {
      final dx = _lockedTarget!.x - shipX;
      final dy = _lockedTarget!.y - shipY;
      final maxR = modifiers.effectiveInteractionRadius;
      if (dx * dx + dy * dy > maxR * maxR) {
        cancelInteraction();
      }
    }

    // Attempt Tier 1+ autonomous target lock when idle
    if (_state == InteractionState.idle &&
        modifiers.roboticsTier >= 1 &&
        candidates.isNotEmpty) {
      final autoTarget = _findBestTarget(
        originX: shipX,
        originY: shipY,
        candidates: candidates,
        requireAutoTechFlag: true,
      );
      if (autoTarget != null) {
        _lockTarget(autoTarget, automated: true);
      }
    }

    if (_state == InteractionState.idle || _lockedTarget == null) return;

    _focusElapsed += dt;
    if (_focusElapsed >= _requiredFocusDuration) {
      _completeCurrentInteraction();
    }
  }

  void _lockTarget(InteractionTarget target, {required bool automated}) {
    _lockedTarget = target;
    _focusElapsed = 0.0;
    _requiredFocusDuration = modifiers.effectiveFocusDurationFor(target);
    _state = automated
        ? InteractionState.autoFocusing
        : InteractionState.manualFocusing;
    onTargetLocked?.call(target, automated);
  }

  void _completeCurrentInteraction() {
    final target = _lockedTarget!;
    final wasAutomated = _state == InteractionState.autoFocusing;
    final duration = _requiredFocusDuration;

    target.isResolved = true;
    final resolution = InteractionResolution(
      target: target,
      wasAutomated: wasAutomated,
      durationSeconds: duration,
      roboticsTierAtCompletion: modifiers.roboticsTier,
    );

    _state = InteractionState.idle;
    _lockedTarget = null;
    _focusElapsed = 0.0;
    _requiredFocusDuration = 0.0;

    _completedHistory.add(resolution);
    onInteractionCompleted?.call(resolution);
  }

  InteractionTarget? _findBestTarget({
    required double originX,
    required double originY,
    required List<InteractionTarget> candidates,
    required bool requireAutoTechFlag,
  }) {
    final maxR = modifiers.effectiveInteractionRadius;
    final maxRSq = maxR * maxR;

    InteractionTarget? best;
    double bestDistSq = double.infinity;
    int bestPriority = -0x7fffffff;

    for (final candidate in candidates) {
      if (candidate.isResolved) continue;
      if (requireAutoTechFlag &&
          !modifiers.isAutoUnlockedFor(candidate.type)) {
        continue;
      }

      final dx = candidate.x - originX;
      final dy = candidate.y - originY;
      final distSq = dx * dx + dy * dy;
      if (distSq > maxRSq) continue;

      if (candidate.priority > bestPriority ||
          (candidate.priority == bestPriority && distSq < bestDistSq)) {
        best = candidate;
        bestDistSq = distSq;
        bestPriority = candidate.priority;
      }
    }

    return best;
  }
}
