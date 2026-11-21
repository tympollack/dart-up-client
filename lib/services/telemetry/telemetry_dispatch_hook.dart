// =============================================================================
// telemetry_dispatch_hook.dart
//
// Post-match telemetry ingestion dispatcher with resilient offline caching
// (IndexedDB on web, local application documents directory on native/mobile)
// and automatic flush on next app launch.
// =============================================================================

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:sd_client/services/hub_api_service.dart';
import 'package:sd_client/simulation/telemetry/telemetry_ring_buffer.dart';

import 'telemetry_event_packer.dart';
import 'telemetry_storage_interface.dart';
import 'telemetry_storage_native.dart'
    if (dart.library.js_interop) 'telemetry_storage_web.dart';

export 'telemetry_storage_interface.dart';

/// Outcome of a single post-match telemetry upload or queued retry.
class TelemetryDispatchResult {
  final String matchId;
  final bool uploaded;
  final bool cachedOffline;
  final int payloadSizeBytes;
  final int statusCode;
  final String? error;

  const TelemetryDispatchResult({
    required this.matchId,
    required this.uploaded,
    required this.cachedOffline,
    required this.payloadSizeBytes,
    this.statusCode = 0,
    this.error,
  });
}

/// Manages post-match telemetry serialization, upload to the SunShade Hub recap
/// ingestion endpoint (`/api/recaps/ingest`), offline persistence on failure,
/// and startup queue flushing.
class TelemetryDispatchHook {
  TelemetryDispatchHook({
    this.baseUrl = HubApiService.defaultBaseUrl,
    http.Client? httpClient,
    TelemetryOfflineStore? offlineStore,
    this.accessTokenProvider,
    this.recapIngestionPath = '/api/recaps/ingest',
  })  : _ownsHttpClient = httpClient == null,
        _httpClient = httpClient ?? http.Client(),
        _offlineStore = offlineStore ?? createPlatformTelemetryOfflineStore();

  final String baseUrl;
  final http.Client _httpClient;
  final bool _ownsHttpClient;
  final TelemetryOfflineStore _offlineStore;
  final String? Function()? accessTokenProvider;
  final String recapIngestionPath;

  TelemetryOfflineStore get offlineStore => _offlineStore;

  /// Packs [ringBuffer] via [TelemetryEventPacker] and dispatches the stream
  /// to the Hub recap ingestion endpoint. On network or server failure,
  /// persists the packed binary stream to local offline storage.
  Future<TelemetryDispatchResult> dispatchMatchTelemetry({
    required String matchId,
    required TelemetryRingBuffer ringBuffer,
  }) async {
    final Uint8List packed = TelemetryEventPacker.pack(
      ringBuffer,
      matchId: matchId,
    );
    return dispatchPackedTelemetry(
      matchId: matchId,
      packedPayload: packed,
    );
  }

  /// Dispatches an already-packed telemetry byte stream to the Hub recap
  /// ingestion endpoint, persisting to [_offlineStore] if upload fails.
  Future<TelemetryDispatchResult> dispatchPackedTelemetry({
    required String matchId,
    required Uint8List packedPayload,
    int retryCount = 0,
  }) async {
    final Uri url = Uri.parse(
      '${baseUrl.replaceAll(RegExp(r'/$'), '')}$recapIngestionPath',
    );
    final String? token = accessTokenProvider?.call();

    final Map<String, String> headers = <String, String>{
      'Content-Type': 'application/json',
      'Idempotency-Key': 'dartup_recap_$matchId',
      if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
    };

    final String requestBody = jsonEncode(<String, Object?>{
      'match_id': matchId,
      'format': 'dtrp_v1',
      'byte_length': packedPayload.length,
      'payload_base64': base64Encode(packedPayload),
    });

    int statusCode = 0;
    String? errorMsg;

    try {
      final response = await _httpClient.post(
        url,
        headers: headers,
        body: requestBody,
      );
      statusCode = response.statusCode;

      Map<String, dynamic>? parsedBody;
      if (response.body.isNotEmpty) {
        try {
          final decoded = jsonDecode(response.body);
          if (decoded is Map<String, dynamic>) {
            parsedBody = decoded;
          }
        } catch (_) {}
      }

      // Check Supabase / Hub error guard `{ error }` on mutation response
      final dynamic bodyError = parsedBody?['error'];
      if (statusCode >= 200 && statusCode < 300 && bodyError == null) {
        await _offlineStore.removePendingRecord(matchId);
        return TelemetryDispatchResult(
          matchId: matchId,
          uploaded: true,
          cachedOffline: false,
          payloadSizeBytes: packedPayload.length,
          statusCode: statusCode,
        );
      }

      errorMsg =
          bodyError?.toString() ?? 'HTTP $statusCode: ${response.body}';
    } catch (e) {
      errorMsg = e.toString();
    }

    debugPrint(
      '[TelemetryDispatchHook] Upload failed for $matchId ($errorMsg). Caching offline.',
    );

    await _offlineStore.savePendingRecord(
      CachedTelemetryRecord(
        matchId: matchId,
        packedPayload: packedPayload,
        queuedAt: DateTime.now().toUtc(),
        retryCount: retryCount + 1,
      ),
    );

    return TelemetryDispatchResult(
      matchId: matchId,
      uploaded: false,
      cachedOffline: true,
      payloadSizeBytes: packedPayload.length,
      statusCode: statusCode,
      error: errorMsg,
    );
  }

  /// Flushes all pending offline-cached telemetry records on app launch or
  /// reconnect. Successfully uploaded records are removed from offline storage.
  Future<List<TelemetryDispatchResult>> flushPendingQueue() async {
    final List<CachedTelemetryRecord> pending =
        await _offlineStore.loadPendingRecords();
    if (pending.isEmpty) return const <TelemetryDispatchResult>[];

    final List<TelemetryDispatchResult> results = <TelemetryDispatchResult>[];
    for (final record in pending) {
      final res = await dispatchPackedTelemetry(
        matchId: record.matchId,
        packedPayload: record.packedPayload,
        retryCount: record.retryCount,
      );
      results.add(res);
    }
    return results;
  }

  void dispose() {
    if (_ownsHttpClient) {
      _httpClient.close();
    }
  }
}
