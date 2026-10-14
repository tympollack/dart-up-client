import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class HubClient {
  static const String baseUrl = 'https://hub.sunshade.health'; // Change if testing locally
  static String? accessToken;

  /// Initializes the token from the URL query parameters (SSO from Hub)
  static void initializeFromUrl(Uri uri) {
    if (uri.queryParameters.containsKey('access_token')) {
      accessToken = uri.queryParameters['access_token'];
    }
  }

  /// Sends the match result to the SunShade Hub UI ingest API
  static Future<void> postMatchResult({
    required String gameName,
    required String opponentName,
    required String result,
    required String matchType,
    required int moves,
  }) async {
    if (accessToken == null) {
      debugPrint('No access token available. Cannot post match result.');
      return;
    }

    final url = Uri.parse('$baseUrl/api/matches/ingest');
    try {
      final response = await http.post(
        url,
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $accessToken',
        },
        body: jsonEncode({
          'game_name': gameName,
          'opponent_name': opponentName,
          'result': result,
          'match_type': matchType,
          'moves': moves,
        }),
      );

      if (response.statusCode == 200) {
        debugPrint('Successfully synced match to Hub!');
      } else {
        debugPrint('Failed to sync match. Status: ${response.statusCode}, Body: ${response.body}');
      }
    } catch (e) {
      debugPrint('Error posting match result: $e');
    }
  }
}
