// Basic smoke test for the Rackery app.

import 'package:flutter_test/flutter_test.dart';

import 'package:rackery/main.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    // Build the app and trigger a frame.
    await tester.pumpWidget(const MyApp());

    // Verify the app renders without throwing.
    expect(find.byType(MyApp), findsOneWidget);
  });
}
