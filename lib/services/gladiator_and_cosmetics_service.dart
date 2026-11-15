// =============================================================================
// gladiator_and_cosmetics_service.dart
//
// Live audience Gladiator drop event listener (`solar_flare`, `drone_swarm`,
// `supply_crate`) and Hub cosmetic loadout profile loader resolving
// `Smuggler Hull` and drone swarm trail manifests via `@sunshade/assets` CDN URLs.
// =============================================================================

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:sd_client/combat/enemy_director.dart';
import 'package:sd_client/player/ship_warp_controller.dart';
import 'package:sd_client/services/hub_api_service.dart';
import 'package:sd_client/swarm/drone_swarm_economy.dart';

/// Supported Gladiator audience intervention types.
enum GladiatorDropType {
  solarFlare('solar_flare'),
  droneSwarm('drone_swarm'),
  supplyCrate('supply_crate');

  const GladiatorDropType(this.wireValue);
  final String wireValue;

  static GladiatorDropType? fromWire(String raw) {
    final normalized = raw.trim().toLowerCase().replaceFirst(RegExp(r'^!'), '');
    for (final t in GladiatorDropType.values) {
      if (t.wireValue == normalized) return t;
    }
    return null;
  }
}

/// Structured Gladiator intervention payload received over the match channel.
class GladiatorDropEvent {
  final String dropId;
  final GladiatorDropType type;
  final double x;
  final double y;
  final double radius;
  final String sponsorHandle;
  final DateTime receivedAt;

  const GladiatorDropEvent({
    required this.dropId,
    required this.type,
    required this.x,
    required this.y,
    this.radius = 220.0,
    this.sponsorHandle = 'TwitchGladiator',
    required this.receivedAt,
  });

  factory GladiatorDropEvent.fromPayload(
    Map<String, dynamic> payload, {
    DateTime? receivedAt,
  }) {
    final Map<String, dynamic> inner =
        payload['payload'] is Map<String, dynamic>
            ? payload['payload'] as Map<String, dynamic>
            : payload;

    final String rawType =
        (inner['drop_type'] ?? inner['command'] ?? inner['type'] ?? 'solar_flare')
            .toString();
    final GladiatorDropType resolvedType =
        GladiatorDropType.fromWire(rawType) ?? GladiatorDropType.solarFlare;

    return GladiatorDropEvent(
      dropId: (inner['drop_id'] ?? inner['id'] ?? 'drop_0').toString(),
      type: resolvedType,
      x: inner['x'] is num ? (inner['x'] as num).toDouble() : 0.0,
      y: inner['y'] is num ? (inner['y'] as num).toDouble() : 0.0,
      radius: inner['radius'] is num ? (inner['radius'] as num).toDouble() : 220.0,
      sponsorHandle:
          (inner['sponsor_handle'] ?? inner['viewer'] ?? 'TwitchGladiator')
              .toString(),
      receivedAt: receivedAt ?? DateTime.now().toUtc(),
    );
  }
}

/// Result of injecting a [GladiatorDropEvent] into the live simulation.
class GladiatorSpawnRecord {
  final GladiatorDropEvent event;
  final Duration injectionLatency;
  final SpatialAnomaly? spawnedAnomaly;
  final int? spawnedSquadIndex;
  final int spawnedStrandedDrones;
  final double energyRestored;

  const GladiatorSpawnRecord({
    required this.event,
    required this.injectionLatency,
    this.spawnedAnomaly,
    this.spawnedSquadIndex,
    this.spawnedStrandedDrones = 0,
    this.energyRestored = 0.0,
  });
}

/// Resolved sprite manifest for a player's equipped Hub cabinet cosmetics
/// via `@sunshade/assets` Cloudflare R2 CDN URLs.
class CosmeticSpriteManifest {
  final String hullSkinId;
  final String hullDisplayName;
  final String hullSpriteCdnUrl;
  final String swarmTrailId;
  final String swarmTrailDisplayName;
  final String swarmTrailSpriteCdnUrl;
  final int primaryTintHex;

  const CosmeticSpriteManifest({
    required this.hullSkinId,
    required this.hullDisplayName,
    required this.hullSpriteCdnUrl,
    required this.swarmTrailId,
    required this.swarmTrailDisplayName,
    required this.swarmTrailSpriteCdnUrl,
    this.primaryTintHex = 0xFF00E5FF,
  });

  static const String defaultCdnBaseUrl = 'https://assets.sunshade.icu/@sunshade/assets';

  /// Resolves a deterministic `@sunshade/assets` CDN URL for an asset category and ID.
  static String resolveAssetCdnUrl(
    String category,
    String assetId, {
    String cdnBaseUrl = defaultCdnBaseUrl,
  }) {
    final cleanBase = cdnBaseUrl.replaceAll(RegExp(r'/+$'), '');
    final cleanId = assetId.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9_-]'), '_');
    return '$cleanBase/dart-up/$category/$cleanId/manifest.json';
  }

  factory CosmeticSpriteManifest.fromProfileJson(
    Map<String, dynamic> json, {
    String cdnBaseUrl = defaultCdnBaseUrl,
  }) {
    final Map<String, dynamic> equipped =
        json['equipped_cosmetics'] is Map<String, dynamic>
            ? json['equipped_cosmetics'] as Map<String, dynamic>
            : json;

    final String hullId =
        (equipped['hull_skin_id'] ?? equipped['smuggler_hull_id'] ?? 'smuggler_hull_mk1')
            .toString();
    final String hullName =
        (equipped['hull_display_name'] ?? 'Smuggler Hull').toString();
    final String trailId =
        (equipped['swarm_trail_id'] ?? 'ion_cyan_trail').toString();
    final String trailName =
        (equipped['swarm_trail_display_name'] ?? 'Ion Cyan Swarm Trail')
            .toString();

    final String hullUrl = equipped['hull_sprite_cdn_url'] is String
        ? equipped['hull_sprite_cdn_url'] as String
        : resolveAssetCdnUrl('hulls', hullId, cdnBaseUrl: cdnBaseUrl);
    final String trailUrl = equipped['swarm_trail_sprite_cdn_url'] is String
        ? equipped['swarm_trail_sprite_cdn_url'] as String
        : resolveAssetCdnUrl('trails', trailId, cdnBaseUrl: cdnBaseUrl);

    final int tint = equipped['primary_tint_hex'] is int
        ? equipped['primary_tint_hex'] as int
        : 0xFF00E5FF;

    return CosmeticSpriteManifest(
      hullSkinId: hullId,
      hullDisplayName: hullName,
      hullSpriteCdnUrl: hullUrl,
      swarmTrailId: trailId,
      swarmTrailDisplayName: trailName,
      swarmTrailSpriteCdnUrl: trailUrl,
      primaryTintHex: tint,
    );
  }
}

/// Listener that binds to the active match Realtime channel, injects Gladiator
/// hazard/supply drops into the simulation, and loads cosmetic hull/trail skins
/// on match start.
class GladiatorMatchListener {
  GladiatorMatchListener({
    required this.hubApiService,
    required this.economy,
    required this.warpController,
    this.enemyDirector,
    http.Client? httpClient,
    this.cdnBaseUrl = CosmeticSpriteManifest.defaultCdnBaseUrl,
  })  : _ownsHttpClient = httpClient == null,
        _httpClient = httpClient ?? http.Client();

  final HubApiService hubApiService;
  final DroneSwarmEconomy economy;
  final ShipWarpController warpController;
  final EnemyDirector? enemyDirector;
  final http.Client _httpClient;
  final bool _ownsHttpClient;
  final String cdnBaseUrl;

  final List<GladiatorSpawnRecord> _spawnRecords = [];
  final StreamController<GladiatorSpawnRecord> _dropStreamController =
      StreamController<GladiatorSpawnRecord>.broadcast();

  RealtimeMatchChannel? _attachedChannel;
  bool _disposed = false;
  CosmeticSpriteManifest? _equippedCosmetics;

  bool get isDisposed => _disposed;
  List<GladiatorSpawnRecord> get spawnRecords => List.unmodifiable(_spawnRecords);
  Stream<GladiatorSpawnRecord> get onGladiatorDropSpawned =>
      _dropStreamController.stream;
  CosmeticSpriteManifest? get equippedCosmetics => _equippedCosmetics;

  /// Attaches a `gladiator_drop` broadcast listener onto [channel], detaching
  /// from any previously bound channel first.
  void attachToChannel(RealtimeMatchChannel channel) {
    if (_disposed) return;
    _attachedChannel?.offBroadcast('gladiator_drop', _onChannelDropBroadcast);
    _attachedChannel = channel;
    channel.onBroadcast('gladiator_drop', _onChannelDropBroadcast);
  }

  void _onChannelDropBroadcast(Map<String, dynamic> payload) {
    if (_disposed) return;
    handleGladiatorDropPayload(payload);
  }

  /// Parses and immediately injects a `gladiator_drop` payload into the
  /// simulation (`solar_flare`, `drone_swarm`, `supply_crate`).
  GladiatorSpawnRecord? handleGladiatorDropPayload(Map<String, dynamic> payload) {
    if (_disposed) return null;

    final stopwatch = Stopwatch()..start();
    final event = GladiatorDropEvent.fromPayload(payload);

    SpatialAnomaly? spawnedAnomaly;
    int? spawnedSquadIndex;
    int spawnedDrones = 0;
    double energyRestored = 0.0;

    switch (event.type) {
      case GladiatorDropType.solarFlare:
        // Inject a high-energy SpatialAnomaly hazard into ShipWarpController
        final anomaly = SpatialAnomaly(
          id: 'gladiator_flare_${event.dropId}',
          x: event.x,
          y: event.y,
          radius: event.radius,
          energyDamage: 30.0,
          decayPenalty: 0.20,
          pullsOutOfSubwarp: true,
        );
        warpController.registerAnomaly(anomaly);
        spawnedAnomaly = anomaly;
        break;

      case GladiatorDropType.droneSwarm:
        // Spawn a hostile patrol squad in EnemyDirector (if present) and scatter
        // hackable derelict drones at the drop coordinates.
        if (enemyDirector != null &&
            enemyDirector!.squadCount < enemyDirector!.maxSquadCount) {
          spawnedSquadIndex = enemyDirector!.spawnSquad(event.x, event.y);
        }
        for (int i = 0; i < 3; i++) {
          final idx = economy.spawnStrandedEnemyDrone(
            event.x + (i * 12.0),
            event.y - (i * 12.0),
          );
          if (idx >= 0) {
            spawnedDrones++;
          }
        }
        break;

      case GladiatorDropType.supplyCrate:
        // Restore player ship energy and add reserve drones up to fleet capacity
        final double beforeEnergy = warpController.shipEnergy;
        warpController.shipEnergy = (warpController.shipEnergy + 35.0)
            .clamp(0.0, warpController.powerConfig.maxShipEnergy);
        energyRestored = warpController.shipEnergy - beforeEnergy;

        for (int i = 0; i < 2; i++) {
          final idx = economy.spawnStrandedEnemyDrone(
            event.x + (i * 8.0),
            event.y,
          );
          if (idx >= 0) {
            spawnedDrones++;
          }
        }
        break;
    }

    stopwatch.stop();
    final record = GladiatorSpawnRecord(
      event: event,
      injectionLatency: stopwatch.elapsed,
      spawnedAnomaly: spawnedAnomaly,
      spawnedSquadIndex: spawnedSquadIndex,
      spawnedStrandedDrones: spawnedDrones,
      energyRestored: energyRestored,
    );

    _spawnRecords.add(record);
    if (!_dropStreamController.isClosed) {
      _dropStreamController.add(record);
    }
    return record;
  }

  /// Fetches the player's equipped `Smuggler Hull` and drone swarm trail IDs
  /// from the Hub profile API and resolves sprite manifests via `@sunshade/assets` CDN URLs.
  Future<CosmeticSpriteManifest> loadEquippedCosmetics() async {
    if (hubApiService.isAuthenticated) {
      final Uri url = Uri.parse('${hubApiService.baseUrl}/api/profile/cosmetics');
      try {
        final response = await _httpClient.get(
          url,
          headers: {
            'Accept': 'application/json',
            'Authorization': 'Bearer ${hubApiService.accessToken}',
          },
        );

        if (response.statusCode >= 200 && response.statusCode < 300 && response.body.isNotEmpty) {
          final decoded = jsonDecode(response.body);
          if (decoded is Map<String, dynamic> && decoded['error'] == null) {
            final manifest = CosmeticSpriteManifest.fromProfileJson(
              decoded,
              cdnBaseUrl: cdnBaseUrl,
            );
            _equippedCosmetics = manifest;
            return manifest;
          }
        }
      } catch (e) {
        debugPrint('[GladiatorMatchListener] Failed to fetch cosmetics: $e');
      }
    }

    final fallback = CosmeticSpriteManifest.fromProfileJson(
      const {
        'hull_skin_id': 'smuggler_hull_mk1',
        'hull_display_name': 'Smuggler Hull',
        'swarm_trail_id': 'ion_cyan_trail',
        'swarm_trail_display_name': 'Ion Cyan Swarm Trail',
      },
      cdnBaseUrl: cdnBaseUrl,
    );
    _equippedCosmetics = fallback;
    return fallback;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _attachedChannel?.offBroadcast('gladiator_drop', _onChannelDropBroadcast);
    _attachedChannel = null;
    _dropStreamController.close();
    if (_ownsHttpClient) {
      _httpClient.close();
    }
  }
}
