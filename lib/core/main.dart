// =============================================================================
// dart_up_game.dart
//
// Root game class. Owns the master instances of every engine-agnostic
// controller (DroneSwarmEconomy, HackingController, ShipWarpController)
// and is the ONLY place that ticks them or pumps the swarm isolate. Every
// component below this in the tree only ever reads from these -- none of
// them call update() on a controller, and none of them contain physics,
// state-transition, or timing math of their own. That split is the whole
// point: this file is allowed to orchestrate ("call .update(dt) on these
// three things, in this order, every frame"); it is NOT allowed to
// reimplement what's inside them.
// =============================================================================

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flame/events.dart';
import 'package:flame/game.dart';

import 'package:sd_client/swarm/drone_swarm_economy.dart';
import 'package:sd_client/combat/fighter_roster.dart';
import 'package:sd_client/player/hacking_controller.dart';
import 'package:sd_client/player/hacking_ui_component.dart';
import 'package:sd_client/player/player_ship_component.dart';
import 'package:sd_client/player/ship_warp_controller.dart';
import 'package:sd_client/swarm/swarm_isolate.dart';
import 'package:sd_client/swarm/swarm_render_component.dart';

class DartUpGame extends FlameGame with TapCallbacks {
  // ---- Engine-agnostic master state. See file header. ----
  late final DroneSwarmEconomy economy;
  late final FighterRoster fighterRoster;
  late final HackingController hackingController;
  late final ShipWarpController shipWarpController;

  // ---- Components ----
  late final PlayerShipComponent shipComponent;
  late final SwarmRenderComponent swarmRenderComponent;
  late final HackingUIComponent hackingUIComponent;

  // ---- Swarm isolate plumbing ----
  Isolate? _swarmIsolate;
  SendPort? _swarmCommandPort;
  ReceivePort? _swarmReceivePort;
  static const int _swarmEntityCount = 1500;

  @override
  Future<void> onLoad() async {
    await super.onLoad();

    economy = DroneSwarmEconomy(maxFleetSize: 300);
    fighterRoster = FighterRoster(maxFighterCount: 24);

    shipWarpController = ShipWarpController(
      economy: economy,
      fighterRoster: fighterRoster,
      onWarpComplete: (result) {
        // Critical: move the ship's own logical position to where it
        // actually landed. economy/fighterRoster already teleported any
        // surviving units to result.arrival.x/y -- without this line the
        // ship sprite would stay stuck at the old departure point while
        // its own fleet jumps out from under it.
        shipComponent.setBasePosition(
          Vector2(result.arrival.x, result.arrival.y),
        );
        // result.dronesStranded / result.fightersStranded.{rendezvousCount,
        // scrambleCount, lastStandCount} / result.wake -- hook your
        // warp-completed VFX/SFX here. Arriving (the 2s deceleration
        // window) resolves back to Idle on its own; no resetToIdle()
        // call needed for the normal flow anymore.
      },
    );

    hackingController = HackingController(
      economy: economy,
      onHackSuccess: (result) {
        // Hook your hack-success VFX/SFX here.
      },
    );

    shipComponent = PlayerShipComponent(
      warpController: shipWarpController,
      size: Vector2(48, 48),
      position: size / 2, // screen center -- adjust to your layout
    );

    // Adjust the asset path and source rect to your actual atlas layout.
    final ui.Image atlasImage = await images.load('drone_atlas.png');
    swarmRenderComponent = SwarmRenderComponent(
      atlasImage: atlasImage,
      spriteRect: const ui.Rect.fromLTWH(0, 0, 32, 32),
    );

    hackingUIComponent = HackingUIComponent(controller: hackingController);

    await addAll([
      swarmRenderComponent, // rendered first -- sits "below" ship/UI
      shipComponent,
      hackingUIComponent,
    ]);

    await _spawnSwarmIsolate();
  }

  Future<void> _spawnSwarmIsolate() async {
    _swarmReceivePort = ReceivePort();
    _swarmIsolate = await Isolate.spawn(
      swarmIsolateEntryPoint,
      _swarmReceivePort!.sendPort,
    );

    final Completer<SendPort> handshake = Completer<SendPort>();

    _swarmReceivePort!.listen((dynamic message) {
      if (message is SwarmHandshake) {
        handshake.complete(message.commandPort);
      } else if (message is SwarmFrameMessage) {
        _onSwarmFrame(message);
      }
    });

    _swarmCommandPort = await handshake.future;
    _swarmCommandPort!.send(SwarmInitMessage(
      entityCount: _swarmEntityCount,
      worldWidth: size.x,
      worldHeight: size.y,
    ));
  }

  void _onSwarmFrame(SwarmFrameMessage message) {
    final ByteBuffer buffer = message.payload.materialize();
    final Float32List frame = Float32List.view(buffer);
    swarmRenderComponent.updateFrame(frame, message.entityCount);
  }

  @override
  void update(double dt) {
    super.update(dt);

    // This is the ONLY place these get ticked. Everything downstream
    // (components) only ever reads the results of these calls -- never
    // recomputes them.
    economy.update(
      dt,
      shipX: shipComponent.basePosition.x,
      shipY: shipComponent.basePosition.y,
    );
    hackingController.update(dt);
    shipWarpController.update(dt);

    _swarmCommandPort?.send(SwarmTickMessage(dt));
  }

  @override
  void onRemove() {
    _swarmCommandPort?.send(kShutdownCommand);
    _swarmReceivePort?.close();
    _swarmIsolate?.kill(priority: Isolate.immediate);
    _swarmIsolate = null;
    super.onRemove();
  }

  // ---------------------------------------------------------------------------
  // Input hooks: pass a target coordinate into the hacking controller.
  // Just event plumbing -- the hack's actual timing/state lives entirely
  // inside HackingController.
  // ---------------------------------------------------------------------------

  @override
  void onTapDown(TapDownEvent event) {
    hackingController.beginHack(
      event.canvasPosition.x,
      event.canvasPosition.y,
    );
  }

  @override
  void onTapUp(TapUpEvent event) {
    hackingController.releaseHack();
  }

  @override
  void onTapCancel(TapCancelEvent event) {
    hackingController.releaseHack();
  }
}
