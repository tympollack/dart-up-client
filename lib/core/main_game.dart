import 'dart:typed_data';
import 'package:flame/game.dart';
import 'package:sd_client/swarm/bugger_swarm.dart';

class DartUpGame extends FlameGame {
  late BuggerSwarmComponent swarm;
  final int swarmCount = 1500;
  late Float32List dummyData;

  @override
  Future<void> onLoad() async {
    // 1. Initialize the empty array (1500 bugs * 4 values each = 6000 slots)
    dummyData = Float32List(swarmCount * 4);
    
    // 2. Add our Swarm renderer to the game
    swarm = BuggerSwarmComponent(maxEntities: swarmCount);
    add(swarm);
    
    // 3. Scatter the bugs randomly for their starting positions
    for (int i = 0; i < swarmCount; i++) {
      dummyData[i * 4] = (i * 13.0) % size.x;     // Fake random X
      dummyData[(i * 4) + 1] = (i * 17.0) % size.y; // Fake random Y
      dummyData[(i * 4) + 3] = 1.0;                 // Scale
    }
  }

  @override
  void update(double dt) {
    super.update(dt);
    
    // THE FAKE MATH: Just make them drift down and to the right
    // Later, this entire block gets deleted and replaced by the Isolate!
    for (int i = 0; i < swarmCount; i++) {
      final int baseIndex = i * 4;
      
      // Update X and Y, wrapping around the screen edges
      dummyData[baseIndex] = (dummyData[baseIndex] + 50 * dt) % size.x; 
      dummyData[baseIndex + 1] = (dummyData[baseIndex + 1] + 30 * dt) % size.y; 
      
      // Add a slight spin to test rotation
      dummyData[baseIndex + 2] += 2.0 * dt; 
    }
    
    // Hand the finished array to the renderer
    swarm.updateSwarmData(dummyData);
  }
}
