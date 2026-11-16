import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sd_client/hub/hub_client.dart';

void main() {
  group('TASK-DARTUP-HUB-SDK-BRIDGE: HubApiService, Achievements & Spectator Cheers', () {
    test('Authenticates player via shared SunShade Hub URL or JWT session', () {
      final service = HubApiService();
      expect(service.isAuthenticated, isFalse);

      // Construct a mock JWT with payload {"sub": "user_tymz_01"}
      final header = base64Url.encode(utf8.encode('{"alg":"HS256","typ":"JWT"}'));
      final payload = base64Url.encode(utf8.encode('{"sub":"user_tymz_01"}'));
      final jwt = '$header.$payload.sig';

      final authenticated = service.authenticateFromUrl(
        Uri.parse('https://dartup-stag.sunshade.icu/?access_token=$jwt&refresh_token=ref_123'),
      );
      expect(authenticated, isTrue);
      expect(service.isAuthenticated, isTrue);
      expect(service.accessToken, equals(jwt));
      expect(service.refreshToken, equals('ref_123'));
      expect(service.userId, equals('user_tymz_01'));
      service.dispose();
    });

    test('submitMatchResult retries transient 500 error, attaches Idempotency-Key, and triggers achievement toasts', () async {
      int ingestAttempts = 0;
      int achievementCalls = 0;
      String? capturedIdempotencyKey;
      final List<String> unlockedCodes = [];

      final mockClient = MockClient((http.Request request) async {
        if (request.url.path == '/api/matches/ingest') {
          ingestAttempts++;
          capturedIdempotencyKey = request.headers['Idempotency-Key'];
          if (ingestAttempts == 1) {
            return http.Response(jsonEncode({'error': 'Transient gateway timeout'}), 503);
          }
          return http.Response(jsonEncode({'status': 'ingested', 'match_id': 'm_101'}), 200);
        }

        if (request.url.path == '/api/achievements/unlock') {
          achievementCalls++;
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          unlockedCodes.add(body['achievement_code'] as String);
          return http.Response(jsonEncode({'unlocked': true}), 200);
        }

        return http.Response('Not Found', 404);
      });

      final service = HubApiService(
        httpClient: mockClient,
        maxRetries: 3,
        retryDelay: const Duration(milliseconds: 1),
      );
      service.authenticateWithSession(accessToken: 'jwt_valid_token', userId: 'u_1');

      final toasts = <AchievementToastNotification>[];
      final sub = service.achievementToasts.listen(toasts.add);

      final result = await service.submitMatchResult(
        const MatchSummary(
          matchId: 'm_101',
          opponentName: 'Star Dart Boss',
          outcome: 'victory',
          moves: 42,
          dronesDeployed: 180,
          dronesHacked: 25,
          featsUnlocked: [
            'star_dart_siege_survivor',
            'three_way_ambush',
            'smuggler_ring_crack',
          ],
        ),
      );

      await Future<void>.delayed(const Duration(milliseconds: 10));
      await sub.cancel();

      expect(result.ok, isTrue);
      expect(result.attempts, equals(2));
      expect(capturedIdempotencyKey, equals('dartup_match_m_101_victory'));
      expect(achievementCalls, equals(3));
      expect(
        unlockedCodes,
        containsAll([
          'ACH_DARTUP_STAR_DART_SIEGE_SURVIVOR',
          'ACH_DARTUP_THREE_WAY_AMBUSH',
          'ACH_DARTUP_SMUGGLER_RING_CRACK',
        ]),
      );
      expect(toasts.length, equals(3));
      expect(toasts.every((t) => t.syncedWithHub), isTrue);
      service.dispose();
    });

    test('Retries failed or offline achievement unlock on subsequent trigger and generates unique match IDs in HubClient', () async {
      int unlockRequests = 0;
      final mockClient = MockClient((http.Request request) async {
        if (request.url.path == '/api/achievements/unlock') {
          unlockRequests++;
          if (unlockRequests == 1) {
            return http.Response(jsonEncode({'error': 'Bad request'}), 400);
          }
          return http.Response(jsonEncode({'unlocked': true}), 200);
        }
        return http.Response('Not Found', 404);
      });

      final service = HubApiService(
        httpClient: mockClient,
        maxRetries: 1,
        retryDelay: Duration.zero,
      );

      // 1. Trigger while unauthenticated -> local toast emitted (syncedWithHub: false)
      final offlineToast = await service.triggerMilestoneAchievement(
        DartUpMilestoneFeat.smugglerRingCrack,
        matchId: 'm_retry',
      );
      expect(offlineToast, isNotNull);
      expect(offlineToast!.syncedWithHub, isFalse);
      expect(service.unlockedFeatIds.contains('smuggler_ring_crack'), isTrue);
      expect(service.syncedFeatIds.contains('smuggler_ring_crack'), isFalse);

      // 2. Authenticate and retry -> first HTTP attempt returns 400, so still unsynced
      service.authenticateWithSession(accessToken: 'jwt_retry');
      final failedRetry = await service.triggerMilestoneAchievement(
        DartUpMilestoneFeat.smugglerRingCrack,
        matchId: 'm_retry',
      );
      expect(failedRetry, isNull);
      expect(service.syncedFeatIds.contains('smuggler_ring_crack'), isFalse);

      // 3. Retry again -> HTTP 200 succeeds and marks feat synced
      final syncedToast = await service.triggerMilestoneAchievement(
        DartUpMilestoneFeat.smugglerRingCrack,
        matchId: 'm_retry',
      );
      expect(syncedToast, isNotNull);
      expect(syncedToast!.syncedWithHub, isTrue);
      expect(service.syncedFeatIds.contains('smuggler_ring_crack'), isTrue);

      // 4. Subsequent call after sync is a no-op
      final postSyncCall = await service.triggerMilestoneAchievement(
        DartUpMilestoneFeat.smugglerRingCrack,
        matchId: 'm_retry',
      );
      expect(postSyncCall, isNull);
      expect(unlockRequests, equals(2));

      // Verify HubClient generates distinct match IDs per match
      final id1 = HubClient.generateMatchId();
      final id2 = HubClient.generateMatchId();
      expect(id1, isNot(equals(id2)));

      service.dispose();
    });

    test('Subscribes to Supabase Realtime match channel and buffers incoming spectator cheers via both simulated and HTTP poll broadcasts', () async {
      final mockClient = MockClient((http.Request request) async {
        if (request.url.path == '/api/realtime/broadcasts') {
          return http.Response(
            jsonEncode({
              'next_cursor': 'cur_2',
              'events': [
                {
                  'event': 'spectator_cheer',
                  'payload': {
                    'cheer_id': 'c_100',
                    'match_id': 'match_77',
                    'spectator_handle': 'LiveStreamer',
                    'message': 'Warp out now!',
                    'cheer_amount': 100,
                  },
                },
              ],
            }),
            200,
          );
        }
        return http.Response('Not Found', 404);
      });

      final service = HubApiService(httpClient: mockClient);
      final channel = service.subscribeToMatchChannel('match_77');
      expect(channel.isSubscribed, isTrue);

      final receivedCheers = <SpectatorCheerEvent>[];
      final sub = service.spectatorCheers.listen(receivedCheers.add);

      channel.emitSimulatedBroadcast('spectator_cheer', {
        'cheer_id': 'c_99',
        'match_id': 'match_77',
        'spectator_handle': 'OrbitalWatcher',
        'message': 'Finish the Star Dart!',
        'cheer_amount': 50,
      });

      if (channel is SupabaseRealtimeMatchChannel) {
        final dispatched = await channel.pollBroadcastsOnce();
        expect(dispatched, equals(1));
      }

      await Future<void>.delayed(const Duration(milliseconds: 5));
      await sub.cancel();

      expect(receivedCheers.length, equals(2));
      expect(receivedCheers.first.spectatorHandle, equals('OrbitalWatcher'));
      expect(receivedCheers.first.cheerAmount, equals(50));
      expect(receivedCheers.last.spectatorHandle, equals('LiveStreamer'));
      expect(receivedCheers.last.cheerAmount, equals(100));
      expect(service.activeCockpitCheers.length, equals(2));
      service.dispose();
    });

    test('unlockedFeatIdsForMatch tracks feats strictly per matchId and channels have nonzero pollInterval', () async {
      final service = HubApiService(
        httpClient: MockClient((_) async => http.Response('{}', 200)),
        maxRetries: 1,
      );

      await service.triggerMilestoneAchievement(
        DartUpMilestoneFeat.smugglerRingCrack,
        matchId: 'match_alpha',
      );
      await service.triggerMilestoneAchievement(
        DartUpMilestoneFeat.threeWayAmbush,
        matchId: 'match_beta',
      );

      expect(service.unlockedFeatIdsForMatch('match_alpha'), equals({'smuggler_ring_crack'}));
      expect(service.unlockedFeatIdsForMatch('match_beta'), equals({'three_way_ambush'}));
      expect(service.unlockedFeatIdsForMatch('match_gamma'), isEmpty);

      final channel = service.subscribeToMatchChannel('match_gamma');
      if (channel is SupabaseRealtimeMatchChannel) {
        expect(channel.pollInterval, isNotNull);
        expect(channel.pollInterval, greaterThan(Duration.zero));
      }

      service.dispose();
    });

    test('SupabaseRealtimeMatchChannel serializes overlapping polls so only one request is in flight', () async {
      final Completer<http.Response> inFlightCompleter = Completer<http.Response>();
      int pollCount = 0;

      final mockClient = MockClient((http.Request request) async {
        if (request.url.path == '/api/realtime/broadcasts') {
          pollCount++;
          return inFlightCompleter.future;
        }
        return http.Response('Not Found', 404);
      });

      final channel = SupabaseRealtimeMatchChannel(
        channelTopic: 'realtime:test:channel',
        httpClient: mockClient,
        endpointUrl: 'https://hub-stag.sunshade.icu/api/realtime/broadcasts',
        pollInterval: const Duration(seconds: 2),
      );
      channel.subscribe();

      // Trigger first poll (which awaits inFlightCompleter)
      final Future<int> poll1 = channel.pollBroadcastsOnce();
      // Trigger overlapping second poll while poll 1 is still in flight
      final int poll2 = await channel.pollBroadcastsOnce();

      // Yield event loop so poll 1 reaches mockClient handler
      await Future<void>.delayed(Duration.zero);

      // Second poll must return 0 immediately without issuing another HTTP GET
      expect(poll2, equals(0));
      expect(pollCount, equals(1));

      // Complete first poll
      inFlightCompleter.complete(
        http.Response(jsonEncode({'events': []}), 200),
      );
      final int poll1Result = await poll1;
      expect(poll1Result, equals(0));

      channel.unsubscribe();
    });

    test('triggerMilestoneAchievement coordinates concurrent in-flight attempts and retries if first fails', () async {
      int unlockAttempts = 0;
      final Completer<http.Response> firstUnlockCompleter = Completer<http.Response>();

      final mockClient = MockClient((http.Request request) async {
        if (request.url.path == '/api/achievements/unlock') {
          unlockAttempts++;
          if (unlockAttempts == 1) {
            return firstUnlockCompleter.future;
          }
          return http.Response(jsonEncode({'unlocked': true}), 200);
        }
        return http.Response('Not Found', 404);
      });

      final service = HubApiService(
        httpClient: mockClient,
        maxRetries: 1,
        retryDelay: Duration.zero,
      );
      service.authenticateWithSession(accessToken: 'jwt_concurrency_test');

      // First call starts and is in-flight
      final Future<AchievementToastNotification?> firstCall =
          service.triggerMilestoneAchievement(
        DartUpMilestoneFeat.starDartSiegeSurvivor,
        matchId: 'm_concurrent',
      );

      // Second call starts concurrently for the same feat
      final Future<AchievementToastNotification?> secondCall =
          service.triggerMilestoneAchievement(
        DartUpMilestoneFeat.starDartSiegeSurvivor,
        matchId: 'm_concurrent',
      );

      // Complete first attempt with a 503 error
      firstUnlockCompleter.complete(
        http.Response(jsonEncode({'error': 'Server unavailable'}), 503),
      );

      final firstResult = await firstCall;
      final secondResult = await secondCall;

      // First result failed to sync with hub
      expect(firstResult, isNotNull);
      expect(firstResult!.syncedWithHub, isFalse);

      // Second result coordinated and ran the retry which succeeded with HTTP 200
      expect(secondResult, isNotNull);
      expect(secondResult!.syncedWithHub, isTrue);
      expect(service.syncedFeatIds.contains('star_dart_siege_survivor'), isTrue);
      expect(unlockAttempts, equals(2));

      service.dispose();
    });
  });
}
