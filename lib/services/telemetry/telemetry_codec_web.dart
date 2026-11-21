// =============================================================================
// telemetry_codec_web.dart
//
// Web-safe pure-Dart LZ77/RLE codec + pure-Dart RFC 1950/1951 ZLIB/DEFLATE
// decompressor so archives created on either native or web unpack identically
// across both platforms.
// =============================================================================

import 'dart:typed_data';

Uint8List platformZlibEncode(Uint8List rawBytes) => lzEncode(rawBytes);

Uint8List platformZlibDecode(Uint8List compressedBytes) {
  if (compressedBytes.length >= 2 &&
      compressedBytes[0] == 0x4C &&
      compressedBytes[1] == 0x5A) {
    return lzDecode(compressedBytes);
  }
  return pureDartZlibInflate(compressedBytes);
}

/// Pure-Dart lossless LZ77 + RLE byte compressor (magic header `0x4C, 0x5A` = `'LZ'`).
Uint8List lzEncode(Uint8List rawBytes) {
  final BytesBuilder out = BytesBuilder(copy: false);
  out.addByte(0x4C);
  out.addByte(0x5A);

  int i = 0;
  final int len = rawBytes.length;
  while (i < len) {
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

/// Pure-Dart lossless LZ77 + RLE byte decompressor.
Uint8List lzDecode(Uint8List compressedBytes) {
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

// ---------------------------------------------------------------------------
// Pure-Dart RFC 1950 (ZLIB) & RFC 1951 (DEFLATE) Inflate Decoder
// ---------------------------------------------------------------------------

/// Decompresses an RFC 1950 zlib stream (`CMF`, `FLG`, DEFLATE blocks, Adler32)
/// in pure Dart with zero native/dart:io dependencies.
Uint8List pureDartZlibInflate(Uint8List data) {
  if (data.length < 6) {
    throw const FormatException('Invalid zlib stream: too short.');
  }
  final int cmf = data[0];
  final int flg = data[1];
  if ((cmf & 0x0F) != 8 || ((cmf << 8) + flg) % 31 != 0) {
    throw const FormatException('Invalid zlib header checksum or method.');
  }
  final bool fdict = (flg & 0x20) != 0;
  final int deflateStart = fdict ? 6 : 2;
  return _inflateDeflateStream(data, deflateStart, data.length - 4);
}

const List<int> _kLengthBase = <int>[
  3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
  35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258,
];

const List<int> _kLengthExtra = <int>[
  0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
  3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
];

const List<int> _kDistBase = <int>[
  1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
  257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
  8193, 12289, 16385, 24577,
];

const List<int> _kDistExtra = <int>[
  0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
  7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13,
];

const List<int> _kCodeLengthOrder = <int>[
  16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15,
];

Uint8List _inflateDeflateStream(Uint8List data, int startOffset, int endOffset) {
  final _BitReader bits = _BitReader(data, startOffset, endOffset);
  final List<int> out = <int>[];

  int bfinal = 0;
  while (bfinal == 0) {
    bfinal = bits.readBits(1);
    final int btype = bits.readBits(2);

    if (btype == 0) {
      // Uncompressed block
      bits.alignToByte();
      final int len = bits.readBits(16);
      final int nlen = bits.readBits(16);
      if ((len ^ 0xFFFF) != nlen) {
        throw const FormatException('Corrupt uncompressed DEFLATE block length.');
      }
      for (int i = 0; i < len; i++) {
        out.add(bits.readByteAligned());
      }
    } else if (btype == 1 || btype == 2) {
      final _HuffmanTable litLenTable;
      final _HuffmanTable distTable;

      if (btype == 1) {
        litLenTable = _HuffmanTable.fixedLitLen;
        distTable = _HuffmanTable.fixedDist;
      } else {
        final int hlit = bits.readBits(5) + 257;
        final int hdist = bits.readBits(5) + 1;
        final int hclen = bits.readBits(4) + 4;

        final List<int> codeLengths = List<int>.filled(19, 0);
        for (int i = 0; i < hclen; i++) {
          codeLengths[_kCodeLengthOrder[i]] = bits.readBits(3);
        }
        final _HuffmanTable codeLenTable = _HuffmanTable(codeLengths);

        final List<int> allLengths = List<int>.filled(hlit + hdist, 0);
        int idx = 0;
        while (idx < hlit + hdist) {
          final int sym = codeLenTable.decode(bits);
          if (sym < 16) {
            allLengths[idx++] = sym;
          } else if (sym == 16) {
            final int repeat = bits.readBits(2) + 3;
            final int prev = idx > 0 ? allLengths[idx - 1] : 0;
            for (int r = 0; r < repeat; r++) {
              allLengths[idx++] = prev;
            }
          } else if (sym == 17) {
            final int repeat = bits.readBits(3) + 3;
            for (int r = 0; r < repeat; r++) {
              allLengths[idx++] = 0;
            }
          } else if (sym == 18) {
            final int repeat = bits.readBits(7) + 11;
            for (int r = 0; r < repeat; r++) {
              allLengths[idx++] = 0;
            }
          }
        }

        litLenTable = _HuffmanTable(allLengths.sublist(0, hlit));
        distTable = _HuffmanTable(allLengths.sublist(hlit, hlit + hdist));
      }

      while (true) {
        final int sym = litLenTable.decode(bits);
        if (sym < 256) {
          out.add(sym);
        } else if (sym == 256) {
          break;
        } else {
          final int lenIdx = sym - 257;
          final int length =
              _kLengthBase[lenIdx] + bits.readBits(_kLengthExtra[lenIdx]);
          final int distSym = distTable.decode(bits);
          final int distance =
              _kDistBase[distSym] + bits.readBits(_kDistExtra[distSym]);
          final int copyStart = out.length - distance;
          for (int i = 0; i < length; i++) {
            out.add(out[copyStart + i]);
          }
        }
      }
    } else {
      throw const FormatException('Invalid DEFLATE block type 3.');
    }
  }

  return Uint8List.fromList(out);
}

class _BitReader {
  _BitReader(this._data, this._bytePos, this._endOffset);
  final Uint8List _data;
  int _bytePos;
  final int _endOffset;
  int _bitBuf = 0;
  int _bitCount = 0;

  int readBits(int count) {
    if (count == 0) return 0;
    while (_bitCount < count) {
      if (_bytePos >= _endOffset) {
        throw const FormatException('Unexpected EOF in DEFLATE bitstream.');
      }
      _bitBuf |= _data[_bytePos++] << _bitCount;
      _bitCount += 8;
    }
    final int val = _bitBuf & ((1 << count) - 1);
    _bitBuf >>>= count;
    _bitCount -= count;
    return val;
  }

  void alignToByte() {
    _bitBuf = 0;
    _bitCount = 0;
  }

  int readByteAligned() {
    if (_bytePos >= _endOffset) {
      throw const FormatException('Unexpected EOF in uncompressed block.');
    }
    return _data[_bytePos++];
  }
}

class _HuffmanTable {
  _HuffmanTable(List<int> lengths) {
    int maxBits = 0;
    for (final l in lengths) {
      if (l > maxBits) maxBits = l;
    }
    _maxBits = maxBits == 0 ? 1 : maxBits;

    final List<int> blCount = List<int>.filled(_maxBits + 1, 0);
    for (final l in lengths) {
      if (l > 0) blCount[l]++;
    }

    final List<int> nextCode = List<int>.filled(_maxBits + 1, 0);
    int code = 0;
    for (int bits = 1; bits <= _maxBits; bits++) {
      code = (code + blCount[bits - 1]) << 1;
      nextCode[bits] = code;
    }

    for (int n = 0; n < lengths.length; n++) {
      final int len = lengths[n];
      if (len != 0) {
        final int c = nextCode[len]++;
        _codeToSymbol[(len << 16) | c] = n;
      }
    }
  }

  late final int _maxBits;
  final Map<int, int> _codeToSymbol = <int, int>{};

  static final _HuffmanTable fixedLitLen = _buildFixedLitLen();
  static final _HuffmanTable fixedDist =
      _HuffmanTable(List<int>.filled(32, 5));

  static _HuffmanTable _buildFixedLitLen() {
    final List<int> lengths = List<int>.filled(288, 0);
    for (int i = 0; i <= 143; i++) {
      lengths[i] = 8;
    }
    for (int i = 144; i <= 255; i++) {
      lengths[i] = 9;
    }
    for (int i = 256; i <= 279; i++) {
      lengths[i] = 7;
    }
    for (int i = 280; i <= 287; i++) {
      lengths[i] = 8;
    }
    return _HuffmanTable(lengths);
  }

  int decode(_BitReader reader) {
    int code = 0;
    for (int len = 1; len <= _maxBits; len++) {
      code = (code << 1) | reader.readBits(1);
      final int? sym = _codeToSymbol[(len << 16) | code];
      if (sym != null) return sym;
    }
    throw const FormatException('Invalid Huffman code in DEFLATE stream.');
  }
}
