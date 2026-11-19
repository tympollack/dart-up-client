import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sd_client/hub/hub_client.dart';
import 'package:sd_client/services/cookie_reader/cookie_reader.dart';

/// Dart Up! Environment & Cloudflare Pages Configuration
class AppConfig {
  static const String supabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://rweehbzsflhhtwjrjnvy.supabase.co',
  );

  static const String supabaseAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue: '',
  );

  static const String hubApiUrl = String.fromEnvironment(
    'HUB_API_URL',
    defaultValue: 'https://hub-stag.sunshade.icu',
  );
}

/// Parsed session extracted from .sunshade.icu cookies or Hub tokens
class ExtractedSession {
  final String accessToken;
  final String? refreshToken;
  final String? userId;

  const ExtractedSession({
    required this.accessToken,
    this.refreshToken,
    this.userId,
  });

  @override
  String toString() {
    // Redact tokens from string representations to prevent logging leaks
    return 'ExtractedSession(userId: $userId, accessToken: [REDACTED], refreshToken: [REDACTED])';
  }
}

/// Manages .sunshade.icu cookie inspection, Supabase auth hydration, and Hub SSO entry
class SsoAuthService {
  SsoAuthService({CookieReader? reader})
      : cookieReader = reader ?? getPlatformCookieReader();

  final CookieReader cookieReader;
  static bool _supabaseInitialized = false;

  /// Initializes Supabase client with environment configuration
  static Future<void> initializeSupabase() async {
    if (_supabaseInitialized) return;

    if (AppConfig.supabaseUrl.isNotEmpty && AppConfig.supabaseAnonKey.isNotEmpty) {
      try {
        await Supabase.initialize(
          url: AppConfig.supabaseUrl,
          // ignore: deprecated_member_use
          anonKey: AppConfig.supabaseAnonKey,
          authOptions: const FlutterAuthClientOptions(
            authFlowType: AuthFlowType.pkce,
          ),
        );
        _supabaseInitialized = true;
      } catch (e) {
        // Redact any potential secrets from exception logs
        debugPrint('[SsoAuthService] Supabase initialization failed: ${e.runtimeType}');
      }
    }
  }

  /// Extracts session credentials from cookie header strings
  static ExtractedSession? parseCookieSession(String cookieHeader) {
    if (cookieHeader.trim().isEmpty) return null;

    final Map<String, String> cookies = {};
    for (final pair in cookieHeader.split(';')) {
      final parts = pair.split('=');
      if (parts.length >= 2) {
        final key = parts[0].trim();
        final val = parts.sublist(1).join('=').trim();
        try {
          cookies[key] = Uri.decodeComponent(val);
        } catch (_) {
          cookies[key] = val;
        }
      }
    }

    // 1. Check for chunked or standalone sb-*-auth-token cookies
    final List<String> authKeys = cookies.keys
        .where((k) => k.contains('-auth-token') || k == 'sb-auth-token')
        .toList();

    if (authKeys.isNotEmpty) {
      // Reassemble chunked cookies (e.g. .0, .1) if present
      final Map<String, List<MapEntry<int, String>>> baseToChunks = {};
      final List<String> standaloneKeys = [];

      for (final key in authKeys) {
        final dotIndex = key.lastIndexOf('.');
        if (dotIndex != -1) {
          final chunkNum = int.tryParse(key.substring(dotIndex + 1));
          if (chunkNum != null) {
            final base = key.substring(0, dotIndex);
            baseToChunks.putIfAbsent(base, () => []).add(MapEntry(chunkNum, cookies[key]!));
            continue;
          }
        }
        standaloneKeys.add(key);
      }

      // Try chunked first
      for (final chunks in baseToChunks.values) {
        chunks.sort((a, b) => a.key.compareTo(b.key));
        final combined = chunks.map((c) => c.value).join();
        final session = _decodeTokenString(combined);
        if (session != null) return session;
      }

      // Try standalone
      for (final key in standaloneKeys) {
        final session = _decodeTokenString(cookies[key]!);
        if (session != null) return session;
      }
    }

    // 2. Check for direct standard cookies
    final directToken = cookies['sb-access-token'] ??
        cookies['access_token'] ??
        cookies['sunshade_session'] ??
        cookies['hub_jwt'];

    if (directToken != null && directToken.isNotEmpty) {
      final refresh = cookies['sb-refresh-token'] ?? cookies['refresh_token'];
      final uid = cookies['user_id'] ?? _tryDecodeJwtSub(directToken);
      return ExtractedSession(
        accessToken: directToken,
        refreshToken: refresh,
        userId: uid,
      );
    }

    return null;
  }

  static ExtractedSession? _decodeTokenString(String raw) {
    var tokenPayload = raw.trim();
    if (tokenPayload.startsWith('base64-')) {
      try {
        final b64 = tokenPayload.substring(7);
        final normalized = base64Url.normalize(b64);
        tokenPayload = utf8.decode(base64Url.decode(normalized));
      } catch (_) {
        return null;
      }
    }

    try {
      final decoded = jsonDecode(tokenPayload);
      if (decoded is List && decoded.isNotEmpty) {
        final accessToken = decoded[0].toString();
        final refreshToken = decoded.length > 1 ? decoded[1].toString() : null;
        return ExtractedSession(
          accessToken: accessToken,
          refreshToken: refreshToken,
          userId: _tryDecodeJwtSub(accessToken),
        );
      } else if (decoded is Map<String, dynamic>) {
        final sessionMap = decoded['currentSession'] is Map<String, dynamic>
            ? decoded['currentSession'] as Map<String, dynamic>
            : decoded;

        final accessToken = sessionMap['access_token']?.toString();
        final refreshToken = sessionMap['refresh_token']?.toString();
        final userId = sessionMap['user'] is Map<String, dynamic>
            ? (sessionMap['user'] as Map<String, dynamic>)['id']?.toString()
            : (sessionMap['user_id']?.toString() ??
                (accessToken != null ? _tryDecodeJwtSub(accessToken) : null));

        if (accessToken != null && accessToken.isNotEmpty) {
          return ExtractedSession(
            accessToken: accessToken,
            refreshToken: refreshToken,
            userId: userId,
          );
        }
      }
    } catch (_) {
      // If it's a raw JWT
      if (tokenPayload.split('.').length == 3) {
        return ExtractedSession(
          accessToken: tokenPayload,
          userId: _tryDecodeJwtSub(tokenPayload),
        );
      }
    }

    return null;
  }

  static String? _tryDecodeJwtSub(String jwt) {
    final parts = jwt.split('.');
    if (parts.length != 3) return null;
    try {
      final normalized = base64Url.normalize(parts[1]);
      final payloadJson = utf8.decode(base64Url.decode(normalized));
      final decoded = jsonDecode(payloadJson);
      if (decoded is Map<String, dynamic> && decoded['sub'] is String) {
        return decoded['sub'] as String;
      }
    } catch (_) {}
    return null;
  }

  /// Inspects document.cookie for active .sunshade.icu Supabase session cookies
  /// and hydrates Supabase.instance.client.auth and HubClient.sharedService.
  Future<bool> hydrateFromCookie() async {
    final cookieStr = cookieReader.getCookieString();
    final session = parseCookieSession(cookieStr);

    if (session == null || session.accessToken.isEmpty) {
      return false;
    }

    // Hydrate HubClient session
    HubClient.sharedService.authenticateWithSession(
      accessToken: session.accessToken,
      refreshToken: session.refreshToken,
      userId: session.userId,
    );

    // Hydrate Supabase client if initialized
    if (_supabaseInitialized) {
      try {
        if (session.refreshToken != null && session.refreshToken!.isNotEmpty) {
          final res = await Supabase.instance.client.auth.setSession(session.refreshToken!);
          if (res.session != null) {
            debugPrint('[SsoAuthService] Successfully hydrated Supabase session via refresh token');
          }
        } else {
          final res = await Supabase.instance.client.auth.recoverSession(session.accessToken);
          if (res.session != null) {
            debugPrint('[SsoAuthService] Successfully hydrated Supabase session via access token');
          }
        }
      } catch (e) {
        // Redact raw token data
        debugPrint('[SsoAuthService] Supabase session recovery boundary handled: ${e.runtimeType}');
      }
    }

    return true;
  }

  /// Whether player is currently authenticated via HubClient or Supabase
  bool get isAuthenticated {
    if (HubClient.sharedService.isAuthenticated) return true;
    if (_supabaseInitialized) {
      try {
        return Supabase.instance.client.auth.currentSession != null;
      } catch (_) {}
    }
    return false;
  }

  /// Signs in anonymously as guest on Supabase and binds HubClient guest session
  Future<bool> signInAsGuest() async {
    String? guestUserId;

    if (_supabaseInitialized) {
      try {
        final AuthResponse res = await Supabase.instance.client.auth.signInAnonymously();
        if (res.session != null) {
          guestUserId = res.user?.id;
          HubClient.sharedService.authenticateWithSession(
            accessToken: res.session!.accessToken,
            refreshToken: res.session?.refreshToken,
            userId: guestUserId,
          );
          debugPrint('[SsoAuthService] Guest session active');
          return true;
        }
      } catch (e) {
        debugPrint('[SsoAuthService] Supabase anonymous auth boundary caught: ${e.runtimeType}');
      }
    }

    // Fallback: Generate local guest session for offline / unconfigured Supabase
    guestUserId ??= 'guest_${DateTime.now().millisecondsSinceEpoch}';
    HubClient.sharedService.authenticateWithSession(
      accessToken: 'guest_token_${DateTime.now().millisecondsSinceEpoch}',
      userId: guestUserId,
    );
    debugPrint('[SsoAuthService] Local guest session initialized');
    return true;
  }

  /// Redirects browser to SunShade Hub login with redirectTo set to current origin
  void loginViaHub({String? currentOrigin}) {
    final origin = currentOrigin ?? cookieReader.getCurrentOrigin();
    final redirectUri = Uri.parse(
      'https://hub.sunshade.icu/login?redirectTo=${Uri.encodeComponent(origin)}',
    );
    cookieReader.redirectTo(redirectUri.toString());
  }

  /// Opens an external URL in a new tab (_blank)
  void openExternalLink(String url) {
    cookieReader.openNewTab(url);
  }
}
