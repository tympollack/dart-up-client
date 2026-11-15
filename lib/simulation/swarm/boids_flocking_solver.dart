// =============================================================================
// boids_flocking_solver.dart
//
// Engine-agnostic, pure-Dart Boids flocking solver using Structure-of-Arrays
// (SoA) typed buffers and a counting-sort uniform spatial hash grid.
// Zero Flutter or Flame imports.
// =============================================================================

import 'dart:math' as math;
import 'dart:typed_data';

/// Pure-Dart axis-aligned 2D rectangle representing the simulation arena.
class ArenaBounds {
  final double left;
  final double top;
  final double width;
  final double height;

  const ArenaBounds({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  })  : assert(width > 0),
        assert(height > 0);

  double get right => left + width;
  double get bottom => top + height;
  double get centerX => left + width * 0.5;
  double get centerY => top + height * 0.5;

  bool contains(double x, double y) =>
      x >= left && x <= right && y >= top && y <= bottom;
}

/// Pure-Dart 2D vector value for steering inspection and testing.
class SteeringVector {
  final double x;
  final double y;

  const SteeringVector(this.x, this.y);

  double get magnitude => math.sqrt(x * x + y * y);

  SteeringVector operator +(SteeringVector other) =>
      SteeringVector(x + other.x, y + other.y);

  SteeringVector operator *(double scalar) =>
      SteeringVector(x * scalar, y * scalar);

  @override
  String toString() => 'SteeringVector($x, $y)';
}

/// Tunable parameters for the Boids flocking solver.
class BoidsConfig {
  double perceptionRadius;
  double separationRadius;
  double maxSpeed;
  double maxForce;
  double cohesionWeight;
  double alignmentWeight;
  double separationWeight;
  double boundaryMargin;
  double boundaryAvoidanceWeight;
  double seekWeight;
  double orbitWeight;
  double arrivalRadius;
  double orbitRadius;
  double orbitCorrection;

  BoidsConfig({
    this.perceptionRadius = 60.0,
    this.separationRadius = 22.0,
    this.maxSpeed = 140.0,
    this.maxForce = 260.0,
    this.cohesionWeight = 0.85,
    this.alignmentWeight = 1.0,
    this.separationWeight = 1.7,
    this.boundaryMargin = 80.0,
    this.boundaryAvoidanceWeight = 2.4,
    this.seekWeight = 1.0,
    this.orbitWeight = 1.3,
    this.arrivalRadius = 90.0,
    this.orbitRadius = 55.0,
    this.orbitCorrection = 2.2,
  });
}

/// High-performance pure-Dart Boids solver supporting cohesion, alignment,
/// separation, arena boundary avoidance, and optional target seeking/orbiting.
class BoidsFlockingSolver {
  BoidsFlockingSolver({
    required this.unitCount,
    required this.bounds,
    BoidsConfig? config,
    double? initialTargetX,
    double? initialTargetY,
    int seed = 1337,
  })  : assert(unitCount > 0),
        config = config ?? BoidsConfig() {
    _targetX = initialTargetX ?? bounds.centerX;
    _targetY = initialTargetY ?? bounds.centerY;
    _allocate();
    _spawnInitialUnits(seed);
  }

  final int unitCount;
  final ArenaBounds bounds;
  final BoidsConfig config;

  late double _targetX;
  late double _targetY;
  bool hasTarget = true;

  double get targetX => _targetX;
  double get targetY => _targetY;

  void setTarget(double x, double y) {
    _targetX = x;
    _targetY = y;
    hasTarget = true;
  }

  void clearTarget() {
    hasTarget = false;
  }

  // ---- Structure-of-Arrays (SoA) unit state ----
  late final Float32List posX;
  late final Float32List posY;
  late final Float32List velX;
  late final Float32List velY;
  late final Float32List _nextVelX;
  late final Float32List _nextVelY;
  late final Float32List heading;

  // ---- Uniform spatial hash grid (counting sort, zero per-tick alloc) ----
  late int _gridCols;
  late int _gridRows;
  late int _numCells;
  late Int32List _cellOf;
  late Int32List _cellCount;
  late Int32List _cellStart;
  late Int32List _cellCursor;
  late Int32List _sortedIndex;

  double get _cellSize => math.max(1.0, config.perceptionRadius);

  void _allocate() {
    posX = Float32List(unitCount);
    posY = Float32List(unitCount);
    velX = Float32List(unitCount);
    velY = Float32List(unitCount);
    _nextVelX = Float32List(unitCount);
    _nextVelY = Float32List(unitCount);
    heading = Float32List(unitCount);

    _gridCols = math.max(1, (bounds.width / _cellSize).floor());
    _gridRows = math.max(1, (bounds.height / _cellSize).floor());
    _numCells = _gridCols * _gridRows;

    _cellOf = Int32List(unitCount);
    _cellCount = Int32List(_numCells);
    _cellStart = Int32List(_numCells + 1);
    _cellCursor = Int32List(_numCells);
    _sortedIndex = Int32List(unitCount);
  }

  void _spawnInitialUnits(int seed) {
    final rng = math.Random(seed);
    final margin = math.min(bounds.boundaryMarginSafe(config.boundaryMargin),
        math.min(bounds.width, bounds.height) * 0.25);
    final spawnLeft = bounds.left + margin;
    final spawnTop = bounds.top + margin;
    final spawnWidth = math.max(1.0, bounds.width - margin * 2);
    final spawnHeight = math.max(1.0, bounds.height - margin * 2);

    for (int i = 0; i < unitCount; i++) {
      posX[i] = spawnLeft + rng.nextDouble() * spawnWidth;
      posY[i] = spawnTop + rng.nextDouble() * spawnHeight;
      final angle = rng.nextDouble() * math.pi * 2;
      final speed = config.maxSpeed * (0.35 + rng.nextDouble() * 0.45);
      velX[i] = math.cos(angle) * speed;
      velY[i] = math.sin(angle) * speed;
      heading[i] = angle;
    }
  }

  /// Explicitly sets a unit's position and velocity (useful for deterministic tests).
  void setUnitState(
    int index, {
    required double x,
    required double y,
    double vx = 0.0,
    double vy = 0.0,
  }) {
    posX[index] = x;
    posY[index] = y;
    velX[index] = vx;
    velY[index] = vy;
    if (vx != 0.0 || vy != 0.0) {
      heading[index] = math.atan2(vy, vx);
    }
  }

  int _cellIndexFor(double x, double y) {
    final cellSize = _cellSize;
    int cx = ((x - bounds.left) / cellSize).floor();
    if (cx < 0) {
      cx = 0;
    } else if (cx >= _gridCols) {
      cx = _gridCols - 1;
    }

    int cy = ((y - bounds.top) / cellSize).floor();
    if (cy < 0) {
      cy = 0;
    } else if (cy >= _gridRows) {
      cy = _gridRows - 1;
    }

    return cy * _gridCols + cx;
  }

  /// Rebuilds the spatial hash grid in O(n + numCells) time with zero allocations.
  void rebuildSpatialGrid() {
    _cellCount.fillRange(0, _numCells, 0);

    for (int i = 0; i < unitCount; i++) {
      final c = _cellIndexFor(posX[i], posY[i]);
      _cellOf[i] = c;
      _cellCount[c]++;
    }

    _cellStart[0] = 0;
    for (int c = 0; c < _numCells; c++) {
      _cellStart[c + 1] = _cellStart[c] + _cellCount[c];
      _cellCursor[c] = _cellStart[c];
    }

    for (int i = 0; i < unitCount; i++) {
      final c = _cellOf[i];
      final writeIdx = _cellCursor[c];
      _sortedIndex[writeIdx] = i;
      _cellCursor[c] = writeIdx + 1;
    }
  }

  /// Computes the boundary avoidance steering vector for a unit at (x, y)
  /// with velocity (vx, vy).
  SteeringVector computeBoundaryAvoidance(
    double x,
    double y,
    double vx,
    double vy,
  ) {
    final margin = config.boundaryMargin;
    if (margin <= 0) return const SteeringVector(0, 0);

    double desiredVx = 0;
    double desiredVy = 0;
    bool nearBoundary = false;

    final leftDist = x - bounds.left;
    final rightDist = bounds.right - x;
    final topDist = y - bounds.top;
    final bottomDist = bounds.bottom - y;

    if (leftDist < margin) {
      final factor = ((margin - leftDist) / margin).clamp(0.0, 2.0);
      desiredVx += config.maxSpeed * factor;
      nearBoundary = true;
    } else if (rightDist < margin) {
      final factor = ((margin - rightDist) / margin).clamp(0.0, 2.0);
      desiredVx -= config.maxSpeed * factor;
      nearBoundary = true;
    }

    if (topDist < margin) {
      final factor = ((margin - topDist) / margin).clamp(0.0, 2.0);
      desiredVy += config.maxSpeed * factor;
      nearBoundary = true;
    } else if (bottomDist < margin) {
      final factor = ((margin - bottomDist) / margin).clamp(0.0, 2.0);
      desiredVy -= config.maxSpeed * factor;
      nearBoundary = true;
    }

    if (!nearBoundary) return const SteeringVector(0, 0);

    final steerX = (desiredVx - vx) * config.boundaryAvoidanceWeight;
    final steerY = (desiredVy - vy) * config.boundaryAvoidanceWeight;
    return SteeringVector(steerX, steerY);
  }

  /// Computes the combined Boids steering vector (cohesion, alignment,
  /// separation, boundary avoidance, and target seek) for `index`.
  /// Requires [rebuildSpatialGrid] to have been called for current positions.
  SteeringVector computeSteeringFor(int index) {
    double outX = 0;
    double outY = 0;
    _computeSteeringInternal(index, (sx, sy) {
      outX = sx;
      outY = sy;
    });
    return SteeringVector(outX, outY);
  }

  void _computeSteeringInternal(
    int i,
    void Function(double steerX, double steerY) onSteer,
  ) {
    final px = posX[i];
    final py = posY[i];
    final vx = velX[i];
    final vy = velY[i];

    final perceptionSq = config.perceptionRadius * config.perceptionRadius;
    final separationSq = config.separationRadius * config.separationRadius;
    final maxSpeed = config.maxSpeed;
    final cellSize = _cellSize;

    double sepX = 0, sepY = 0;
    double alignX = 0, alignY = 0;
    double cohX = 0, cohY = 0;
    int neighborCount = 0;

    int cx = ((px - bounds.left) / cellSize).floor();
    if (cx < 0) {
      cx = 0;
    } else if (cx >= _gridCols) {
      cx = _gridCols - 1;
    }

    int cy = ((py - bounds.top) / cellSize).floor();
    if (cy < 0) {
      cy = 0;
    } else if (cy >= _gridRows) {
      cy = _gridRows - 1;
    }

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
          final dx = px - posX[j];
          final dy = py - posY[j];
          final distSq = dx * dx + dy * dy;
          if (distSq > perceptionSq || distSq <= 0.0) continue;

          neighborCount++;
          alignX += velX[j];
          alignY += velY[j];
          cohX += posX[j];
          cohY += posY[j];

          if (distSq < separationSq) {
            final inv = 1.0 / distSq;
            sepX += dx * inv;
            sepY += dy * inv;
          }
        }
      }
    }

    double accX = 0;
    double accY = 0;

    if (neighborCount > 0) {
      final invN = 1.0 / neighborCount;

      // Alignment
      final avgVx = alignX * invN;
      final avgVy = alignY * invN;
      final alignMag = math.sqrt(avgVx * avgVx + avgVy * avgVy);
      if (alignMag > 1e-5) {
        final s = maxSpeed / alignMag;
        accX += (avgVx * s - vx) * config.alignmentWeight;
        accY += (avgVy * s - vy) * config.alignmentWeight;
      }

      // Cohesion
      final centerX = cohX * invN;
      final centerY = cohY * invN;
      final towardX = centerX - px;
      final towardY = centerY - py;
      final cohMag = math.sqrt(towardX * towardX + towardY * towardY);
      if (cohMag > 1e-5) {
        final s = maxSpeed / cohMag;
        accX += (towardX * s - vx) * config.cohesionWeight;
        accY += (towardY * s - vy) * config.cohesionWeight;
      }
    }

    // Separation
    final sepMag = math.sqrt(sepX * sepX + sepY * sepY);
    if (sepMag > 1e-5) {
      final s = maxSpeed / sepMag;
      accX += (sepX * s - vx) * config.separationWeight;
      accY += (sepY * s - vy) * config.separationWeight;
    }

    // Target seek / orbit
    if (hasTarget) {
      final toTargetX = _targetX - px;
      final toTargetY = _targetY - py;
      final distToTarget =
          math.sqrt(toTargetX * toTargetX + toTargetY * toTargetY);

      if (distToTarget > config.arrivalRadius) {
        final s = maxSpeed / distToTarget;
        accX += (toTargetX * s - vx) * config.seekWeight;
        accY += (toTargetY * s - vy) * config.seekWeight;
      } else if (distToTarget > 1e-4) {
        final radialX = toTargetX / distToTarget;
        final radialY = toTargetY / distToTarget;
        final tangentX = -radialY;
        final tangentY = radialX;
        final radiusError = distToTarget - config.orbitRadius;
        double desiredX =
            tangentX * maxSpeed + radialX * radiusError * config.orbitCorrection;
        double desiredY =
            tangentY * maxSpeed + radialY * radiusError * config.orbitCorrection;
        final desiredMag =
            math.sqrt(desiredX * desiredX + desiredY * desiredY);
        if (desiredMag > maxSpeed && desiredMag > 0) {
          final s = maxSpeed / desiredMag;
          desiredX *= s;
          desiredY *= s;
        }
        accX += (desiredX - vx) * config.orbitWeight;
        accY += (desiredY - vy) * config.orbitWeight;
      }
    }

    // Boundary avoidance
    final margin = config.boundaryMargin;
    if (margin > 0) {
      final leftDist = px - bounds.left;
      final rightDist = bounds.right - px;
      final topDist = py - bounds.top;
      final bottomDist = bounds.bottom - py;

      double desiredVx = 0;
      double desiredVy = 0;
      bool nearEdge = false;

      if (leftDist < margin) {
        final factor = ((margin - leftDist) / margin).clamp(0.0, 2.0);
        desiredVx += maxSpeed * factor;
        nearEdge = true;
      } else if (rightDist < margin) {
        final factor = ((margin - rightDist) / margin).clamp(0.0, 2.0);
        desiredVx -= maxSpeed * factor;
        nearEdge = true;
      }

      if (topDist < margin) {
        final factor = ((margin - topDist) / margin).clamp(0.0, 2.0);
        desiredVy += maxSpeed * factor;
        nearEdge = true;
      } else if (bottomDist < margin) {
        final factor = ((margin - bottomDist) / margin).clamp(0.0, 2.0);
        desiredVy -= maxSpeed * factor;
        nearEdge = true;
      }

      if (nearEdge) {
        accX += (desiredVx - vx) * config.boundaryAvoidanceWeight;
        accY += (desiredVy - vy) * config.boundaryAvoidanceWeight;
      }
    }

    // Clamp total force to maxForce
    final accLen = math.sqrt(accX * accX + accY * accY);
    if (accLen > config.maxForce && accLen > 0) {
      final s = config.maxForce / accLen;
      accX *= s;
      accY *= s;
    }

    onSteer(accX, accY);
  }

  /// Advances the Boids simulation by deterministic fixed timestep [dt].
  void update(double dt) {
    if (dt <= 0) return;

    rebuildSpatialGrid();

    final maxSpeed = config.maxSpeed;

    // Pass 1: compute next velocities from current snapshot
    for (int i = 0; i < unitCount; i++) {
      final vx = velX[i];
      final vy = velY[i];

      double steerX = 0;
      double steerY = 0;
      _computeSteeringInternal(i, (sx, sy) {
        steerX = sx;
        steerY = sy;
      });

      double nvx = vx + steerX * dt;
      double nvy = vy + steerY * dt;
      final speed = math.sqrt(nvx * nvx + nvy * nvy);
      if (speed > maxSpeed && speed > 0) {
        final s = maxSpeed / speed;
        nvx *= s;
        nvy *= s;
      }

      _nextVelX[i] = nvx;
      _nextVelY[i] = nvy;
    }

    // Pass 2: commit velocities and integrate positions
    for (int i = 0; i < unitCount; i++) {
      final nvx = _nextVelX[i];
      final nvy = _nextVelY[i];
      velX[i] = nvx;
      velY[i] = nvy;

      double nx = posX[i] + nvx * dt;
      double ny = posY[i] + nvy * dt;

      if (nx < bounds.left) {
        nx = bounds.left;
        if (velX[i] < 0) velX[i] = -velX[i] * 0.5;
      } else if (nx > bounds.right) {
        nx = bounds.right;
        if (velX[i] > 0) velX[i] = -velX[i] * 0.5;
      }

      if (ny < bounds.top) {
        ny = bounds.top;
        if (velY[i] < 0) velY[i] = -velY[i] * 0.5;
      } else if (ny > bounds.bottom) {
        ny = bounds.bottom;
        if (velY[i] > 0) velY[i] = -velY[i] * 0.5;
      }

      posX[i] = nx;
      posY[i] = ny;

      final speedSq = velX[i] * velX[i] + velY[i] * velY[i];
      if (speedSq > 1e-4) {
        heading[i] = math.atan2(velY[i], velX[i]);
      }
    }
  }
}

extension _ArenaMarginExtension on ArenaBounds {
  double boundaryMarginSafe(double requested) => math.max(0.0, requested);
}
