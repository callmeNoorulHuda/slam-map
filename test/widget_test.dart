// Basic smoke test for the SLAM app's home screen.
//
// Verifies the app builds and starts in the "not scanning" state
// (Start Scan visible, Export disabled since there's no data yet).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:slam_app/main.dart';

void main() {
  testWidgets('SLAM home screen shows initial state',
      (WidgetTester tester) async {
    await tester.pumpWidget(const SlamApp());

    // Starts idle: "Start Scan" is shown, not "Stop Scan".
    expect(find.text('Start Scan'), findsOneWidget);
    expect(find.text('Stop Scan'), findsNothing);

    // No points captured yet, so the point count reads 0 and the
    // export button (which requires points > 0) is disabled.
    expect(find.textContaining('Map points: 0'), findsOneWidget);

    final exportButton = tester.widget<ElevatedButton>(
      find.widgetWithText(ElevatedButton, 'Export & Share Map (.ply)'),
    );
    expect(exportButton.onPressed, isNull);
  });
}
