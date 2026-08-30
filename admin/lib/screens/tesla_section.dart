import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/maps_usage.dart';
import '../models/tesla_session.dart';
import '../services/maps_limits.dart';
import '../services/tesla_stats.dart';
import '../theme.dart';
import '../widgets/kpi_card.dart';

/// The chart's second series. The grid lines are drawn in kBgSurface, so a
/// sessions bar in that colour vanished into them; this one reads as a bar.
const Color _kSessionBar = Color(0xFF4C5C6B);

/// The Tesla tab: who uses tesla.geocharge.ge, how long for, and how much of
/// Google's free tier that is spending.
///
/// Pure — data in, pixels out — so it previews without Firebase, like the rest
/// of the dashboard. Two independent things share the tab because they answer
/// one question between them: the usage is what costs the money, and the free
/// tier is how much of it is left before it does.
class TeslaUsageView extends StatelessWidget {
  const TeslaUsageView({
    super.key,
    required this.sessions,
    required this.usage,
    required this.nameByUid,
    this.sessionsError,
    this.usageError,
    this.window = 30,
  });

  /// Visit rows for the window. `null` means "still loading".
  final List<TeslaSession>? sessions;

  /// Daily Google Maps usage rows. `null` means "still loading".
  final List<MapsUsageDay>? usage;

  /// uid → display name, from the user directory the panel already holds.
  final Map<String, String> nameByUid;

  final String? sessionsError;
  final String? usageError;
  final int window;

  static String _hm(Duration d) {
    if (d.inMinutes < 1) return '${d.inSeconds}s';
    if (d.inHours < 1) return '${d.inMinutes} min';
    final h = d.inHours;
    final m = d.inMinutes % 60;
    return m == 0 ? '${h}h' : '${h}h ${m}m';
  }

  String _who(TeslaUser u) {
    final name = nameByUid[u.uid] ?? '';
    if (name.isNotEmpty) return name;
    if (u.email.isNotEmpty) return u.email;
    return u.uid.substring(0, u.uid.length.clamp(0, 8));
  }

  @override
  Widget build(BuildContext context) {
    if (sessionsError != null) {
      return _Message(
        icon: Icons.lock_outline,
        title: 'Usage could not be read',
        body: '$sessionsError\n\nIf this says "permission-denied", the updated '
            'firestore.rules (teslaSessions) have not been deployed yet.',
      );
    }
    if (sessions == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final stats = TeslaStats.from(sessions!, window: window);

    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth;
      final isMobile = w < 680;
      final isDesktop = w >= 1080;
      final pad = isMobile ? 12.0 : 20.0;

      final limitsCard = _MapsLimitsCard(usage: usage, error: usageError);

      if (isDesktop) {
        return Padding(
          padding: EdgeInsets.all(pad),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _kpis(stats, w),
              const SizedBox(height: 16),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      flex: 3,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SizedBox(height: 220, child: _chartCard(stats)),
                          const SizedBox(height: 16),
                          Expanded(child: _usersCard(stats)),
                        ],
                      ),
                    ),
                    const SizedBox(width: 16),
                    SizedBox(
                      width: 340,
                      child: SingleChildScrollView(child: limitsCard),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      }

      return ListView(
        padding: EdgeInsets.all(pad),
        children: [
          _kpis(stats, w),
          const SizedBox(height: 16),
          SizedBox(height: 200, child: _chartCard(stats)),
          const SizedBox(height: 16),
          limitsCard,
          const SizedBox(height: 16),
          _usersCard(stats, scrollable: false),
        ],
      );
    });
  }

  Widget _kpis(TeslaStats s, double width) {
    final cards = <Widget>[
      KpiCard(
          label: 'Visitors today',
          value: '${s.todayVisitors}',
          icon: Icons.directions_car_filled,
          accent: kEmerald),
      KpiCard(
          label: 'Sessions today',
          value: '${s.todaySessions}',
          icon: Icons.play_circle_outline,
          accent: kEmerald),
      KpiCard(
          label: 'Avg session',
          value: _hm(s.avgSession),
          icon: Icons.timer_outlined,
          accent: kBlue),
      KpiCard(
          label: 'Drivers ($window d)',
          value: '${s.uniqueUsers}',
          icon: Icons.people_outline,
          accent: kBlue),
      KpiCard(
          label: 'Navigations',
          value: '${s.drives}',
          icon: Icons.navigation_outlined,
          accent: kAmber),
    ];
    final perRow = width >= 1080 ? 5 : (width >= 680 ? 3 : 2);
    const gap = 12.0;
    return LayoutBuilder(builder: (context, c) {
      final itemW = (c.maxWidth - (perRow - 1) * gap) / perRow;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: cards.map((w) => SizedBox(width: itemW, child: w)).toList(),
      );
    });
  }

  Widget _chartCard(TeslaStats s) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('Daily visitors',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                const Spacer(),
                _legendDot(kEmerald, 'drivers'),
                const SizedBox(width: 12),
                _legendDot(_kSessionBar, 'sessions'),
              ],
            ),
            const SizedBox(height: 10),
            Expanded(child: _VisitorsChart(stats: s)),
          ],
        ),
      ),
    );
  }

  Widget _legendDot(Color c, String label) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 9, height: 9, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
          const SizedBox(width: 5),
          Text(label, style: const TextStyle(color: kTextSec, fontSize: 11.5)),
        ],
      );

  Widget _usersCard(TeslaStats s, {bool scrollable = true}) {
    final table = DataTable(
      headingRowHeight: 40,
      dataRowMinHeight: 44,
      dataRowMaxHeight: 52,
      headingTextStyle: const TextStyle(
          color: kTextSec, fontSize: 11.5, fontWeight: FontWeight.w600),
      columns: const [
        DataColumn(label: Text('DRIVER')),
        DataColumn(label: Text('SESSIONS'), numeric: true),
        DataColumn(label: Text('DAYS'), numeric: true),
        DataColumn(label: Text('TOTAL TIME'), numeric: true),
        DataColumn(label: Text('AVG'), numeric: true),
        DataColumn(label: Text('NAVIGATIONS'), numeric: true),
        DataColumn(label: Text('LAST SEEN')),
      ],
      rows: [
        for (final u in s.users)
          DataRow(cells: [
            DataCell(Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(_who(u), style: const TextStyle(fontWeight: FontWeight.w500)),
                if (u.email.isNotEmpty && (nameByUid[u.uid] ?? '').isNotEmpty)
                  Text(u.email,
                      style: const TextStyle(color: kTextSec, fontSize: 11)),
              ],
            )),
            DataCell(Text('${u.sessions}')),
            DataCell(Text('${u.days.length}')),
            DataCell(Text(_hm(u.time))),
            DataCell(Text(_hm(u.avgSession))),
            DataCell(Text('${u.drives}')),
            DataCell(Text(
              u.lastSeen == null
                  ? '—'
                  : DateFormat('d MMM, HH:mm').format(u.lastSeen!),
              style: const TextStyle(fontSize: 12.5),
            )),
          ]),
      ],
    );

    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: scrollable ? MainAxisSize.max : MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Row(
              children: [
                const Text('Who uses the car app',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                const Spacer(),
                Text('${s.users.length} in $window days',
                    style: const TextStyle(color: kTextSec, fontSize: 12)),
              ],
            ),
          ),
          if (s.users.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 24),
              child: Text(
                'No sessions recorded yet. The car app starts writing them the '
                'moment the updated tesla.geocharge.ge is deployed and someone '
                'signs in.',
                style: TextStyle(color: kTextSec, fontSize: 13, height: 1.4),
              ),
            )
          else if (scrollable)
            Expanded(
              child: SingleChildScrollView(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: table,
                ),
              ),
            )
          else
            SingleChildScrollView(scrollDirection: Axis.horizontal, child: table),
        ],
      ),
    );
  }
}

/// Bars per day: drivers in front, sessions behind, so a day where one person
/// opened it six times cannot be mistaken for six people.
class _VisitorsChart extends StatelessWidget {
  const _VisitorsChart({required this.stats});
  final TeslaStats stats;

  @override
  Widget build(BuildContext context) {
    final n = stats.days.length;
    final maxV = [
      ...stats.sessionsPerDay,
      ...stats.visitorsPerDay,
      1,
    ].reduce((a, b) => a > b ? a : b).toDouble();
    final step = maxV <= 5 ? 1.0 : (maxV / 4).ceilToDouble();

    return BarChart(
      BarChartData(
        alignment: BarChartAlignment.spaceBetween,
        maxY: maxV,
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: step,
          getDrawingHorizontalLine: (_) =>
              const FlLine(color: kBgSurface, strokeWidth: 1),
        ),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 28,
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
                if (i % 5 != 0 || i >= n) return const SizedBox.shrink();
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
              barsSpace: 1,
              barRods: [
                BarChartRodData(
                  toY: stats.sessionsPerDay[i].toDouble(),
                  color: _kSessionBar,
                  width: 5,
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(2)),
                ),
                BarChartRodData(
                  toY: stats.visitorsPerDay[i].toDouble(),
                  color: kEmerald,
                  width: 5,
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(2)),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// The free-tier gauge: one bar per Google API, month against free tier and
/// today against the daily cap.
class _MapsLimitsCard extends StatefulWidget {
  const _MapsLimitsCard({required this.usage, this.error});
  final List<MapsUsageDay>? usage;
  final String? error;

  @override
  State<_MapsLimitsCard> createState() => _MapsLimitsCardState();
}

class _MapsLimitsCardState extends State<_MapsLimitsCard> {
  @override
  void initState() {
    super.initState();
    MapsLimits.I.addListener(_onLimits);
  }

  @override
  void dispose() {
    MapsLimits.I.removeListener(_onLimits);
    super.dispose();
  }

  void _onLimits() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final rows = widget.usage;
    final summary = rows == null ? null : mapsUsageSummary(rows);
    final monthName = DateFormat('MMMM').format(DateTime.now());
    final lastUpdate = (rows ?? const <MapsUsageDay>[])
        .map((r) => r.updatedAt)
        .whereType<DateTime>()
        .fold<DateTime?>(null, (a, b) => a == null || b.isAfter(a) ? b : a);

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text('Google Maps free tier',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                ),
                IconButton(
                  tooltip: 'Edit the limits',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.tune, size: 18),
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => const _LimitsDialog(),
                  ),
                ),
              ],
            ),
            Text(
              '$monthName against what Google gives away each month — or today '
              'against our daily cap, where the counter is raw requests.',
              style: const TextStyle(color: kTextSec, fontSize: 12, height: 1.35),
            ),
            const SizedBox(height: 14),
            if (widget.error != null)
              Text(
                'Usage could not be read: ${widget.error}',
                style: const TextStyle(color: kAmber, fontSize: 12, height: 1.4),
              )
            else if (summary == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (summary.every((u) => u.monthCalls == 0))
              const Text(
                'No usage recorded yet. The hourly pullMapsUsage function fills '
                'this in once it is deployed and its service account has '
                'Monitoring Viewer on the ev-charger-app-497408 project.',
                style: TextStyle(color: kTextSec, fontSize: 12.5, height: 1.4),
              )
            else
              for (final u in summary) _ApiBar(usage: u),
            if (lastUpdate != null) ...[
              const SizedBox(height: 6),
              Text(
                'Read from Cloud Monitoring ${DateFormat('d MMM, HH:mm').format(lastUpdate)}',
                style: const TextStyle(color: kTextSec, fontSize: 11),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ApiBar extends StatelessWidget {
  const _ApiBar({required this.usage});
  final ApiUsage usage;

  static final _n = NumberFormat.decimalPattern();

  /// The numbers under the bar, with the one the bar is drawn from first.
  /// An API counted in raw requests is led by today against the daily cap —
  /// the only pair here measured in the same unit — and its month total
  /// follows as context rather than as a fraction of a billed free tier.
  static String _caption(ApiUsage u) {
    final today = u.limit.dailyCap > 0
        ? 'today ${_n.format(u.todayCalls)} / ${_n.format(u.limit.dailyCap)} cap'
        : '';
    if (u.limit.rawRequests) {
      return today.isEmpty
          ? '${_n.format(u.monthCalls)} requests this month'
          : '$today · ${_n.format(u.monthCalls)} requests this month';
    }
    final month =
        '${_n.format(u.monthCalls)} / ${_n.format(u.limit.freeMonthly)} this month';
    return today.isEmpty ? month : '$month · $today';
  }

  @override
  Widget build(BuildContext context) {
    final left = usage.percentLeft;
    final colour = left <= 10
        ? const Color(0xFFEF4444)
        : (left <= 30 || usage.willOverrun ? kAmber : kEmerald);

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(usage.limit.label,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
              ),
              Text(
                '${left.toStringAsFixed(left.abs() < 10 ? 1 : 0)}% left',
                style: TextStyle(
                    color: colour, fontSize: 13, fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: usage.gaugeFraction.clamp(0, 1).toDouble(),
              minHeight: 7,
              backgroundColor: kBgSurface,
              valueColor: AlwaysStoppedAnimation<Color>(colour),
            ),
          ),
          const SizedBox(height: 5),
          Text(
            _caption(usage),
            style: const TextStyle(color: kTextSec, fontSize: 11.5),
          ),
          if (usage.limit.rawRequests)
            const Padding(
              padding: EdgeInsets.only(top: 3),
              child: Text(
                'Raw requests, not billed calls: one search is 3-6 of them but '
                'bills as one.',
                style: TextStyle(color: kTextSec, fontSize: 11.5, height: 1.35),
              ),
            ),
          if (usage.willOverrun)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                'On track for ${_n.format(usage.projectedMonth)} by month end — over the free tier.',
                style: const TextStyle(color: kAmber, fontSize: 11.5),
              ),
            ),
          if (usage.stale)
            const Padding(
              padding: EdgeInsets.only(top: 3),
              child: Text(
                'Last refresh could not read this API — the figure is older than the others.',
                style: TextStyle(color: kAmber, fontSize: 11.5),
              ),
            ),
        ],
      ),
    );
  }
}

/// Edit the ceilings. Google moves its price list and we move our own caps;
/// neither should need a rebuild of this panel.
class _LimitsDialog extends StatefulWidget {
  const _LimitsDialog();

  @override
  State<_LimitsDialog> createState() => _LimitsDialogState();
}

class _LimitsDialogState extends State<_LimitsDialog> {
  late final Map<String, TextEditingController> _free = {
    for (final l in MapsLimits.I.all)
      l.key: TextEditingController(text: l.freeMonthly.toString()),
  };
  late final Map<String, TextEditingController> _cap = {
    for (final l in MapsLimits.I.all)
      l.key: TextEditingController(text: l.dailyCap.toString()),
  };

  @override
  void dispose() {
    for (final c in [..._free.values, ..._cap.values]) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    for (final l in MapsLimits.I.all) {
      MapsLimits.I.update(
        l.key,
        freeMonthly: int.tryParse(_free[l.key]!.text.trim()),
        dailyCap: int.tryParse(_cap[l.key]!.text.trim()),
      );
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: kBgCard,
      title: const Text('Free tiers and daily caps'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Free calls per month come from Google\'s price list; the daily '
                'cap is the quota set by hand on the ev-charger-app-497408 '
                'project. A cap makes calls fail rather than bill.',
                style: TextStyle(color: kTextSec, fontSize: 12.5, height: 1.4),
              ),
              const SizedBox(height: 16),
              for (final l in MapsLimits.I.all) ...[
                Text(l.label,
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                if (l.note.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2, bottom: 6),
                    child: Text(l.note,
                        style: const TextStyle(
                            color: kTextSec, fontSize: 11.5, height: 1.35)),
                  ),
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: _free[l.key],
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Free / month'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: _cap[l.key],
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Daily cap'),
                    ),
                  ),
                ]),
                const SizedBox(height: 14),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            MapsLimits.I.reset();
            Navigator.of(context).pop();
          },
          child: const Text('Reset'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
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
                style: const TextStyle(color: kTextSec, fontSize: 12.5, height: 1.45)),
          ],
        ),
      ),
    );
  }
}
