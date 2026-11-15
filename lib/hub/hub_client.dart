import 'package:flutter/foundation.dart';
import 'package:sd_client/services/hub_api_service.dart';

export 'package:sd_client/services/hub_api_service.dart';

class HubClient {
  static const String baseUrl = 'https://hub-stag.sunshade.icu';
  static HubApiService sharedService = HubApiService(baseUrl: baseUrl);

  static String? get accessToken => sharedService.accessToken;
  static set accessToken(String? token) {
    if (token == null || token.isEmpty) {
      sharedService = HubApiService(baseUrl: baseUrl);
    } else {
      sharedService.authenticateWithSession(accessToken: token);
    }
  }

  /// Initializes the token from the URL query parameters (SSO from Hub)
  static void initializeFromUrl(Uri uri) {
    sharedService.authenticateFromUrl(uri);
  }

  /// Sends the match result to the SunShade Hub UI ingest API
  static Future<MatchSubmissionResult> postMatchResult({
    required String gameName,
    required String opponentName,
    required String result,
    required String matchType,
    required int moves,
    String matchId = 'sandbox_match',
    List<String> featsUnlocked = const [],
  }) async {
    if (!sharedService.isAuthenticated) {
      debugPrint('No access token available. Cannot post match result.');
      return MatchSubmissionResult(
        ok: false,
        statusCode: 401,
        attempts: 0,
        idempotencyKey: 'unauthenticated',
        error: 'No access token available.',
      );
    }

    return sharedService.submitMatchResult(
      MatchSummary(
        matchId: matchId,
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
