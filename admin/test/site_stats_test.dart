// Pure aggregation behind the Site tab. Runs on the VM:
//   cd admin && flutter test test/site_stats_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:geocharge_admin/models/site_day.dart';
import 'package:geocharge_admin/services/site_stats.dart';

void main() {
  // 21:30 UTC on the 14th is already 01:30 on the 15th in Tbilisi.
  final now = DateTime.utc(2026, 9, 14, 21, 30);

  test('today is the Tbilisi date, whatever clock the panel runs on', () {
    expect(SiteStats.tbilisiToday(now), DateTime(2026, 9, 15));
    expect(SiteStats.tbilisiToday(DateTime.utc(2026, 9, 14, 19, 59)),
        DateTime(2026, 9, 14));
  });

  test('totals cover the range only, and the chart shows the empty days', () {
    final stats = SiteStats.from([
      const SiteDay(
        day: '2026-09-15',
        views: 30,
        visits: 12,
        visitors: 10,
        newVisitors: 6,
        clicks: {'play': 2, 'appstore': 1},
      ),
      const SiteDay(
        day: '2026-09-13',
        views: 20,
        visits: 8,
        visitors: 7,
        newVisitors: 1,
        clicks: {'play': 1},
      ),
      // Well outside a seven-day range.
      const SiteDay(day: '2026-08-01', views: 999, visits: 999, visitors: 999),
    ], window: 7, now: now);

    expect(stats.views, 50);
    expect(stats.visits, 20);
    expect(stats.visitors, 17);
    expect(stats.returningVisitors, 10);
    expect(stats.play, 3);
    expect(stats.appstore, 1);
    expect(stats.clickRate, closeTo(4 / 17, 1e-9));
    expect(stats.pagesPerVisit, 2.5);

    expect(stats.days.length, 7);
    expect(stats.days.last, DateTime(2026, 9, 15));
    expect(stats.visitorsPerDay, [0, 0, 0, 0, 7, 0, 10]);
  });

  test('a one-day range still charts a week, but counts only today', () {
    final stats = SiteStats.from([
      const SiteDay(day: '2026-09-15', views: 5, visitors: 2),
      const SiteDay(day: '2026-09-14', views: 9, visitors: 4),
    ], window: 1, now: now);

    expect(stats.views, 5);
    expect(stats.visitors, 2);
    expect(stats.days.length, 7);
    expect(stats.viewsPerDay.sublist(5), [9, 5]);
  });

  test('breakdowns add up across days and rank largest first', () {
    final stats = SiteStats.from([
      const SiteDay(
        day: '2026-09-15',
        sources: {'google': 3, 'facebook': 5},
        countries: {'GE': 4},
      ),
      const SiteDay(
        day: '2026-09-14',
        sources: {'google': 4, 'direct': 1},
        countries: {'GE': 2, 'TR': 3},
      ),
    ], window: 7, now: now);

    expect(stats.sources.map((e) => '${e.key}=${e.value}'),
        ['google=7', 'facebook=5', 'direct=1']);
    expect(stats.countries.map((e) => '${e.key}=${e.value}'), ['GE=6', 'TR=3']);
  });

  test('pages join views, landings and store clicks, even a click with no view',
      () {
    final stats = SiteStats.from([
      const SiteDay(
        day: '2026-09-15',
        views: 7,
        pages: {'/': 4, '/en/chargers/': 3},
        entries: {'/': 2},
        clickPages: {
          '/': {'play': 1},
          '/get/': {'appstore': 2},
        },
      ),
    ], window: 7, now: now);

    expect(stats.pages.map((p) => p.path), ['/', '/en/chargers/', '/get/']);
    final home = stats.pages.first;
    expect([home.views, home.entries, home.play, home.appstore], [4, 2, 1, 0]);
    expect(stats.pages.last.storeClicks, 2);
    expect(stats.englishViews, 3);
    expect(stats.georgianViews, 4);
  });

  test('the last activity is the newest update in any row, in range or not',
      () {
    final stats = SiteStats.from([
      SiteDay(day: '2026-07-01', updatedAt: DateTime(2026, 7, 1, 23)),
      SiteDay(day: '2026-09-15', updatedAt: DateTime(2026, 9, 15, 1, 20)),
      const SiteDay(day: '2026-09-14'),
    ], window: 1, now: now);
    expect(stats.lastHit, DateTime(2026, 9, 15, 1, 20));
  });

  test('a document is read defensively: stray types never throw', () {
    final day = SiteDay.fromMap('2026-09-15', {
      'views': 12,
      'visits': 4.0,
      'pages': {'/': 3, '/bad/': 'x'},
      'clickPages': {
        '/': {'play': 2},
        '/x/': 'nope',
      },
      'sources': 'not a map',
    });

    expect(day.day, '2026-09-15');
    expect(day.views, 12);
    expect(day.visits, 4);
    expect(day.pages, {'/': 3});
    expect(day.clickPages, {
      '/': {'play': 2},
    });
    expect(day.sources, isEmpty);
    expect(day.updatedAt, isNull);
  });
}
