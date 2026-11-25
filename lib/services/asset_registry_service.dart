import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../game/grid_layer.dart';

/// Canonical `@digitalcanopy/assets` R2 CDN, isometric tile atlas manifest,
/// and hot-swapping registry adapter for Dart Up! (`app_scope: 'dart-up'`).
class DartUpSpriteBounds {
  final double x;
  final double y;
  final double w;
  final double h;

  const DartUpSpriteBounds({
    required this.x,
    required this.y,
    required this.w,
    required this.h,
  });
}

class DartUpAnchorPoint {
  final double ax;
  final double ay;

  const DartUpAnchorPoint({required this.ax, required this.ay});
}

class DartUpFlameSpriteData {
  final List<double> srcPosition;
  final List<double> srcSize;
  final List<double> anchor;

  const DartUpFlameSpriteData({
    required this.srcPosition,
    required this.srcSize,
    required this.anchor,
  });
}

class DartUpCatalogAsset {
  final String appScope;
  final String category;
  final String assetKey;
  final String cdnUrl;
  final Map<String, dynamic> metadata;

  const DartUpCatalogAsset({
    required this.appScope,
    required this.category,
    required this.assetKey,
    required this.cdnUrl,
    this.metadata = const {},
  });

  factory DartUpCatalogAsset.fromMap(Map<String, dynamic> map) {
    final rawMeta = map['metadata'];
    final Map<String, dynamic> parsedMeta;
    if (rawMeta is Map<String, dynamic>) {
      parsedMeta = rawMeta;
    } else if (rawMeta is String && rawMeta.isNotEmpty) {
      parsedMeta = Map<String, dynamic>.from(jsonDecode(rawMeta) as Map);
    } else {
      parsedMeta = const {};
    }

    return DartUpCatalogAsset(
      appScope: (map['app_scope'] ?? '').toString(),
      category: (map['category'] ?? '').toString(),
      assetKey: (map['asset_key'] ?? '').toString(),
      cdnUrl: (map['cdn_url'] ?? '').toString(),
      metadata: parsedMeta,
    );
  }
}

class DartUpAssetOverride {
  final String url;
  final DartUpSpriteBounds? frame;
  final DartUpAnchorPoint? anchor;
  final Map<String, dynamic> metadata;

  const DartUpAssetOverride({
    required this.url,
    this.frame,
    this.anchor,
    this.metadata = const {},
  });
}

class AssetRegistryService {
  AssetRegistryService._internal();

  static final AssetRegistryService instance = AssetRegistryService._internal();

  factory AssetRegistryService.create() => AssetRegistryService._internal();

  static const String cdnBaseUrl = 'https://cdn.sunshade.icu/assets/kenney';
  static const String appScope = 'dart-up';

  static const List<String> isometricTileKeys = [
    'tile-isometric-grass',
    'tile-isometric-dirt',
    'tile-isometric-stone',
    'tile-isometric-water',
    'tile-isometric-sand',
    'tile-isometric-wood-floor',
    'tile-isometric-dungeon-floor',
    'tile-isometric-wall-stone',
    'tile-isometric-wall-wood',
    'tile-isometric-wall-corner',
    'tile-isometric-stairs-stone',
    'tile-isometric-stairs-wood',
    'tile-isometric-door-closed',
    'tile-isometric-door-open',
    'tile-isometric-chest-closed',
    'tile-isometric-chest-open',
    'tile-isometric-barrel',
    'tile-isometric-crate',
    'tile-isometric-bookshelf',
    'tile-isometric-table',
    'tile-isometric-chair',
    'tile-isometric-pillar',
    'tile-isometric-torch',
    'tile-isometric-rug',
  ];

  static const double isoTileWidth = 256;
  static const double isoTileHeight = 128;
  static const double isoAtlasMaxWidth = 2048;

  /// Generates all 24 `isometricTilesAtlas` frames matching `@digitalcanopy/assets`.
  static Map<String, DartUpSpriteBounds> buildIsometricAtlasFrames() {
    final frames = <String, DartUpSpriteBounds>{};
    double x = 0;
    double y = 0;
    for (final key in isometricTileKeys) {
      frames[key] = DartUpSpriteBounds(
        x: x,
        y: y,
        w: isoTileWidth,
        h: isoTileHeight,
      );
      x += isoTileWidth;
      if (x + isoTileWidth > isoAtlasMaxWidth) {
        x = 0;
        y += isoTileHeight;
      }
    }
    return frames;
  }

  static final Map<String, DartUpSpriteBounds> isometricAtlasFrames =
      buildIsometricAtlasFrames();

  static const Map<HexTerrainType, String> terrainTileKeyMap = {
    HexTerrainType.plains: 'tile-isometric-grass',
    HexTerrainType.crystalCrater: 'tile-isometric-stone',
    HexTerrainType.volcanicRidge: 'tile-isometric-dirt',
    HexTerrainType.voidChasm: 'tile-isometric-water',
    HexTerrainType.energyWell: 'tile-isometric-dungeon-floor',
  };

  /// Seed catalog entries aligned with `@digitalcanopy/assets` taxonomy (`dart-up` + `all`).
  static const List<DartUpCatalogAsset> seedCatalog = [
    DartUpCatalogAsset(
      appScope: 'dart-up',
      category: 'rts_turret',
      assetKey: 'turret-defensive',
      cdnUrl: '$cdnBaseUrl/scifi-rts/turrets/turret_defensive.png',
      metadata: {'format': 'png', 'width': 64, 'height': 64, 'license': 'CC0-Kenney'},
    ),
    DartUpCatalogAsset(
      appScope: 'dart-up',
      category: 'rts_unit',
      assetKey: 'squad-vanguard-raider',
      cdnUrl: '$cdnBaseUrl/scifi-rts/units/squad_vanguard.png',
      metadata: {'format': 'png', 'width': 64, 'height': 64, 'license': 'CC0-Kenney'},
    ),
    DartUpCatalogAsset(
      appScope: 'dart-up',
      category: 'rts_unit',
      assetKey: 'squad-corsair-marauder',
      cdnUrl: '$cdnBaseUrl/scifi-rts/units/squad_corsair.png',
      metadata: {'format': 'png', 'width': 64, 'height': 64, 'license': 'CC0-Kenney'},
    ),
    DartUpCatalogAsset(
      appScope: 'dart-up',
      category: 'rts_harvester',
      assetKey: 'harvester-crawler',
      cdnUrl: '$cdnBaseUrl/scifi-rts/units/harvester_crawler.png',
      metadata: {'format': 'png', 'width': 64, 'height': 64, 'license': 'CC0-Kenney'},
    ),
    DartUpCatalogAsset(
      appScope: 'all',
      category: 'particle_fx',
      assetKey: 'fx-particle-starburst',
      cdnUrl: '$cdnBaseUrl/particles/starburst.png',
      metadata: {'format': 'png', 'width': 64, 'height': 64, 'license': 'CC0-Kenney'},
    ),
    DartUpCatalogAsset(
      appScope: 'all',
      category: 'particle_fx',
      assetKey: 'fx-particle-dust-puff',
      cdnUrl: '$cdnBaseUrl/particles/dust_puff.png',
      metadata: {'format': 'png', 'width': 64, 'height': 64, 'license': 'CC0-Kenney'},
    ),
    DartUpCatalogAsset(
      appScope: 'all',
      category: 'ui_audio',
      assetKey: 'audio-ui-tap',
      cdnUrl: '$cdnBaseUrl/audio/ui/tap_clean.ogg',
      metadata: {'format': 'ogg', 'duration_ms': 85, 'license': 'CC0-Kenney'},
    ),
  ];

  final Map<String, DartUpAssetOverride> _overrides = {};
  final Map<String, String> _packOverrides = {};
  final ValueNotifier<int> swapRevision = ValueNotifier<int>(0);
  bool _hydrated = false;

  bool get isHydrated => _hydrated;

  void reset() {
    _overrides.clear();
    _packOverrides.clear();
    _hydrated = false;
    swapRevision.value++;
  }

  void registerOverride(String key, DartUpAssetOverride override) {
    _overrides[key.trim()] = override;
    swapRevision.value++;
  }

  void registerPackOverride(String pack, String cdnBase) {
    final cleanPack = pack.replaceAll(RegExp(r'^/+|/+$'), '').toLowerCase();
    _packOverrides[cleanPack] = cdnBase.replaceAll(RegExp(r'/+$'), '');
    swapRevision.value++;
  }

  bool hasOverride(String key) => _overrides.containsKey(key.trim());

  void loadCatalog(List<DartUpCatalogAsset> assets, {String? scope}) {
    final filtered = scope == null
        ? assets
        : assets.where((a) => a.appScope == scope || a.appScope == 'all');
    for (final asset in filtered) {
      final cleanKey = asset.assetKey.trim();
      if (cleanKey.isEmpty) continue;
      _overrides[cleanKey] = DartUpAssetOverride(
        url: asset.cdnUrl,
        metadata: asset.metadata,
      );
    }
    _hydrated = true;
    swapRevision.value++;
  }

  Future<List<DartUpCatalogAsset>> hydrateCatalog({
    SupabaseClient? supabaseClient,
    bool force = false,
  }) async {
    if (_hydrated && !force) {
      return seedCatalog;
    }

    if (supabaseClient != null) {
      try {
        final rows = await supabaseClient
            .schema('catalog')
            .from('assets')
            .select('app_scope, category, asset_key, cdn_url, metadata')
            .inFilter('app_scope', [appScope, 'all']);

        if (rows.isNotEmpty) {
          final parsed = rows
              .map(DartUpCatalogAsset.fromMap)
              .where((a) => a.assetKey.isNotEmpty && a.cdnUrl.isNotEmpty)
              .toList();
          if (parsed.isNotEmpty) {
            loadCatalog(parsed, scope: appScope);
            return parsed;
          }
        }
      } catch (err) {
        debugPrint('[AssetRegistryService] Remote catalog unavailable, using seed: $err');
      }
    }

    loadCatalog(seedCatalog, scope: appScope);
    return seedCatalog;
  }

  String resolveAssetUrl(String pack, String assetPath, {String ext = 'png'}) {
    final cleanPack = pack.replaceAll(RegExp(r'^/+|/+$'), '').toLowerCase();
    final cleanPath = assetPath.replaceAll(RegExp(r'^/+|/+$'), '');
    final bareKey = cleanPath.replaceAll(RegExp(r'\.[a-zA-Z0-9]+$'), '');

    if (_overrides.containsKey(bareKey)) {
      return _overrides[bareKey]!.url;
    }
    if (_overrides.containsKey(cleanPath)) {
      return _overrides[cleanPath]!.url;
    }

    final cleanExt = ext.startsWith('.') ? ext.substring(1) : ext;
    final hasExt = RegExp(r'\.[a-zA-Z0-9]+$').hasMatch(cleanPath);
    final finalPath = hasExt ? cleanPath : '$cleanPath.$cleanExt';

    final packBase = _packOverrides[cleanPack];
    if (packBase != null) {
      return '$packBase/$finalPath';
    }
    return '$cdnBaseUrl/$cleanPack/$finalPath';
  }

  String terrainTileKeyFor(HexTerrainType terrain) {
    return terrainTileKeyMap[terrain] ?? 'tile-isometric-grass';
  }

  String resolveTerrainAssetUrl(HexTerrainType terrain) {
    final tileKey = terrainTileKeyFor(terrain);
    return resolveAssetUrl('isometric-tiles', tileKey);
  }

  String resolveEntityAssetUrl(String entityKey) {
    final cleanKey = entityKey.trim().toLowerCase().replaceAll(' ', '-');
    if (_overrides.containsKey(cleanKey)) {
      return _overrides[cleanKey]!.url;
    }
    return resolveAssetUrl('scifi-rts', 'units/$cleanKey');
  }

  DartUpFlameSpriteData? resolveFlameIsometricData(String tileKey) {
    final cleanKey = tileKey.trim();
    final override = _overrides[cleanKey];
    final frame = override?.frame ?? isometricAtlasFrames[cleanKey];
    if (frame == null) return null;

    final anchor = override?.anchor ?? const DartUpAnchorPoint(ax: 0.5, ay: 0.75);
    return DartUpFlameSpriteData(
      srcPosition: [frame.x, frame.y],
      srcSize: [frame.w, frame.h],
      anchor: [anchor.ax, anchor.ay],
    );
  }

  DartUpFlameSpriteData? resolveTerrainFlameSpriteData(HexTerrainType terrain) {
    return resolveFlameIsometricData(terrainTileKeyFor(terrain));
  }
}
