// =============================================================================
// reel_share_adapter_web.dart
//
// Web Share API (`navigator.share` with MP4 file) and anchor download fallback
// adapter for exported 9:16 MP4 highlight reels.
// =============================================================================

import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'reel_share_adapter_interface.dart';

ReelShareAdapter createPlatformReelShareAdapter() => WebReelShareAdapter();

class WebReelShareAdapter implements ReelShareAdapter {
  @override
  Future<ReelShareResult> shareMp4Reel({
    required Uint8List mp4Bytes,
    required String fileName,
    required String title,
    required String recapUrl,
  }) async {
    try {
      final blobParts = <JSAny>[mp4Bytes.toJS].toJS;
      final file = web.File(
        blobParts,
        fileName,
        web.FilePropertyBag(type: 'video/mp4'),
      );

      // 1. Attempt Web Share API (`navigator.canShare` / `navigator.share`)
      final nav = web.window.navigator;
      final shareData = web.ShareData(
        title: title,
        text: '$title — $recapUrl',
        url: recapUrl,
        files: <web.File>[file].toJS,
      );

      if ((nav as JSObject).has('canShare') && nav.canShare(shareData)) {
        await nav.share(shareData).toDart;
        return ReelShareResult(
          shared: true,
          status: ReelShareStatus.sharedViaSystemSheet,
          fileName: fileName,
          shareUrl: recapUrl,
        );
      }

      // 2. Fallback to browser Blob download
      final blob = web.Blob(
        blobParts,
        web.BlobPropertyBag(type: 'video/mp4'),
      );
      final objectUrl = web.URL.createObjectURL(blob);
      final anchor =
          web.document.createElement('a') as web.HTMLAnchorElement;
      anchor.href = objectUrl;
      anchor.download = fileName;
      anchor.click();
      web.URL.revokeObjectURL(objectUrl);

      return ReelShareResult(
        shared: true,
        status: ReelShareStatus.savedOrDownloadedFallback,
        fileName: fileName,
        shareUrl: recapUrl,
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
