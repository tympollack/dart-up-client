// =============================================================================
// telemetry_codec_native.dart
//
// Native (dart:io) compression adapter for TelemetryEventPacker.
// Supports decoding both native zlib streams and cross-platform 'LZ' (0x4C, 0x5A)
// streams produced by web clients.
// =============================================================================

import 'dart:io';
import 'dart:typed_data';

import 'telemetry_codec_web.dart' as web_lz;

Uint8List platformZlibEncode(Uint8List rawBytes) {
  final compressed = zlib.encode(rawBytes);
  return compressed is Uint8List ? compressed : Uint8List.fromList(compressed);
}

Uint8List platformZlibDecode(Uint8List compressedBytes) {
  if (compressedBytes.length >= 2 &&
      compressedBytes[0] == 0x4C &&
      compressedBytes[1] == 0x5A) {
    return web_lz.lzDecode(compressedBytes);
  }
  final decompressed = zlib.decode(compressedBytes);
  return decompressed is Uint8List
      ? decompressed
      : Uint8List.fromList(decompressed);
}
