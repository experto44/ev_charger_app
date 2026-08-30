import 'package:cloud_firestore/cloud_firestore.dart' show Timestamp;
import 'package:flutter_test/flutter_test.dart';

import 'package:ev_charger_app/services/expenses_service.dart';

/// The expenses log's arithmetic and its two serialisation shapes. The money a
/// driver sees is computed here, so the numbers are pinned down by hand:
/// a 60 kWh battery taken from 20% to 80% puts 36 kWh into the cells, and with
/// a tenth of the metered energy lost on the way, 40 kWh comes off the meter.
void main() {
  group('home charge maths', () {
    const s = ExpenseSettings(batteryKwh: 60, tariff: 0.29, lossPercent: 10);

    test('loss is added on top of what reaches the battery', () {
      expect(s.kwhFor(20, 80), closeTo(40.0, 0.0001));
      expect(s.costFor(20, 80), closeTo(11.60, 0.0001));
    });

    test('a lossless setting costs exactly battery × Δ% × tariff', () {
      const perfect = ExpenseSettings(
          batteryKwh: 60, tariff: 0.29, lossPercent: 0);
      expect(perfect.kwhFor(20, 80), closeTo(36.0, 0.0001));
      expect(perfect.costFor(20, 80), closeTo(10.44, 0.0001));
    });

    test('a full charge from empty is the whole battery plus the loss', () {
      expect(s.kwhFor(0, 100), closeTo(66.6667, 0.001));
    });

    test('an unchanged or backwards range has no cost', () {
      expect(s.kwhFor(80, 80), isNull);
      expect(s.costFor(80, 20), isNull);
    });

    test('nothing is computed until the battery and tariff are known', () {
      const empty = ExpenseSettings();
      expect(empty.isComplete, isFalse);
      expect(empty.costFor(20, 80), isNull);
      expect(const ExpenseSettings(batteryKwh: 60).costFor(20, 80), isNull);
      expect(const ExpenseSettings(tariff: 0.29).costFor(20, 80), isNull);
    });

    test('the loss is capped at half, so a typo cannot divide by zero', () {
      const daft = ExpenseSettings(
          batteryKwh: 60, tariff: 0.29, lossPercent: 100);
      final kwh = daft.kwhFor(0, 100);
      expect(kwh, isNotNull);
      expect(kwh, closeTo(120.0, 0.0001)); // clamped to a 50% loss
    });

    test('the default loss is the 10% agreed for AC charging', () {
      expect(ExpenseSettings.kDefaultLossPercent, 10);
      expect(const ExpenseSettings(batteryKwh: 60, tariff: 0.29)
          .kwhFor(20, 80), closeTo(40.0, 0.0001));
    });
  });

  group('entry serialisation', () {
    final home = ExpenseEntry(
      id: 'abc',
      date: DateTime(2026, 8, 30),
      kind: ChargeKind.home,
      amount: 11.6,
      updatedAt: 1756500000000,
      fromPercent: 20,
      toPercent: 80,
      batteryKwh: 60,
      tariff: 0.29,
      lossPercent: 10,
      kwh: 40,
      dirty: true,
    );

    test('the local cache round-trips every field, dirty flag included', () {
      final back = ExpenseEntry.fromJson(home.toJson())!;
      expect(back.id, 'abc');
      expect(back.date, DateTime(2026, 8, 30));
      expect(back.kind, ChargeKind.home);
      expect(back.amount, 11.6);
      expect(back.updatedAt, 1756500000000);
      expect(back.fromPercent, 20);
      expect(back.toPercent, 80);
      expect(back.batteryKwh, 60);
      expect(back.tariff, 0.29);
      expect(back.lossPercent, 10);
      expect(back.kwh, 40);
      expect(back.dirty, isTrue);
    });

    test('the Firestore shape carries the stamps but never the dirty flag', () {
      final map = home.toMap();
      expect(map.containsKey('dirty'), isFalse);
      expect(map['kind'], 'home');
      expect(map['batteryKwh'], 60);
      expect((map['date'] as Timestamp).toDate(), DateTime(2026, 8, 30));

      final back = ExpenseEntry.fromMap('abc', map)!;
      expect(back.dirty, isFalse);
      expect(back.tariff, 0.29);
      expect(back.kwh, 40);
    });

    test('a paid entry carries an amount and nothing else', () {
      final paid = ExpenseEntry(
        id: 'p1',
        date: DateTime(2026, 8, 30),
        kind: ChargeKind.paid,
        amount: 24.5,
        updatedAt: 1756500000000,
      );
      final map = paid.toMap();
      expect(map['kind'], 'paid');
      expect(map.containsKey('fromPercent'), isFalse);
      expect(map.containsKey('kwh'), isFalse);

      final back = ExpenseEntry.fromJson(paid.toJson())!;
      expect(back.isHome, isFalse);
      expect(back.amount, 24.5);
      expect(back.fromPercent, isNull);
    });

    test('junk in the cache is dropped rather than crashing the list', () {
      expect(ExpenseEntry.fromJson(<String, dynamic>{}), isNull);
      expect(ExpenseEntry.fromJson(<String, dynamic>{'id': 'x'}), isNull);
      expect(
        ExpenseEntry.fromMap('x', <String, dynamic>{'amount': 5}),
        isNull,
      );
    });

    test('ids are unique even when two entries are made in the same ms', () {
      final ids = List.generate(500, (_) => ExpensesService.newId());
      expect(ids.toSet().length, 500);
    });
  });

  group('sync planning', () {
    ExpenseEntry entry(String id, {bool dirty = false, int updatedAt = 1000}) =>
        ExpenseEntry(
          id: id,
          date: DateTime(2026, 8, 30),
          kind: ChargeKind.paid,
          amount: 10,
          updatedAt: updatedAt,
          dirty: dirty,
        );

    ExpensesSyncPlan plan({
      List<ExpenseEntry> local = const [],
      Map<String, ExpenseEntry> remote = const {},
      Set<String> pendingDeletes = const {},
      bool serverAnswered = true,
      int fetchedAt = 5000,
    }) =>
        ExpensesService.planSync(
          local: local,
          remote: remote,
          pendingDeletes: pendingDeletes,
          serverAnswered: serverAnswered,
          fetchedAt: fetchedAt,
        );

    test('an entry that has never reached the server is uploaded, not dropped',
        () {
      // The case that bites after signing in: entries recorded signed out are
      // adopted as dirty, and the server has never heard of them.
      final p = plan(local: [entry('a', dirty: true)]);
      expect(p.upload.map((e) => e.id), ['a']);
      expect(p.dropLocally, isEmpty);
      expect(p.adopt, isEmpty);
    });

    test('an entry deleted on another phone is dropped here', () {
      final p = plan(local: [entry('a')]);
      expect(p.dropLocally, ['a']);
      expect(p.upload, isEmpty);
    });

    test('nothing is dropped when the answer came from the offline cache', () {
      final p = plan(local: [entry('a')], serverAnswered: false);
      expect(p.dropLocally, isEmpty);
    });

    test('an entry recorded while the sync was in flight survives it', () {
      // Saved after the read was issued, and already pushed (so no longer
      // dirty): the server's answer simply predates it.
      final p = plan(local: [entry('a', updatedAt: 6000)], fetchedAt: 5000);
      expect(p.dropLocally, isEmpty);
    });

    test('the newer side wins, whichever device it is on', () {
      final newerRemote = entry('a', updatedAt: 2000);
      final fromServer = plan(
        local: [entry('a', updatedAt: 1000, dirty: true)],
        remote: {'a': newerRemote},
      );
      expect(fromServer.adopt.single.updatedAt, 2000);
      expect(fromServer.upload, isEmpty);

      final fromHere = plan(
        local: [entry('a', updatedAt: 3000, dirty: true)],
        remote: {'a': entry('a', updatedAt: 2000)},
      );
      expect(fromHere.upload.single.updatedAt, 3000);
      expect(fromHere.adopt, isEmpty);
    });

    test('an entry only the server has is pulled down', () {
      final p = plan(remote: {'b': entry('b')});
      expect(p.adopt.map((e) => e.id), ['b']);
    });

    test('a deletion still waiting to reach the server is not undone by it',
        () {
      // The delete replay failed this round, so the doc is still on the server.
      // Pulling it back would resurrect what the driver deleted.
      final p = plan(remote: {'b': entry('b')}, pendingDeletes: {'b'});
      expect(p.adopt, isEmpty);
    });

    test('a clean entry both sides agree on is left alone', () {
      final p = plan(local: [entry('a')], remote: {'a': entry('a')});
      expect(p.upload, isEmpty);
      expect(p.adopt, isEmpty);
      expect(p.dropLocally, isEmpty);
    });
  });
}
