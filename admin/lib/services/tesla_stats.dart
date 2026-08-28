import '../models/maps_usage.dart';
import '../models/tesla_session.dart';
import 'maps_limits.dart';

/// One account's use of the car app over the window.
class TeslaUser {
  TeslaUser({required this.uid, required this.email});

  final String uid;
  String email;

  int sessions = 0;
  int seconds = 0;
  int drives = 0;
  DateTime? lastSeen;

  /// Days (in the window) on which this account used the car app at all —
  /// a better measure of a habit than a session count, which one restless
  /// afternoon can inflate.
  final Set<String> days = {};

  Duration get time => Duration(seconds: seconds);
  Duration get avgSession =>
      Duration(seconds: sessions == 0 ? 0 : seconds ~/ sessions);
}

/// Everything the Tesla tab shows about usage, folded out of the raw session
/// rows once. Pure: no Firebase, no widgets — so it can be tested and previewed.
class TeslaStats {
  TeslaStats._({
    required this.days,
    required this.visitorsPerDay,
    required this.sessionsPerDay,
    required this.users,
    required this.totalSessions,
    required this.totalSeconds,
  });

  /// Local dates, oldest first — one per bar of the chart.
  final List<DateTime> days;

  /// Distinct accounts per day, aligned with [days].
  final List<int> visitorsPerDay;

  /// Visits per day, aligned with [days].
  final List<int> sessionsPerDay;

  /// Everyone who appeared in the window, busiest first.
  final List<TeslaUser> users;

  final int totalSessions;
  final int totalSeconds;

  int get todayVisitors => visitorsPerDay.isEmpty ? 0 : visitorsPerDay.last;
  int get todaySessions => sessionsPerDay.isEmpty ? 0 : sessionsPerDay.last;
  int get uniqueUsers => users.length;
  Duration get totalTime => Duration(seconds: totalSeconds);
  Duration get avgSession =>
      Duration(seconds: totalSessions == 0 ? 0 : totalSeconds ~/ totalSessions);

  /// Sessions that turned into an actual navigation.
  int get drives => users.fold(0, (s, u) => s + u.drives);

  static String _key(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// Fold [sessions] into per-day counts and per-user totals over the last
  /// [window] days, ending today. Sessions outside the window (or with no
  /// server timestamp yet — the split second before the write resolves) are
  /// skipped rather than piled onto today.
  factory TeslaStats.from(
    List<TeslaSession> sessions, {
    int window = 30,
    DateTime? now,
  }) {
    final today0 = () {
      final n = now ?? DateTime.now();
      return DateTime(n.year, n.month, n.day);
    }();

    final days = [
      for (var i = window - 1; i >= 0; i--) today0.subtract(Duration(days: i)),
    ];
    final index = {for (var i = 0; i < days.length; i++) _key(days[i]): i};

    final visitorsPerDay = List<Set<String>>.generate(window, (_) => <String>{});
    final sessionsPerDay = List<int>.filled(window, 0);
    final byUid = <String, TeslaUser>{};
    var totalSessions = 0;
    var totalSeconds = 0;

    for (final s in sessions) {
      final started = s.startedAt;
      if (started == null || s.uid.isEmpty) continue;
      final key = _key(DateTime(started.year, started.month, started.day));
      final i = index[key];
      if (i == null) continue; // outside the window

      visitorsPerDay[i].add(s.uid);
      sessionsPerDay[i]++;
      totalSessions++;
      totalSeconds += s.seconds;

      final u = byUid.putIfAbsent(s.uid, () => TeslaUser(uid: s.uid, email: s.email));
      if (u.email.isEmpty) u.email = s.email;
      u.sessions++;
      u.seconds += s.seconds;
      u.drives += s.drives;
      u.days.add(key);
      final seen = s.lastSeenAt ?? started;
      if (u.lastSeen == null || seen.isAfter(u.lastSeen!)) u.lastSeen = seen;
    }

    final users = byUid.values.toList()
      ..sort((a, b) {
        final t = b.seconds.compareTo(a.seconds);
        return t != 0 ? t : b.sessions.compareTo(a.sessions);
      });

    return TeslaStats._(
      days: days,
      visitorsPerDay: [for (final s in visitorsPerDay) s.length],
      sessionsPerDay: sessionsPerDay,
      users: users,
      totalSessions: totalSessions,
      totalSeconds: totalSeconds,
    );
  }
}

/// One API's position against its two ceilings.
class ApiUsage {
  const ApiUsage({
    required this.limit,
    required this.monthCalls,
    required this.todayCalls,
    required this.projectedMonth,
    required this.stale,
  });

  final ApiLimit limit;

  /// Calls so far this calendar month, and today.
  final int monthCalls;
  final int todayCalls;

  /// Where the month ends at the current daily rate — the number that says
  /// whether a free tier that looks comfortable today actually survives.
  final int projectedMonth;

  /// The last refresh could not read this API; the figures are the previous
  /// ones, not current.
  final bool stale;

  /// Fraction of the monthly free tier spent (0..1+, uncapped so an overrun
  /// still reads as an overrun).
  double get monthFraction =>
      limit.freeMonthly <= 0 ? 0 : monthCalls / limit.freeMonthly;

  /// What the driver of this panel actually asked for: how much is LEFT.
  double get percentLeft =>
      limit.freeMonthly <= 0 ? 100 : ((1 - monthFraction) * 100).clamp(-999, 100);

  int get callsLeft => (limit.freeMonthly - monthCalls).clamp(-1 << 30, 1 << 30);

  double get dayFraction =>
      limit.dailyCap <= 0 ? 0 : todayCalls / limit.dailyCap;

  /// The free tier will not survive the month at this rate.
  bool get willOverrun =>
      limit.freeMonthly > 0 && projectedMonth > limit.freeMonthly;
}

/// Fold the daily usage rows into one figure per API for the current month.
///
/// The month is the calendar month of [now] in local time, which is how Google
/// counts a free tier. The projection is deliberately naive — today's partial
/// day is included in the rate, because a rate that ignores the day in progress
/// reads low every afternoon.
List<ApiUsage> mapsUsageSummary(
  List<MapsUsageDay> rows, {
  DateTime? now,
  MapsLimits? limits,
}) {
  final n = now ?? DateTime.now();
  final monthStart = DateTime(n.year, n.month, 1);
  final daysInMonth = DateTime(n.year, n.month + 1, 0).day;
  final todayKey =
      '${n.year}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';

  final month = rows.where((r) {
    final d = r.date;
    return d != null && !d.isBefore(monthStart) && d.month == n.month;
  }).toList();

  final today = rows.where((r) => r.day == todayKey).toList();
  final staleApis = {for (final r in today) ...r.stale};

  return [
    for (final limit in (limits ?? MapsLimits.I).all)
      () {
        final monthCalls =
            month.fold<int>(0, (s, r) => s + r[limit.key]);
        final todayCalls = today.fold<int>(0, (s, r) => s + r[limit.key]);
        // Elapsed days including today as a whole one: at the end of day 10 of
        // a 31-day month, ten days of traffic predict the remaining twenty-one.
        final elapsed = n.day;
        final projected = elapsed == 0
            ? monthCalls
            : (monthCalls / elapsed * daysInMonth).round();
        return ApiUsage(
          limit: limit,
          monthCalls: monthCalls,
          todayCalls: todayCalls,
          projectedMonth: projected,
          stale: staleApis.contains(limit.key),
        );
      }(),
  ];
}
