// =============================================================================
// telemetry_storage_native.dart
//
// Native/mobile disk persistence for failed telemetry uploads in the app's
// local documents / support directory.
// =============================================================================

import 'dart:convert';
import 'dart:io';

import 'telemetry_storage_interface.dart';

TelemetryOfflineStore createPlatformTelemetryOfflineStore({
  String? customDirectoryPath,
}) =>
    NativeDiskTelemetryOfflineStore(directoryPath: customDirectoryPath);

/// Persists pending telemetry records as JSON files inside the local app
/// documents/data directory on native and mobile platforms.
class NativeDiskTelemetryOfflineStore implements TelemetryOfflineStore {
  NativeDiskTelemetryOfflineStore({String? directoryPath})
      : _directoryPath = directoryPath ?? _resolveDefaultDirectoryPath();

  final String _directoryPath;

  String get directoryPath => _directoryPath;

  static String _resolveDefaultDirectoryPath() {
    final String? appData = Platform.environment['APPDATA'] ??
        Platform.environment['LOCALAPPDATA'] ??
        Platform.environment['HOME'];
    if (appData != null && appData.isNotEmpty) {
      return '$appData${Platform.pathSeparator}dart_up_telemetry_cache';
    }
    return '${Directory.systemTemp.path}${Platform.pathSeparator}dart_up_telemetry_cache';
  }

  File get _queueFile =>
      File('$_directoryPath${Platform.pathSeparator}pending_telemetry_queue.json');

  @override
  Future<void> savePendingRecord(CachedTelemetryRecord record) async {
    final Map<String, CachedTelemetryRecord> map = await _readMap();
    map[record.matchId] = record;
    await _writeMap(map);
  }

  @override
  Future<List<CachedTelemetryRecord>> loadPendingRecords() async {
    final Map<String, CachedTelemetryRecord> map = await _readMap();
    final List<CachedTelemetryRecord> list = map.values.toList()
      ..sort((a, b) => a.queuedAt.compareTo(b.queuedAt));
    return list;
  }

  @override
  Future<void> removePendingRecord(String matchId) async {
    final Map<String, CachedTelemetryRecord> map = await _readMap();
    if (map.remove(matchId) != null) {
      await _writeMap(map);
    }
  }

  @override
  Future<void> clearAll() async {
    final file = _queueFile;
    if (await file.exists()) {
      await file.delete();
    }
  }

  Future<Map<String, CachedTelemetryRecord>> _readMap() async {
    final file = _queueFile;
    if (!await file.exists()) {
      return <String, CachedTelemetryRecord>{};
    }
    try {
      final String raw = await file.readAsString();
      if (raw.trim().isEmpty) return <String, CachedTelemetryRecord>{};
      final dynamic decoded = jsonDecode(raw);
      if (decoded is! List) return <String, CachedTelemetryRecord>{};
      final Map<String, CachedTelemetryRecord> result =
          <String, CachedTelemetryRecord>{};
      for (final item in decoded) {
        if (item is Map<String, dynamic>) {
          final rec = CachedTelemetryRecord.fromJson(item);
          if (rec.matchId.isNotEmpty) {
            result[rec.matchId] = rec;
          }
        }
      }
      return result;
    } catch (_) {
      return <String, CachedTelemetryRecord>{};
    }
  }

  Future<void> _writeMap(Map<String, CachedTelemetryRecord> map) async {
    final dir = Directory(_directoryPath);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final List<Map<String, Object?>> serialized =
        map.values.map((e) => e.toJson()).toList();
    await _queueFile.writeAsString(jsonEncode(serialized), flush: true);
  }
}
