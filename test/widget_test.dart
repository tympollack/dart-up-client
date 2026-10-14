// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter_test/flutter_test.dart';
import 'package:flame/game.dart';

import 'package:sd_client/core/main_mvp.dart';

void main() {
  testWidgets('Game loads smoke test', (WidgetTester tester) async {
    // Build our game and trigger a frame.
    await tester.pumpWidget(GameWidget(game: StarDartMVP()));

    // Verify that the game loaded without errors.
    expect(find.byType(GameWidget<StarDartMVP>), findsOneWidget);
  });
}
