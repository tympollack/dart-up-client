// =============================================================================
// combat_vfx_component.dart
//
// Pure render component, with one deliberate exception: it DOES own a
// small amount of state -- a short-lived list of "currently fading
// strikes." This is purely a rendering-lifecycle concern (how long has
// this laser flash been on screen, how transparent should it be right
// now), not game logic: CombatManager already resolved the hit, decided
// who got hurt, and fired the event. All this component decides is how
// to animate something that already happened.
//
// Wire this up by passing `combatVFXComponent.recordHit` as
// CombatManager's `onDamageDealt` callback -- see dart_up_game.dart.
// =============================================================================

import 'dart:typed_data';
import 'dart:ui';

import 'package:flame/components.dart';

import 'package:sd_client/combat/combat_manager.dart';

class CombatVFXComponent extends PositionComponent {
  CombatVFXComponent({
    this.fadeDuration = 0.15,
    this.maxStrikes = 256,
  })  : _sourceX = Float32List(maxStrikes),
        _sourceY = Float32List(maxStrikes),
        _targetX = Float32List(maxStrikes),
        _targetY = Float32List(maxStrikes),
        _totalDuration = Float32List(maxStrikes),
        _timeRemaining = Float32List(maxStrikes),
        _sourceType = Uint8List(maxStrikes);

  /// How long a strike's line takes to fade out completely, in seconds.
  final double fadeDuration;

  /// Capacity of the pre-allocated SoA strike buffer.
  final int maxStrikes;

  final Float32List _sourceX;
  final Float32List _sourceY;
  final Float32List _targetX;
  final Float32List _targetY;
  final Float32List _totalDuration;
  final Float32List _timeRemaining;
  final Uint8List _sourceType;
  int _activeCount = 0;

  static const Color enemyOnShipColor = Color(0xFFFF3B3B); // red
  static const Color pointDefenseColor = Color(0xFF4FFFB0); // green
  static const Color shipTurretColor = Color(0xFF4FB3FF); // blue

  final Paint _linePaint = Paint()
    ..strokeWidth = 2.5
    ..strokeCap = StrokeCap.round;

  /// Number of currently active fading laser strikes in the pool.
  int get activeStrikeCount => _activeCount;

  /// Returns the base color for a given [CombatHitSource].
  Color colorForSource(CombatHitSource source) => _colorForIndex(source.index);

  /// Pass this directly as CombatManager's onDamageDealt callback. Just
  /// stores the strike data in the pre-allocated SoA pool and starts its fade
  /// timer -- zero heap allocation per strike.
  void recordHit(CombatHitEvent event) {
    final int slot = _activeCount < maxStrikes ? _activeCount++ : 0;
    _sourceX[slot] = event.sourceX;
    _sourceY[slot] = event.sourceY;
    _targetX[slot] = event.targetX;
    _targetY[slot] = event.targetY;
    _totalDuration[slot] = fadeDuration;
    _timeRemaining[slot] = fadeDuration;
    _sourceType[slot] = event.source.index;
  }

  /// Clears all active strikes in the pool.
  void clear() {
    _activeCount = 0;
  }

  @override
  void update(double dt) {
    super.update(dt);
    for (int i = _activeCount - 1; i >= 0; i--) {
      final double rem = _timeRemaining[i] - dt;
      if (rem <= 0) {
        final int last = _activeCount - 1;
        if (i != last) {
          _sourceX[i] = _sourceX[last];
          _sourceY[i] = _sourceY[last];
          _targetX[i] = _targetX[last];
          _targetY[i] = _targetY[last];
          _totalDuration[i] = _totalDuration[last];
          _timeRemaining[i] = _timeRemaining[last];
          _sourceType[i] = _sourceType[last];
        }
        _activeCount--;
      } else {
        _timeRemaining[i] = rem;
      }
    }
  }

  @override
  void render(Canvas canvas) {
    for (int i = 0; i < _activeCount; i++) {
      final double total = _totalDuration[i];
      final double t =
          total > 0 ? (_timeRemaining[i] / total).clamp(0.0, 1.0) : 0.0;
      _linePaint.color = _colorForIndex(_sourceType[i]).withValues(alpha: t);

      canvas.drawLine(
        Offset(_sourceX[i], _sourceY[i]),
        Offset(_targetX[i], _targetY[i]),
        _linePaint,
      );
    }
  }

  @override
  void onRemove() {
    _activeCount = 0;
    super.onRemove();
  }

  Color _colorForIndex(int index) {
    if (index == CombatHitSource.enemyFighterOnShip.index) {
      return enemyOnShipColor;
    }
    if (index == CombatHitSource.dronePointDefense.index) {
      return pointDefenseColor;
    }
    return shipTurretColor;
  }
}
