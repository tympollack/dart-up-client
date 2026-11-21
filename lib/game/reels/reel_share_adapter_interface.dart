// =============================================================================
// reel_share_adapter_interface.dart
//
// Platform-agnostic interface for invoking the native OS / Web Share API share
// sheet for exported 9:16 vertical highlight reel MP4 clips.
// =============================================================================

import 'dart:typed_data';

/// Result returned when invoking the OS / browser share sheet for a 9:16 reel.
class ReelShareResult {
  final bool shared;
  final String fileName;
  final String shareUrl;
  final String? savedFilePath;

  const ReelShareResult({
    required this.shared,
    required this.fileName,
    required this.shareUrl,
    this.savedFilePath,
  });
}

abstract class ReelShareAdapter {
  Future<ReelShareResult> shareMp4Reel({
    required Uint8List mp4Bytes,
    required String fileName,
    required String title,
    required String recapUrl,
  });
}
