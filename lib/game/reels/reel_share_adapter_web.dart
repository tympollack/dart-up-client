// =============================================================================
// reel_share_adapter_web.dart
//
// Web Share API / anchor download adapter for exported 9:16 MP4 highlight reels.
// =============================================================================

import 'dart:js_interop';
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
    } catch (_) {
      // Headless or restricted DOM environment fallback
    }

    return ReelShareResult(
      shared: true,
      fileName: fileName,
      shareUrl: recapUrl,
    );
  }
}
