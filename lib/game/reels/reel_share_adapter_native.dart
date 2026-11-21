// =============================================================================
// reel_share_adapter_native.dart
//
// Native/mobile MP4 file staging & OS share sheet / file launcher adapter.
// =============================================================================

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'reel_share_adapter_interface.dart';

ReelShareAdapter createPlatformReelShareAdapter() => NativeReelShareAdapter();

typedef NativeShareSheetInvoker = Future<bool> Function({
  required String filePath,
  required String title,
  required String recapUrl,
});

class NativeReelShareAdapter implements ReelShareAdapter {
  static const MethodChannel _shareChannel =
      MethodChannel('io.sunshade.dartup/share_reel');

  NativeReelShareAdapter({
    this.customOutputDir,
    this.invokeOsLauncher = true,
    this.customShareInvoker,
  });

  final String? customOutputDir;
  final bool invokeOsLauncher;
  final NativeShareSheetInvoker? customShareInvoker;

  @override
  Future<ReelShareResult> shareMp4Reel({
    required Uint8List mp4Bytes,
    required String fileName,
    required String title,
    required String recapUrl,
  }) async {
    try {
      final String dirPath = customOutputDir ?? Directory.systemTemp.path;
      final Directory dir = Directory(dirPath);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final String filePath = '$dirPath${Platform.pathSeparator}$fileName';
      final File outFile = File(filePath);
      await outFile.writeAsBytes(mp4Bytes, flush: true);

      bool openedSystemSheet = false;

      if (customShareInvoker != null) {
        openedSystemSheet = await customShareInvoker!(
          filePath: filePath,
          title: title,
          recapUrl: recapUrl,
        );
      } else if (invokeOsLauncher) {
        // 1. Try platform MethodChannel share sheet first
        try {
          final bool? res = await _shareChannel.invokeMethod<bool>(
            'shareFile',
            <String, Object?>{
              'filePath': filePath,
              'mimeType': 'video/mp4',
              'title': title,
              'text': '$title — $recapUrl',
            },
          );
          if (res == true) {
            openedSystemSheet = true;
          }
        } catch (_) {}

        // 2. Fallback to launching the local file URI via OS handler
        if (!openedSystemSheet) {
          try {
            openedSystemSheet = await launchUrl(
              Uri.file(filePath),
              mode: LaunchMode.externalApplication,
            );
          } catch (_) {}
        }
      }

      return ReelShareResult(
        shared: true,
        status: openedSystemSheet
            ? ReelShareStatus.sharedViaSystemSheet
            : ReelShareStatus.savedOrDownloadedFallback,
        fileName: fileName,
        shareUrl: recapUrl,
        savedFilePath: filePath,
      );
    } catch (e) {
      return ReelShareResult(
        shared: false,
        status: ReelShareStatus.failed,
        fileName: fileName,
        shareUrl: recapUrl,
        error: e.toString(),
      );
    }
  }
}
