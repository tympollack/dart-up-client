// =============================================================================
// reel_share_adapter_native.dart
//
// Native/mobile MP4 file staging & OS share / URL launcher adapter.
// =============================================================================

import 'dart:io';
import 'dart:typed_data';

import 'package:url_launcher/url_launcher.dart';

import 'reel_share_adapter_interface.dart';

ReelShareAdapter createPlatformReelShareAdapter() => NativeReelShareAdapter();

class NativeReelShareAdapter implements ReelShareAdapter {
  NativeReelShareAdapter({
    this.customOutputDir,
    this.invokeOsLauncher = false,
  });

  final String? customOutputDir;
  final bool invokeOsLauncher;

  @override
  Future<ReelShareResult> shareMp4Reel({
    required Uint8List mp4Bytes,
    required String fileName,
    required String title,
    required String recapUrl,
  }) async {
    final String dirPath = customOutputDir ?? Directory.systemTemp.path;
    final Directory dir = Directory(dirPath);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final String filePath = '$dirPath${Platform.pathSeparator}$fileName';
    final File outFile = File(filePath);
    await outFile.writeAsBytes(mp4Bytes, flush: true);

    if (invokeOsLauncher) {
      final Uri? uri = Uri.tryParse(recapUrl);
      if (uri != null) {
        try {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        } catch (_) {}
      }
    }

    return ReelShareResult(
      shared: true,
      fileName: fileName,
      shareUrl: recapUrl,
      savedFilePath: filePath,
    );
  }
}
