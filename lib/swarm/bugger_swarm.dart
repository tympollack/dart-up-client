import 'dart:typed_data';
import 'package:flame/components.dart';
import 'package:flame/sprite.dart';
import 'package:flutter/material.dart';

class BuggerSwarmComponent extends PositionComponent with HasGameReference {
  late final SpriteBatch _spriteBatch;
  final int maxEntities;

  // This holds our [x, y, rotation, scale] flat array
  Float32List _transformations = Float32List(0);

  BuggerSwarmComponent({required this.maxEntities});

  @override
  Future<void> onLoad() async {
    // Load the single texture for the bugger.
    // (Ensure you have a small 'bugger.png' in your assets/images folder!)
    final image = await game.images.load('bugger.png');
    _spriteBatch = SpriteBatch(image);
  }

  // We call this from the main game loop (or the Isolate later)
  void updateSwarmData(Float32List newTransformations) {
    _transformations = newTransformations;
  }

  @override
  void render(Canvas canvas) {
    if (_transformations.isEmpty) return;

    _spriteBatch.clear(); // Empty the batch from the previous frame

    // Read the array in chunks of 4: [x, y, rotation, scale]
    for (int i = 0; i < maxEntities; i++) {
      final int baseIndex = i * 4;
      
      // Safety check in case the array isn't fully populated
      if (baseIndex + 3 >= _transformations.length) break;

      final double x = _transformations[baseIndex];
      final double y = _transformations[baseIndex + 1];
      final double rotation = _transformations[baseIndex + 2];
      final double scale = _transformations[baseIndex + 3];

      _spriteBatch.add(
        source: const Rect.fromLTWH(0, 0, 16, 16), // The bounds of your sprite image
        offset: Vector2(x, y),
        rotation: rotation,
        scale: scale,
        anchor: Vector2(8, 8), // Center the sprite on its X/Y coordinates
      );
    }

    // BOOM. One draw call for the entire swarm.
    _spriteBatch.render(canvas);
  }
}
