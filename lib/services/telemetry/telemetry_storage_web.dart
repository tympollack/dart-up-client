// =============================================================================
// telemetry_storage_web.dart
//
// Web IndexedDB & localStorage persistence for failed telemetry uploads.
// =============================================================================

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'telemetry_storage_interface.dart';

TelemetryOfflineStore createPlatformTelemetryOfflineStore({
  String? customDirectoryPath,
}) =>
    WebIndexedDbTelemetryOfflineStore();

/// Web offline telemetry cache backed by IndexedDB (`dart_up_telemetry_db` /
/// `pending_recaps`) with synchronous mirror fallback to `window.localStorage`.
class WebIndexedDbTelemetryOfflineStore implements TelemetryOfflineStore {
  static const String _dbName = 'dart_up_telemetry_db';
  static const String _storeName = 'pending_recaps';
  static const String _localStorageFallbackKey =
      'dart_up_pending_telemetry_queue_v1';

  final Map<String, CachedTelemetryRecord> _memoryMirror =
      <String, CachedTelemetryRecord>{};

  Future<web.IDBDatabase?> _openDb() async {
    try {
      final completer = Completer<web.IDBDatabase?>();
      final request = web.window.indexedDB.open(_dbName, 1);

      request.onupgradeneeded = ((web.IDBVersionChangeEvent _) {
        final db = request.result as web.IDBDatabase?;
        if (db != null && !db.objectStoreNames.contains(_storeName)) {
          db.createObjectStore(_storeName);
        }
      }).toJS;

      request.onsuccess = ((web.Event _) {
        completer.complete(request.result as web.IDBDatabase?);
      }).toJS;

      request.onerror = ((web.Event _) {
        if (!completer.isCompleted) completer.complete(null);
      }).toJS;

      return await completer.future.timeout(
        const Duration(milliseconds: 500),
        onTimeout: () => null,
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> savePendingRecord(CachedTelemetryRecord record) async {
    _memoryMirror[record.matchId] = record;
    _saveToLocalStorageMirror();

    final db = await _openDb();
    if (db == null) return;
    try {
      final tx = db.transaction(_storeName.toJS, 'readwrite');
      final store = tx.objectStore(_storeName);
      store.put(jsonEncode(record.toJson()).toJS, record.matchId.toJS);
    } catch (_) {
      // Fallback mirror already saved
    } finally {
      db.close();
    }
  }

  @override
  Future<List<CachedTelemetryRecord>> loadPendingRecords() async {
    _hydrateFromLocalStorageMirror();
    final list = _memoryMirror.values.toList()
      ..sort((a, b) => a.queuedAt.compareTo(b.queuedAt));
    return list;
  }

  @override
  Future<void> removePendingRecord(String matchId) async {
    _memoryMirror.remove(matchId);
    _saveToLocalStorageMirror();

    final db = await _openDb();
    if (db == null) return;
    try {
      final tx = db.transaction(_storeName.toJS, 'readwrite');
      final store = tx.objectStore(_storeName);
      store.delete(matchId.toJS);
    } catch (_) {
    } finally {
      db.close();
    }
  }

  @override
  Future<void> clearAll() async {
    _memoryMirror.clear();
    try {
      web.window.localStorage.removeItem(_localStorageFallbackKey);
    } catch (_) {}

    final db = await _openDb();
    if (db == null) return;
    try {
      final tx = db.transaction(_storeName.toJS, 'readwrite');
      tx.objectStore(_storeName).clear();
    } catch (_) {
    } finally {
      db.close();
    }
  }

  void _saveToLocalStorageMirror() {
    try {
      final list = _memoryMirror.values.map((r) => r.toJson()).toList();
      web.window.localStorage.setItem(
        _localStorageFallbackKey,
        jsonEncode(list),
      );
    } catch (_) {}
  }

  void _hydrateFromLocalStorageMirror() {
    try {
      final raw = web.window.localStorage.getItem(_localStorageFallbackKey);
      if (raw == null || raw.isEmpty) return;
      final dynamic decoded = jsonDecode(raw);
      if (decoded is List) {
        for (final item in decoded) {
          if (item is Map<String, dynamic>) {
            final rec = CachedTelemetryRecord.fromJson(item);
            if (rec.matchId.isNotEmpty) {
              _memoryMirror[rec.matchId] = rec;
            }
          }
        }
      }
    } catch (_) {}
  }
}
