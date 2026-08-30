import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ev_charger_app/l10n/app_strings.dart';
import 'package:ev_charger_app/screens/expenses_screen.dart';
import 'package:ev_charger_app/services/expenses_service.dart';

/// Drives the expenses screen the way a driver does: add a charge, watch the
/// totals move, edit it, delete it. Signed out and with no Firebase app, so
/// everything runs against the local cache.

/// A tall phone-sized surface: the default 800x600 test window cuts the record
/// list off below the fold, and a ListView never builds what it cannot show.
void _useTallPhone(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 3200);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

Future<void> _openScreen(WidgetTester tester) async {
  _useTallPhone(tester);
  await tester.pumpWidget(const MaterialApp(home: ExpensesScreen()));
  await tester.pumpAndSettle();
}

/// FAB → "At a paid charger" / "At home".
Future<void> _tapAdd(WidgetTester tester, String option) async {
  await tester.tap(find.byType(FloatingActionButton));
  await tester.pumpAndSettle();
  await tester.tap(find.text(option));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    AppStrings.notifier.value = false; // English, so the finders are stable
    // Reset the singleton's in-memory state between tests.
    await ExpensesService.I.load(sync: false);
    await ExpensesService.I.saveSettings(const ExpenseSettings());
  });

  testWidgets('an empty log explains what the plus button is for',
      (tester) async {
    await _openScreen(tester);
    expect(find.text('Nothing recorded yet'), findsOneWidget);
    expect(find.text('0.00 ₾'), findsWidgets); // this month, all time
  });

  testWidgets('a paid charge is the amount and nothing else', (tester) async {
    await _openScreen(tester);
    await _tapAdd(tester, 'At a paid charger');

    // The paid sheet asks for one number only.
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('From'), findsNothing);

    await tester.enterText(find.byType(TextField), '24.50');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('Paid charge'), findsOneWidget);
    expect(find.text('24.50 ₾'), findsWidgets);
    expect(ExpensesService.I.entries.single.amount, 24.5);
    expect(ExpensesService.I.entries.single.isHome, isFalse);
  });

  testWidgets('a paid charge refuses to save without an amount',
      (tester) async {
    await _openScreen(tester);
    await _tapAdd(tester, 'At a paid charger');

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('Enter an amount'), findsOneWidget);
    expect(ExpensesService.I.entries, isEmpty);
  });

  testWidgets('a home charge needs the battery and tariff first',
      (tester) async {
    await _openScreen(tester);
    await _tapAdd(tester, 'At home');

    expect(
      find.text('Fill in your battery capacity and electricity tariff first.'),
      findsOneWidget,
    );
    expect(find.text('Save'), findsNothing); // nothing to save yet

    // The prompt leads straight to the settings screen.
    await tester.tap(find.text('Fill them in'));
    await tester.pumpAndSettle();
    expect(find.text('Battery capacity'), findsOneWidget);
    expect(find.text('Electricity tariff'), findsOneWidget);
    expect(find.text('Charging loss'), findsOneWidget);
  });

  testWidgets('the settings screen refuses a zero battery or tariff',
      (tester) async {
    _useTallPhone(tester);
    await tester.pumpWidget(const MaterialApp(home: ExpenseSettingsScreen()));
    await tester.pumpAndSettle();

    // Loss is pre-filled with the agreed default.
    expect(find.text('10'), findsOneWidget);

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Capacity and tariff must be above zero.'), findsOneWidget);
    expect(ExpensesService.I.settings.isComplete, isFalse);
  });

  testWidgets('filling the settings in from the sheet, then recording a charge',
      (tester) async {
    await _openScreen(tester);
    await _tapAdd(tester, 'At home');

    // Straight into the settings, and straight back out again.
    await tester.tap(find.text('Fill them in'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), '60');
    await tester.enterText(find.byType(TextField).at(1), '0.29');
    await tester.tap(find.text('Save'));
    await tester.pump(const Duration(milliseconds: 900)); // the "Saved!" beat
    await tester.pumpAndSettle();

    expect(ExpensesService.I.settings.batteryKwh, 60);
    expect(ExpensesService.I.settings.tariff, 0.29);
    expect(ExpensesService.I.settings.lossPercent, 10);

    // The sheet has picked the new settings up and now asks for percentages.
    expect(find.text('From'), findsOneWidget);
    await tester.enterText(find.byType(TextField).at(0), '20');
    await tester.enterText(find.byType(TextField).at(1), '80');
    await tester.pumpAndSettle();
    expect(find.text('11.60 ₾'), findsOneWidget);
  });

  testWidgets('a home charge is costed from the percentages', (tester) async {
    await ExpensesService.I.saveSettings(
        const ExpenseSettings(batteryKwh: 60, tariff: 0.29, lossPercent: 10));
    await _openScreen(tester);
    await _tapAdd(tester, 'At home');

    await tester.enterText(find.byType(TextField).at(0), '20');
    await tester.enterText(find.byType(TextField).at(1), '80');
    await tester.pumpAndSettle();

    // The sheet shows the cost before it is saved.
    expect(find.text('40.0 kWh'), findsOneWidget);
    expect(find.text('11.60 ₾'), findsOneWidget);

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('Home charge'), findsOneWidget);
    expect(find.textContaining('20% → 80%'), findsOneWidget);
    expect(find.text('11.60 ₾'), findsWidgets);

    final saved = ExpensesService.I.entries.single;
    expect(saved.kwh, closeTo(40, 0.001));
    expect(saved.batteryKwh, 60);
    expect(saved.tariff, 0.29);
    expect(saved.lossPercent, 10);
  });

  testWidgets('backwards percentages are rejected', (tester) async {
    await ExpensesService.I.saveSettings(
        const ExpenseSettings(batteryKwh: 60, tariff: 0.29));
    await _openScreen(tester);
    await _tapAdd(tester, 'At home');

    await tester.enterText(find.byType(TextField).at(0), '80');
    await tester.enterText(find.byType(TextField).at(1), '20');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Percentages run from 0 to 100'),
      findsOneWidget,
    );
    expect(ExpensesService.I.entries, isEmpty);
  });

  testWidgets('changing the tariff never rewrites an old record',
      (tester) async {
    await ExpensesService.I.saveSettings(
        const ExpenseSettings(batteryKwh: 60, tariff: 0.29, lossPercent: 10));
    await _openScreen(tester);
    await _tapAdd(tester, 'At home');
    await tester.enterText(find.byType(TextField).at(0), '20');
    await tester.enterText(find.byType(TextField).at(1), '80');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    // A new car and a dearer tariff: the charge already recorded still cost
    // what it cost.
    await ExpensesService.I.saveSettings(
        const ExpenseSettings(batteryKwh: 100, tariff: 0.50, lossPercent: 10));
    await tester.pumpAndSettle();

    expect(find.text('11.60 ₾'), findsWidgets);
    expect(ExpensesService.I.entries.single.amount, closeTo(11.6, 0.001));
    expect(ExpensesService.I.entries.single.batteryKwh, 60);
  });

  testWidgets('a record can be edited and deleted', (tester) async {
    await _openScreen(tester);
    await _tapAdd(tester, 'At a paid charger');
    await tester.enterText(find.byType(TextField), '10');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('10.00 ₾'), findsWidgets);

    // Tapping the row reopens it for editing, keeping the same record.
    await tester.tap(find.text('Paid charge'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '15.75');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(ExpensesService.I.entries.length, 1);
    expect(ExpensesService.I.entries.single.amount, 15.75);
    expect(find.text('15.75 ₾'), findsWidgets);

    // Delete, with a confirmation in between.
    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Delete this record?'), findsOneWidget);
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(ExpensesService.I.entries, isEmpty);
    expect(find.text('Nothing recorded yet'), findsOneWidget);
  });

  testWidgets('the totals split home from paid', (tester) async {
    await ExpensesService.I.saveSettings(
        const ExpenseSettings(batteryKwh: 60, tariff: 0.29, lossPercent: 10));
    await _openScreen(tester);

    await _tapAdd(tester, 'At a paid charger');
    await tester.enterText(find.byType(TextField), '28.40');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    await _tapAdd(tester, 'At home');
    await tester.enterText(find.byType(TextField).at(0), '20');
    await tester.enterText(find.byType(TextField).at(1), '80');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(ExpensesService.I.totalAll, closeTo(40.0, 0.001));
    expect(ExpensesService.I.totalForKind(ChargeKind.home), closeTo(11.6, 0.001));
    expect(ExpensesService.I.totalForKind(ChargeKind.paid), closeTo(28.4, 0.001));

    // 11.60 of 40.00 is 29%, the paid share the remaining 71%.
    expect(find.text('29%'), findsOneWidget);
    expect(find.text('71%'), findsOneWidget);
    expect(find.text('40.00 ₾'), findsWidgets);
  });

  testWidgets('records survive leaving and reopening the screen',
      (tester) async {
    await _openScreen(tester);
    await _tapAdd(tester, 'At a paid charger');
    await tester.enterText(find.byType(TextField), '9.90');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    // A fresh screen with a fresh service state, reading the cache back.
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pumpAndSettle();
    await ExpensesService.I.load(sync: false);
    await _openScreen(tester);

    expect(find.text('9.90 ₾'), findsWidgets);
    expect(ExpensesService.I.entries.single.amount, 9.9);
  });

  testWidgets('editing a home record reprices it at its OWN tariff',
      (tester) async {
    await ExpensesService.I.saveSettings(
        const ExpenseSettings(batteryKwh: 60, tariff: 0.29, lossPercent: 10));
    await _openScreen(tester);
    await _tapAdd(tester, 'At home');
    await tester.enterText(find.byType(TextField).at(0), '20');
    await tester.enterText(find.byType(TextField).at(1), '80');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    // Bigger car, dearer electricity — then the driver fixes a typo in the old
    // record's percentages.
    await ExpensesService.I.saveSettings(
        const ExpenseSettings(batteryKwh: 100, tariff: 0.50, lossPercent: 10));
    await tester.tap(find.text('Home charge'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(1), '70');
    await tester.pumpAndSettle();

    // 60 kWh × 50% ÷ 0.9 × 0.29 — the settings the charge was recorded with.
    expect(find.text('9.67 ₾'), findsOneWidget);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final saved = ExpensesService.I.entries.single;
    expect(saved.amount, closeTo(9.6667, 0.001));
    expect(saved.batteryKwh, 60);
    expect(saved.tariff, 0.29);
  });

  testWidgets('an amount left mid-typing as "24." still saves', (tester) async {
    await _openScreen(tester);
    await _tapAdd(tester, 'At a paid charger');
    await tester.enterText(find.byType(TextField), '24.');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(ExpensesService.I.entries.single.amount, 24);
    expect(find.text('24.00 ₾'), findsWidgets);
  });

  testWidgets('the Georgian layout fits a narrow phone', (tester) async {
    // Georgian words are longer than the English ones and the phone is only
    // 360dp wide: this is where a row would overflow if it were going to.
    GoogleFonts.config.allowRuntimeFetching = false;
    AppStrings.notifier.value = true;
    addTearDown(() => AppStrings.notifier.value = false);

    await ExpensesService.I.saveSettings(
        const ExpenseSettings(batteryKwh: 60, tariff: 0.29, lossPercent: 10));
    await ExpensesService.I.upsert(ExpenseEntry(
      id: ExpensesService.newId(),
      date: DateTime.now(),
      kind: ChargeKind.paid,
      amount: 128.40,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    ));
    await ExpensesService.I.upsert(ExpenseEntry(
      id: ExpensesService.newId(),
      date: DateTime.now(),
      kind: ChargeKind.home,
      amount: 11.6,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
      fromPercent: 20,
      toPercent: 80,
      batteryKwh: 60,
      tariff: 0.29,
      lossPercent: 10,
      kwh: 40,
    ));

    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0; // 360 x 800 logical
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(const MaterialApp(home: ExpensesScreen()));
    await tester.pumpAndSettle();

    expect(find.text('ხარჯები'), findsWidgets);
    expect(find.text('ამ თვეში'), findsOneWidget);
    expect(find.text('სახლში'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // The add sheet and both forms, still in Georgian.
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    expect(find.text('როგორ დატენე?'), findsOneWidget);
    await tester.tap(find.text('სახლის დამტენზე'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), '20');
    await tester.enterText(find.byType(TextField).at(1), '80');
    await tester.pumpAndSettle();
    // "40.0 kWh" on its own belongs to the live preview (the record row shows it
    // inside a longer subtitle), so this proves the sheet computed the charge.
    expect(find.text('40.0 kWh'), findsOneWidget);
    expect(find.text('11.60 ₾'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
