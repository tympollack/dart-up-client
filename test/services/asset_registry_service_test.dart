import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sd_client/game/grid_layer.dart';
import 'package:sd_client/services/asset_registry_service.dart';

void main() {
  group('TASK-PKG-APP-DARTUP: @digitalcanopy/assets Isometric Grid & RTS Entity Adapter', () {
    test('generates all 24 isometricTilesAtlas frames with (0.5, 0.75) anchor', () {
      expect(AssetRegistryService.isometricAtlasFrames.length, equals(24));

      final registry = AssetRegistryService.create();
      final grass = registry.resolveTerrainFlameSpriteData(HexTerrainType.plains);
      expect(grass, isNotNull);
      expect(grass!.srcPosition, [0.0, 0.0]);
      expect(grass.srcSize, [256.0, 128.0]);
      expect(grass.anchor, [0.5, 0.75]);

      final stone = registry.resolveTerrainFlameSpriteData(HexTerrainType.crystalCrater);
      expect(stone, isNotNull);
      expect(stone!.srcPosition, [512.0, 0.0]);
    });

    test('hydrates dart-up and shared catalog assets and resolves turrets, units, and harvesters', () async {
      final registry = AssetRegistryService.create();
      final assets = await registry.hydrateCatalog();

      expect(assets.any((a) => a.assetKey == 'turret-defensive'), isTrue);
      expect(assets.any((a) => a.assetKey == 'squad-vanguard-raider'), isTrue);
      expect(assets.any((a) => a.assetKey == 'harvester-crawler'), isTrue);
      expect(assets.any((a) => a.assetKey == 'fx-particle-starburst'), isTrue);

      expect(
        registry.resolveEntityAssetUrl('turret-defensive'),
        '${AssetRegistryService.cdnBaseUrl}/scifi-rts/turrets/turret_defensive.png',
      );
      expect(
        registry.resolveEntityAssetUrl('squad-vanguard-raider'),
        '${AssetRegistryService.cdnBaseUrl}/scifi-rts/units/squad_vanguard.png',
      );
      expect(
        registry.resolveTerrainAssetUrl(HexTerrainType.voidChasm),
        '${AssetRegistryService.cdnBaseUrl}/isometric-tiles/tile-isometric-water.png',
      );
    });

    test('supports pack-level and per-entity hot-swapping via registry', () async {
      final registry = AssetRegistryService.create();
      await registry.hydrateCatalog();

      registry.registerPackOverride('isometric-tiles', 'https://custom-ip.sunshade.icu/hex');
      expect(
        registry.resolveTerrainAssetUrl(HexTerrainType.plains),
        'https://custom-ip.sunshade.icu/hex/tile-isometric-grass.png',
      );

      registry.registerPackOverride('scifi-rts', 'https://custom-ip.sunshade.icu/custom-rts');
      expect(
        registry.resolveEntityAssetUrl('squad-vanguard-raider'),
        'https://custom-ip.sunshade.icu/custom-rts/units/squad-vanguard-raider.png',
      );

      registry.registerOverride(
        'turret-defensive',
        const DartUpAssetOverride(
          url: 'https://custom-ip.sunshade.icu/laser-turret.png',
          frame: DartUpSpriteBounds(x: 0, y: 0, w: 128, h: 128),
          anchor: DartUpAnchorPoint(ax: 0.5, ay: 0.5),
        ),
      );
      expect(
        registry.resolveEntityAssetUrl('turret-defensive'),
        'https://custom-ip.sunshade.icu/laser-turret.png',
      );
      expect(
        registry.resolveFlameIsometricData('turret-defensive')!.srcSize,
        [128.0, 128.0],
      );
    });

    test('fails fast returning null on empty or invalid image bytes', () async {
      final registry = AssetRegistryService.create();
      final empty = await registry.loadCdnImage(
        'https://cdn.sunshade.icu/assets/kenney/empty.png',
        byteLoader: (_) async => ByteData(0),
      );
      final corrupt = await registry.loadCdnImage(
        'https://cdn.sunshade.icu/assets/kenney/corrupt.png',
        byteLoader: (_) async => ByteData.sublistView(Uint8List.fromList([7, 8, 9])),
      );
      expect(empty, isNull);
      expect(corrupt, isNull);
    });
  });
}
