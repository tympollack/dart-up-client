import 'dart:math';
import 'package:flame/components.dart';
import 'package:flame/events.dart';
import 'package:flame/game.dart';
import 'package:flutter/material.dart';
import 'package:flame/particles.dart';

import 'package:sd_client/swarm/swarm_manager.dart'; // NEW: Import our Boids engine
import 'package:sd_client/hub/hub_client.dart'; // Hub integration

void main() {
  HubClient.initializeFromUrl(Uri.base);
  
  runApp(GameWidget(
    game: StarDartMVP(),
    overlayBuilderMap: {
      'EndMatch': (BuildContext context, StarDartMVP game) {
        return Align(
          alignment: Alignment.topRight,
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: ElevatedButton(
              onPressed: () {
                game.endMatch();
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.redAccent,
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              ),
              child: const Text('End Match', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          ),
        );
      },
    },
    initialActiveOverlays: const ['EndMatch'],
  ));
}

class StarDartMVP extends FlameGame with TapCallbacks {
  late Ship playerShip;
  late SwarmManager droneSwarm; // NEW: The Swarm!
  
  late final World gameWorld;
  late final CameraComponent gameCamera;

  @override
  Color backgroundColor() => const Color(0xFF0F0F1A);

  @override
  Future<void> onLoad() async {
    gameWorld = World();
    add(gameWorld);

    // 1. GENERATE THE STARFIELD
    final starfield = Starfield(starCount: 500, fieldRadius: 3000);
    gameWorld.add(starfield);

    // 2. SPAWN THE SHIP
    playerShip = Ship()
      ..position = Vector2.zero() 
      ..size = Vector2(40, 50)
      ..anchor = Anchor.center;
    gameWorld.add(playerShip);

    // 3. SPAWN THE SWARM
    droneSwarm = SwarmManager(
      unitCount: 300, // 300 drones protecting your ship!
      targetCoordinate: playerShip.position, 
      // We set the bounds to match the 6000x6000 starfield
      worldBounds: const Rect.fromLTWH(-3000, -3000, 6000, 6000), 
    );
    gameWorld.add(droneSwarm); // Add it to the infinite world

    // 4. SET UP THE CAMERA
    gameCamera = CameraComponent(world: gameWorld)
      ..follow(playerShip); 
    add(gameCamera);
  }

  @override
  void update(double dt) {
    super.update(dt);
    
    // NEW: The core integration!
    // Every single frame, we tell the swarm exactly where the ship is.
    // If the ship is moving, the drones will chase it. If it's still, they will orbit.
    droneSwarm.setTarget(playerShip.position);
  }

  @override
  void onTapDown(TapDownEvent event) {
    final worldTapCoordinate = gameCamera.globalToLocal(event.canvasPosition);
    playerShip.setTarget(worldTapCoordinate);
  }

  void endMatch() {
    print("Ending match and syncing to Hub...");
    HubClient.postMatchResult(
      gameName: 'Star Dart',
      opponentName: 'Swarm Director',
      result: 'victory', // Mocking a victory for now
      matchType: 'sandbox',
      moves: droneSwarm.unitCount, // Arbitrary "moves" score based on active drones
    );
  }
}

/// A component that procedurally places random stars on the world map.
class Starfield extends Component {
  final int starCount;
  final double fieldRadius;
  
  final List<Vector2> _starPositions = [];
  final List<double> _starSizes = [];
  final Random _random = Random();

  Starfield({required this.starCount, required this.fieldRadius});

  @override
  void onLoad() {
    super.onLoad();
    for (int i = 0; i < starCount; i++) {
      double x = (_random.nextDouble() * fieldRadius * 2) - fieldRadius;
      double y = (_random.nextDouble() * fieldRadius * 2) - fieldRadius;
      _starPositions.add(Vector2(x, y));
      _starSizes.add(_random.nextDouble() * 2.0 + 0.5);
    }
  }

  @override
  void render(Canvas canvas) {
    super.render(canvas);
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.5)
      ..style = PaintingStyle.fill;

    for (int i = 0; i < _starPositions.length; i++) {
      final position = _starPositions[i];
      final radius = _starSizes[i];
      canvas.drawCircle(Offset(position.x, position.y), radius, paint);
    }
  }
}

class Ship extends PositionComponent {
  Vector2? targetPosition;
  final double speed = 300.0; 
  double _particleTimer = 0.0;

  @override
  void render(Canvas canvas) {
    final paint = Paint()
      ..color = const Color(0xFF00FFCC) 
      ..style = PaintingStyle.fill;

    final path = Path()
      ..moveTo(size.x / 2, 0) 
      ..lineTo(size.x, size.y) 
      ..lineTo(size.x / 2, size.y * 0.75) 
      ..lineTo(0, size.y) 
      ..close();

    canvas.drawPath(path, paint);
  }

  void setTarget(Vector2 target) {
    targetPosition = target;
  }

  @override
  void update(double dt) {
    super.update(dt); 

    if (targetPosition != null) {
      Vector2 direction = targetPosition! - position;

      if (direction.length > 5.0) {
        angle = atan2(direction.y, direction.x) + (pi / 2);
        direction.normalize();
        position += direction * speed * dt;

        _particleTimer += dt;
        if (_particleTimer > 0.03) { 
          _particleTimer = 0.0; 
          _spawnParticle();
        }
      } else {
        targetPosition = null;
      }
    }
  }

  void _spawnParticle() {
    final backOffset = Vector2(0, size.y / 2)..rotate(angle);

    final particleComponent = ParticleSystemComponent(
      position: position + backOffset,
      particle: Particle.generate(
        count: 1, 
        lifespan: 0.4, 
        generator: (i) => ComputedParticle(
          renderer: (canvas, particle) {
            final opacity = (1.0 - particle.progress).clamp(0.0, 1.0);
            final paint = Paint()
              ..color = const Color(0xFF00FFCC).withValues(alpha: opacity)
              ..style = PaintingStyle.fill;
            canvas.drawCircle(Offset.zero, 3.0, paint);
          },
        ),
      ),
    );

    parent?.add(particleComponent);
  }
}