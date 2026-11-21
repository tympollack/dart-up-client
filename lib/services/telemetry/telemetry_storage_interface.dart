// =============================================================================
// telemetry_storage_interface.dart
//
// Platform-agnostic offline storage queue contract for persisted post-match
// telemetry payloads when Hub upload fails.
// =============================================================================

import 'dart:convert';
import 'dart:typed_data';

/// A single queued telemetry payload persisted to local offline storage.
class CachedTelemetryRecord {
  final String matchId;
  final Uint8List packedPayload;
  final DateTime queuedAt;
  final int retryCount;

  const CachedTelemetryRecord({
    required this.matchId,
    required this.packedPayload,
    required this.queuedAt,
    this.retryCount = 0,
  });

  CachedTelemetryRecord copyWith({int? retryCount}) {
    return CachedTelemetryRecord(
      matchId: matchId,
      packedPayload: packedPayload,
      queuedAt: queuedAt,
      retryCount: retryCount ?? this.retryCount,
    );
  }

  Map<String, Object?> toJson() => {
        'match_id': matchId,
        'payload_base64': base64Encode(packedPayload),
        'queued_at': queuedAt.toUtc().toIso8601String(),
        'retry_count': retryCount,
      };

  factory CachedTelemetryRecord.fromJson(Map<String, dynamic> json) {
    final String rawMatchId = (json['match_id'] ?? '').toString();
    final String b64 = (json['payload_base64'] ?? '').toString();
    final String rawQueuedAt = (json['queued_at'] ?? '').toString();
    final int retries =
        json['retry_count'] is num ? (json['retry_count'] as num).toInt() : 0;

    return CachedTelemetryRecord(
      matchId: rawMatchId,
      packedPayload: b64.isEmpty ? Uint8List(0) : base64Decode(b64),
      queuedAt: DateTime.tryParse(rawQueuedAt)?.toUtc() ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      retryCount: retries,
    );
  }
}

/// Offline persistence contract implemented by IndexedDB/Web Storage on web and
/// application documents directory file storage on native/mobile.
abstract class TelemetryOfflineStore {
  Future<void> savePendingRecord(CachedTelemetryRecord record);
  Future<List<CachedTelemetryRecord>> loadPendingRecords();
  Future<void> removePendingRecord(String matchId);
  Future<void> clearAll();
}

/// In-memory fallback / test implementation of [TelemetryOfflineStore].
class InMemoryTelemetryOfflineStore implements TelemetryOfflineStore {
  final Map<String, CachedTelemetryRecord> _records =
      <String, CachedTelemetryRecord>{};

  @override
  Future<void> savePendingRecord(CachedTelemetryRecord record) async {
    _records[record.matchId] = record;
  }

  @override
  Future<List<CachedTelemetryRecord>> loadPendingRecords() async {
    final list = _records.values.toList()
      ..sort((a, b) => a.queuedAt.compareTo(b.queuedAt));
    return list;
  }

  @override
  Future<void> removePendingRecord(String matchId) async {
    _records.remove(matchId);
  }

  @override
  Future<void> clearAll() async {
    _records.clear();
  }
}
