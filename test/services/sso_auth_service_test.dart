import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sd_client/hub/hub_client.dart';
import 'package:sd_client/hub/auth_entry_gate.dart';
import 'package:sd_client/services/sso_auth_service.dart';
import 'package:sd_client/services/cookie_reader/cookie_reader_stub.dart';

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

      authService.loginViaHub();
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
  });
}
