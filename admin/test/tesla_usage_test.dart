// Pure aggregation behind the Tesla tab. Runs on the VM:
//   cd admin && flutter test test/tesla_usage_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:geocharge_admin/models/maps_usage.dart';
import 'package:geocharge_admin/models/tesla_session.dart';
import 'package:geocharge_admin/services/maps_limits.dart';
import 'package:geocharge_admin/services/tesla_stats.dart';

TeslaSession session(
  String uid,
  DateTime started, {
  int seconds = 600,
  int drives = 0,
}) =>
    TeslaSession(
      id: '$uid${started.microsecondsSinceEpoch}',
      uid: uid,
      email: '$uid@example.com',
      startedAt: started,
      lastSeenAt: started.add(Duration(seconds: seconds)),
      seconds: seconds,
      drives: drives,
    );

void main() {
  final now = DateTime(2026, 8, 29, 15);
  final today = DateTime(2026, 8, 29, 9);
  final yesterday = DateTime(2026, 8, 28, 9);

  group('TeslaStats', () {
    test('counts people, not page loads', () {
      final stats = TeslaStats.from([
        session('a', today),
        session('a', today.add(const Duration(hours: 2))),
        session('a', today.add(const Duration(hours: 4))),
        session('b', today),
      ], now: now);

      expect(stats.todayVisitors, 2); // two drivers
      expect(stats.todaySessions, 4); // four visits
    });

    test('adds up time and drives per driver, busiest first', () {
      final stats = TeslaStats.from([
        session('a', today, seconds: 300, drives: 1),
        session('a', yesterday, seconds: 900, drives: 2),
        session('b', today, seconds: 1800),
      ], now: now);

      expect(stats.users.first.uid, 'b'); // 30 min beats 20
      final a = stats.users.firstWhere((u) => u.uid == 'a');
      expect(a.sessions, 2);
      expect(a.time, const Duration(minutes: 20));
      expect(a.days.length, 2);
      expect(a.drives, 3);
      expect(stats.drives, 3);
      expect(stats.totalTime, const Duration(seconds: 3000));
      expect(stats.avgSession, const Duration(seconds: 1000));
    });

    test('a session older than the window is left out, not piled onto today', () {
      final stats = TeslaStats.from([
        session('old', now.subtract(const Duration(days: 45))),
        session('a', today),
      ], now: now);

      expect(stats.uniqueUsers, 1);
      expect(stats.totalSessions, 1);
      expect(stats.days.length, 30);
      expect(stats.days.last.day, 29);
    });

    test('a row whose server timestamp has not resolved yet is skipped', () {
      final stats = TeslaStats.from([
        const TeslaSession(id: 'x', uid: 'a'), // startedAt still null
      ], now: now);
      expect(stats.totalSessions, 0);
      expect(stats.uniqueUsers, 0);
    });
  });

  group('mapsUsageSummary', () {
    MapsUsageDay day(String d, {int directions = 0, int maps = 0}) =>
        MapsUsageDay(day: d, calls: {'directions': directions, 'maps': maps});

    test('sums the calendar month and today, and projects the rest', () {
      final rows = [
        day('2026-07-31', directions: 500), // previous month — not counted
        for (var i = 1; i <= 29; i++)
          day('2026-08-${i.toString().padLeft(2, '0')}', directions: 100),
      ];

      final directions = mapsUsageSummary(rows, now: now)
          .firstWhere((u) => u.limit.key == 'directions');

      expect(directions.monthCalls, 2900);
      expect(directions.todayCalls, 100);
      // 2900 over 29 days → 100/day → 3100 by the 31st.
      expect(directions.projectedMonth, 3100);
      expect(directions.willOverrun, isFalse); // free tier is 5000
      expect(directions.callsLeft, 2100);
      expect(directions.percentLeft, closeTo(42, 0.5));
    });

    test('an overrun reads as one, and past the tier the percentage goes negative', () {
      final rows = [
        for (var i = 1; i <= 29; i++)
          day('2026-08-${i.toString().padLeft(2, '0')}', directions: 200),
      ];
      final d = mapsUsageSummary(rows, now: now)
          .firstWhere((u) => u.limit.key == 'directions');

      expect(d.monthCalls, 5800);
      expect(d.willOverrun, isTrue);
      expect(d.percentLeft, lessThan(0));
    });

    test('Places is judged by its daily cap, because its metric is raw requests', () {
      // The real 2026-08-30 shape: 5,800 raw requests against a 5,000 free tier
      // that is denominated in billed calls. Read that way the card said "-16%
      // left, on track to go over"; read against the 1,000/day raw cap, which
      // is the same unit the metric is in, today is comfortable.
      final rows = [
        for (var i = 1; i <= 29; i++)
          MapsUsageDay(
            day: '2026-08-${i.toString().padLeft(2, '0')}',
            calls: const {'places': 200},
          ),
      ];
      final p = mapsUsageSummary(rows, now: now)
          .firstWhere((u) => u.limit.key == 'places');

      expect(p.monthCalls, 5800);
      expect(p.projectedMonth, greaterThan(p.limit.freeMonthly));
      expect(p.willOverrun, isFalse); // raw requests are not billed calls
      expect(p.gaugeFraction, closeTo(0.2, 0.001)); // 200 of a 1,000/day cap
      expect(p.percentLeft, closeTo(80, 0.5));
    });

    test('an API nothing calls sits at a full free tier rather than dividing by zero', () {
      final u = mapsUsageSummary([day('2026-08-29')], now: now)
          .firstWhere((u) => u.limit.key == 'geocoding');
      expect(u.monthCalls, 0);
      expect(u.percentLeft, 100);
      expect(u.dayFraction, 0); // no daily cap set for it
    });

    test('a day the refresh could not read is flagged stale', () {
      final rows = [
        MapsUsageDay(
          day: '2026-08-29',
          calls: const {'directions': 40},
          stale: const ['directions'],
        ),
      ];
      final s = mapsUsageSummary(rows, now: now);
      expect(s.firstWhere((u) => u.limit.key == 'directions').stale, isTrue);
      expect(s.firstWhere((u) => u.limit.key == 'maps').stale, isFalse);
    });

    test('the limits are the shipped ones until they are edited', () {
      expect(MapsLimits.I.byKey('directions').freeMonthly, 5000);
      expect(MapsLimits.I.byKey('directions').dailyCap, 160);
      expect(MapsLimits.I.byKey('maps').dailyCap, 330);
    });
  });
}
