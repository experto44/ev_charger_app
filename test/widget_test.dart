import 'package:flutter_test/flutter_test.dart';
import 'package:ev_charger_app/main.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const EVChargerApp());
    // Just verify the app builds without crashing
    expect(find.byType(EVChargerApp), findsOneWidget);
  });
}
