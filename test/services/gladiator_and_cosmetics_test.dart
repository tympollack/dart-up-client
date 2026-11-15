import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sd_client/celestial/celestial_node_manager.dart';
import 'package:sd_client/combat/enemy_director.dart';
import 'package:sd_client/combat/fighter_roster.dart';
import 'package:sd_client/player/ship_warp_controller.dart';
import 'package:sd_client/services/gladiator_and_cosmetics_service.dart';
import 'package:sd_client/services/hub_api_service.dart';
import 'package:sd_client/swarm/drone_swarm_economy.dart';

void main() {
  group('TASK-DARTUP-GLADIATOR-LISTENER: Gladiator Drop Events & Cosmetic Hull Skin Loader', () {
    test('Handles solar_flare, drone_swarm, and supply_crate gladiator_drop broadcasts within 250ms', () {
      final hubService = HubApiService();
      final economy = DroneSwarmEconomy(maxFleetSize: 50);
      economy.availableCount = 10;

      final warpController = ShipWarpController(
        economy: economy,
        fighterRoster: FighterRoster(maxFighterCount: 12),
      );
      warpController.shipEnergy = 40.0;

      final nodeManager = CelestialNodeManager();
      nodeManager.registerNode(const PlanetNode(
        id: 'p1',
        x: 500,
        y: 500,
        interactionRadius: 150,
        factionAlignment: 'neutral',
      ));

      final director = EnemyDirector(
        maxSquadCount: 8,
        nodeManager: nodeManager,
        enemyFighterRoster: FighterRoster(maxFighterCount: 24),
        playerShipController: warpController,
      );

      final listener = GladiatorMatchListener(
        hubApiService: hubService,
        economy: economy,
        warpController: warpController,
        enemyDirector: director,
      );

      final channel = hubService.subscribeToMatchChannel('match_gladiator_1');
      listener.attachToChannel(channel);

      // 1. !solar_flare drop
      channel.emitSimulatedBroadcast('gladiator_drop', {
        'drop_id': 'flare_01',
        'command': '!solar_flare',
        'x': 320.0,
        'y': -180.0,
        'radius': 260.0,
        'sponsor_handle': 'SolarKing',
      });

      expect(listener.spawnRecords.length, equals(1));
      final flareRecord = listener.spawnRecords.first;
      expect(flareRecord.event.type, equals(GladiatorDropType.solarFlare));
      expect(flareRecord.injectionLatency.inMilliseconds, lessThan(250));
      expect(warpController.anomalies.length, equals(1));
      expect(warpController.anomalies.first.id, equals('gladiator_flare_flare_01'));

      // 2. !drone_swarm drop
      channel.emitSimulatedBroadcast('gladiator_drop', {
        'drop_id': 'swarm_02',
        'drop_type': 'drone_swarm',
        'x': -400.0,
        'y': 250.0,
      });

      expect(listener.spawnRecords.length, equals(2));
      final swarmRecord = listener.spawnRecords[1];
      expect(swarmRecord.event.type, equals(GladiatorDropType.droneSwarm));
      expect(swarmRecord.injectionLatency.inMilliseconds, lessThan(250));
      expect(director.squadCount, equals(1));
      expect(swarmRecord.spawnedStrandedDrones, equals(3));

      // 3. supply_crate drop
      channel.emitSimulatedBroadcast('gladiator_drop', {
        'drop_id': 'supply_03',
        'drop_type': 'supply_crate',
        'x': 100.0,
        'y': 100.0,
      });

      expect(listener.spawnRecords.length, equals(3));
      final supplyRecord = listener.spawnRecords[2];
      expect(supplyRecord.event.type, equals(GladiatorDropType.supplyCrate));
      expect(supplyRecord.injectionLatency.inMilliseconds, lessThan(250));
      expect(supplyRecord.energyRestored, closeTo(35.0, 1e-4));
      expect(warpController.shipEnergy, closeTo(75.0, 1e-4));

      listener.dispose();
      hubService.dispose();
    });

    test('Loads equipped Smuggler Hull and drone swarm trail cosmetics from Hub profile and resolves @sunshade/assets CDN URLs', () async {
      final mockClient = MockClient((http.Request req) async {
        if (req.url.path == '/api/profile/cosmetics') {
          return http.Response(
            jsonEncode({
              'equipped_cosmetics': {
                'hull_skin_id': 'smuggler_hull_crimson',
                'hull_display_name': 'Smuggler Hull (Crimson)',
                'swarm_trail_id': 'void_ember_trail',
                'swarm_trail_display_name': 'Void Ember Trail',
                'primary_tint_hex': 0xFFFF3B3B,
              },
            }),
            200,
          );
        }
        return http.Response('Not Found', 404);
      });

      final hubService = HubApiService(httpClient: mockClient);
      hubService.authenticateWithSession(accessToken: 'jwt_cosmetics_test');

      final economy = DroneSwarmEconomy(maxFleetSize: 10);
      final warpController = ShipWarpController(
        economy: economy,
        fighterRoster: FighterRoster(maxFighterCount: 4),
      );

      final listener = GladiatorMatchListener(
        hubApiService: hubService,
        economy: economy,
        warpController: warpController,
        httpClient: mockClient,
      );

      final manifest = await listener.loadEquippedCosmetics();
      expect(manifest.hullSkinId, equals('smuggler_hull_crimson'));
      expect(manifest.hullDisplayName, equals('Smuggler Hull (Crimson)'));
      expect(
        manifest.hullSpriteCdnUrl,
        equals('https://assets.sunshade.icu/@sunshade/assets/dart-up/hulls/smuggler_hull_crimson/manifest.json'),
      );
      expect(manifest.swarmTrailId, equals('void_ember_trail'));
      expect(
        manifest.swarmTrailSpriteCdnUrl,
        equals('https://assets.sunshade.icu/@sunshade/assets/dart-up/trails/void_ember_trail/manifest.json'),
      );
      expect(manifest.primaryTintHex, equals(0xFFFF3B3B));

      listener.dispose();
      hubService.dispose();
    });

    test('Disposed GladiatorMatchListener detaches from channel and ignores subsequent drops', () {
      final hubService = HubApiService();
      final economy = DroneSwarmEconomy(maxFleetSize: 20);
      final warpController = ShipWarpController(
        economy: economy,
        fighterRoster: FighterRoster(maxFighterCount: 4),
      );

      final listener = GladiatorMatchListener(
        hubApiService: hubService,
        economy: economy,
        warpController: warpController,
      );

      final channel = hubService.subscribeToMatchChannel('match_dispose_test');
      listener.attachToChannel(channel);
      listener.dispose();

      channel.emitSimulatedBroadcast('gladiator_drop', {
        'drop_id': 'flare_after_dispose',
        'command': '!solar_flare',
        'x': 100.0,
        'y': 100.0,
      });

      expect(listener.spawnRecords, isEmpty);
      expect(warpController.anomalies, isEmpty);
      hubService.dispose();
    });
  });
}
