import '../models/site_day.dart';

/// One page's line in the Site tab's pages table.
class SitePage {
  SitePage(this.path);

  final String path;
  int views = 0;

  /// Visits that started on this page: how people land on the site.
  int entries = 0;

  int play = 0;
  int appstore = 0;

  int get storeClicks => play + appstore;
}

/// Everything the Site tab shows for one date range, folded out of the daily
/// rows once. Pure: no Firebase, no widgets, so it can be tested and previewed.
class SiteStats {
  SiteStats._({
    required this.window,
    required this.days,
    required this.visitorsPerDay,
    required this.viewsPerDay,
    required this.views,
    required this.visits,
    required this.visitors,
    required this.newVisitors,
    required this.play,
    required this.appstore,
    required this.sources,
    required this.referrers,
    required this.campaigns,
    required this.countries,
    required this.devices,
    required this.os,
    required this.pages,
    required this.lastHit,
  });

  /// Days the totals cover, ending today.
  final int window;

  /// The chart's days, oldest first. At least a week even for a one-day range,
  /// so today always has something to be compared against.
  final List<DateTime> days;
  final List<int> visitorsPerDay;
  final List<int> viewsPerDay;

  final int views;
  final int visits;
  final int visitors;
  final int newVisitors;
  final int play;
  final int appstore;

  /// Each ranked largest first.
  final List<MapEntry<String, int>> sources;
  final List<MapEntry<String, int>> referrers;
  final List<MapEntry<String, int>> campaigns;
  final List<MapEntry<String, int>> countries;
  final List<MapEntry<String, int>> devices;
  final List<MapEntry<String, int>> os;

  /// Every page seen in the range, most viewed first.
  final List<SitePage> pages;

  /// The most recent hit in any row, inside the range or not: whether the
  /// counter is alive at all.
  final DateTime? lastHit;

  int get storeClicks => play + appstore;

  int get returningVisitors => (visitors - newVisitors).clamp(0, visitors);

  /// Store clicks per visitor. Above 1 is possible: one person may tap both.
  double get clickRate => visitors == 0 ? 0 : storeClicks / visitors;

  double get pagesPerVisit => visits == 0 ? 0 : views / visits;

  /// Views of the English mirror (everything under /en/).
  int get englishViews => pages
      .where((p) => p.path == '/en' || p.path.startsWith('/en/'))
      .fold(0, (s, p) => s + p.views);

  int get georgianViews => views - englishViews;

  /// The Tbilisi date [now] falls on, at midnight. Hits are filed under
  /// Tbilisi days, so "today" must be one too, whatever time zone the admin's
  /// browser happens to be in.
  static DateTime tbilisiToday([DateTime? now]) {
    final t = (now ?? DateTime.now()).toUtc().add(const Duration(hours: 4));
    return DateTime(t.year, t.month, t.day);
  }

  static String dayKey(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  factory SiteStats.from(
    List<SiteDay> rows, {
    int window = 30,
    DateTime? now,
  }) {
    final today = tbilisiToday(now);
    final chartLength = window < 7 ? 7 : window;
    // Calendar arithmetic rather than subtracting 24-hour Durations, which
    // would skip or repeat a date across a daylight-saving change in the
    // admin's own time zone.
    final days = [
      for (var i = chartLength - 1; i >= 0; i--)
        DateTime(today.year, today.month, today.day - i),
    ];
    final byKey = {for (final r in rows) r.day: r};
    final inRange = [
      for (final d in days.sublist(chartLength - window)) byKey[dayKey(d)],
    ].whereType<SiteDay>();

    var views = 0, visits = 0, visitors = 0, newVisitors = 0;
    var play = 0, appstore = 0;
    final sources = <String, int>{};
    final referrers = <String, int>{};
    final campaigns = <String, int>{};
    final countries = <String, int>{};
    final devices = <String, int>{};
    final os = <String, int>{};
    final pages = <String, SitePage>{};

    void add(Map<String, int> into, Map<String, int> from) =>
        from.forEach((k, v) => into[k] = (into[k] ?? 0) + v);
    SitePage page(String path) => pages.putIfAbsent(path, () => SitePage(path));

    for (final r in inRange) {
      views += r.views;
      visits += r.visits;
      visitors += r.visitors;
      newVisitors += r.newVisitors;
      play += r.clicks['play'] ?? 0;
      appstore += r.clicks['appstore'] ?? 0;
      add(sources, r.sources);
      add(referrers, r.referrers);
      add(campaigns, r.campaigns);
      add(countries, r.countries);
      add(devices, r.devices);
      add(os, r.os);
      r.pages.forEach((path, n) => page(path).views += n);
      r.entries.forEach((path, n) => page(path).entries += n);
      // A page can carry clicks with no views in the range: the view was
      // counted just before midnight and the click just after.
      r.clickPages.forEach((path, c) {
        final p = page(path);
        p.play += c['play'] ?? 0;
        p.appstore += c['appstore'] ?? 0;
      });
    }

    DateTime? lastHit;
    for (final r in rows) {
      final u = r.updatedAt;
      if (u != null && (lastHit == null || u.isAfter(lastHit))) lastHit = u;
    }

    List<MapEntry<String, int>> ranked(Map<String, int> m) =>
        m.entries.where((e) => e.value > 0).toList()
          ..sort((a, b) {
            final c = b.value.compareTo(a.value);
            return c != 0 ? c : a.key.compareTo(b.key);
          });

    final pageList = pages.values.toList()
      ..sort((a, b) {
        final byViews = b.views.compareTo(a.views);
        if (byViews != 0) return byViews;
        final byClicks = b.storeClicks.compareTo(a.storeClicks);
        return byClicks != 0 ? byClicks : a.path.compareTo(b.path);
      });

    return SiteStats._(
      window: window,
      days: days,
      visitorsPerDay: [for (final d in days) byKey[dayKey(d)]?.visitors ?? 0],
      viewsPerDay: [for (final d in days) byKey[dayKey(d)]?.views ?? 0],
      views: views,
      visits: visits,
      visitors: visitors,
      newVisitors: newVisitors,
      play: play,
      appstore: appstore,
      sources: ranked(sources),
      referrers: ranked(referrers),
      campaigns: ranked(campaigns),
      countries: ranked(countries),
      devices: ranked(devices),
      os: ranked(os),
      pages: pageList,
      lastHit: lastHit,
    );
  }
}
