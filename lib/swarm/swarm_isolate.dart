// =============================================================================
// swarm_isolate.dart
//
// Off-main-thread Boids simulation for a 1,500+ entity "Bugger" swarm.
//
// Design notes:
//  - Pure Structure-of-Arrays (SoA). There is no Bugger class and no
//    per-entity heap object is ever allocated during a tick.
//  - Neighbor lookups use a flat, array-based uniform spatial hash built
//    every tick via counting sort: O(n + numCells), zero Map usage, zero
//    per-entity allocation. Cell size == perceptionRadius.
//  - The world is toroidal: positions wrap at width/height, and neighbor
//    distance math wraps too, so boids near an edge correctly flock with
//    boids that "wrapped around" to the opposite edge.
//  - Final output is one flat Float32List, 4 floats/entity: [x, y, rot, scale],
//    handed back to the main isolate via TransferableTypedData (zero-copy).
// =============================================================================

import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

// -----------------------------------------------------------------------------
// Message protocol (main isolate <-> this worker)
// -----------------------------------------------------------------------------

/// Sent once, immediately on spawn, so the main isolate gets a port to
/// talk back to this worker.
class SwarmHandshake {
  final SendPort commandPort;
  const SwarmHandshake(this.commandPort);
}

/// Sent once to configure (or re-configure) the simulation.
class SwarmInitMessage {
  final int entityCount;
  final double worldWidth;
  final double worldHeight;

  final double perceptionRadius; // also == spatial hash cell size
  final double separationRadius;
  final double maxSpeed;
  final double maxForce;
  final double cohesionWeight;
  final double alignmentWeight;
  final double separationWeight;
  final int seed;

  /// Optional interleaved [x0,y0,x1,y1,...]. If null, entities are
  /// scattered uniformly at random across the world.
  final Float32List? initialPositions;

  /// Optional interleaved [vx0,vy0,vx1,vy1,...]. If null, random headings
  /// at a random fraction of maxSpeed are used.
  final Float32List? initialVelocities;

  const SwarmInitMessage({
    required this.entityCount,
    required this.worldWidth,
    required this.worldHeight,
    this.perceptionRadius = 64.0,
    this.separationRadius = 24.0,
    this.maxSpeed = 120.0,
    this.maxForce = 220.0,
    this.cohesionWeight = 1.0,
    this.alignmentWeight = 1.2,
    this.separationWeight = 1.8,
    this.seed = 1337,
    this.initialPositions,
    this.initialVelocities,
  });
}

/// Sent every frame from the main isolate to request a step.
class SwarmTickMessage {
  final double dt;
  const SwarmTickMessage(this.dt);
}

/// Sent back every frame.
///
/// On the main isolate, materialize it like this:
/// ```dart
/// final ByteBuffer buf = message.payload.materialize();
/// final Float32List frame = Float32List.view(buf);
/// // frame[i*4+0]=x, [i*4+1]=y, [i*4+2]=rotation, [i*4+3]=scale
/// ```
class SwarmFrameMessage {
  final TransferableTypedData payload;
  final int entityCount;
  const SwarmFrameMessage(this.payload, this.entityCount);
}

const String kShutdownCommand = '__swarm_shutdown__';

// -----------------------------------------------------------------------------
// Entry point
//
// Usage from the main isolate:
//   final receivePort = ReceivePort();
//   await Isolate.spawn(swarmIsolateEntryPoint, receivePort.sendPort);
//   // first message received is a SwarmHandshake -> stash its commandPort
//   // then commandPort.send(SwarmInitMessage(...))
//   // then every frame: commandPort.send(SwarmTickMessage(dt))
// -----------------------------------------------------------------------------

void swarmIsolateEntryPoint(SendPort mainSendPort) {
  final ReceivePort commandPort = ReceivePort();
  mainSendPort.send(SwarmHandshake(commandPort.sendPort));

  _SwarmWorld? world;

  commandPort.listen((dynamic message) {
    if (message is SwarmInitMessage) {
      world = _SwarmWorld(message);
    } else if (message is SwarmTickMessage) {
      final w = world;
      if (w == null) return; // ignore ticks that arrive before init
      final Float32List frame = w.step(message.dt);
      // TransferableTypedData.fromList CONSUMES the list passed to it
      // (it becomes unusable in this isolate afterwards), which is exactly
      // what we want: ownership of the buffer's memory moves to the main
      // isolate with zero copying. That's why `frame` must be a fresh
      // allocation every tick rather than a reused scratch buffer.
      final transferable = TransferableTypedData.fromList(<TypedData>[frame]);
      mainSendPort.send(SwarmFrameMessage(transferable, w.entityCount));
    } else if (message == kShutdownCommand) {
      commandPort.close();
    }
  });
}

// -----------------------------------------------------------------------------
// Simulation world. NOTE: this is a manager/container class, not a per-entity
// object -- there is exactly one instance of it, ever. All entity data lives
// in flat typed-data arrays below.
// -----------------------------------------------------------------------------

class _SwarmWorld {
  _SwarmWorld(SwarmInitMessage init)
      : entityCount = init.entityCount,
        width = init.worldWidth,
        height = init.worldHeight,
        perceptionRadius = init.perceptionRadius,
        separationRadius = init.separationRadius,
        maxSpeed = init.maxSpeed,
        maxForce = init.maxForce,
        cohesionWeight = init.cohesionWeight,
        alignmentWeight = init.alignmentWeight,
        separationWeight = init.separationWeight,
        cellSize = init.perceptionRadius {
    posX = Float32List(entityCount);
    posY = Float32List(entityCount);
    velX = Float32List(entityCount);
    velY = Float32List(entityCount);
    newVelX = Float32List(entityCount);
    newVelY = Float32List(entityCount);
    rotation = Float32List(entityCount);
    scale = Float32List(entityCount);

    final rng = math.Random(init.seed);

    for (int i = 0; i < entityCount; i++) {
      if (init.initialPositions != null) {
        posX[i] = init.initialPositions![i * 2];
        posY[i] = init.initialPositions![i * 2 + 1];
      } else {
        posX[i] = rng.nextDouble() * width;
        posY[i] = rng.nextDouble() * height;
      }

      if (init.initialVelocities != null) {
        velX[i] = init.initialVelocities![i * 2];
        velY[i] = init.initialVelocities![i * 2 + 1];
      } else {
        final angle = rng.nextDouble() * math.pi * 2;
        final speed = maxSpeed * (0.3 + rng.nextDouble() * 0.7);
        velX[i] = math.cos(angle) * speed;
        velY[i] = math.sin(angle) * speed;
      }

      scale[i] = 1.0;
      rotation[i] = math.atan2(velY[i], velX[i]);
    }

    // Grid sizing: floor (not ceil) the cell counts so any remainder is
    // absorbed into the last row/column, making boundary cells >= cellSize
    // rather than smaller than it. That guarantees a 3x3-cell search
    // around any entity is always sufficient to find every true neighbor
    // within perceptionRadius -- a grid with cells *smaller* than the
    // search radius would silently miss neighbors two cells away.
    gridCols = math.max(1, (width / cellSize).floor());
    gridRows = math.max(1, (height / cellSize).floor());
    numCells = gridCols * gridRows;

    cellCount = Int32List(numCells);
    cellStart = Int32List(numCells + 1);
    cellCursor = Int32List(numCells);
    entityCellIndex = Int32List(entityCount);
    sortedIndices = Int32List(entityCount);

    dxOffsets = _neighborOffsets(gridCols);
    dyOffsets = _neighborOffsets(gridRows);
  }

  // --- Config --------------------------------------------------------------
  final int entityCount;
  final double width;
  final double height;
  final double perceptionRadius;
  final double separationRadius;
  final double maxSpeed;
  final double maxForce;
  final double cohesionWeight;
  final double alignmentWeight;
  final double separationWeight;
  final double cellSize;

  static const double _maxDt = 1 / 15; // clamp dt spikes (app resume, jank)
  static const double _minSpeedSqForRotation = 1.0; // avoid rotation jitter near-zero speed

  // --- SoA entity state ------------------------------------------------------
  late final Float32List posX;
  late final Float32List posY;
  late final Float32List velX;
  late final Float32List velY;
  late final Float32List newVelX; // scratch: written in pass A, applied in pass B
  late final Float32List newVelY;
  late final Float32List rotation; // persisted so heading doesn't jitter when nearly stopped
  late final Float32List scale; // extension hook (spawn/death pulses, selection, etc.)

  // --- Spatial hash grid (array-based counting sort, rebuilt every tick) -----
  late int gridCols;
  late int gridRows;
  late int numCells;
  late Int32List cellCount; // entities per cell, this tick
  late Int32List cellStart; // size numCells+1, prefix-summed offsets
  late Int32List cellCursor; // scratch write cursor for the counting sort
  late Int32List entityCellIndex; // cell index per entity, this tick
  late Int32List sortedIndices; // entity indices grouped contiguously by cell
  late List<int> dxOffsets;
  late List<int> dyOffsets;

  /// For a grid axis with < 3 cells, wrapping would otherwise visit the
  /// same cell more than once in a naive [-1,0,1] loop. This collapses the
  /// offsets to the unique set for that axis size.
  static List<int> _neighborOffsets(int gridSize) {
    if (gridSize <= 1) return const [0];
    if (gridSize == 2) return const [0, 1];
    return const [-1, 0, 1];
  }

  static int _clampIndex(int v, int sizeExclusive) {
    if (v < 0) return 0;
    if (v >= sizeExclusive) return sizeExclusive - 1;
    return v;
  }

  int _cellIndexOf(int i) {
    final cx = _clampIndex((posX[i] / cellSize).floor(), gridCols);
    final cy = _clampIndex((posY[i] / cellSize).floor(), gridRows);
    return cy * gridCols + cx;
  }

  /// Shortest signed delta on a toroidal axis (handles wrap-around).
  static double _wrapDelta(double d, double size) {
    if (d > size * 0.5) return d - size;
    if (d < -size * 0.5) return d + size;
    return d;
  }

  /// Wraps a coordinate back into [0, size).
  static double _wrapCoord(double v, double size) {
    double r = v % size;
    if (r < 0) r += size;
    return r;
  }

  // ---------------------------------------------------------------------------
  // Rebuild the spatial hash via counting sort: O(n + numCells), no Map,
  // no per-entity heap allocation. Replaces an O(n^2) neighbor scan.
  // ---------------------------------------------------------------------------
  void _rebuildGrid() {
    cellCount.fillRange(0, numCells, 0);

    for (int i = 0; i < entityCount; i++) {
      final cellIdx = _cellIndexOf(i);
      entityCellIndex[i] = cellIdx;
      cellCount[cellIdx]++;
    }

    cellStart[0] = 0;
    for (int c = 0; c < numCells; c++) {
      cellStart[c + 1] = cellStart[c] + cellCount[c];
    }

    for (int c = 0; c < numCells; c++) {
      cellCursor[c] = cellStart[c];
    }

    for (int i = 0; i < entityCount; i++) {
      final cellIdx = entityCellIndex[i];
      final writePos = cellCursor[cellIdx];
      sortedIndices[writePos] = i;
      cellCursor[cellIdx] = writePos + 1;
    }
  }

  // ---------------------------------------------------------------------------
  // Advance the simulation by `rawDt` seconds. Returns a freshly-allocated
  // [x, y, rotation, scale] buffer (4 floats per entity). Fresh allocation
  // is required every call because TransferableTypedData consumes it.
  // ---------------------------------------------------------------------------
  Float32List step(double rawDt) {
    double dt = rawDt;
    if (dt < 0) dt = 0;
    if (dt > _maxDt) dt = _maxDt;

    _rebuildGrid();

    final double perceptionSq = perceptionRadius * perceptionRadius;
    final double separationSq = separationRadius * separationRadius;

    // ---- Pass A: compute steering, write into scratch newVelX/newVelY. ----
    // (Reads only the *previous* tick's posX/posY/velX/velY, so write order
    // across entities cannot affect the result -- this is what makes it
    // safe to mutate velX/velY for real in Pass B.)
    for (int i = 0; i < entityCount; i++) {
      final double pix = posX[i];
      final double piy = posY[i];
      final double vix = velX[i];
      final double viy = velY[i];

      double cohSumX = 0, cohSumY = 0;
      double alignSumX = 0, alignSumY = 0;
      double sepSumX = 0, sepSumY = 0;
      int neighborCount = 0;
      int sepCount = 0;

      final cx = _clampIndex((pix / cellSize).floor(), gridCols);
      final cy = _clampIndex((piy / cellSize).floor(), gridRows);

      for (final dxOff in dxOffsets) {
        final nx = (cx + dxOff + gridCols) % gridCols;
        for (final dyOff in dyOffsets) {
          final ny = (cy + dyOff + gridRows) % gridRows;
          final cellIdx = ny * gridCols + nx;

          final start = cellStart[cellIdx];
          final end = cellStart[cellIdx + 1];

          for (int k = start; k < end; k++) {
            final j = sortedIndices[k];
            if (j == i) continue;

            final dx = _wrapDelta(posX[j] - pix, width);
            final dy = _wrapDelta(posY[j] - piy, height);
            final distSq = dx * dx + dy * dy;
            if (distSq <= 0.0) continue; // skip exact overlaps (avoid div-by-zero)

            if (distSq < perceptionSq) {
              cohSumX += dx;
              cohSumY += dy;
              alignSumX += velX[j];
              alignSumY += velY[j];
              neighborCount++;
            }
            if (distSq < separationSq) {
              // Inverse-distance-squared repulsion: closer neighbors push harder.
              sepSumX -= dx / distSq;
              sepSumY -= dy / distSq;
              sepCount++;
            }
          }
        }
      }

      double steerX = 0, steerY = 0;

      if (neighborCount > 0) {
        final invN = 1.0 / neighborCount;

        // Cohesion: steer toward the average position offset of neighbors.
        final cohX = cohSumX * invN;
        final cohY = cohSumY * invN;
        final cohMag = math.sqrt(cohX * cohX + cohY * cohY);
        if (cohMag > 1e-5) {
          final s = maxSpeed / cohMag;
          steerX += (cohX * s - vix) * cohesionWeight;
          steerY += (cohY * s - viy) * cohesionWeight;
        }

        // Alignment: steer toward the average heading of neighbors.
        final avgVx = alignSumX * invN;
        final avgVy = alignSumY * invN;
        final velMag = math.sqrt(avgVx * avgVx + avgVy * avgVy);
        if (velMag > 1e-5) {
          final s = maxSpeed / velMag;
          steerX += (avgVx * s - vix) * alignmentWeight;
          steerY += (avgVy * s - viy) * alignmentWeight;
        }
      }

      if (sepCount > 0) {
        final invN = 1.0 / sepCount;
        final sepX = sepSumX * invN;
        final sepY = sepSumY * invN;
        final sepMag = math.sqrt(sepX * sepX + sepY * sepY);
        if (sepMag > 1e-5) {
          final s = maxSpeed / sepMag;
          steerX += (sepX * s - vix) * separationWeight;
          steerY += (sepY * s - viy) * separationWeight;
        }
      }

      // Clamp total steering force.
      final steerMag = math.sqrt(steerX * steerX + steerY * steerY);
      if (steerMag > maxForce) {
        final s = maxForce / steerMag;
        steerX *= s;
        steerY *= s;
      }

      double nvx = vix + steerX * dt;
      double nvy = viy + steerY * dt;
      final speed = math.sqrt(nvx * nvx + nvy * nvy);
      if (speed > maxSpeed) {
        final s = maxSpeed / speed;
        nvx *= s;
        nvy *= s;
      }

      newVelX[i] = nvx;
      newVelY[i] = nvy;
    }

    // ---- Pass B: commit velocities, integrate position, wrap, pack output. ----
    final Float32List out = Float32List(entityCount * 4);

    for (int i = 0; i < entityCount; i++) {
      final nvx = newVelX[i];
      final nvy = newVelY[i];
      velX[i] = nvx;
      velY[i] = nvy;

      double px = posX[i] + nvx * dt;
      double py = posY[i] + nvy * dt;
      px = _wrapCoord(px, width);
      py = _wrapCoord(py, height);
      posX[i] = px;
      posY[i] = py;

      final speedSq = nvx * nvx + nvy * nvy;
      if (speedSq > _minSpeedSqForRotation) {
        rotation[i] = math.atan2(nvy, nvx);
      }

      final o = i * 4;
      out[o] = px;
      out[o + 1] = py;
      out[o + 2] = rotation[i];
      out[o + 3] = scale[i];
    }

    return out;
  }
}
