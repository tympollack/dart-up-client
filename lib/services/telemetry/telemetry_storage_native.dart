// =============================================================================
// telemetry_storage_native.dart
//
// Native/mobile disk persistence for failed telemetry uploads in the app's
// local documents / support directory.
//
// Stores each pending recap in its own atomically replaced per-match file
// (`recap_<safeMatchId>.json`), keeps an in-memory fallback queue if disk
// writes fail, and serializes mutations per directory path so concurrent
// flushes and End Match saves across separate store instances never overwrite
// or lose each other's recaps.
// =============================================================================

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'telemetry_storage_interface.dart';

TelemetryOfflineStore createPlatformTelemetryOfflineStore({
  String? customDirectoryPath,
}) =>
    NativeDiskTelemetryOfflineStore(directoryPath: customDirectoryPath);

/// Persists pending telemetry records as individual atomic JSON files inside
/// the local app documents/data directory on native and mobile platforms.
class NativeDiskTelemetryOfflineStore implements TelemetryOfflineStore {
  NativeDiskTelemetryOfflineStore({String? directoryPath})
      : _directoryPath = directoryPath ?? _resolveDefaultDirectoryPath();

  final String _directoryPath;

  String get directoryPath => _directoryPath;

  /// Process-wide per-directory async mutex chain so concurrent operations on
  /// the same directory path serialize cleanly.
  static final Map<String, Future<void>> _directoryLocks =
      <String, Future<void>>{};

  /// Process-wide in-memory fallback records keyed by directory path and matchId,
  /// retained ONLY when a disk write fails so same-session `loadPendingRecords`
  /// calls can still retry them.
  static final Map<String, Map<String, CachedTelemetryRecord>>
      _memoryFallbacksByDir = <String, Map<String, CachedTelemetryRecord>>{};

  Map<String, CachedTelemetryRecord> get _memoryFallback =>
      _memoryFallbacksByDir.putIfAbsent(
        _directoryPath,
        () => <String, CachedTelemetryRecord>{},
      );

  Future<T> _withDirectoryLock<T>(Future<T> Function() action) {
    final Future<void> previous =
        _directoryLocks[_directoryPath] ?? Future<void>.value();
    final Completer<void> completer = Completer<void>();
    _directoryLocks[_directoryPath] = completer.future;

    return previous.then((_) => action()).whenComplete(() {
      completer.complete();
      if (identical(_directoryLocks[_directoryPath], completer.future)) {
        _directoryLocks.remove(_directoryPath);
      }
    });
  }

  static String _resolveDefaultDirectoryPath() {
    final String? appData = Platform.environment['APPDATA'] ??
        Platform.environment['LOCALAPPDATA'] ??
        Platform.environment['HOME'];
    if (appData != null && appData.isNotEmpty) {
      return '$appData${Platform.pathSeparator}dart_up_telemetry_cache';
    }
    return '${Directory.systemTemp.path}${Platform.pathSeparator}dart_up_telemetry_cache';
  }

  static String _sanitizeMatchId(String matchId) {
    final bytes = utf8.encode(matchId);
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  static bool _isRecapNamespaceFileName(String fileName) {
    if (fileName == 'pending_telemetry_queue.json' ||
        fileName == 'pending_telemetry_queue.json.tmp') {
      return true;
    }
    return fileName.startsWith('recap_') &&
        (fileName.endsWith('.json') || fileName.endsWith('.json.tmp'));
  }

  static String _baseName(String path) {
    final int sep = path.lastIndexOf(Platform.pathSeparator);
    final int fwd = path.lastIndexOf('/');
    final int idx = sep > fwd ? sep : fwd;
    return idx >= 0 ? path.substring(idx + 1) : path;
  }

  File _recordFileForMatch(String matchId) {
    final String safeName = _sanitizeMatchId(matchId);
    return File(
      '$_directoryPath${Platform.pathSeparator}recap_$safeName.json',
    );
  }

  File get _legacyQueueFile => File(
        '$_directoryPath${Platform.pathSeparator}pending_telemetry_queue.json',
      );

  @override
  Future<bool> savePendingRecord(CachedTelemetryRecord record) {
    return _withDirectoryLock<bool>(() async {
      try {
        final dir = Directory(_directoryPath);
        if (!await dir.exists()) {
          await dir.create(recursive: true);
        }
        final File targetFile = _recordFileForMatch(record.matchId);
        final File tempFile = File('${targetFile.path}.tmp');
        await tempFile.writeAsString(
          jsonEncode(record.toJson()),
          flush: true,
        );
        await tempFile.rename(targetFile.path);
        _memoryFallback.remove(record.matchId);
        return true;
      } catch (_) {
        _memoryFallback[record.matchId] = record;
        return false;
      }
    });
  }

  @override
  Future<List<CachedTelemetryRecord>> loadPendingRecords() {
    return _withDirectoryLock<List<CachedTelemetryRecord>>(() async {
      final Map<String, CachedTelemetryRecord> records =
          <String, CachedTelemetryRecord>{..._memoryFallback};

      // 1. Read legacy shared file if present
      final legacy = _legacyQueueFile;
      if (await legacy.exists()) {
        try {
          final String raw = await legacy.readAsString();
          if (raw.trim().isNotEmpty) {
            final dynamic decoded = jsonDecode(raw);
            if (decoded is List) {
              for (final item in decoded) {
                if (item is Map<String, dynamic>) {
                  final rec = CachedTelemetryRecord.fromJson(item);
                  if (rec.matchId.isNotEmpty) {
                    records[rec.matchId] = rec;
                  }
                }
              }
            }
          }
        } catch (_) {}
      }

      // 2. Read per-match atomic files (`recap_*.json`)
      final dir = Directory(_directoryPath);
      if (await dir.exists()) {
        await for (final entity in dir.list(followLinks: false)) {
          if (entity is File) {
            final String name = _baseName(entity.path);
            if (name.startsWith('recap_') && name.endsWith('.json')) {
              try {
                final String raw = await entity.readAsString();
                if (raw.trim().isEmpty) continue;
                final dynamic decoded = jsonDecode(raw);
                if (decoded is Map<String, dynamic>) {
                  final rec = CachedTelemetryRecord.fromJson(decoded);
                  if (rec.matchId.isNotEmpty) {
                    records[rec.matchId] = rec;
                  }
                }
              } catch (_) {}
            }
          }
        }
      }

      final List<CachedTelemetryRecord> list = records.values.toList()
        ..sort((a, b) => a.queuedAt.compareTo(b.queuedAt));
      return list;
    });
  }

  @override
  Future<void> removePendingRecord(String matchId) {
    return _withDirectoryLock<void>(() async {
      _memoryFallback.remove(matchId);

      final File targetFile = _recordFileForMatch(matchId);
      if (await targetFile.exists()) {
        try {
          await targetFile.delete();
        } catch (_) {}
      }

      // Also clean from legacy file if present, ONLY rewriting if `matchId` was
      // actually present in the legacy list, using atomic temp rename.
      final legacy = _legacyQueueFile;
      if (await legacy.exists()) {
        try {
          final String raw = await legacy.readAsString();
          final dynamic decoded = jsonDecode(raw);
          if (decoded is List) {
            final int beforeCount = decoded.length;
            final filtered = decoded
                .where((item) =>
                    item is Map<String, dynamic> &&
                    item['match_id']?.toString() != matchId)
                .toList();
            if (filtered.length != beforeCount) {
              if (filtered.isEmpty) {
                await legacy.delete();
              } else {
                final File legacyTmp = File('${legacy.path}.tmp');
                await legacyTmp.writeAsString(
                  jsonEncode(filtered),
                  flush: true,
                );
                await legacyTmp.rename(legacy.path);
              }
            }
          }
        } catch (_) {}
      }
    });
  }

  @override
  Future<void> clearAll() {
    return _withDirectoryLock<void>(() async {
      _memoryFallback.clear();
      final dir = Directory(_directoryPath);
      if (!await dir.exists()) return;
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is File &&
            _isRecapNamespaceFileName(_baseName(entity.path))) {
          try {
            await entity.delete();
          } catch (_) {}
        }
      }
    });
  }
}
