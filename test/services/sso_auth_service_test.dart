import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sd_client/hub/hub_client.dart';
import 'package:sd_client/hub/auth_entry_gate.dart';
import 'package:sd_client/services/sso_auth_service.dart';
import 'package:sd_client/services/cookie_reader/cookie_reader_stub.dart';
import 'package:sd_client/services/cookie_reader/cookie_reader_native.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  group('TASK-CF-DARTUP-02: SsoAuthService & Cookie Parsing', () {
    test('Empty cookie string returns null session', () {
      expect(SsoAuthService.parseCookieSession(''), isNull);
      expect(SsoAuthService.parseCookieSession('   '), isNull);
      expect(SsoAuthService.parseCookieSession('theme=dark; path=/'), isNull);
    });

    test('Parses direct sb-access-token and sb-refresh-token', () {
      const cookie = 'sb-access-token=jwt_access_123; sb-refresh-token=refresh_456; path=/';
      final session = SsoAuthService.parseCookieSession(cookie);
      expect(session, isNotNull);
      expect(session!.accessToken, equals('jwt_access_123'));
      expect(session.refreshToken, equals('refresh_456'));
    });

    test('Parses sunshade_session and hub_jwt cookies', () {
      const cookie1 = 'sunshade_session=hub_token_abc; path=/';
      final session1 = SsoAuthService.parseCookieSession(cookie1);
      expect(session1, isNotNull);
      expect(session1!.accessToken, equals('hub_token_abc'));

      const cookie2 = 'hub_jwt=hub_token_xyz; path=/';
      final session2 = SsoAuthService.parseCookieSession(cookie2);
      expect(session2, isNotNull);
      expect(session2!.accessToken, equals('hub_token_xyz'));
    });

    test('Parses JSON array in sb-auth-token', () {
      final jsonPayload = jsonEncode(['access_token_abc', 'refresh_token_def']);
      final cookie = 'sb-auth-token=${Uri.encodeComponent(jsonPayload)}; path=/';
      final session = SsoAuthService.parseCookieSession(cookie);
      expect(session, isNotNull);
      expect(session!.accessToken, equals('access_token_abc'));
      expect(session.refreshToken, equals('refresh_token_def'));
    });

    test('Reassembles chunked sb-*-auth-token.0 and .1 cookies', () {
      final jsonPayload = jsonEncode({
        'access_token': 'chunked_access_jwt',
        'refresh_token': 'chunked_refresh_jwt',
        'user': {'id': 'user_uuid_1234'},
      });

      final half = jsonPayload.length ~/ 2;
      final chunk0 = jsonPayload.substring(0, half);
      final chunk1 = jsonPayload.substring(half);

      final cookie =
          'sb-rweehbzsflhhtwjrjnvy-auth-token.0=${Uri.encodeComponent(chunk0)}; '
          'sb-rweehbzsflhhtwjrjnvy-auth-token.1=${Uri.encodeComponent(chunk1)}; path=/';

      final session = SsoAuthService.parseCookieSession(cookie);
      expect(session, isNotNull);
      expect(session!.accessToken, equals('chunked_access_jwt'));
      expect(session.refreshToken, equals('chunked_refresh_jwt'));
      expect(session.userId, equals('user_uuid_1234'));
    });

    test('Parses base64- prefixed supabase auth token', () {
      final jsonPayload = jsonEncode({
        'currentSession': {
          'access_token': 'b64_access_token',
          'refresh_token': 'b64_refresh_token',
          'user_id': 'b64_user_99',
        }
      });
      final b64 = 'base64-${base64Url.encode(utf8.encode(jsonPayload))}';
      final cookie = 'sb-rweehbzsflhhtwjrjnvy-auth-token=$b64; path=/';

      final session = SsoAuthService.parseCookieSession(cookie);
      expect(session, isNotNull);
      expect(session!.accessToken, equals('b64_access_token'));
      expect(session.refreshToken, equals('b64_refresh_token'));
      expect(session.userId, equals('b64_user_99'));
    });

    test('ExtractedSession.toString() redacts sensitive access/refresh tokens', () {
      const session = ExtractedSession(
        accessToken: 'SUPER_SECRET_JWT_TOKEN',
        refreshToken: 'SUPER_SECRET_REFRESH_TOKEN',
        userId: 'pilot_42',
      );
      final str = session.toString();
      expect(str, contains('[REDACTED]'));
      expect(str, isNot(contains('SUPER_SECRET_JWT_TOKEN')));
      expect(str, isNot(contains('SUPER_SECRET_REFRESH_TOKEN')));
    });

    test('SsoAuthService.hydrateFromCookie hydrates HubClient session', () async {
      final stubReader = StubCookieReader();
      stubReader.stubCookie = 'sb-access-token=hydrate_test_token; user_id=test_user_77';

      final authService = SsoAuthService(reader: stubReader);
      final result = await authService.hydrateFromCookie();

      expect(result, isTrue);
      expect(authService.isAuthenticated, isTrue);
      expect(HubClient.sharedService.accessToken, equals('hydrate_test_token'));
      expect(HubClient.sharedService.userId, equals('test_user_77'));
    });

    test('SsoAuthService.signInAsGuest authenticates player as guest', () async {
      final stubReader = StubCookieReader();
      final authService = SsoAuthService(reader: stubReader);

      final result = await authService.signInAsGuest();
      expect(result, isTrue);
      expect(authService.isAuthenticated, isTrue);
      expect(HubClient.sharedService.accessToken, isNotNull);
      expect(HubClient.sharedService.userId, startsWith('guest_'));
    });

    test('SsoAuthService.loginViaHub redirects to Hub login with redirectTo', () {
      final stubReader = StubCookieReader();
      stubReader.stubOrigin = 'https://dartup-stag.sunshade.icu';
      final authService = SsoAuthService(reader: stubReader);

      // Default redirects to AppConfig.hubApiUrl
      authService.loginViaHub();
      expect(
        stubReader.lastRedirectUrl,
        equals('${AppConfig.hubApiUrl}/login?redirectTo=https%3A%2F%2Fdartup-stag.sunshade.icu'),
      );

      // Explicit hubHost override
      authService.loginViaHub(hubHost: 'https://hub.sunshade.icu');
      expect(
        stubReader.lastRedirectUrl,
        equals('https://hub.sunshade.icu/login?redirectTo=https%3A%2F%2Fdartup-stag.sunshade.icu'),
      );
    });

    test('SsoAuthService.openExternalLink delegates to reader', () {
      final stubReader = StubCookieReader();
      final authService = SsoAuthService(reader: stubReader);

      authService.openExternalLink('https://sunshade.icu/eula');
      expect(stubReader.lastOpenedUrl, equals('https://sunshade.icu/eula'));
    });
  });

  group('TASK-CF-DARTUP-02: AuthEntryGate Widget', () {
    testWidgets('Renders child directly when already authenticated', (WidgetTester tester) async {
      final stubReader = StubCookieReader();
      stubReader.stubCookie = 'sb-access-token=active_token_123';
      final authService = SsoAuthService(reader: stubReader);

      await tester.pumpWidget(
        MaterialApp(
          home: AuthEntryGate(
            authService: authService,
            child: const Text('Game Running'),
          ),
        ),
      );

      await tester.pumpAndSettle();
      expect(find.text('Game Running'), findsOneWidget);
      expect(find.byKey(const Key('login_via_hub_button')), findsNothing);
    });

    testWidgets('Renders entry gate and legal links when unauthenticated', (WidgetTester tester) async {
      HubClient.sharedService.dispose();
      HubClient.sharedService = HubApiService(baseUrl: HubClient.baseUrl);

      final stubReader = StubCookieReader();
      stubReader.stubCookie = '';
      final authService = SsoAuthService(reader: stubReader);

      await tester.pumpWidget(
        MaterialApp(
          home: AuthEntryGate(
            authService: authService,
            child: const Text('Game Running'),
          ),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.text('DART UP!'), findsOneWidget);
      expect(find.byKey(const Key('login_via_hub_button')), findsOneWidget);
      expect(find.byKey(const Key('play_as_guest_button')), findsOneWidget);
      expect(find.byKey(const Key('eula_link')), findsOneWidget);
      expect(find.byKey(const Key('privacy_link')), findsOneWidget);
      expect(find.text('Game Running'), findsNothing);

      // Tap Play as Guest
      await tester.tap(find.byKey(const Key('play_as_guest_button')));
      await tester.pumpAndSettle();

      // Now authenticated -> renders child!
      expect(find.text('Game Running'), findsOneWidget);
      expect(find.byKey(const Key('login_via_hub_button')), findsNothing);
    });

    testWidgets('Tapping EULA and Privacy links triggers openExternalLink', (WidgetTester tester) async {
      HubClient.sharedService.dispose();
      HubClient.sharedService = HubApiService(baseUrl: HubClient.baseUrl);

      final stubReader = StubCookieReader();
      stubReader.stubCookie = '';
      final authService = SsoAuthService(reader: stubReader);

      await tester.pumpWidget(
        MaterialApp(
          home: AuthEntryGate(
            authService: authService,
            child: const Text('Game Running'),
          ),
        ),
      );

      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('eula_link')));
      expect(stubReader.lastOpenedUrl, equals('https://sunshade.icu/eula'));

      await tester.tap(find.byKey(const Key('privacy_link')));
      expect(stubReader.lastOpenedUrl, equals('https://sunshade.icu/privacy'));
    });

    testWidgets('AuthEntryGate displays login gate and does not open game when cookie session is rejected', (WidgetTester tester) async {
      HubClient.sharedService.dispose();
      HubClient.sharedService = HubApiService(baseUrl: HubClient.baseUrl);

      final client = SupabaseClient(
        'https://rweehbzsflhhtwjrjnvy.supabase.co',
        'dummy_anon_key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      final stubReader = StubCookieReader();
      stubReader.stubCookie = 'sb-access-token=stale_token; sb-refresh-token=revoked_token_456';
      final authService = SsoAuthService(reader: stubReader, supabaseClient: client);

      await tester.pumpWidget(
        MaterialApp(
          home: AuthEntryGate(
            authService: authService,
            child: const Text('Game Running'),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Because cookie refresh token was rejected, game is NOT opened!
      expect(find.text('Game Running'), findsNothing);
      expect(find.text('DART UP!'), findsOneWidget);
      expect(find.byKey(const Key('login_via_hub_button')), findsOneWidget);
      expect(find.byKey(const Key('play_as_guest_button')), findsOneWidget);

      client.dispose();
    });
    test('HubApiService.defaultBaseUrl, AppConfig.hubApiUrl, and HubClient.baseUrl are unified', () {
      expect(AppConfig.hubApiUrl, equals(HubApiService.defaultBaseUrl));
      expect(HubClient.baseUrl, equals(HubApiService.defaultBaseUrl));
    });

    test('Supabase session recovery synchronizes credentials into HubClient.sharedService', () async {
      HubClient.sharedService.dispose();
      HubClient.sharedService = HubApiService(baseUrl: HubClient.baseUrl);

      final client = SupabaseClient(
        'https://rweehbzsflhhtwjrjnvy.supabase.co',
        'dummy_anon_key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      final authService = SsoAuthService(supabaseClient: client);

      final sessionJson = jsonEncode({
        'access_token': 'refreshed_access_token_999',
        'refresh_token': 'refreshed_refresh_token_999',
        'token_type': 'bearer',
        'user': {
          'id': 'pilot_uuid_999',
          'app_metadata': {},
          'user_metadata': {},
          'aud': 'authenticated',
          'created_at': '2026-01-01T00:00:00Z',
        },
      });

      // Recovering a session into Supabase notifies authStateChange listener
      await client.auth.recoverSession(sessionJson);

      expect(authService.isAuthenticated, isTrue);
      expect(HubClient.sharedService.accessToken, equals('refreshed_access_token_999'));
      expect(HubClient.sharedService.refreshToken, equals('refreshed_refresh_token_999'));
      expect(HubClient.sharedService.userId, equals('pilot_uuid_999'));
      client.dispose();
    });

    test('Restored persisted Supabase session populates HubClient when calling isAuthenticated', () async {
      HubClient.sharedService.dispose();
      HubClient.sharedService = HubApiService(baseUrl: HubClient.baseUrl);

      final client = SupabaseClient(
        'https://rweehbzsflhhtwjrjnvy.supabase.co',
        'dummy_anon_key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      final sessionJson = jsonEncode({
        'access_token': 'persisted_access_jwt',
        'token_type': 'bearer',
        'user': {
          'id': 'persisted_pilot_1',
          'app_metadata': {},
          'user_metadata': {},
          'aud': 'authenticated',
          'created_at': '2026-01-01T00:00:00Z',
        },
      });
      await client.auth.recoverSession(sessionJson);

      // Reset HubClient to emulate app start with restored Supabase session but clean HubClient
      HubClient.sharedService.dispose();
      HubClient.sharedService = HubApiService(baseUrl: HubClient.baseUrl);
      expect(HubClient.sharedService.accessToken, isNull);

      final authService = SsoAuthService(supabaseClient: client);
      // Calling isAuthenticated should sync credentials from Supabase to HubClient
      expect(authService.isAuthenticated, isTrue);
      expect(HubClient.sharedService.accessToken, equals('persisted_access_jwt'));
      expect(HubClient.sharedService.userId, equals('persisted_pilot_1'));
      client.dispose();
    });

    test('Supabase session sign-out clears HubClient.sharedService authorization', () async {
      final client = SupabaseClient(
        'https://rweehbzsflhhtwjrjnvy.supabase.co',
        'dummy_anon_key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      final authService = SsoAuthService(supabaseClient: client);

      final sessionJson = jsonEncode({
        'access_token': 'session_to_sign_out',
        'token_type': 'bearer',
        'user': {
          'id': 'pilot_sign_out',
          'app_metadata': {},
          'user_metadata': {},
          'aud': 'authenticated',
          'created_at': '2026-01-01T00:00:00Z',
        },
      });
      await client.auth.recoverSession(sessionJson);
      expect(HubClient.sharedService.accessToken, equals('session_to_sign_out'));

      try {
        await client.auth.signOut(scope: SignOutScope.local);
      } catch (_) {}
      expect(HubClient.sharedService.accessToken, isNull);
      expect(authService.isAuthenticated, isFalse);
      client.dispose();
    });

    test('Access-only cookie session recovers into Supabase and HubClient without FormatException', () async {
      HubClient.sharedService.dispose();
      HubClient.sharedService = HubApiService(baseUrl: HubClient.baseUrl);

      final client = SupabaseClient(
        'https://rweehbzsflhhtwjrjnvy.supabase.co',
        'dummy_anon_key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      final stubReader = StubCookieReader();
      stubReader.stubCookie = 'sb-access-token=access_only_token_abc; user_id=pilot_access_only';

      final authService = SsoAuthService(reader: stubReader, supabaseClient: client);
      final result = await authService.hydrateFromCookie();

      expect(result, isTrue);
      expect(authService.isAuthenticated, isTrue);
      expect(HubClient.sharedService.accessToken, equals('access_only_token_abc'));
      expect(HubClient.sharedService.userId, equals('pilot_access_only'));
      expect(client.auth.currentSession?.accessToken, equals('access_only_token_abc'));
      client.dispose();
    });

    test('Revoked or invalid refresh token in cookie does not authenticate and returns false', () async {
      HubClient.sharedService.dispose();
      HubClient.sharedService = HubApiService(baseUrl: HubClient.baseUrl);

      final client = SupabaseClient(
        'https://rweehbzsflhhtwjrjnvy.supabase.co',
        'dummy_anon_key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      final stubReader = StubCookieReader();
      // Cookie has invalid refresh token
      stubReader.stubCookie = 'sb-access-token=stale_token; sb-refresh-token=revoked_refresh_token_123';

      final authService = SsoAuthService(reader: stubReader, supabaseClient: client);
      final result = await authService.hydrateFromCookie();

      // Hydration fails because setSession fails on invalid refresh token
      expect(result, isFalse);
      expect(authService.isAuthenticated, isFalse);
      expect(HubClient.sharedService.accessToken, isNull);
      client.dispose();
    });

    test('Preserves existing valid managed session when access-only cookie belongs to the same user', () async {
      HubClient.sharedService.dispose();
      HubClient.sharedService = HubApiService(baseUrl: HubClient.baseUrl);

      final client = SupabaseClient(
        'https://rweehbzsflhhtwjrjnvy.supabase.co',
        'dummy_anon_key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );

      // 1. Establish an existing managed session with a valid refresh token
      final managedSessionJson = jsonEncode({
        'access_token': 'saved_managed_access_token',
        'refresh_token': 'saved_managed_refresh_token',
        'token_type': 'bearer',
        'user': {
          'id': 'pilot_same_user_1',
          'app_metadata': {},
          'user_metadata': {},
          'aud': 'authenticated',
          'created_at': '2026-01-01T00:00:00Z',
        },
      });
      await client.auth.recoverSession(managedSessionJson);
      expect(client.auth.currentSession?.refreshToken, equals('saved_managed_refresh_token'));

      // 2. Hydrate an access-only cookie for the SAME user (e.g. sb-access-token without refresh token)
      final stubReader = StubCookieReader();
      stubReader.stubCookie = 'sb-access-token=new_cookie_access_jwt; user_id=pilot_same_user_1';

      final authService = SsoAuthService(reader: stubReader, supabaseClient: client);
      final result = await authService.hydrateFromCookie();

      expect(result, isTrue);
      expect(authService.isAuthenticated, isTrue);
      // The managed session with its refresh token is preserved!
      expect(client.auth.currentSession?.refreshToken, equals('saved_managed_refresh_token'));
      expect(HubClient.sharedService.accessToken, equals('saved_managed_access_token'));
      expect(HubClient.sharedService.refreshToken, equals('saved_managed_refresh_token'));
      expect(HubClient.sharedService.userId, equals('pilot_same_user_1'));
      client.dispose();
    });

    test('Account switch: access-only cookie for a different user does not inherit prior refresh token', () async {
      HubClient.sharedService.dispose();
      HubClient.sharedService = HubApiService(baseUrl: HubClient.baseUrl);

      final client = SupabaseClient(
        'https://rweehbzsflhhtwjrjnvy.supabase.co',
        'dummy_anon_key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );

      // 1. Prior user session with refresh token
      final priorSessionJson = jsonEncode({
        'access_token': 'user1_access_token',
        'refresh_token': 'user1_refresh_token',
        'token_type': 'bearer',
        'user': {
          'id': 'user_1_id',
          'app_metadata': {},
          'user_metadata': {},
          'aud': 'authenticated',
          'created_at': '2026-01-01T00:00:00Z',
        },
      });
      await client.auth.recoverSession(priorSessionJson);

      // 2. Cookie for a DIFFERENT user (user_2_id) arrives with access token only
      final stubReader = StubCookieReader();
      stubReader.stubCookie = 'sb-access-token=user2_access_token; user_id=user_2_id';

      final authService = SsoAuthService(reader: stubReader, supabaseClient: client);
      final result = await authService.hydrateFromCookie();

      expect(result, isTrue);
      // User 2 is active, and User 1's refresh token was NOT transferred
      expect(client.auth.currentSession?.user.id, equals('user_2_id'));
      expect(client.auth.currentSession?.accessToken, equals('user2_access_token'));
      expect(client.auth.currentSession?.refreshToken, isNull);
      expect(HubClient.sharedService.userId, equals('user_2_id'));
      expect(HubClient.sharedService.accessToken, equals('user2_access_token'));
      expect(HubClient.sharedService.refreshToken, isNull);
      client.dispose();
    });
  });

  group('PR-12: NativeCookieReader & Navigation Adapter', () {
    test('NativeCookieReader getCookieString returns empty and getCurrentOrigin returns default origin', () {
      final nativeReader = NativeCookieReader();
      expect(nativeReader.getCookieString(), isEmpty);
      expect(nativeReader.getCurrentOrigin(), equals('https://dartup.sunshade.icu'));
    });

    test('NativeCookieReader redirectTo invokes launcher handler with valid URI', () {
      Uri? launchedUri;
      final nativeReader = NativeCookieReader(launcher: (uri) async {
        launchedUri = uri;
        return true;
      });

      nativeReader.redirectTo('https://hub.sunshade.icu/login?redirectTo=app');
      expect(launchedUri, isNotNull);
      expect(launchedUri.toString(), equals('https://hub.sunshade.icu/login?redirectTo=app'));
    });

    test('NativeCookieReader openNewTab invokes launcher handler with valid URI', () {
      Uri? openedUri;
      final nativeReader = NativeCookieReader(launcher: (uri) async {
        openedUri = uri;
        return true;
      });

      nativeReader.openNewTab('https://sunshade.icu/eula');
      expect(openedUri, isNotNull);
      expect(openedUri.toString(), equals('https://sunshade.icu/eula'));
    });
  });
}
