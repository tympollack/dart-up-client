// swarm_manager.dart
//
// Standalone Flame Component rendering a large Boids-driven drone swarm.
//
// PERFORMANCE ARCHITECTURE
// -------------------------------------------------------------------------
// 1. Struct-of-arrays (Float32List/Int32List) instead of a List<Drone> of
//    objects. This keeps everything in flat, cache-friendly typed memory
//    and means update() allocates *nothing* per frame once warmed up.
//
// 2. Neighbor search uses a uniform spatial hash grid built with a
//    bucket-sort each frame (counting sort), which is O(n) to build and
//    O(n) to query on average — no per-frame List<int> allocation, no
//    HashMap. This replaces the naive O(n^2) Boids neighbor loop.
//
// 3. Rendering never creates 500 PositionComponents. A single procedurally
//    generated 10x10 ui.Image "drone" sprite is drawn `unitCount` times in
//    ONE canvas.drawRawAtlas call using raw Float32List transforms — this
//    is the fastest sprite-batching path Flutter/Skia/Impeller (and by
//    extension the Metal/WebGPU backends) expose, since it avoids building
//    a List<RSTransform>/List<Rect> of Dart objects every frame.
//
// USAGE
// -------------------------------------------------------------------------
//   final swarm = SwarmManager(
//     unitCount: 500,
//     targetCoordinate: capitalShip.position,
//     worldBounds: const Rect.fromLTWH(0, 0, 2000, 2000),
//   );
//   world.add(swarm); // add directly to the World/Game, not under a
//                      // transformed parent — positions are world-space.
//
// To redirect the swarm at runtime (e.g. player issues a new attack order):
//   swarm.setTarget(newCapitalShipPosition);

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flame/components.dart';

class SwarmManager extends Component {
  SwarmManager({
    required this.unitCount,
    required Vector2 targetCoordinate,
    required this.worldBounds,
    this.perceptionRadius = 60.0,
    this.separationRadius = 22.0,
    this.maxSpeed = 140.0,
    this.maxForce = 260.0,
    this.separationWeight = 1.7,
    this.alignmentWeight = 1.0,
    this.cohesionWeight = 0.85,
    this.seekWeight = 1.0,
    this.orbitWeight = 1.3,
    this.arrivalRadius = 90.0,
    this.orbitRadius = 55.0,
    this.orbitCorrection = 2.2,
    this.wanderStrength = 16.0,
  }) : targetCoordinate = targetCoordinate.clone();

  // --- Public config -------------------------------------------------
  final int unitCount;
  Vector2 targetCoordinate;
  final ui.Rect worldBounds;

  /// How far a drone "sees" other drones for alignment/cohesion.
  double perceptionRadius;
  /// Distance inside which drones actively push apart (must be <= perceptionRadius).
  double separationRadius;
  double maxSpeed;
  double maxForce;
  double separationWeight;
  double alignmentWeight;
  double cohesionWeight;
  double seekWeight;
  double orbitWeight;
  /// Distance from target at which a drone switches from "seek" to "orbit".
  double arrivalRadius;
  /// Desired steady-state distance from target while orbiting.
  double orbitRadius;
  /// How strongly drones correct back toward [orbitRadius] while circling.
  double orbitCorrection;
  /// Amplitude of per-drone organic jitter (gives the "insect swarm" feel).
  double wanderStrength;

  void setTarget(Vector2 newTarget) => targetCoordinate.setFrom(newTarget);

  // --- Drone state (struct-of-arrays) ---------------------------------
  late Float32List _posX, _posY;
  late Float32List _velX, _velY;
  late Float32List _wanderPhase;
  late Int32List _colors; // packed ARGB, one per drone

  // --- Spatial hash grid (bucket-sort, rebuilt every frame, zero alloc) -
  late int _gridCols, _gridRows, _numCells;
  late Int32List _cellOf;      // cell index per drone
  late Int32List _cellCount;   // scratch: drones per cell
  late Int32List _cellStart;   // prefix-sum offsets, length numCells+1
  late Int32List _cellCursor;  // scratch cursor while filling buckets
  late Int32List _sortedIndex; // drone indices grouped by cell

  double get _cellSize => perceptionRadius;

  // --- Rendering ---------------------------------------------------------
  static const double _spriteSize = 10.0;
  ui.Image? _spriteAtlas;
  late Float32List _rstTransforms; // 4 floats per drone: scos, ssin, tx, ty
  late Float32List _rectF;         // 4 floats per drone: constant src rect
  final ui.Paint _paint = ui.Paint()..isAntiAlias = false;

  double _time = 0;
  final math.Random _rng = math.Random();

  // ---------------------------------------------------------------------
  @override
  Future<void> onLoad() async {
    await super.onLoad();
    _allocate();
    _spawnDrones();
    _spriteAtlas = await _buildDroneSprite();
  }

  @override
  void onRemove() {
    _spriteAtlas?.dispose();
    super.onRemove();
  }

  void _allocate() {
    _posX = Float32List(unitCount);
    _posY = Float32List(unitCount);
    _velX = Float32List(unitCount);
    _velY = Float32List(unitCount);
    _wanderPhase = Float32List(unitCount);
    _colors = Int32List(unitCount);

    _gridCols = math.max(1, (worldBounds.width / _cellSize).ceil());
    _gridRows = math.max(1, (worldBounds.height / _cellSize).ceil());
    _numCells = _gridCols * _gridRows;

    _cellOf = Int32List(unitCount);
    _cellCount = Int32List(_numCells);
    _cellStart = Int32List(_numCells + 1);
    _cellCursor = Int32List(_numCells);
    _sortedIndex = Int32List(unitCount);

    _rstTransforms = Float32List(unitCount * 4);
    _rectF = Float32List(unitCount * 4);
    for (int i = 0; i < unitCount; i++) {
      final o = i * 4;
      _rectF[o] = 0;
      _rectF[o + 1] = 0;
      _rectF[o + 2] = _spriteSize;
      _rectF[o + 3] = _spriteSize;
    }
  }

  void _spawnDrones() {
    for (int i = 0; i < unitCount; i++) {
      _posX[i] = worldBounds.left + _rng.nextDouble() * worldBounds.width;
      _posY[i] = worldBounds.top + _rng.nextDouble() * worldBounds.height;
      final angle = _rng.nextDouble() * math.pi * 2;
      final speed = maxSpeed * (0.3 + _rng.nextDouble() * 0.4);
      _velX[i] = math.cos(angle) * speed;
      _velY[i] = math.sin(angle) * speed;
      _wanderPhase[i] = _rng.nextDouble() * math.pi * 2;

      // Subtle per-drone color variance (e.g. hull tint/damage states).
      final brightness = 180 + _rng.nextInt(75); // 180-255
      _colors[i] = ui.Color.fromARGB(255, brightness, brightness, 255).toARGB32();
    }
  }

  Future<ui.Image> _buildDroneSprite() async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(
      recorder,
      const ui.Rect.fromLTWH(0, 0, _spriteSize, _spriteSize),
    );
    final paint = ui.Paint()
      ..color = const ui.Color(0xFFFFFFFF)
      ..isAntiAlias = true;
    // Chevron/insect silhouette pointing along +X (rotation = 0).
    final path = ui.Path()
      ..moveTo(_spriteSize, _spriteSize * 0.5)
      ..lineTo(0, 0)
      ..lineTo(_spriteSize * 0.35, _spriteSize * 0.5)
      ..lineTo(0, _spriteSize)
      ..close();
    canvas.drawPath(path, paint);
    final picture = recorder.endRecording();
    final image = await picture.toImage(
      _spriteSize.ceil(),
      _spriteSize.ceil(),
    );
    picture.dispose();
    return image;
  }

  // ---------------------------------------------------------------------
  @override
  void update(double dt) {
    super.update(dt);
    _time += dt;
    _rebuildSpatialGrid();
    _stepBoids(dt);
  }

  int _cellIndexFor(double x, double y) {
    final cx = (((x - worldBounds.left) / _cellSize).floor())
        .clamp(0, _gridCols - 1);
    final cy = (((y - worldBounds.top) / _cellSize).floor())
        .clamp(0, _gridRows - 1);
    return cy * _gridCols + cx;
  }

  void _rebuildSpatialGrid() {
    _cellCount.fillRange(0, _numCells, 0);

    for (int i = 0; i < unitCount; i++) {
      final c = _cellIndexFor(_posX[i], _posY[i]);
      _cellOf[i] = c;
      _cellCount[c]++;
    }

    _cellStart[0] = 0;
    for (int c = 1; c <= _numCells; c++) {
      _cellStart[c] = _cellStart[c - 1] + _cellCount[c - 1];
    }
    for (int c = 0; c < _numCells; c++) {
      _cellCursor[c] = _cellStart[c];
    }
    for (int i = 0; i < unitCount; i++) {
      final c = _cellOf[i];
      _sortedIndex[_cellCursor[c]] = i;
      _cellCursor[c]++;
    }
  }

  void _stepBoids(double dt) {
    final perceptionSq = perceptionRadius * perceptionRadius;
    final separationSq = separationRadius * separationRadius;
    final cellSize = _cellSize;

    for (int i = 0; i < unitCount; i++) {
      final px = _posX[i];
      final py = _posY[i];
      final vx = _velX[i];
      final vy = _velY[i];

      double sepX = 0, sepY = 0;
      double alignX = 0, alignY = 0;
      double cohX = 0, cohY = 0;
      int neighborCount = 0;

      final cx = (((px - worldBounds.left) / cellSize).floor())
          .clamp(0, _gridCols - 1);
      final cy = (((py - worldBounds.top) / cellSize).floor())
          .clamp(0, _gridRows - 1);

      for (int ny = cy - 1; ny <= cy + 1; ny++) {
        if (ny < 0 || ny >= _gridRows) continue;
        for (int nx = cx - 1; nx <= cx + 1; nx++) {
          if (nx < 0 || nx >= _gridCols) continue;
          final cell = ny * _gridCols + nx;
          final start = _cellStart[cell];
          final end = _cellStart[cell + 1];
          for (int k = start; k < end; k++) {
            final j = _sortedIndex[k];
            if (j == i) continue;
            final dx = px - _posX[j];
            final dy = py - _posY[j];
            final distSq = dx * dx + dy * dy;
            if (distSq > perceptionSq || distSq == 0) continue;

            neighborCount++;
            alignX += _velX[j];
            alignY += _velY[j];
            cohX += _posX[j];
            cohY += _posY[j];

            if (distSq < separationSq) {
              final inv = 1.0 / distSq; // closer drones push harder
              sepX += dx * inv;
              sepY += dy * inv;
            }
          }
        }
      }

      double accX = 0, accY = 0;

      if (neighborCount > 0) {
        // Alignment: steer toward average neighbor heading.
        final invN = 1.0 / neighborCount;
        double desiredX = alignX * invN;
        double desiredY = alignY * invN;
        _limit(desiredX, desiredY, maxSpeed, (lx, ly) {
          accX += (lx - vx) * alignmentWeight;
          accY += (ly - vy) * alignmentWeight;
        });

        // Cohesion: steer toward average neighbor position.
        final centerX = cohX * invN;
        final centerY = cohY * invN;
        double towardX = centerX - px;
        double towardY = centerY - py;
        _seekSteer(towardX, towardY, vx, vy, cohesionWeight, (sx, sy) {
          accX += sx;
          accY += sy;
        });
      }

      // Separation: steer away from anything that's too close.
      if (sepX != 0 || sepY != 0) {
        _seekSteer(sepX, sepY, vx, vy, separationWeight, (sx, sy) {
          accX += sx;
          accY += sy;
        });
      }

      // Seek-or-orbit the target.
      final toTargetX = targetCoordinate.x - px;
      final toTargetY = targetCoordinate.y - py;
      final distToTarget =
          math.sqrt(toTargetX * toTargetX + toTargetY * toTargetY);

      if (distToTarget > arrivalRadius) {
        _seekSteer(toTargetX, toTargetY, vx, vy, seekWeight, (sx, sy) {
          accX += sx;
          accY += sy;
        });
      } else if (distToTarget > 0.0001) {
        final radialX = toTargetX / distToTarget;
        final radialY = toTargetY / distToTarget;
        // Perpendicular vector -> consistent swirl direction around target.
        final tangentX = -radialY;
        final tangentY = radialX;

        final radiusError = distToTarget - orbitRadius;
        double desiredX = tangentX * maxSpeed + radialX * radiusError * orbitCorrection;
        double desiredY = tangentY * maxSpeed + radialY * radiusError * orbitCorrection;

        _limit(desiredX, desiredY, maxSpeed, (lx, ly) {
          accX += (lx - vx) * orbitWeight;
          accY += (ly - vy) * orbitWeight;
        });
      }

      // Wander: cheap per-drone rotating jitter for organic insect motion.
      final wanderAngle = _time * 1.3 + _wanderPhase[i];
      accX += math.cos(wanderAngle) * wanderStrength;
      accY += math.sin(wanderAngle) * wanderStrength;

      // Clamp total steering force, integrate.
      final accLen = math.sqrt(accX * accX + accY * accY);
      if (accLen > maxForce && accLen > 0) {
        final s = maxForce / accLen;
        accX *= s;
        accY *= s;
      }

      double newVx = vx + accX * dt;
      double newVy = vy + accY * dt;
      final speed = math.sqrt(newVx * newVx + newVy * newVy);
      if (speed > maxSpeed && speed > 0) {
        final s = maxSpeed / speed;
        newVx *= s;
        newVy *= s;
      }

      _velX[i] = newVx;
      _velY[i] = newVy;
      _posX[i] = px + newVx * dt;
      _posY[i] = py + newVy * dt;
    }
  }

  /// Steering-force helper: desired velocity toward (dx,dy) at maxSpeed,
  /// minus current velocity, scaled by [weight]. Avoids Vector2 allocation.
  void _seekSteer(
    double dx,
    double dy,
    double vx,
    double vy,
    double weight,
    void Function(double sx, double sy) onResult,
  ) {
    final len = math.sqrt(dx * dx + dy * dy);
    if (len == 0) {
      onResult(0, 0);
      return;
    }
    final s = maxSpeed / len;
    final desiredX = dx * s;
    final desiredY = dy * s;
    onResult((desiredX - vx) * weight, (desiredY - vy) * weight);
  }

  void _limit(
    double x,
    double y,
    double maxLen,
    void Function(double lx, double ly) onResult,
  ) {
    final len = math.sqrt(x * x + y * y);
    if (len > maxLen && len > 0) {
      final s = maxLen / len;
      onResult(x * s, y * s);
    } else {
      onResult(x, y);
    }
  }

  // ---------------------------------------------------------------------
  @override
  void render(ui.Canvas canvas) {
    super.render(canvas);
    final atlas = _spriteAtlas;
    if (atlas == null) return; // sprite still loading

    const anchor = _spriteSize / 2;

    for (int i = 0; i < unitCount; i++) {
      final vx = _velX[i];
      final vy = _velY[i];
      final rotation = math.atan2(vy, vx);
      final scos = math.cos(rotation);
      final ssin = math.sin(rotation);

      final tx = _posX[i] - scos * anchor + ssin * anchor;
      final ty = _posY[i] - ssin * anchor - scos * anchor;

      final o = i * 4;
      _rstTransforms[o] = scos;
      _rstTransforms[o + 1] = ssin;
      _rstTransforms[o + 2] = tx;
      _rstTransforms[o + 3] = ty;
    }

    // Single batched draw call for the entire swarm.
    canvas.drawRawAtlas(
      atlas,
      _rstTransforms,
      _rectF,
      _colors,
      ui.BlendMode.modulate,
      null,
      _paint,
    );
  }
}
