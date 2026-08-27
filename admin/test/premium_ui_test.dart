// The manual-activation dialog: what the admin sees before confirming, and
// what the panel gets back. Kept to the dialog (not the whole dashboard) so it
// runs on the plain VM — the dashboard drags in package:web through the Excel
// export and the finance config, which only compiles for the browser.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geocharge_admin/models/app_user.dart';
import 'package:geocharge_admin/services/premium_terms.dart';
import 'package:geocharge_admin/widgets/grant_premium_dialog.dart';
import 'package:intl/intl.dart';

final DateFormat _dfmt = DateFormat('yyyy-MM-dd');

AppUser _user({DateTime? until}) {
  return AppUser(
    uid: 'u1',
    name: 'Nino Beridze',
    email: 'nino@example.com',
    phone: '+995500000000',
    isPremium: until != null,
    platform: 'android',
    createdAt: DateTime.now().subtract(const Duration(days: 40)),
    lastSeenAt: DateTime.now(),
    openCount: 10,
    premiumUntil: until,
    premiumSource: until == null ? '' : 'manual',
    premiumPlan: until == null ? '' : 'monthly',
  );
}

/// Pumps a host widget that opens the dialog and captures its result.
Future<PremiumGrant?> _open(WidgetTester tester, AppUser user) async {
  PremiumGrant? result;
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () async {
              result = await GrantPremiumDialog.show(context, user);
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return result;
}

void main() {
  testWidgets('previews the stacked expiry for a running subscription',
      (tester) async {
    final user = _user(until: DateTime.now().add(const Duration(days: 10)));
    await _open(tester, user);

    expect(find.textContaining('10 days left'), findsOneWidget);
    expect(
        find.text(
            'Premium until ${_dfmt.format(PremiumTerms.extend(user.premiumUntil, PremiumTerms.monthly))}'),
        findsOneWidget);
    expect(find.text('Added on top of the remaining time.'), findsOneWidget);
  });

  testWidgets('a free user starts from today and is told ads stop now',
      (tester) async {
    final user = _user();
    await _open(tester, user);

    expect(find.textContaining('free, ad-supported'), findsOneWidget);
    expect(
        find.text(
            'Premium until ${_dfmt.format(PremiumTerms.extend(null, PremiumTerms.monthly))}'),
        findsOneWidget);
    expect(find.text('Ads stop immediately and come back on this date.'),
        findsOneWidget);
  });

  testWidgets('switching to the yearly term follows its list price',
      (tester) async {
    await _open(tester, _user());

    expect(find.widgetWithText(TextField, '1.00'), findsOneWidget);
    await tester.tap(find.text('1 year'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, '9.99'), findsOneWidget);
  });

  testWidgets('a hand-typed amount survives a plan change', (tester) async {
    await _open(tester, _user());

    await tester.enterText(find.byType(TextField).first, '25');
    await tester.tap(find.text('1 year'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, '25'), findsOneWidget);
  });

  testWidgets('confirming returns the term, amount and note', (tester) async {
    PremiumGrant? captured;
    final user = _user();
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async {
                captured = await GrantPremiumDialog.show(context, user);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('1 year'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'BOG #4471');
    await tester.tap(find.widgetWithText(FilledButton, 'Activate'));
    await tester.pumpAndSettle();

    expect(captured, isNotNull);
    expect(captured!.plan, PremiumTerms.yearly);
    expect(captured!.amountGel, 9.99);
    expect(captured!.note, 'BOG #4471');
  });

  testWidgets('cancelling grants nothing', (tester) async {
    PremiumGrant? captured;
    final user = _user();
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async {
                captured = await GrantPremiumDialog.show(context, user);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(captured, isNull);
  });
}
