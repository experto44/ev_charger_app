import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:ev_charger_app/l10n/app_strings.dart';
import 'package:ev_charger_app/main.dart';
import 'package:ev_charger_app/screens/paywall_screen.dart';
import 'package:ev_charger_app/services/purchase_service.dart';

ProductDetails _product(String id, String price, double raw) => ProductDetails(
      id: id,
      title: id,
      description: id,
      price: price,
      rawPrice: raw,
      currencyCode: 'USD',
    );

Future<void> _pumpPaywall(WidgetTester tester) async {
  await tester.pumpWidget(MaterialApp(
    theme: buildAppTheme(),
    home: const PaywallScreen(),
  ));
  await tester.pump();
}

void main() {
  setUp(() {
    AppStrings.notifier.value = false; // English, so titles are stable
    PurchaseService.I.storeAvailable.value = true;
    PurchaseService.I.loadingProducts.value = false;
    PurchaseService.I.isPremium.value = false;
  });

  tearDown(() => PurchaseService.I.products = const []);

  testWidgets('a plan the store did not return is not offered',
      (WidgetTester tester) async {
    // Exactly the production state on iOS: App Store Connect has the monthly
    // subscription but no `geocharge_premium_yearly`, so the query comes back
    // with monthly only. The yearly card used to render anyway, showing the
    // Android GEL fallback price over a tap that could never open a purchase.
    PurchaseService.I.products = [
      _product(PurchaseService.monthlyId, 'USD 0.39', 0.39),
    ];

    await _pumpPaywall(tester);

    expect(find.text('Monthly'), findsOneWidget);
    expect(find.text('USD 0.39'), findsOneWidget);
    expect(find.text('Yearly'), findsNothing,
        reason: 'a plan the store cannot sell must not be advertised');
    expect(find.text('9.99 ₾'), findsNothing,
        reason: 'the hardcoded fallback price must never reach the screen');
  });

  testWidgets('both plans are offered when the store returns both',
      (WidgetTester tester) async {
    PurchaseService.I.products = [
      _product(PurchaseService.monthlyId, 'USD 0.39', 0.39),
      _product(PurchaseService.yearlyId, 'USD 3.99', 3.99),
    ];

    await _pumpPaywall(tester);

    expect(find.text('Monthly'), findsOneWidget);
    expect(find.text('Yearly'), findsOneWidget);
    expect(find.text('USD 3.99'), findsOneWidget);
  });
}
