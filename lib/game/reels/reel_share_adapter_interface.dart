// =============================================================================
// reel_share_adapter_interface.dart
//
// Platform-agnostic interface for invoking the native OS / Web Share API share
// sheet for exported 9:16 vertical highlight reel MP4 clips.
// =============================================================================

import 'dart:typed_data';

/// Delivery outcome of a 9:16 highlight reel share request.
enum ReelShareStatus {
  /// Native OS share sheet or Web Share API completed.
  sharedViaSystemSheet,

  /// Downloaded or staged to local storage as fallback.
  savedOrDownloadedFallback,

  /// User dismissed or cancelled the share dialog.
  cancelled,

  /// Share and fallback both failed.
  failed,
}

/// Result returned when invoking the OS / browser share sheet for a 9:16 reel.
class ReelShareResult {
  final bool shared;
  final ReelShareStatus status;
  final String fileName;
  final String shareUrl;
  final String? savedFilePath;
  final String? error;

  const ReelShareResult({
    required this.shared,
    this.status = ReelShareStatus.sharedViaSystemSheet,
    required this.fileName,
    required this.shareUrl,
    this.savedFilePath,
    this.error,
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
