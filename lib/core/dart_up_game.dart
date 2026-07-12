// =============================================================================
// dart_up_game.dart
//
// Root game class. Owns the master instances of every engine-agnostic
// controller/manager (DroneSwarmEconomy, HackingController,
// ShipWarpController, CelestialNodeManager, EnemyDirector, CombatManager)
// and is the ONLY place that ticks them or pumps the swarm isolate. Every
// component below this in the tree only ever reads from these -- none of
// them call update() on a controller, and none of them contain physics,
// state-transition, or timing math of their own. That split is the whole
// point: this file is allowed to orchestrate ("call .update(dt) on these
// things, in this order, every frame"); it is NOT allowed to reimplement
// what's inside them.
// =============================================================================

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flame/components.dart';
import 'package:flame/events.dart';
import 'package:flame/game.dart';

import 'package:sd_client/celestial/celestial_node_component.dart';
import 'package:sd_client/celestial/celestial_node_manager.dart';
import 'package:sd_client/combat/combat_manager.dart';
import 'package:sd_client/combat/combat_vfx_component.dart';
import 'package:sd_client/swarm/drone_swarm_economy.dart';
import 'package:sd_client/combat/enemy_director.dart';
import 'package:sd_client/combat/enemy_fighter_render_component.dart';
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
  late final FighterRoster fighterRoster; // the PLAYER's own fighters
  late final FighterRoster enemyFighterRoster; // a SEPARATE roster -- never shared with the player's
  late final HackingController hackingController;
  late final ShipWarpController shipWarpController;
  late final CelestialNodeManager nodeManager;
  late final EnemyDirector enemyDirector;
  late final CombatManager combatManager;

  // ---- Components ----
  late final PlayerShipComponent shipComponent;
  late final SwarmRenderComponent swarmRenderComponent;
  late final HackingUIComponent hackingUIComponent;
  late final CelestialNodeComponent celestialNodeComponent;
  late final EnemyFighterRenderComponent enemyFighterRenderComponent;
  late final CombatVFXComponent combatVFXComponent;

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
    enemyFighterRoster = FighterRoster(maxFighterCount: 60);

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

    // ---- Celestial nodes ----------------------------------------------
    nodeManager = CelestialNodeManager();
    // Placeholder nodes, per your request, so this is visible
    // immediately. Swap coordinates/ids for your actual sector layout
    // whenever you're ready.
    nodeManager.registerNode(const PlanetNode(
      id: 'planet_alpha',
      x: 500,
      y: 350,
      interactionRadius: 220,
      factionAlignment: 'neutral',
      richnessMultiplier: 1.0,
    ));
    nodeManager.registerNode(const NebulaNode(
      id: 'nebula_veil',
      x: -450,
      y: -300,
      interactionRadius: 380,
      obscurityMultiplier: 0.2,
    ));

    // ---- Enemy AI -------------------------------------------------------
    enemyDirector = EnemyDirector(
      maxSquadCount: 12,
      nodeManager: nodeManager,
      enemyFighterRoster: enemyFighterRoster,
      playerShipController: shipWarpController,
      onSquadEngaged: (squadIndex) {
        // Hook your "incoming!" alert SFX/HUD here.
      },
    );
    // Beyond what you asked for, but the Director would otherwise be
    // entirely invisible until something else spawns a squad -- two
    // placeholder patrols so there's an actual hunt to see. Remove once
    // you have real squad-spawning logic (e.g. sector population on
    // arrival).
    enemyDirector.spawnSquad(900, 900);
    enemyDirector.spawnSquad(-900, 600);

    // ---- Combat ---------------------------------------------------------
    // combatVFXComponent must exist BEFORE combatManager is constructed:
    // CombatManager.onDamageDealt is final, set only via the constructor,
    // so the callback target has to already exist at that point. It
    // doesn't need to be added to the component tree yet, just instantiated.
    combatVFXComponent = CombatVFXComponent();

    combatManager = CombatManager(
      economy: economy,
      enemyFighterRoster: enemyFighterRoster,
      playerShipController: shipWarpController,
      onDamageDealt: combatVFXComponent.recordHit,
    );

    // Adjust the asset path and source rect to your actual atlas layout.
    final ui.Image atlasImage = await images.load('drone_atlas.png');
    swarmRenderComponent = SwarmRenderComponent(
      atlasImage: atlasImage,
      spriteRect: const ui.Rect.fromLTWH(0, 0, 32, 32),
    );

    hackingUIComponent = HackingUIComponent(controller: hackingController);
    celestialNodeComponent = CelestialNodeComponent(nodeManager: nodeManager);
    enemyFighterRenderComponent = EnemyFighterRenderComponent(
      enemyFighterRoster: enemyFighterRoster,
    );

    await addAll([
      celestialNodeComponent, // background: planets/nebulae
      swarmRenderComponent, // player drone swarm
      enemyFighterRenderComponent, // enemy fighters
      shipComponent, // player ship
      hackingUIComponent, // hack circle overlay
      combatVFXComponent, // laser flashes -- drawn last, on top of everything
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
    final double playerX = shipComponent.basePosition.x;
    final double playerY = shipComponent.basePosition.y;

    economy.update(dt, shipX: playerX, shipY: playerY);
    hackingController.update(dt);
    shipWarpController.update(dt);

    // Order matters here: EnemyDirector may spawn fresh enemy fighters
    // this tick (a squad engaging for the first time); running
    // CombatManager.update() AFTER it means those fighters are already
    // visible to combat resolution the very same frame they spawn,
    // rather than sitting idle for one extra tick.
    enemyDirector.update(dt, playerX: playerX, playerY: playerY);
    combatManager.update(dt, playerX: playerX, playerY: playerY);

    _swarmCommandPort?.send(SwarmTickMessage(dt));
  }

  @override
  void onRemove() {
    _swarmCommandPort?.send(kShutdownCommand);
    _swarmReceivePort?.close();
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
