import 'package:flutter/foundation.dart';
import 'package:sd_client/services/hub_api_service.dart';

export 'package:sd_client/services/hub_api_service.dart';

class HubClient {
  static const String baseUrl = HubApiService.defaultBaseUrl;
  static HubApiService sharedService = HubApiService(baseUrl: baseUrl);
  static int _matchSequence = 0;

  /// Generates a unique per-match identifier so distinct matches never collide
  /// on `Idempotency-Key` while retries for the same match remain idempotent.
  static String generateMatchId([String prefix = 'match']) {
    _matchSequence++;
    final int timestampMicros = DateTime.now().toUtc().microsecondsSinceEpoch;
    return '${prefix}_${timestampMicros}_$_matchSequence';
  }

  static String? get accessToken => sharedService.accessToken;
  static set accessToken(String? token) {
    if (token == null || token.isEmpty) {
      sharedService.dispose();
      sharedService = HubApiService(baseUrl: baseUrl);
    } else {
      if (sharedService.isDisposed) {
        sharedService = HubApiService(baseUrl: baseUrl);
      }
      sharedService.authenticateWithSession(accessToken: token);
    }
  }

  /// Initializes the token from the URL query parameters (SSO from Hub)
  static void initializeFromUrl(Uri uri) {
    if (sharedService.isDisposed) {
      sharedService = HubApiService(baseUrl: baseUrl);
    }
    sharedService.authenticateFromUrl(uri);
  }

  /// Sends the match result to the SunShade Hub UI ingest API
  static Future<MatchSubmissionResult> postMatchResult({
    required String gameName,
    required String opponentName,
    required String result,
    required String matchType,
    required int moves,
    String? matchId,
    List<String> featsUnlocked = const [],
  }) async {
    final String resolvedMatchId =
        (matchId != null && matchId.trim().isNotEmpty)
            ? matchId.trim()
            : generateMatchId();

    if (!sharedService.isAuthenticated) {
      debugPrint('No access token available. Cannot post match result.');
      return MatchSubmissionResult(
        ok: false,
        statusCode: 401,
        attempts: 0,
        idempotencyKey: 'dartup_match_${resolvedMatchId}_${result.toLowerCase()}',
        error: 'No access token available.',
      );
    }

    return sharedService.submitMatchResult(
      MatchSummary(
        matchId: resolvedMatchId,
        gameName: gameName,
        opponentName: opponentName,
        outcome: result,
        matchType: matchType,
        moves: moves,
        featsUnlocked: featsUnlocked,
      ),
    );
  }
}
