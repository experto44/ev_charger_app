import 'package:cloud_firestore/cloud_firestore.dart';

/// One Tbilisi day of geocharge.ge traffic, counted by the `sitePulse` function
/// into `siteStats/{YYYY-MM-DD}` from the beacons `site/assets/pulse.js` sends.
///
/// Totals only, no visitor is named anywhere. A *visitor* is a browser's first
/// page of the day; a *visit* starts whenever someone arrives from outside the
/// site. Everything that says where a visit came from (source, referrer,
/// country, device) is counted once per visit, not once per page read.
class SiteDay {
  const SiteDay({
    required this.day,
    this.views = 0,
    this.visits = 0,
    this.visitors = 0,
    this.newVisitors = 0,
    this.clicks = const {},
    this.pages = const {},
    this.entries = const {},
    this.clickPages = const {},
    this.sources = const {},
    this.referrers = const {},
    this.campaigns = const {},
    this.countries = const {},
    this.devices = const {},
    this.os = const {},
    this.updatedAt,
  });

  /// `YYYY-MM-DD`, Asia/Tbilisi.
  final String day;

  final int views;
  final int visits;
  final int visitors;

  /// Visitors whose browser had never been to the site before.
  final int newVisitors;

  /// Store-link clicks by store: `play`, `appstore`.
  final Map<String, int> clicks;

  /// Page views per path.
  final Map<String, int> pages;

  /// Visits that started on each path.
  final Map<String, int> entries;

  /// Store-link clicks per path, e.g. `{'/damtenebi/': {'play': 3}}`.
  final Map<String, Map<String, int>> clickPages;

  final Map<String, int> sources;
  final Map<String, int> referrers;
  final Map<String, int> campaigns;

  /// ISO country code, worked out from the device's time zone.
  final Map<String, int> countries;
  final Map<String, int> devices;
  final Map<String, int> os;

  /// Server time of the last hit counted into this day.
  final DateTime? updatedAt;

  factory SiteDay.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) =>
      SiteDay.fromMap(doc.id, doc.data() ?? const {});

  factory SiteDay.fromMap(String id, Map<String, dynamic> d) {
    final clickPages = <String, Map<String, int>>{};
    final rawClickPages = d['clickPages'];
    if (rawClickPages is Map) {
      for (final e in rawClickPages.entries) {
        final c = _counts(e.value);
        if (c.isNotEmpty) clickPages[e.key.toString()] = c;
      }
    }
    final updated = d['updatedAt'];
    return SiteDay(
      day: (d['day'] as String?) ?? id,
      views: _int(d['views']),
      visits: _int(d['visits']),
      visitors: _int(d['visitors']),
      newVisitors: _int(d['newVisitors']),
      clicks: _counts(d['clicks']),
      pages: _counts(d['pages']),
      entries: _counts(d['entries']),
      clickPages: clickPages,
      sources: _counts(d['sources']),
      referrers: _counts(d['referrers']),
      campaigns: _counts(d['campaigns']),
      countries: _counts(d['countries']),
      devices: _counts(d['devices']),
      os: _counts(d['os']),
      updatedAt: updated is Timestamp
          ? updated.toDate()
          : (updated is DateTime ? updated : null),
    );
  }

  static int _int(dynamic v) => v is num ? v.round() : 0;

  static Map<String, int> _counts(dynamic v) {
    if (v is! Map) return const {};
    return {
      for (final e in v.entries)
        if (e.value is num) e.key.toString(): (e.value as num).round(),
    };
  }
}
