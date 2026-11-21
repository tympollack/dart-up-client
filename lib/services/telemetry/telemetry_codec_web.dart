// =============================================================================
// telemetry_codec_web.dart
//
// Web-safe pure-Dart LZ77/RLE codec fallback when dart:io is unavailable.
// =============================================================================

import 'dart:typed_data';

Uint8List platformZlibEncode(Uint8List rawBytes) {
  // Pure-Dart lossless LZ77 + RLE byte compressor for web builds
  final BytesBuilder out = BytesBuilder(copy: false);
  // Header magic: 'LZ'
  out.addByte(0x4C);
  out.addByte(0x5A);

  int i = 0;
  final int len = rawBytes.length;
  while (i < len) {
    // Look back up to 255 bytes for a matching run of up to 127 bytes
    int bestOffset = 0;
    int bestLength = 0;
    final int maxBack = i < 255 ? i : 255;

    for (int back = 1; back <= maxBack; back++) {
      int matchLen = 0;
      while (matchLen < 127 &&
          i + matchLen < len &&
          rawBytes[i - back + matchLen] == rawBytes[i + matchLen]) {
        matchLen++;
      }
      if (matchLen >= 4 && matchLen > bestLength) {
        bestLength = matchLen;
        bestOffset = back;
        if (bestLength == 127) break;
      }
    }

    if (bestLength >= 4) {
      out.addByte(0x80 | bestLength);
      out.addByte(bestOffset);
      i += bestLength;
    } else {
      final int litStart = i;
      int litLen = 0;
      while (litLen < 127 && i < len) {
        // Check if a 4-byte match starts here
        bool foundMatch = false;
        final int mb = i < 255 ? i : 255;
        for (int back = 1; back <= mb; back++) {
          if (i + 3 < len &&
              rawBytes[i - back] == rawBytes[i] &&
              rawBytes[i - back + 1] == rawBytes[i + 1] &&
              rawBytes[i - back + 2] == rawBytes[i + 2] &&
              rawBytes[i - back + 3] == rawBytes[i + 3]) {
            foundMatch = true;
            break;
          }
        }
        if (foundMatch && litLen > 0) break;
        i++;
        litLen++;
      }
      out.addByte(litLen);
      out.add(Uint8List.sublistView(rawBytes, litStart, litStart + litLen));
    }
  }

  return out.takeBytes();
}

Uint8List platformZlibDecode(Uint8List compressedBytes) {
  if (compressedBytes.length < 2 ||
      compressedBytes[0] != 0x4C ||
      compressedBytes[1] != 0x5A) {
    return Uint8List.fromList(compressedBytes);
  }

  final List<int> out = <int>[];
  int i = 2;
  final int len = compressedBytes.length;

  while (i < len) {
    final int token = compressedBytes[i++];
    if ((token & 0x80) != 0) {
      final int matchLen = token & 0x7F;
      if (i >= len) break;
      final int offset = compressedBytes[i++];
      final int startIdx = out.length - offset;
      for (int k = 0; k < matchLen; k++) {
        out.add(out[startIdx + k]);
      }
    } else {
      final int litLen = token & 0x7F;
      for (int k = 0; k < litLen && i < len; k++) {
        out.add(compressedBytes[i++]);
      }
    }
  }

  return Uint8List.fromList(out);
}
