// =============================================================================
// telemetry_codec_native.dart
//
// Native (dart:io) zlib compression adapter for TelemetryEventPacker.
// =============================================================================

import 'dart:io';
import 'dart:typed_data';

Uint8List platformZlibEncode(Uint8List rawBytes) {
  final compressed = zlib.encode(rawBytes);
  return compressed is Uint8List ? compressed : Uint8List.fromList(compressed);
}

Uint8List platformZlibDecode(Uint8List compressedBytes) {
  final decompressed = zlib.decode(compressedBytes);
  return decompressed is Uint8List
      ? decompressed
      : Uint8List.fromList(decompressed);
}
