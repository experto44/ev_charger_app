import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ev_charger_app/main.dart';

void main() {
  test('the colour-scheme trap behind the invisible SnackBar is still latent',
      () {
    final ThemeData theme = buildAppTheme();
    // `ColorScheme.dark()` leaves onInverseSurface unset and its getter falls
    // back to `surface` — the very colour the paywall/profile/route SnackBars
    // pass as `backgroundColor`. Material 3 takes the SnackBar content colour
    // from onInverseSurface, so without an explicit snackBarTheme the text and
    // its background match to the byte and the bar renders empty.
    expect(theme.colorScheme.onInverseSurface, theme.colorScheme.surface);
  });

  testWidgets('a paywall-style SnackBar paints text readable against its own '
      'background', (WidgetTester tester) async {
    final ThemeData theme = buildAppTheme();
    final messengerKey = GlobalKey<ScaffoldMessengerState>();
    await tester.pumpWidget(MaterialApp(
      theme: theme,
      scaffoldMessengerKey: messengerKey,
      home: const Scaffold(body: SizedBox.shrink()),
    ));

    // Exactly what PaywallScreen._snack builds.
    messengerKey.currentState!.showSnackBar(SnackBar(
      content: const Text('store unavailable'),
      backgroundColor: theme.colorScheme.surface,
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 750));

    final Finder content = find.text('store unavailable');
    expect(content, findsOneWidget);
    final Color? painted =
        DefaultTextStyle.of(tester.element(content)).style.color;
    expect(painted, isNotNull);
    expect(painted, isNot(theme.colorScheme.surface),
        reason: 'SnackBar text must not be painted in its own background colour');
  });
}
