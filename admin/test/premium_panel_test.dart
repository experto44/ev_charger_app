// Renders the Premium tab for real. A build-time crash here (a stray flex
// widget inside a Wrap, a bad DataTable row) shows up as Flutter's grey error
// box in a release build and hides the whole register — this test is what
// catches that before it ships.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geocharge_admin/models/app_user.dart';
import 'package:geocharge_admin/models/purchase.dart';
import 'package:geocharge_admin/screens/dashboard_screen.dart';
import 'package:geocharge_admin/services/premium_terms.dart';
import 'package:geocharge_admin/theme.dart';
import 'package:geocharge_admin/widgets/kpi_card.dart';

AppUser _user({
  required String uid,
  required int daysLeft,
  String plan = 'monthly',
}) {
  return AppUser(
    uid: uid,
    name: 'User $uid',
    email: '$uid@example.com',
    phone: '+995500000000',
    isPremium: daysLeft > 0,
    platform: 'android',
    createdAt: DateTime.now().subtract(const Duration(days: 40)),
    lastSeenAt: DateTime.now(),
    openCount: 10,
    premiumUntil: DateTime.now().add(Duration(days: daysLeft)),
    premiumSource: 'manual',
    premiumPlan: plan,
    premiumGrantedBy: 'admin@geocharge.ge',
    premiumNote: 'BOG #$uid',
  );
}

Widget _dashboard(List<AppUser> users, {SectionTab tab = SectionTab.premium}) {
  return MaterialApp(
    theme: buildAdminTheme(),
    home: DashboardView(
      email: 'admin@geocharge.ge',
      users: users,
      purchases: const <Purchase>[],
      initialSection: tab,
      onSignOut: () {},
      onManageAdmins: () {},
      onGrantPremium: (u, g) async =>
          PremiumTerms.extend(u.premiumUntil, g.plan),
      onRevokePremium: (_) async {},
    ),
  );
}

void main() {
  _storeRevokeTests();
  // Desktop-sized viewport: the branch that renders the data table.
  Future<void> pumpDesktop(WidgetTester tester, Widget app) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app);
    await tester.pumpAndSettle();
  }

  testWidgets('Premium tab renders the register without a build error',
      (tester) async {
    await pumpDesktop(
        tester, _dashboard([_user(uid: 'a', daysLeft: 26)]));

    expect(tester.takeException(), isNull);
    // The grey error box replaces the subtree, so asserting on real content is
    // what proves the panel actually built.
    expect(find.text('Activate premium'), findsOneWidget);
    expect(find.text('User a'), findsOneWidget);
    expect(find.text('26 days'), findsOneWidget);
    expect(find.text('BOG #a'), findsOneWidget);
  });

  testWidgets('the KPI strip counts active, expiring and expired grants',
      (tester) async {
    await pumpDesktop(
      tester,
      _dashboard([
        _user(uid: 'a', daysLeft: 26),
        _user(uid: 'b', daysLeft: 3),
        _user(uid: 'c', daysLeft: -5),
      ]),
    );

    expect(tester.takeException(), isNull);
    // Read the tiles themselves — "Expired" also appears as a status chip and
    // as a time-left cell, so matching on loose text would prove nothing.
    String kpi(String label) => tester
        .widget<KpiCard>(find.byWidgetPredicate(
            (w) => w is KpiCard && w.label == label))
        .value;

    expect(kpi('Active manual'), '2'); // 26 days + 3 days
    expect(kpi('Expiring ≤ 7 days'), '1'); // just the 3-day one
    expect(kpi('Expired'), '1');
  });

  testWidgets('empty state explains what the tab is for', (tester) async {
    await pumpDesktop(tester, _dashboard(const <AppUser>[]));

    expect(tester.takeException(), isNull);
    expect(find.text('No manual activations yet.'), findsOneWidget);
  });

  testWidgets('mobile layout renders the grants as cards', (tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_dashboard([_user(uid: 'a', daysLeft: 26)]));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('User a'), findsOneWidget);
    expect(find.text('26 days'), findsOneWidget);
  });

  testWidgets('the Users tab still builds with the new premium column',
      (tester) async {
    await pumpDesktop(
        tester, _dashboard([_user(uid: 'a', daysLeft: 26)],
            tab: SectionTab.users));

    expect(tester.takeException(), isNull);
    expect(find.text('PREMIUM'), findsOneWidget);
    expect(find.text('Premium · manual'), findsWidgets);
  });
}

/// A user whose premium came from the STORE, not from an admin grant: no
/// `premiumSource`, no expiry. This is the shape the mobile app writes — and the
/// shape a wrongly-granted flag has, which is why the panel must be able to end
/// it.
AppUser _storeUser(String uid) => AppUser(
      uid: uid,
      name: 'User $uid',
      email: '$uid@example.com',
      phone: '+995500000000',
      isPremium: true,
      platform: 'ios',
      createdAt: DateTime.now().subtract(const Duration(days: 3)),
      lastSeenAt: DateTime.now(),
      openCount: 2,
    );

void _storeRevokeTests() {
  testWidgets('store-sourced premium can be ended from the panel',
      (WidgetTester tester) async {
    // Wide enough for the whole Users table: the actions sit in the last column
    // and would otherwise be off-screen for the tap.
    tester.view.physicalSize = const Size(2400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    AppUser? revoked;
    await tester.pumpWidget(MaterialApp(
      theme: buildAdminTheme(),
      home: DashboardView(
        email: 'admin@geocharge.ge',
        users: [_storeUser('leaked')],
        purchases: const <Purchase>[],
        // Users tab: the Premium tab is a register of manual grants and lists
        // only users with a premiumUntil, which a store subscription never has.
        initialSection: SectionTab.users,
        onSignOut: () {},
        onManageAdmins: () {},
        onGrantPremium: (u, g) async =>
            PremiumTerms.extend(u.premiumUntil, g.plan),
        onRevokePremium: (u) async => revoked = u,
      ),
    ));
    await tester.pumpAndSettle();

    // Before this action existed, a store-sourced isPremium flag — including one
    // the app had written by mistake — could not be cleared from the panel at all.
    final endNow = find.byTooltip('End premium now');
    expect(endNow, findsOneWidget,
        reason: 'a live premium must always be endable from the panel');

    await tester.tap(endNow);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'End now'));
    await tester.pumpAndSettle();

    expect(revoked?.uid, 'leaked');
  });
}
