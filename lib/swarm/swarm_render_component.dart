// =============================================================================
// swarm_render_component.dart
//
// Pure render component for the boids swarm produced by swarm_isolate.dart.
//
// Deliberately does NOT extend Flame's SpriteBatchComponent / use its
// SpriteBatch.add() API: that path allocates an RSTransform object per
// sprite, per frame (1,500 entities x 60fps = ~90,000 allocations/sec --
// exactly the kind of GC pressure this whole project has been avoiding
// with SoA everywhere else). Instead, this repacks the isolate's flat
// [x, y, rotation, scale] buffer directly into the Float32List layout
// canvas.drawRawAtlas wants, with zero per-frame allocation after a
// one-time setup, issuing the entire flock in a single GPU draw call --
// matching the canvas.drawRawAtlas approach already established
// elsewhere in this project.
//
// There is no update() override here. There's no dt-driven logic and no
// decision being made -- only already-final simulation output getting
// repacked into the GPU's expected layout, which happens in render().
// =============================================================================

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flame/components.dart';

class SwarmRenderComponent extends PositionComponent {
  SwarmRenderComponent({
    required this.atlasImage,
    required this.spriteRect,
  });

  final ui.Image atlasImage;

  /// The single drone sprite's region within the atlas. Repeated for
  /// every entity -- this is one flock of one drone type, not a
  /// per-entity atlas lookup.
  final ui.Rect spriteRect;

  Float32List? _frame; // raw [x, y, rotation, scale] quads from the isolate
  Float32List? _rects; // precomputed once: the same 4 values, repeated per entity
  Float32List? _rstTransforms; // rebuilt every render() call
  int _entityCount = 0;

  /// Called by DartUpGame whenever a fresh frame arrives from the swarm
  /// isolate. Pure data hand-off: store the reference, and -- only the
  /// very first time, since entity count never changes mid-game -- size
  /// the scratch buffers to match. No per-entity math happens here.
  void updateFrame(Float32List frame, int entityCount) {
    _frame = frame;

    if (_entityCount != entityCount) {
      _entityCount = entityCount;
      _rects = Float32List(entityCount * 4);
      _rstTransforms = Float32List(entityCount * 4);

      final Float32List rects = _rects!;
      for (int i = 0; i < entityCount; i++) {
        final int o = i * 4;
        rects[o] = spriteRect.left;
        rects[o + 1] = spriteRect.top;
        rects[o + 2] = spriteRect.right;
        rects[o + 3] = spriteRect.bottom;
      }
    }
  }

  @override
  void render(ui.Canvas canvas) {
    final Float32List? frame = _frame;
    final Float32List? rects = _rects;
    final Float32List? transforms = _rstTransforms;
    if (frame == null || rects == null || transforms == null) return;

    final double halfW = spriteRect.width / 2;
    final double halfH = spriteRect.height / 2;

    // Repack [x, y, rotation, scale] -> RSTransform's packed
    // [scos, ssin, tx, ty] form, anchored at the sprite's center. This is
    // GPU-format bookkeeping, not simulation -- the physics already
    // happened in the isolate before this buffer ever arrived here.
    for (int i = 0; i < _entityCount; i++) {
      final int src = i * 4;
      final double x = frame[src];
      final double y = frame[src + 1];
      final double rotation = frame[src + 2];
      final double scale = frame[src + 3];

      final double cosScaled = math.cos(rotation) * scale;
      final double sinScaled = math.sin(rotation) * scale;

      final int dst = i * 4;
      transforms[dst] = cosScaled;
      transforms[dst + 1] = sinScaled;
      transforms[dst + 2] = x - (cosScaled * halfW - sinScaled * halfH);
      transforms[dst + 3] = y - (sinScaled * halfW + cosScaled * halfH);
    }

    canvas.drawRawAtlas(
      atlasImage,
      transforms,
      rects,
      null, // no per-sprite color tint
      ui.BlendMode.srcOver,
      null, // no cull rect -- the flock roams the whole world
      ui.Paint(),
    );
  }
}
