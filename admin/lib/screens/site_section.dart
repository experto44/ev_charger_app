import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/site_day.dart';
import '../services/browser.dart' as browser;
import '../services/country_names.dart';
import '../services/site_stats.dart';
import '../theme.dart';
import '../widgets/breakdown_card.dart';
import '../widgets/kpi_card.dart';

/// The chart's page-view bars. Grid lines are drawn in kBgSurface, so a bar in
/// that colour would vanish into them (same shade as the Tesla tab's sessions).
const Color _kViewsBar = Color(0xFF4C5C6B);

const String _kSite = 'https://geocharge.ge';

/// The Site tab: how many people come to geocharge.ge, where from, what they
/// read, and how many of them go on to a store.
///
/// Pure (data in, pixels out) so it previews without Firebase like the rest of
/// the dashboard. The date range is this tab's own state and filters nothing
/// else on the panel.
class SiteAnalyticsView extends StatefulWidget {
  const SiteAnalyticsView({
    super.key,
    required this.rows,
    this.error,
    this.now,
  });

  /// Daily rows for the last 90 days. `null` means "still loading".
  final List<SiteDay>? rows;
  final String? error;

  /// A fixed clock for previews and tests.
  final DateTime? now;

  @override
  State<SiteAnalyticsView> createState() => _SiteAnalyticsViewState();
}

enum _PageSort { views, entries, play, appstore }

class _SiteAnalyticsViewState extends State<SiteAnalyticsView> {
  int _window = 30;
  _PageSort _sort = _PageSort.views;
  bool _allPages = false;

  static const int _pageLimit = 20;
  static final NumberFormat _n = NumberFormat.decimalPattern();

  static const Map<String, String> _sourceNames = {
    'direct': 'Direct / no referrer',
    'google': 'Google',
    'google-ads': 'Google Ads',
    'bing': 'Bing',
    'yandex': 'Yandex',
    'duckduckgo': 'DuckDuckGo',
    'yahoo': 'Yahoo',
    'facebook': 'Facebook',
    'instagram': 'Instagram',
    'youtube': 'YouTube',
    'x': 'X / Twitter',
    'linkedin': 'LinkedIn',
    'tiktok': 'TikTok',
    'telegram': 'Telegram',
    'email': 'Email',
    'chatgpt': 'ChatGPT',
    'perplexity': 'Perplexity',
    'gemini': 'Gemini',
    'claude': 'Claude',
    'copilot': 'Copilot',
    'referral': 'Other websites',
  };

  static const Map<String, String> _deviceNames = {
    'mobile': 'Phone',
    'desktop': 'Computer',
    'tablet': 'Tablet',
    'car': 'Tesla (car browser)',
  };

  static const Map<String, String> _osNames = {
    'android': 'Android',
    'ios': 'iOS',
    'windows': 'Windows',
    'macos': 'macOS',
    'linux': 'Linux',
    'chromeos': 'ChromeOS',
    'other': 'Other',
  };

  static String _capitalised(String k) =>
      k.isEmpty ? k : k[0].toUpperCase() + k.substring(1);

  static String _sourceLabel(String k) => _sourceNames[k] ?? _capitalised(k);

  // Names only, no flag emoji: the web build draws them as empty boxes until
  // Flutter has fetched a multi-megabyte colour emoji font from Google's CDN,
  // which is a poor trade for decoration.
  static String _countryLabel(String code) => code.length == 2
      ? (kCountryNames[code.toUpperCase()] ?? code.toUpperCase())
      : 'Unknown';

  @override
  Widget build(BuildContext context) {
    if (widget.error != null) {
      return _Message(
        icon: Icons.lock_outline,
        title: 'Site statistics could not be read',
        body: '${widget.error}\n\nIf this says "permission-denied", the updated '
            'firestore.rules (siteStats) have not been deployed yet.',
      );
    }
    final rows = widget.rows;
    if (rows == null) return const Center(child: CircularProgressIndicator());
    if (rows.isEmpty) {
      return const _Message(
        icon: Icons.public_off,
        title: 'No visits recorded yet',
        body: 'Counting starts with the first page view after site/assets/pulse.js '
            'and the sitePulse function are deployed.',
      );
    }

    final s = SiteStats.from(rows, window: _window, now: widget.now);

    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth;
      final isMobile = w < 680;
      final isDesktop = w >= 1080;
      final pad = isMobile ? 12.0 : 20.0;
      const gap = 16.0;

      final top = [
        _header(s),
        const SizedBox(height: 14),
        _kpis(s),
        const SizedBox(height: gap),
      ];

      final whereFrom = [
        _rankCard('Where visits come from', s.sources, kEmerald, _sourceLabel),
        _rankCard('Countries · by device time zone', s.countries, kBlue,
            _countryLabel),
      ];
      final more = [
        _rankCard('Referring sites', s.referrers, kAmber, (k) => k),
        BreakdownCard(title: 'Visitors', rows: [
          BreakdownRow('New', s.newVisitors, kEmerald),
          BreakdownRow('Returning', s.returningVisitors, kBlue),
        ]),
        _rankCard('Devices', s.devices, kBlue,
            (k) => _deviceNames[k] ?? _capitalised(k)),
        _rankCard('Operating system', s.os, kEmerald,
            (k) => _osNames[k] ?? _capitalised(k)),
        BreakdownCard(title: 'Page language · views', rows: [
          BreakdownRow('Georgian', s.georgianViews, kEmerald),
          BreakdownRow('English (/en/)', s.englishViews, kBlue),
        ]),
        if (s.campaigns.isNotEmpty)
          _rankCard('Campaigns (utm)', s.campaigns, kAmber, (k) => k),
      ];

      if (isDesktop) {
        return ListView(
          padding: EdgeInsets.all(pad),
          children: [
            ...top,
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(height: 290, child: _chartCard(s)),
                      const SizedBox(height: gap),
                      _pagesCard(s),
                    ],
                  ),
                ),
                const SizedBox(width: gap),
                SizedBox(
                  width: 340,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: _spaced([...whereFrom, ...more], gap),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            _footnote(),
          ],
        );
      }

      // Tablet: breakdowns two abreast. Phone: one column, the chart shorter.
      final cols = isMobile ? 1 : 2;
      final cardW = ((w - 2 * pad - (cols - 1) * gap) / cols).floorToDouble();
      Widget grid(List<Widget> cards) => Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [for (final card in cards) SizedBox(width: cardW, child: card)],
          );

      return ListView(
        padding: EdgeInsets.all(pad),
        children: [
          ...top,
          SizedBox(height: isMobile ? 230 : 270, child: _chartCard(s)),
          const SizedBox(height: gap),
          grid(whereFrom),
          const SizedBox(height: gap),
          _pagesCard(s),
          const SizedBox(height: gap),
          grid(more),
          const SizedBox(height: 14),
          _footnote(),
        ],
      );
    });
  }

  List<Widget> _spaced(List<Widget> items, double gap) => [
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0) SizedBox(height: gap),
          items[i],
        ],
      ];

  // ── Range + liveness ──────────────────────────────────────────────────────
  Widget _header(SiteStats s) {
    return Wrap(
      spacing: 16,
      runSpacing: 10,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SegmentedButton<int>(
          segments: const [
            ButtonSegment(value: 1, label: Text('Today')),
            ButtonSegment(value: 7, label: Text('7 days')),
            ButtonSegment(value: 30, label: Text('30 days')),
            ButtonSegment(value: 90, label: Text('90 days')),
          ],
          selected: {_window},
          showSelectedIcon: false,
          onSelectionChanged: (v) => setState(() {
            _window = v.first;
            _allPages = false;
          }),
          style: ButtonStyle(
            visualDensity: VisualDensity.compact,
            backgroundColor: WidgetStateProperty.resolveWith((states) =>
                states.contains(WidgetState.selected)
                    ? kEmerald.withValues(alpha: 0.18)
                    : kBgSurface),
          ),
        ),
        if (s.lastHit != null) _lastHit(s.lastHit!),
      ],
    );
  }

  Widget _lastHit(DateTime at) {
    final now = widget.now ?? DateTime.now();
    // Green while the counter has seen someone in the last half hour: a quick
    // way to tell a quiet night from a broken beacon.
    final fresh = now.difference(at).inMinutes < 30;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: fresh ? kEmerald : kTextSec,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 7),
        Text(
          'Last activity ${DateFormat('d MMM, HH:mm').format(at)}',
          style: const TextStyle(color: kTextSec, fontSize: 12.5),
        ),
      ],
    );
  }

  // ── KPI strip ─────────────────────────────────────────────────────────────
  Widget _kpis(SiteStats s) {
    final rate = s.clickRate * 100;
    final cards = <Widget>[
      KpiCard(
          label: 'Visitors',
          value: _n.format(s.visitors),
          icon: Icons.person_outline,
          accent: kEmerald),
      KpiCard(
          label: 'Visits',
          value: _n.format(s.visits),
          icon: Icons.login,
          accent: kEmerald),
      KpiCard(
          label: 'Page views',
          value: _n.format(s.views),
          icon: Icons.visibility_outlined,
          accent: kBlue),
      KpiCard(
          label: 'Google Play clicks',
          value: _n.format(s.play),
          icon: Icons.android,
          accent: kAmber),
      KpiCard(
          label: 'App Store clicks',
          value: _n.format(s.appstore),
          icon: Icons.apple,
          accent: kAmber),
      KpiCard(
          label: 'Store clicks / visitor',
          value: '${rate.toStringAsFixed(rate < 10 ? 1 : 0)}%',
          icon: Icons.ads_click,
          accent: kBlue),
    ];
    return LayoutBuilder(builder: (context, c) {
      // Six abreast only where the labels still fit beside their icons.
      final perRow = c.maxWidth >= 1320 ? 6 : (c.maxWidth >= 640 ? 3 : 2);
      const gap = 12.0;
      final itemW =
          ((c.maxWidth - (perRow - 1) * gap) / perRow).floorToDouble();
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: cards.map((w) => SizedBox(width: itemW, child: w)).toList(),
      );
    });
  }

  // ── Chart ─────────────────────────────────────────────────────────────────
  Widget _chartCard(SiteStats s) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('Daily · last ${s.days.length} days',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
                _legendDot(kEmerald, 'visitors'),
                const SizedBox(width: 12),
                _legendDot(_kViewsBar, 'page views'),
              ],
            ),
            const SizedBox(height: 10),
            Expanded(child: _DailyChart(stats: s)),
          ],
        ),
      ),
    );
  }

  Widget _legendDot(Color c, String label) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
              width: 9,
              height: 9,
              decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
          const SizedBox(width: 5),
          Text(label, style: const TextStyle(color: kTextSec, fontSize: 11.5)),
        ],
      );

  // ── Pages table ───────────────────────────────────────────────────────────
  int _compare(SitePage a, SitePage b) {
    final int by;
    switch (_sort) {
      case _PageSort.views:
        by = b.views.compareTo(a.views);
      case _PageSort.entries:
        by = b.entries.compareTo(a.entries);
      case _PageSort.play:
        by = b.play.compareTo(a.play);
      case _PageSort.appstore:
        by = b.appstore.compareTo(a.appstore);
    }
    return by != 0 ? by : b.views.compareTo(a.views);
  }

  void _sortBy(_PageSort sort) => setState(() => _sort = sort);

  Widget _clickCell(int n) => Text(
        n == 0 ? '·' : _n.format(n),
        style: TextStyle(
          color: n == 0 ? kTextSec : kAmber,
          fontWeight: n == 0 ? FontWeight.normal : FontWeight.w600,
        ),
      );

  Widget _pagesCard(SiteStats s) {
    final sorted = [...s.pages]..sort(_compare);
    final shown = _allPages ? sorted : sorted.take(_pageLimit).toList();

    final table = DataTable(
      headingRowHeight: 40,
      dataRowMinHeight: 38,
      dataRowMaxHeight: 42,
      columnSpacing: 24,
      showCheckboxColumn: false,
      sortColumnIndex: _sort.index + 1,
      sortAscending: false,
      headingTextStyle: const TextStyle(
          color: kTextSec, fontSize: 11.5, fontWeight: FontWeight.w600),
      columns: [
        const DataColumn(label: Text('PAGE')),
        DataColumn(
            label: const Text('VIEWS'),
            numeric: true,
            onSort: (col, asc) => _sortBy(_PageSort.views)),
        DataColumn(
            label: const Text('LANDINGS'),
            tooltip: 'Visits that started on this page',
            numeric: true,
            onSort: (col, asc) => _sortBy(_PageSort.entries)),
        DataColumn(
            label: const Text('GOOGLE PLAY'),
            numeric: true,
            onSort: (col, asc) => _sortBy(_PageSort.play)),
        DataColumn(
            label: const Text('APP STORE'),
            numeric: true,
            onSort: (col, asc) => _sortBy(_PageSort.appstore)),
      ],
      rows: [
        for (final p in shown)
          DataRow(
            // "(other)" pools paths that are not real site URLs; nothing to open.
            onSelectChanged: p.path.startsWith('/')
                ? (_) => browser.openUrl('$_kSite${p.path}')
                : null,
            cells: [
              DataCell(ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 320),
                child: Text(p.path,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13)),
              )),
              DataCell(Text(_n.format(p.views))),
              DataCell(Text(_n.format(p.entries))),
              DataCell(_clickCell(p.play)),
              DataCell(_clickCell(p.appstore)),
            ],
          ),
      ],
    );

    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Row(
              children: [
                const Text('Pages', style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '${s.pages.length} in range · click a row to open the page',
                    textAlign: TextAlign.right,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: kTextSec, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
          if (sorted.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 24),
              child: Text('No page views in this range.',
                  style: TextStyle(color: kTextSec, fontSize: 13)),
            )
          else ...[
            LayoutBuilder(
              builder: (context, c) => SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: ConstrainedBox(
                  constraints: BoxConstraints(minWidth: c.maxWidth),
                  child: table,
                ),
              ),
            ),
            if (sorted.length > _pageLimit)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Center(
                  child: TextButton(
                    onPressed: () => setState(() => _allPages = !_allPages),
                    child: Text(_allPages
                        ? 'Show the top $_pageLimit'
                        : 'Show all ${sorted.length} pages'),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  // ── Breakdowns ────────────────────────────────────────────────────────────
  /// The top [top] entries as share bars, the long tail folded into "Other" so
  /// the percentages stay shares of the whole.
  Widget _rankCard(
    String title,
    List<MapEntry<String, int>> ranked,
    Color color,
    String Function(String) label, {
    int top = 6,
  }) {
    if (ranked.isEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 14)),
              const SizedBox(height: 10),
              const Text('No data in this range.',
                  style: TextStyle(color: kTextSec, fontSize: 12.5)),
            ],
          ),
        ),
      );
    }
    final rest = ranked.skip(top).fold<int>(0, (sum, e) => sum + e.value);
    return BreakdownCard(
      title: title,
      rows: [
        for (final e in ranked.take(top)) BreakdownRow(label(e.key), e.value, color),
        if (rest > 0) BreakdownRow('Other', rest, kTextSec),
      ],
    );
  }

  Widget _footnote() => const Text(
        'A visitor is a browser\'s first page of the day, so one person on a '
        'phone and a laptop counts twice. A visit starts whenever someone '
        'arrives from outside the site. Countries come from the device time '
        'zone, which a VPN does not change. Bots are not counted, and neither '
        'is any browser that has opened geocharge.ge/?notrack=1 once. Store '
        'clicks on /get/ are the QR-code redirect sending phones to their store.',
        style: TextStyle(color: kTextSec, fontSize: 11.5, height: 1.45),
      );
}

/// Two bars per day: page views behind, visitors in front, so a day where a few
/// people read a lot is not mistaken for a day when many came.
class _DailyChart extends StatelessWidget {
  const _DailyChart({required this.stats});
  final SiteStats stats;

  /// 1, 2 or 5 times a power of ten, so the axis reads 0, 200, 400 rather
  /// than 0, 117, 234.
  static double _niceStep(double raw) {
    if (raw <= 1) return 1;
    final magnitude =
        math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
    final f = raw / magnitude;
    final nice = f <= 1 ? 1.0 : (f <= 2 ? 2.0 : (f <= 5 ? 5.0 : 10.0));
    return nice * magnitude;
  }

  @override
  Widget build(BuildContext context) {
    final n = stats.days.length;
    final peak = [...stats.viewsPerDay, ...stats.visitorsPerDay, 1]
        .reduce(math.max)
        .toDouble();
    final step = _niceStep(peak / 4);
    final maxY = (peak / step).ceilToDouble() * step;
    // About six date labels whatever the range, counted back from today so the
    // last bar is always labelled.
    final labelEvery = math.max(1, (n / 6).ceil());

    return LayoutBuilder(builder: (context, c) {
      // Bars sized to the room: a week on a desktop gets solid bars, ninety
      // days on a phone get hairlines rather than overlapping ones.
      final rod = ((c.maxWidth - 36) / n * 0.34).clamp(1.5, 10.0).toDouble();

      return BarChart(
        BarChartData(
          alignment: BarChartAlignment.spaceBetween,
          maxY: maxY,
          barTouchData: BarTouchData(
            touchTooltipData: BarTouchTooltipData(
              getTooltipColor: (_) => kBgSurface,
              fitInsideHorizontally: true,
              fitInsideVertically: true,
              getTooltipItem: (group, groupIndex, rodData, rodIndex) {
                if (rodIndex != 1) return null; // one tooltip per day, not per bar
                final i = group.x;
                return BarTooltipItem(
                  '${DateFormat('EEE d MMM').format(stats.days[i])}\n',
                  const TextStyle(color: kTextSec, fontSize: 11),
                  children: [
                    TextSpan(
                      text: '${stats.visitorsPerDay[i]} visitors',
                      style: const TextStyle(
                          color: kEmerald,
                          fontSize: 12,
                          fontWeight: FontWeight.w600),
                    ),
                    TextSpan(
                      text: ' · ${stats.viewsPerDay[i]} views',
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ],
                );
              },
            ),
          ),
          gridData: FlGridData(
            show: true,
            drawVerticalLine: false,
            horizontalInterval: step,
            getDrawingHorizontalLine: (_) =>
                const FlLine(color: kBgSurface, strokeWidth: 1),
          ),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            topTitles:
                const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles:
                const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 32,
                interval: step,
                getTitlesWidget: (v, _) => Text(v.toInt().toString(),
                    style: const TextStyle(color: kTextSec, fontSize: 10)),
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 22,
                interval: 1,
                getTitlesWidget: (v, _) {
                  final i = v.toInt();
                  if (i < 0 || i >= n || (n - 1 - i) % labelEvery != 0) {
                    return const SizedBox.shrink();
                  }
                  return Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(DateFormat('d/M').format(stats.days[i]),
                        style: const TextStyle(color: kTextSec, fontSize: 10)),
                  );
                },
              ),
            ),
          ),
          barGroups: [
            for (var i = 0; i < n; i++)
              BarChartGroupData(
                x: i,
                barsSpace: rod * 0.2,
                barRods: [
                  BarChartRodData(
                    toY: stats.viewsPerDay[i].toDouble(),
                    color: _kViewsBar,
                    width: rod,
                    borderRadius:
                        const BorderRadius.vertical(top: Radius.circular(2)),
                  ),
                  BarChartRodData(
                    toY: stats.visitorsPerDay[i].toDouble(),
                    color: kEmerald,
                    width: rod,
                    borderRadius:
                        const BorderRadius.vertical(top: Radius.circular(2)),
                  ),
                ],
              ),
          ],
        ),
      );
    });
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.title, required this.body});
  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 34, color: kTextSec),
            const SizedBox(height: 12),
            Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text(body,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: kTextSec, fontSize: 12.5, height: 1.45)),
          ],
        ),
      ),
    );
  }
}
