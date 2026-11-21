// =============================================================================
// telemetry_storage_web.dart
//
// Web IndexedDB & per-match localStorage persistence for failed telemetry
// uploads.
//
// Uses one localStorage key per match (`dart_up_pending_recap_v2_<matchId>`)
// so concurrent flushes and End Match saves across separate store instances
// never overwrite unrelated matches, and returns durable persistence status
// (`true` only when IndexedDB or localStorage commits the write).
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
/// `pending_recaps`) with per-match mirror fallback in `window.localStorage`.
class WebIndexedDbTelemetryOfflineStore implements TelemetryOfflineStore {
  static const String _dbName = 'dart_up_telemetry_db';
  static const String _storeName = 'pending_recaps';
  static const String _perMatchKeyPrefix = 'dart_up_pending_recap_v2_';
  static const String _legacyQueueKey = 'dart_up_pending_telemetry_queue_v1';

  final Map<String, CachedTelemetryRecord> _memoryMirror =
      <String, CachedTelemetryRecord>{};

  static String _storageKeyForMatch(String matchId) =>
      '$_perMatchKeyPrefix$matchId';

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
  Future<bool> savePendingRecord(CachedTelemetryRecord record) async {
    _memoryMirror[record.matchId] = record;
    final String encoded = jsonEncode(record.toJson());
    final bool savedToLocalStorage =
        _saveRecordToLocalStorage(record.matchId, encoded);
    final bool savedToIndexedDb =
        await _saveRecordToIndexedDb(record.matchId, encoded);

    return savedToLocalStorage || savedToIndexedDb;
  }

  @override
  Future<List<CachedTelemetryRecord>> loadPendingRecords() async {
    _hydrateFromLocalStorageKeys();
    await _hydrateFromIndexedDb();
    final list = _memoryMirror.values.toList()
      ..sort((a, b) => a.queuedAt.compareTo(b.queuedAt));
    return list;
  }

  @override
  Future<void> removePendingRecord(String matchId) async {
    _memoryMirror.remove(matchId);
    _removeRecordFromLocalStorage(matchId);

    final db = await _openDb();
    if (db == null) return;
    try {
      final completer = Completer<void>();
      final tx = db.transaction(_storeName.toJS, 'readwrite');
      tx.oncomplete = ((web.Event _) {
        if (!completer.isCompleted) completer.complete();
      }).toJS;
      tx.onerror = ((web.Event _) {
        if (!completer.isCompleted) completer.complete();
      }).toJS;
      final store = tx.objectStore(_storeName);
      store.delete(matchId.toJS);
      await completer.future.timeout(
        const Duration(milliseconds: 500),
        onTimeout: () {},
      );
    } catch (_) {
    } finally {
      db.close();
    }
  }

  @override
  Future<void> clearAll() async {
    _memoryMirror.clear();
    _clearAllLocalStorageRecords();

    final db = await _openDb();
    if (db == null) return;
    try {
      final completer = Completer<void>();
      final tx = db.transaction(_storeName.toJS, 'readwrite');
      tx.oncomplete = ((web.Event _) {
        if (!completer.isCompleted) completer.complete();
      }).toJS;
      tx.onerror = ((web.Event _) {
        if (!completer.isCompleted) completer.complete();
      }).toJS;
      tx.objectStore(_storeName).clear();
      await completer.future.timeout(
        const Duration(milliseconds: 500),
        onTimeout: () {},
      );
    } catch (_) {
    } finally {
      db.close();
    }
  }

  Future<bool> _saveRecordToIndexedDb(String matchId, String encodedJson) async {
    final db = await _openDb();
    if (db == null) return false;
    try {
      final completer = Completer<bool>();
      final tx = db.transaction(_storeName.toJS, 'readwrite');
      tx.oncomplete = ((web.Event _) {
        if (!completer.isCompleted) completer.complete(true);
      }).toJS;
      tx.onerror = ((web.Event _) {
        if (!completer.isCompleted) completer.complete(false);
      }).toJS;
      tx.onabort = ((web.Event _) {
        if (!completer.isCompleted) completer.complete(false);
      }).toJS;
      final store = tx.objectStore(_storeName);
      store.put(encodedJson.toJS, matchId.toJS);
      return await completer.future.timeout(
        const Duration(milliseconds: 500),
        onTimeout: () => false,
      );
    } catch (_) {
      return false;
    } finally {
      db.close();
    }
  }

  Future<void> _hydrateFromIndexedDb() async {
    final db = await _openDb();
    if (db == null) return;
    try {
      final completer = Completer<void>();
      final tx = db.transaction(_storeName.toJS, 'readonly');
      final store = tx.objectStore(_storeName);
      final req = store.getAll();

      req.onsuccess = ((web.Event _) {
        try {
          final JSArray<JSAny?>? results = req.result as JSArray<JSAny?>?;
          if (results != null) {
            final dartList = results.toDart;
            for (final entry in dartList) {
              if (entry != null && entry.isA<JSString>()) {
                final String rawJson = (entry as JSString).toDart;
                final dynamic decoded = jsonDecode(rawJson);
                if (decoded is Map<String, dynamic>) {
                  final rec = CachedTelemetryRecord.fromJson(decoded);
                  if (rec.matchId.isNotEmpty) {
                    _memoryMirror[rec.matchId] = rec;
                  }
                }
              }
            }
          }
        } catch (_) {}
        if (!completer.isCompleted) completer.complete();
      }).toJS;

      req.onerror = ((web.Event _) {
        if (!completer.isCompleted) completer.complete();
      }).toJS;

      await completer.future.timeout(
        const Duration(milliseconds: 500),
        onTimeout: () {},
      );
    } catch (_) {
    } finally {
      db.close();
    }
  }

  bool _saveRecordToLocalStorage(String matchId, String encodedJson) {
    try {
      web.window.localStorage.setItem(
        _storageKeyForMatch(matchId),
        encodedJson,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  void _removeRecordFromLocalStorage(String matchId) {
    try {
      web.window.localStorage.removeItem(_storageKeyForMatch(matchId));
      final String? legacyRaw =
          web.window.localStorage.getItem(_legacyQueueKey);
      if (legacyRaw != null && legacyRaw.isNotEmpty) {
        final dynamic decoded = jsonDecode(legacyRaw);
        if (decoded is List) {
          final int beforeLen = decoded.length;
          final filtered = decoded
              .where((item) =>
                  item is Map<String, dynamic> &&
                  item['match_id']?.toString() != matchId)
              .toList();
          if (filtered.length != beforeLen) {
            if (filtered.isEmpty) {
              web.window.localStorage.removeItem(_legacyQueueKey);
            } else {
              web.window.localStorage.setItem(
                _legacyQueueKey,
                jsonEncode(filtered),
              );
            }
          }
        }
      }
    } catch (_) {}
  }

  void _clearAllLocalStorageRecords() {
    try {
      final storage = web.window.localStorage;
      final List<String> keysToRemove = <String>[];
      for (int i = 0; i < storage.length; i++) {
        final String? key = storage.key(i);
        if (key != null &&
            (key.startsWith(_perMatchKeyPrefix) || key == _legacyQueueKey)) {
          keysToRemove.add(key);
        }
      }
      for (final key in keysToRemove) {
        storage.removeItem(key);
      }
    } catch (_) {}
  }

  void _hydrateFromLocalStorageKeys() {
    try {
      final storage = web.window.localStorage;
      for (int i = 0; i < storage.length; i++) {
        final String? key = storage.key(i);
        if (key == null) continue;
        if (key.startsWith(_perMatchKeyPrefix)) {
          final String? raw = storage.getItem(key);
          if (raw == null || raw.isEmpty) continue;
          final dynamic decoded = jsonDecode(raw);
          if (decoded is Map<String, dynamic>) {
            final rec = CachedTelemetryRecord.fromJson(decoded);
            if (rec.matchId.isNotEmpty) {
              _memoryMirror[rec.matchId] = rec;
            }
          }
        } else if (key == _legacyQueueKey) {
          final String? raw = storage.getItem(key);
          if (raw == null || raw.isEmpty) continue;
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
        }
      }
    } catch (_) {}
  }
}
