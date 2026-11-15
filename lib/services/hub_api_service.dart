// =============================================================================
// hub_api_service.dart
//
// SunShade Hub SSO, verified match result submission (with retry and
// idempotency keys), @digitalcanopy/achievements milestone dispatching,
// and Supabase Realtime spectator cheer stream integration.
// =============================================================================

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Supported in-game milestone feats mapped to `@digitalcanopy/achievements` triggers.
enum DartUpMilestoneFeat {
  starDartSiegeSurvivor(
    id: 'star_dart_siege_survivor',
    achievementCode: 'ACH_DARTUP_STAR_DART_SIEGE_SURVIVOR',
    title: 'Star Dart Siege Survivor',
    description: 'Survive or capture the Star Dart boss amid an active sector ambush.',
  ),
  threeWayAmbush(
    id: 'three_way_ambush',
    achievementCode: 'ACH_DARTUP_THREE_WAY_AMBUSH',
    title: 'Three-Way Ambush',
    description: 'Engage multiple hostile factions simultaneously during a Star Dart chase.',
  ),
  smugglerRingCrack(
    id: 'smuggler_ring_crack',
    achievementCode: 'ACH_DARTUP_SMUGGLER_RING_CRACK',
    title: 'Smuggler Ring Crack',
    description: 'Hijack and refit an entire cluster of stranded smuggler drones.',
  );

  const DartUpMilestoneFeat({
    required this.id,
    required this.achievementCode,
    required this.title,
    required this.description,
  });

  final String id;
  final String achievementCode;
  final String title;
  final String description;

  static DartUpMilestoneFeat? fromId(String rawId) {
    for (final feat in DartUpMilestoneFeat.values) {
      if (feat.id == rawId || feat.achievementCode == rawId) {
        return feat;
      }
    }
    return null;
  }
}

/// Achievement toast notification payload emitted when a milestone feat is unlocked.
class AchievementToastNotification {
  final DartUpMilestoneFeat feat;
  final DateTime unlockedAt;
  final String matchId;
  final bool syncedWithHub;

  const AchievementToastNotification({
    required this.feat,
    required this.unlockedAt,
    required this.matchId,
    required this.syncedWithHub,
  });
}

/// Summary of a completed match submitted on Victory or Defeat screens.
class MatchSummary {
  final String matchId;
  final String gameName;
  final String opponentName;
  final String outcome; // 'victory' | 'defeat'
  final String matchType;
  final int moves;
  final int durationSeconds;
  final int dronesDeployed;
  final int dronesHacked;
  final List<String> featsUnlocked;
  final String? idempotencyKey;

  const MatchSummary({
    required this.matchId,
    this.gameName = 'Dart Up!',
    required this.opponentName,
    required this.outcome,
    this.matchType = 'ranked_sector',
    required this.moves,
    this.durationSeconds = 0,
    this.dronesDeployed = 0,
    this.dronesHacked = 0,
    this.featsUnlocked = const [],
    this.idempotencyKey,
  });

  bool get isVictory => outcome.toLowerCase() == 'victory';

  String get effectiveIdempotencyKey =>
      idempotencyKey ?? 'dartup_match_${matchId}_${outcome.toLowerCase()}';

  Map<String, dynamic> toJson() => {
        'match_id': matchId,
        'game_name': gameName,
        'opponent_name': opponentName,
        'result': outcome.toLowerCase(),
        'match_type': matchType,
        'moves': moves,
        'duration_seconds': durationSeconds,
        'drones_deployed': dronesDeployed,
        'drones_hacked': dronesHacked,
        'feats_unlocked': featsUnlocked,
        'idempotency_key': effectiveIdempotencyKey,
      };
}

/// Result returned by [HubApiService.submitMatchResult].
class MatchSubmissionResult {
  final bool ok;
  final int statusCode;
  final int attempts;
  final String idempotencyKey;
  final String? error;
  final Map<String, dynamic>? data;

  const MatchSubmissionResult({
    required this.ok,
    required this.statusCode,
    required this.attempts,
    required this.idempotencyKey,
    this.error,
    this.data,
  });
}

/// Ephemeral spectator cheer broadcast received over the Supabase Realtime match channel.
class SpectatorCheerEvent {
  final String cheerId;
  final String matchId;
  final String spectatorHandle;
  final String message;
  final int cheerAmount;
  final DateTime timestamp;

  const SpectatorCheerEvent({
    required this.cheerId,
    required this.matchId,
    required this.spectatorHandle,
    required this.message,
    this.cheerAmount = 1,
    required this.timestamp,
  });

  factory SpectatorCheerEvent.fromPayload(
    Map<String, dynamic> payload, {
    String defaultMatchId = 'active_match',
  }) {
    final Map<String, dynamic> inner =
        payload['payload'] is Map<String, dynamic>
            ? payload['payload'] as Map<String, dynamic>
            : payload;

    return SpectatorCheerEvent(
      cheerId: (inner['cheer_id'] ?? inner['id'] ?? 'cheer_0').toString(),
      matchId: (inner['match_id'] ?? defaultMatchId).toString(),
      spectatorHandle:
          (inner['spectator_handle'] ?? inner['sender'] ?? 'Anonymous')
              .toString(),
      message: (inner['message'] ?? 'GG!').toString(),
      cheerAmount: inner['cheer_amount'] is num
          ? (inner['cheer_amount'] as num).toInt()
          : 1,
      timestamp: inner['timestamp'] is String
          ? (DateTime.tryParse(inner['timestamp'] as String) ??
              DateTime.fromMillisecondsSinceEpoch(0, isUtc: true))
          : DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );
  }
}

/// Lightweight abstraction over a Supabase Realtime broadcast channel so tests
/// and live WebSocket/HTTP clients can subscribe and inject ephemeral events cleanly.
abstract class RealtimeMatchChannel {
  String get channelTopic;
  bool get isSubscribed;
  void subscribe();
  void unsubscribe();
  void onBroadcast(
    String eventName,
    void Function(Map<String, dynamic> payload) callback,
  );
  void offBroadcast(
    String eventName,
    void Function(Map<String, dynamic> payload) callback,
  );
  void emitSimulatedBroadcast(String eventName, Map<String, dynamic> payload);
}

/// Transport-backed implementation of [RealtimeMatchChannel] supporting both
/// live HTTP/Realtime broadcast polling and direct simulated broadcasts.
class SupabaseRealtimeMatchChannel implements RealtimeMatchChannel {
  SupabaseRealtimeMatchChannel({
    required this.channelTopic,
    this.httpClient,
    this.endpointUrl,
    this.accessTokenProvider,
    this.pollInterval,
  });

  @override
  final String channelTopic;

  final http.Client? httpClient;
  final String? endpointUrl;
  final String? Function()? accessTokenProvider;
  final Duration? pollInterval;

  bool _subscribed = false;
  Timer? _pollTimer;
  String? _lastCursor;
  final Map<String, List<void Function(Map<String, dynamic> payload)>>
      _listeners = {};

  @override
  bool get isSubscribed => _subscribed;

  @override
  void subscribe() {
    if (_subscribed) return;
    _subscribed = true;
    final interval = pollInterval;
    if (interval != null &&
        interval > Duration.zero &&
        httpClient != null &&
        endpointUrl != null) {
      _pollTimer?.cancel();
      _pollTimer = Timer.periodic(interval, (_) {
        unawaited(pollBroadcastsOnce());
      });
    }
  }

  @override
  void unsubscribe() {
    _subscribed = false;
    _pollTimer?.cancel();
    _pollTimer = null;
    _listeners.clear();
  }

  @override
  void onBroadcast(
    String eventName,
    void Function(Map<String, dynamic> payload) callback,
  ) {
    final callbacks = _listeners.putIfAbsent(eventName, () => []);
    if (!callbacks.contains(callback)) {
      callbacks.add(callback);
    }
  }

  @override
  void offBroadcast(
    String eventName,
    void Function(Map<String, dynamic> payload) callback,
  ) {
    _listeners[eventName]?.remove(callback);
  }

  @override
  void emitSimulatedBroadcast(String eventName, Map<String, dynamic> payload) {
    if (!_subscribed) return;
    final callbacks = _listeners[eventName];
    if (callbacks == null || callbacks.isEmpty) return;
    for (final cb
        in List<void Function(Map<String, dynamic>)>.from(callbacks)) {
      cb(payload);
    }
  }

  /// Polls the Hub Realtime broadcast bridge once for any pending server events
  /// on [channelTopic] and dispatches them to registered broadcast listeners.
  Future<int> pollBroadcastsOnce() async {
    if (!_subscribed || httpClient == null || endpointUrl == null) {
      return 0;
    }

    final Uri baseUri = Uri.parse(endpointUrl!);
    final Map<String, String> query = {
      ...baseUri.queryParameters,
      'topic': channelTopic,
      'cursor': ?_lastCursor,
    };
    final Uri requestUri = baseUri.replace(queryParameters: query);

    final String? token = accessTokenProvider?.call();
    final Map<String, String> headers = {
      'Accept': 'application/json',
      if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
    };

    try {
      final response = await httpClient!.get(requestUri, headers: headers);
      if (!_subscribed ||
          response.statusCode < 200 ||
          response.statusCode >= 300 ||
          response.body.isEmpty) {
        return 0;
      }

      final dynamic decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic> || decoded['error'] != null) {
        return 0;
      }

      if (decoded['next_cursor'] is String) {
        _lastCursor = decoded['next_cursor'] as String;
      }

      final dynamic rawEvents = decoded['events'];
      if (rawEvents is! List) return 0;

      int dispatched = 0;
      for (final item in rawEvents) {
        if (!_subscribed) break;
        if (item is Map<String, dynamic>) {
          final String? eventName =
              (item['event'] ?? item['type'])?.toString();
          final Map<String, dynamic> eventPayload =
              item['payload'] is Map<String, dynamic>
                  ? item['payload'] as Map<String, dynamic>
                  : item;
          if (eventName != null && eventName.isNotEmpty) {
            emitSimulatedBroadcast(eventName, eventPayload);
            dispatched++;
          }
        }
      }
      return dispatched;
    } catch (e) {
      debugPrint('[SupabaseRealtimeMatchChannel] poll error: $e');
      return 0;
    }
  }
}

/// Service connecting *Dart Up!* to SunShade Hub SSO authentication, post-match
/// submission, `@digitalcanopy/achievements`, and Supabase Realtime spectator cheers.
class HubApiService {
  static const String defaultBaseUrl = String.fromEnvironment(
    'SUNSHADE_HUB_URL',
    defaultValue: 'https://hub-stag.sunshade.icu',
  );

  HubApiService({
    this.baseUrl = defaultBaseUrl,
    http.Client? httpClient,
    this.maxRetries = 3,
    this.retryDelay = const Duration(milliseconds: 20),
    this.realtimePollInterval = const Duration(seconds: 2),
  })  : _ownsHttpClient = httpClient == null,
        _httpClient = httpClient ?? http.Client();

  final String baseUrl;
  final http.Client _httpClient;
  final bool _ownsHttpClient;
  final int maxRetries;
  final Duration retryDelay;
  final Duration? realtimePollInterval;

  String? _accessToken;
  String? _refreshToken;
  String? _userId;
  RealtimeMatchChannel? _activeMatchChannel;
  bool _disposed = false;

  final Set<String> _unlockedFeatIds = {};
  final Map<String, Set<String>> _matchUnlockedFeats = {};
  final Set<String> _syncedFeatIds = {};
  final Set<String> _inFlightFeatIds = {};
  final List<AchievementToastNotification> _toastHistory = [];
  final List<SpectatorCheerEvent> _activeCockpitCheers = [];

  final StreamController<AchievementToastNotification>
      _achievementToastController =
      StreamController<AchievementToastNotification>.broadcast();
  final StreamController<SpectatorCheerEvent> _spectatorCheerController =
      StreamController<SpectatorCheerEvent>.broadcast();

  String? get accessToken => _accessToken;
  String? get refreshToken => _refreshToken;
  String? get userId => _userId;
  bool get isAuthenticated => _accessToken != null && _accessToken!.isNotEmpty;
  bool get isDisposed => _disposed;

  RealtimeMatchChannel? get activeMatchChannel => _activeMatchChannel;

  Stream<AchievementToastNotification> get achievementToasts =>
      _achievementToastController.stream;
  List<AchievementToastNotification> get toastHistory =>
      List.unmodifiable(_toastHistory);
  Set<String> get unlockedFeatIds => Set.unmodifiable(_unlockedFeatIds);

  /// Returns the set of feat IDs unlocked specifically during [matchId].
  Set<String> unlockedFeatIdsForMatch(String matchId) =>
      Set.unmodifiable(_matchUnlockedFeats[matchId] ?? {});
  Set<String> get syncedFeatIds => Set.unmodifiable(_syncedFeatIds);

  Stream<SpectatorCheerEvent> get spectatorCheers =>
      _spectatorCheerController.stream;
  List<SpectatorCheerEvent> get activeCockpitCheers =>
      List.unmodifiable(_activeCockpitCheers);

  // ---------------------------------------------------------------------------
  // 1. SunShade Hub SSO / Supabase JWT Session Authentication
  // ---------------------------------------------------------------------------

  /// Authenticates the player from a shared SunShade Hub SSO URL or JWT session.
  bool authenticateFromUrl(Uri uri) {
    final token = uri.queryParameters['access_token'] ??
        uri.queryParameters['hub_jwt'] ??
        _extractFragmentParam(uri.fragment, 'access_token');
    final refresh = uri.queryParameters['refresh_token'] ??
        _extractFragmentParam(uri.fragment, 'refresh_token');
    final uid = uri.queryParameters['user_id'];

    if (token == null || token.trim().isEmpty) {
      return false;
    }

    authenticateWithSession(
      accessToken: token.trim(),
      refreshToken: refresh?.trim(),
      userId: uid?.trim() ?? _tryDecodeJwtSub(token.trim()),
    );
    return true;
  }

  /// Directly sets the authenticated SunShade Supabase / Hub JWT session.
  void authenticateWithSession({
    required String accessToken,
    String? refreshToken,
    String? userId,
  }) {
    _accessToken = accessToken;
    _refreshToken = refreshToken;
    _userId = userId ?? _tryDecodeJwtSub(accessToken);
  }

  String? _extractFragmentParam(String fragment, String key) {
    if (fragment.isEmpty) return null;
    try {
      final params = Uri.splitQueryString(fragment);
      return params[key];
    } catch (_) {
      return null;
    }
  }

  String? _tryDecodeJwtSub(String jwt) {
    final parts = jwt.split('.');
    if (parts.length != 3) return null;
    try {
      final normalized = base64Url.normalize(parts[1]);
      final payloadJson = utf8.decode(base64Url.decode(normalized));
      final decoded = jsonDecode(payloadJson);
      if (decoded is Map<String, dynamic> && decoded['sub'] is String) {
        return decoded['sub'] as String;
      }
    } catch (_) {
      // Non-JWT or opaque token; ignore
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // 2. Post-Match Result Submission (Victory / Defeat) with Retry & Idempotency
  // ---------------------------------------------------------------------------

  /// Submits a [MatchSummary] to `/api/matches/ingest` with an `Idempotency-Key`
  /// header and automatic retry on transient 5xx or network failures.
  /// Also automatically dispatches any milestone feats included in [summary.featsUnlocked].
  Future<MatchSubmissionResult> submitMatchResult(MatchSummary summary) async {
    final String idempotencyKey = summary.effectiveIdempotencyKey;

    if (!isAuthenticated) {
      return MatchSubmissionResult(
        ok: false,
        statusCode: 401,
        attempts: 0,
        idempotencyKey: idempotencyKey,
        error: 'Unauthenticated: missing SunShade Hub JWT session token.',
      );
    }

    final Uri url = Uri.parse('$baseUrl/api/matches/ingest');
    final String encodedBody = jsonEncode(summary.toJson());
    final Map<String, String> headers = {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $_accessToken',
      'Idempotency-Key': idempotencyKey,
    };

    int attempts = 0;
    String? lastError;
    int lastStatus = 0;

    while (attempts < maxRetries) {
      attempts++;
      try {
        final response = await _httpClient.post(
          url,
          headers: headers,
          body: encodedBody,
        );
        lastStatus = response.statusCode;

        Map<String, dynamic>? parsedData;
        if (response.body.isNotEmpty) {
          try {
            final decoded = jsonDecode(response.body);
            if (decoded is Map<String, dynamic>) {
              parsedData = decoded;
            }
          } catch (_) {}
        }

        // Check Supabase / API error guard `{ error }` on mutation response
        final dynamic bodyError = parsedData?['error'];
        if (response.statusCode >= 200 &&
            response.statusCode < 300 &&
            bodyError == null) {
          // Trigger achievement milestones included in match summary
          for (final featId in summary.featsUnlocked) {
            final feat = DartUpMilestoneFeat.fromId(featId);
            if (feat != null) {
              await triggerMilestoneAchievement(feat, matchId: summary.matchId);
            }
          }

          return MatchSubmissionResult(
            ok: true,
            statusCode: response.statusCode,
            attempts: attempts,
            idempotencyKey: idempotencyKey,
            data: parsedData,
          );
        }

        lastError = bodyError?.toString() ??
            'HTTP ${response.statusCode}: ${response.body}';

        // Do not retry 4xx client errors (except 429 rate limit)
        if (response.statusCode >= 400 &&
            response.statusCode < 500 &&
            response.statusCode != 429) {
          break;
        }
      } catch (e) {
        lastError = e.toString();
      }

      if (attempts < maxRetries && retryDelay > Duration.zero) {
        await Future<void>.delayed(retryDelay);
      }
    }

    debugPrint('[HubApiService] submitMatchResult failed: $lastError');
    return MatchSubmissionResult(
      ok: false,
      statusCode: lastStatus,
      attempts: attempts,
      idempotencyKey: idempotencyKey,
      error: lastError,
    );
  }

  // ---------------------------------------------------------------------------
  // 3. @digitalcanopy/achievements Milestone Dispatching
  // ---------------------------------------------------------------------------

  /// Maps in-game feats (`star_dart_siege_survivor`, `three_way_ambush`,
  /// `smuggler_ring_crack`) to `@digitalcanopy/achievements` milestone triggers
  /// and emits an [AchievementToastNotification] for the HUD.
  ///
  /// If a previous call unlocked the feat locally while offline or during a
  /// network failure, subsequent calls retry the Hub sync without duplicating
  /// local unlock state once synced.
  Future<AchievementToastNotification?> triggerMilestoneAchievement(
    DartUpMilestoneFeat feat, {
    String matchId = 'active_match',
  }) async {
    if (_disposed ||
        _syncedFeatIds.contains(feat.id) ||
        _inFlightFeatIds.contains(feat.id)) {
      return null;
    }

    final bool wasAlreadyUnlockedLocally = _unlockedFeatIds.contains(feat.id);
    _unlockedFeatIds.add(feat.id);
    _matchUnlockedFeats.putIfAbsent(matchId, () => {}).add(feat.id);
    _inFlightFeatIds.add(feat.id);

    bool synced = false;
    try {
      if (isAuthenticated) {
        final Uri url = Uri.parse('$baseUrl/api/achievements/unlock');
        int attempts = 0;
        while (attempts < maxRetries && !synced) {
          attempts++;
          try {
            final response = await _httpClient.post(
              url,
              headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer $_accessToken',
                'Idempotency-Key': 'ach_${matchId}_${feat.id}',
              },
              body: jsonEncode({
                'package': '@digitalcanopy/achievements',
                'achievement_code': feat.achievementCode,
                'feat_id': feat.id,
                'match_id': matchId,
                'title': feat.title,
              }),
            );

            Map<String, dynamic>? parsed;
            if (response.body.isNotEmpty) {
              try {
                final d = jsonDecode(response.body);
                if (d is Map<String, dynamic>) parsed = d;
              } catch (_) {}
            }

            if (response.statusCode >= 200 &&
                response.statusCode < 300 &&
                parsed?['error'] == null) {
              synced = true;
              _syncedFeatIds.add(feat.id);
              break;
            }

            if (response.statusCode >= 400 &&
                response.statusCode < 500 &&
                response.statusCode != 429) {
              break;
            }
          } catch (e) {
            debugPrint('[HubApiService] Achievement unlock error: $e');
          }

          if (!synced && attempts < maxRetries && retryDelay > Duration.zero) {
            await Future<void>.delayed(retryDelay);
          }
        }
      }
    } finally {
      _inFlightFeatIds.remove(feat.id);
    }

    if (wasAlreadyUnlockedLocally && !synced) {
      return null;
    }

    final toast = AchievementToastNotification(
      feat: feat,
      unlockedAt: DateTime.now().toUtc(),
      matchId: matchId,
      syncedWithHub: synced,
    );

    if (wasAlreadyUnlockedLocally) {
      final int existingIdx =
          _toastHistory.indexWhere((t) => t.feat.id == feat.id);
      if (existingIdx >= 0) {
        _toastHistory[existingIdx] = toast;
      } else {
        _toastHistory.add(toast);
      }
    } else {
      _toastHistory.add(toast);
    }

    if (!_achievementToastController.isClosed) {
      _achievementToastController.add(toast);
    }
    return toast;
  }

  // ---------------------------------------------------------------------------
  // 4. Supabase Realtime Match Channel & Spectator Cheer Broadcasts
  // ---------------------------------------------------------------------------

  /// Subscribes to the Supabase Realtime match channel (`match:<matchId>`) to
  /// receive ephemeral spectator cheers and surface them in the cockpit HUD.
  RealtimeMatchChannel subscribeToMatchChannel(
    String matchId, {
    RealtimeMatchChannel? customChannel,
    Duration? pollInterval,
  }) {
    _activeMatchChannel?.unsubscribe();

    final channel = customChannel ??
        SupabaseRealtimeMatchChannel(
          channelTopic: 'realtime:hub:match:$matchId',
          httpClient: _httpClient,
          endpointUrl: '$baseUrl/api/realtime/broadcasts',
          accessTokenProvider: () => _accessToken,
          pollInterval: pollInterval ?? realtimePollInterval,
        );
    _activeMatchChannel = channel;

    channel.onBroadcast('spectator_cheer', (payload) {
      if (_disposed) return;
      final cheer = SpectatorCheerEvent.fromPayload(
        payload,
        defaultMatchId: matchId,
      );
      _activeCockpitCheers.add(cheer);
      if (_activeCockpitCheers.length > 20) {
        _activeCockpitCheers.removeAt(0);
      }
      if (!_spectatorCheerController.isClosed) {
        _spectatorCheerController.add(cheer);
      }
    });

    channel.subscribe();
    return channel;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _activeMatchChannel?.unsubscribe();
    _activeMatchChannel = null;
    _achievementToastController.close();
    _spectatorCheerController.close();
    if (_ownsHttpClient) {
      _httpClient.close();
    }
  }
}
