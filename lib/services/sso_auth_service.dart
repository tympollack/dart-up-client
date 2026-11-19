import 'dart:async';
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

  static const String hubApiUrl = HubApiService.defaultBaseUrl;
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
  SsoAuthService({
    CookieReader? reader,
    SupabaseClient? supabaseClient,
  })  : cookieReader = reader ?? getPlatformCookieReader(),
        _customSupabaseClient = supabaseClient {
    if (supabaseClient != null) {
      _authSubscription?.cancel();
      _authSubscription = supabaseClient.auth.onAuthStateChange.listen((data) {
        final session = data.session;
        if (session != null) {
          syncSessionToHubClient(session);
        } else if (data.event == AuthChangeEvent.signedOut) {
          clearHubClientAuth();
        }
      });
      final current = supabaseClient.auth.currentSession;
      if (current != null && !current.isExpired) {
        syncSessionToHubClient(current);
      }
    }
  }

  final CookieReader cookieReader;
  final SupabaseClient? _customSupabaseClient;
  static bool _supabaseInitialized = false;
  static StreamSubscription<AuthState>? _authSubscription;

  SupabaseClient? get _supabaseClient {
    if (_customSupabaseClient != null) return _customSupabaseClient;
    if (_supabaseInitialized) {
      try {
        return Supabase.instance.client;
      } catch (_) {}
    }
    return null;
  }

  /// Synchronizes a validated Supabase session into HubClient.sharedService
  static void syncSessionToHubClient(Session session) {
    HubClient.sharedService.authenticateWithSession(
      accessToken: session.accessToken,
      refreshToken: session.refreshToken,
      userId: session.user.id,
    );
  }

  /// Resets HubClient.sharedService authorization on sign out
  static void clearHubClientAuth() {
    HubClient.sharedService.dispose();
    HubClient.sharedService = HubApiService(baseUrl: HubClient.baseUrl);
  }

  /// Initializes Supabase client with environment configuration
  static Future<void> initializeSupabase({String? url, String? anonKey}) async {
    if (_supabaseInitialized) return;

    final resolvedUrl = url ?? AppConfig.supabaseUrl;
    final resolvedAnonKey = anonKey ?? AppConfig.supabaseAnonKey;

    if (resolvedUrl.isNotEmpty && resolvedAnonKey.isNotEmpty) {
      try {
        await Supabase.initialize(
          url: resolvedUrl,
          // ignore: deprecated_member_use
          anonKey: resolvedAnonKey,
          authOptions: const FlutterAuthClientOptions(
            authFlowType: AuthFlowType.pkce,
          ),
        );
        _supabaseInitialized = true;

        // Subscribe to auth state changes to keep HubClient in sync
        _authSubscription?.cancel();
        _authSubscription = Supabase.instance.client.auth.onAuthStateChange.listen((data) {
          final session = data.session;
          if (session != null) {
            syncSessionToHubClient(session);
          } else if (data.event == AuthChangeEvent.signedOut) {
            clearHubClientAuth();
          }
        });

        // Synchronize restored persistent session if available
        final current = Supabase.instance.client.auth.currentSession;
        if (current != null && !current.isExpired) {
          syncSessionToHubClient(current);
        }
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
  /// and hydrates Supabase and HubClient.sharedService.
  Future<bool> hydrateFromCookie() async {
    final cookieStr = cookieReader.getCookieString();
    final session = parseCookieSession(cookieStr);

    if (session == null || session.accessToken.isEmpty) {
      return false;
    }

    final client = _supabaseClient;

    if (client != null) {
      try {
        if (session.refreshToken != null && session.refreshToken!.isNotEmpty) {
          // 1. Managed Supabase flow via refresh token
          final res = await client.auth.setSession(session.refreshToken!);
          final validatedSession = res.session;
          if (validatedSession != null) {
            syncSessionToHubClient(validatedSession);
            debugPrint('[SsoAuthService] Successfully hydrated Supabase session via refresh token');
            return true;
          } else {
            debugPrint('[SsoAuthService] Supabase setSession returned null session');
            return false;
          }
        } else {
          // 2. Access-only token: check if an active managed session already exists for the same user
          final currentSession = client.auth.currentSession;
          final bool hasValidManagedSession = currentSession != null &&
              !currentSession.isExpired &&
              currentSession.refreshToken != null &&
              currentSession.refreshToken!.isNotEmpty;

          final cookieUserId = session.userId;
          // Identity must be proven to belong to the same session or same user.
          // Never assume an unknown/opaque token without user ID belongs to the previous account!
          final bool isSameSessionToken = hasValidManagedSession &&
              session.accessToken == currentSession.accessToken;
          final bool isSameUser = hasValidManagedSession &&
              cookieUserId != null &&
              cookieUserId == currentSession.user.id;

          if (isSameSessionToken || isSameUser) {
            // Proven same session or proven same user!
            syncSessionToHubClient(currentSession);
            debugPrint('[SsoAuthService] Preserved existing managed Supabase session for user ${currentSession.user.id}');
            return true;
          }

          // Either no valid managed session exists, or cookie belongs to a different user (account switch).
          // Do NOT transfer refresh tokens across different user identities.
          final sessionJson = jsonEncode({
            'access_token': session.accessToken,
            'token_type': 'bearer',
            'user': {
              'id': session.userId ?? '',
              'aud': 'authenticated',
              'created_at': DateTime.now().toIso8601String(),
              'app_metadata': {},
              'user_metadata': {},
            },
          });
          final res = await client.auth.recoverSession(sessionJson);
          final recoveredSession = res.session;
          if (recoveredSession != null) {
            syncSessionToHubClient(recoveredSession);
            debugPrint('[SsoAuthService] Successfully hydrated Supabase session via access token');
            return true;
          } else {
            debugPrint('[SsoAuthService] Supabase recoverSession returned null session');
            return false;
          }
        }
      } on AuthException catch (e) {
        // Terminal session rejection (revoked or expired refresh token)
        debugPrint('[SsoAuthService] Supabase session rejected (${e.statusCode}): ${e.message}');
        return false;
      } catch (e) {
        // Transient network or serialization errors
        debugPrint('[SsoAuthService] Supabase session recovery boundary handled: ${e.runtimeType}');
        return false;
      }
    } else {
      // Standalone Hub mode (Supabase uninitialized / unconfigured)
      HubClient.sharedService.authenticateWithSession(
        accessToken: session.accessToken,
        refreshToken: session.refreshToken,
        userId: session.userId,
      );
      return true;
    }
  }

  /// Whether player is currently authenticated via HubClient or Supabase
  bool get isAuthenticated {
    final client = _supabaseClient;
    if (client != null) {
      try {
        final session = client.auth.currentSession;
        if (session != null) {
          if (!session.isExpired) {
            if (HubClient.sharedService.accessToken != session.accessToken) {
              syncSessionToHubClient(session);
            }
            return true;
          }
          return false;
        }
      } catch (_) {}
    }
    return HubClient.sharedService.isAuthenticated;
  }

  /// Signs in anonymously as guest on Supabase and binds HubClient guest session
  Future<bool> signInAsGuest() async {
    final client = _supabaseClient;
    String? guestUserId;

    if (client != null) {
      try {
        final AuthResponse res = await client.auth.signInAnonymously();
        if (res.session != null) {
          guestUserId = res.user?.id;
          syncSessionToHubClient(res.session!);
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
  void loginViaHub({String? currentOrigin, String? hubHost}) {
    final origin = currentOrigin ?? cookieReader.getCurrentOrigin();
    final host = hubHost ?? AppConfig.hubApiUrl;
    final redirectUri = Uri.parse(
      '$host/login?redirectTo=${Uri.encodeComponent(origin)}',
    );
    cookieReader.redirectTo(redirectUri.toString());
  }

  /// Handles native deep-link or web redirect auth callbacks (e.g. io.sunshade.dartup://login-callback)
  /// and establishes Supabase and HubClient sessions.
  Future<bool> handleAuthCallback(Uri uri) async {
    String? accessToken = uri.queryParameters['access_token'] ??
        uri.queryParameters['hub_jwt'] ??
        uri.queryParameters['token'];
    String? refreshToken = uri.queryParameters['refresh_token'];
    String? userId = uri.queryParameters['user_id'];

    if (uri.hasFragment) {
      final fragmentParams = Uri.splitQueryString(uri.fragment);
      accessToken ??= fragmentParams['access_token'] ??
          fragmentParams['hub_jwt'] ??
          fragmentParams['token'];
      refreshToken ??= fragmentParams['refresh_token'];
      userId ??= fragmentParams['user_id'];
    }

    if (accessToken == null || accessToken.trim().isEmpty) {
      return false;
    }

    final client = _supabaseClient;
    if (client != null) {
      try {
        if (refreshToken != null && refreshToken.isNotEmpty) {
          final res = await client.auth.setSession(refreshToken);
          if (res.session != null) {
            syncSessionToHubClient(res.session!);
            debugPrint('[SsoAuthService] Successfully hydrated callback session via refresh token');
            return true;
          }
        }

        final resolvedUserId = userId ?? _tryDecodeJwtSub(accessToken);
        final sessionJson = jsonEncode({
          'access_token': accessToken,
          'token_type': 'bearer',
          'user': {
            'id': resolvedUserId ?? '',
            'aud': 'authenticated',
            'created_at': DateTime.now().toIso8601String(),
            'app_metadata': {},
            'user_metadata': {},
          },
        });
        final res = await client.auth.recoverSession(sessionJson);
        if (res.session != null) {
          syncSessionToHubClient(res.session!);
          debugPrint('[SsoAuthService] Successfully hydrated callback session via access token');
          return true;
        }
      } catch (e) {
        debugPrint('[SsoAuthService] Supabase callback handling exception: ${e.runtimeType}');
      }
    }

    // Direct HubClient hydration fallback
    HubClient.sharedService.authenticateWithSession(
      accessToken: accessToken,
      refreshToken: refreshToken,
      userId: userId ?? _tryDecodeJwtSub(accessToken),
    );
    return true;
  }

  /// Opens an external URL in a new tab (_blank)
  void openExternalLink(String url) {
    cookieReader.openNewTab(url);
  }
}
