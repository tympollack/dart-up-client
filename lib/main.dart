import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flame/game.dart';
import 'package:sd_client/core/main_mvp.dart';
import 'package:sd_client/hub/hub_client.dart';
import 'package:sd_client/hub/auth_entry_gate.dart';
import 'package:sd_client/services/sso_auth_service.dart';
import 'package:sd_client/services/telemetry/telemetry_dispatch_hook.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1. Initialize Supabase if configured via --dart-define
  await SsoAuthService.initializeSupabase();

  // 2. Initialize token from URL if redirected from Hub SSO
  HubClient.initializeFromUrl(Uri.base);

  // 3. Inspect document.cookie via package:web for active .sunshade.icu session
  final authService = SsoAuthService();
  await authService.hydrateFromCookie();

  // 4. Flush any pending offline-cached telemetry recaps on app launch
  final startupTelemetryHook = TelemetryDispatchHook(
    baseUrl: HubClient.sharedService.baseUrl,
    accessTokenProvider: () => HubClient.sharedService.accessToken,
  );
  unawaited(startupTelemetryHook.flushPendingQueue());

  runApp(
    MaterialApp(
      title: 'Dart Up!',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0C0A09),
        primaryColor: const Color(0xFFF97316),
      ),
      home: AuthEntryGate(
        authService: authService,
        child: GameWidget(
          game: StarDartMVP(),
          overlayBuilderMap: {
            'EndMatch': (BuildContext context, StarDartMVP game) {
              return Align(
                alignment: Alignment.topRight,
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: ElevatedButton(
                    onPressed: () {
                      game.endMatch();
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.redAccent,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 12,
                      ),
                    ),
                    child: const Text(
                      'End Match',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              );
            },
          },
          initialActiveOverlays: const ['EndMatch'],
        ),
      ),
    ),
  );
}
