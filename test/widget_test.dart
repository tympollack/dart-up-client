// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flame/game.dart';

import 'package:sd_client/core/main_mvp.dart';

void main() {
  testWidgets('Game loads smoke test', (WidgetTester tester) async {
    // Build our game with realtime polling disabled for headless test and trigger a frame.
    final game = StarDartMVP(enableRealtimePolling: false);
    await tester.pumpWidget(GameWidget(game: game));

    // Verify that the game loaded without errors.
    expect(find.byType(GameWidget<StarDartMVP>), findsOneWidget);

    // Unmount widget and teardown cleanly
    await tester.pumpWidget(const SizedBox());
  });
}
