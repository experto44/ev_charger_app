import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_strings.dart';
import '../services/ad_service.dart';
import '../services/expenses_service.dart';
import '../services/purchase_service.dart';

// ── Palette (mirrors the profile screen) ──────────────────────────────────────
const _bgDark    = Color(0xFF1A1A1A);
const _bgCard    = Color(0xFF252525);
const _bgSurface = Color(0xFF2E2E2E);
const _emerald   = Color(0xFF00C896);
const _blue      = Color(0xFF4C9AFF);
const _textPri   = Color(0xFFFFFFFF);
const _textSec   = Color(0xFF9E9E9E);
const _errorRed  = Color(0xFFCF6679);

/// "How much is this car costing me" — the driver's own charging-expenses log.
///
/// Every charge is typed in by hand: a paid one carries the amount they paid in
/// the provider's app, a home one is costed from their battery, tariff and
/// charging loss (see [ExpensesService]).
class ExpensesScreen extends StatefulWidget {
  const ExpensesScreen({super.key});

  @override
  State<ExpensesScreen> createState() => _ExpensesScreenState();
}

class _ExpensesScreenState extends State<ExpensesScreen> {
  final _svc = ExpensesService.I;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  /// The cache paints first and the sync runs behind it, so the list is on
  /// screen immediately even on a slow connection.
  Future<void> _boot() async {
    await _svc.load(sync: false);
    if (!mounted) { return; }
    setState(() => _loading = false);
    _svc.sync();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bgDark,
      // Free-tier banner. Rebuilds when the ads SDK finishes initialising (on
      // iOS that is after the ATT prompt) and when premium changes, so it turns
      // up as soon as it can and vanishes the moment it should not be there.
      bottomNavigationBar: ValueListenableBuilder<bool>(
        valueListenable: AdService.I.ready,
        builder: (_, __, ___) => ValueListenableBuilder<bool>(
          valueListenable: PurchaseService.I.isPremium,
          builder: (_, __, ___) =>
              AdService.I.bottomBanner() ?? const SizedBox.shrink(),
        ),
      ),
      appBar: AppBar(
        backgroundColor: _bgCard,
        elevation: 0,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded,
              color: _textPri, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          AppStrings.expensesTitle,
          style: AppStrings.font(const TextStyle(
              color: _textPri, fontSize: 17, fontWeight: FontWeight.w600)),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.tune_rounded, color: _textSec, size: 22),
            tooltip: AppStrings.expensesSettings,
            onPressed: _openSettings,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: _emerald,
        onPressed: _addEntry,
        child: const Icon(Icons.add_rounded, color: Colors.black, size: 28),
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: _emerald, strokeWidth: 2))
          : AppStrings.wrap(
              ValueListenableBuilder<int>(
                valueListenable: _svc.revision,
                builder: (_, __, ___) => _body(),
              ),
            ),
    );
  }

  Widget _body() {
    final entries = _svc.entries;
    return RefreshIndicator(
      color: _emerald,
      backgroundColor: _bgCard,
      onRefresh: () => _svc.sync(),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 100),
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          _TotalsCard(
            month: _svc.totalForMonth(DateTime.now()),
            allTime: _svc.totalAll,
          ),
          const SizedBox(height: 20),
          if (entries.isNotEmpty) ...[
            _SplitCard(
              home: _svc.totalForKind(ChargeKind.home),
              paid: _svc.totalForKind(ChargeKind.paid),
            ),
            const SizedBox(height: 20),
            _MonthsChart(months: _svc.monthlyTotals(6)),
            const SizedBox(height: 24),
            _Label(AppStrings.expensesRecords),
            const SizedBox(height: 8),
            ..._recordTiles(entries),
          ] else
            const _EmptyState(),
          if (!_svc.isSignedIn) ...[
            const SizedBox(height: 24),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.cloud_off_rounded, color: _textSec, size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    AppStrings.expensesSignedOutHint,
                    style: AppStrings.font(const TextStyle(
                        color: _textSec, fontSize: 12, height: 1.35)),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// Records, newest first, with a heading (and subtotal) per month.
  List<Widget> _recordTiles(List<ExpenseEntry> entries) {
    final out = <Widget>[];
    int? lastYear, lastMonth;
    for (final e in entries) {
      if (e.date.year != lastYear || e.date.month != lastMonth) {
        lastYear = e.date.year;
        lastMonth = e.date.month;
        final subtotal = entries
            .where((x) => x.date.year == lastYear && x.date.month == lastMonth)
            .fold<double>(0, (s, x) => s + x.amount);
        out.add(Padding(
          padding: EdgeInsets.only(top: out.isEmpty ? 4 : 18, bottom: 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${AppStrings.monthLong(e.date.month)} ${e.date.year}',
                  style: AppStrings.font(const TextStyle(
                      color: _textPri, fontSize: 14, fontWeight: FontWeight.w600)),
                ),
              ),
              Text(
                _money(subtotal),
                style: const TextStyle(
                    color: _textSec, fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ));
      }
      out.add(_RecordTile(
        entry: e,
        onEdit: () => _editEntry(e),
        onDelete: () => _confirmDelete(e),
      ));
      out.add(const SizedBox(height: 8));
    }
    return out;
  }

  // ── Actions ────────────────────────────────────────────────────────────────

  Future<void> _openSettings() async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(builder: (_) => const ExpenseSettingsScreen()),
    );
    if (mounted) { setState(() {}); }
  }

  Future<void> _addEntry() async {
    final kind = await showModalBottomSheet<ChargeKind>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => AppStrings.wrap(const _KindSheet()),
    );
    if (kind == null || !mounted) { return; }
    await _openEntrySheet(kind: kind);
  }

  Future<void> _editEntry(ExpenseEntry e) =>
      _openEntrySheet(kind: e.kind, existing: e);

  Future<void> _openEntrySheet({
    required ChargeKind kind,
    ExpenseEntry? existing,
  }) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _EntrySheet(kind: kind, existing: existing),
    );
    if (saved == true && mounted) { setState(() {}); }
  }

  Future<void> _confirmDelete(ExpenseEntry e) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AppStrings.wrap(AlertDialog(
        backgroundColor: _bgCard,
        title: Text(AppStrings.expensesDeleteTitle,
            style: AppStrings.font(
                const TextStyle(color: _textPri, fontSize: 17))),
        content: Text(AppStrings.expensesDeleteBody,
            style: AppStrings.font(
                const TextStyle(color: _textSec, fontSize: 14))),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(AppStrings.cancel,
                style: AppStrings.font(const TextStyle(color: _textSec))),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(AppStrings.delete,
                style: AppStrings.font(const TextStyle(color: _errorRed))),
          ),
        ],
      )),
    );
    if (ok != true) { return; }
    await _svc.remove(e.id);
    if (!mounted) { return; }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      backgroundColor: _bgSurface,
      content: Text(AppStrings.expensesDeleted,
          style: AppStrings.font(const TextStyle(color: _textPri))),
    ));
  }
}

// ── Formatting helpers ────────────────────────────────────────────────────────

/// "12.40 ₾". Two decimals everywhere, so columns of numbers line up.
String _money(double v) => '${v.toStringAsFixed(2)} ₾';

String _energy(double v) => '${v.toStringAsFixed(1)} kWh';

String _dateLabel(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';

// ── Summary cards ─────────────────────────────────────────────────────────────

class _TotalsCard extends StatelessWidget {
  const _TotalsCard({required this.month, required this.allTime});
  final double month;
  final double allTime;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
      decoration: BoxDecoration(
        color: _bgCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _bgSurface),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            AppStrings.expensesThisMonth,
            style: AppStrings.font(const TextStyle(
                color: _textSec,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.6)),
          ),
          const SizedBox(height: 6),
          Text(
            _money(month),
            style: const TextStyle(
                color: _emerald, fontSize: 32, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 14),
          const Divider(color: _bgSurface, height: 1),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Text(
                  AppStrings.expensesAllTime,
                  style: AppStrings.font(
                      const TextStyle(color: _textSec, fontSize: 13)),
                ),
              ),
              Text(
                _money(allTime),
                style: const TextStyle(
                    color: _textPri, fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Home against paid, over the whole history: one stacked bar and two legend
/// rows carrying the amount and its share.
class _SplitCard extends StatelessWidget {
  const _SplitCard({required this.home, required this.paid});
  final double home;
  final double paid;

  @override
  Widget build(BuildContext context) {
    final total = home + paid;
    // flex takes ints, so shares are expressed in tenths of a percent; a
    // non-zero side always keeps at least a sliver of the bar.
    final homeFlex = total <= 0 ? 1 : (home / total * 1000).round().clamp(1, 1000);
    final paidFlex = total <= 0 ? 1 : (paid / total * 1000).round().clamp(1, 1000);

    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      decoration: BoxDecoration(
        color: _bgCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _bgSurface),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              height: 10,
              child: Row(
                children: [
                  if (home > 0)
                    Expanded(flex: homeFlex, child: Container(color: _emerald)),
                  if (paid > 0)
                    Expanded(flex: paidFlex, child: Container(color: _blue)),
                  if (total <= 0)
                    Expanded(child: Container(color: _bgSurface)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          _legendRow(_emerald, AppStrings.expensesHome, home, total),
          const SizedBox(height: 8),
          _legendRow(_blue, AppStrings.expensesPaid, paid, total),
        ],
      ),
    );
  }

  Widget _legendRow(Color c, String label, double value, double total) {
    final share = total <= 0 ? 0 : (value / total * 100).round();
    return Row(
      children: [
        Container(
          width: 10, height: 10,
          decoration: BoxDecoration(color: c, shape: BoxShape.circle),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(label,
              style:
                  AppStrings.font(const TextStyle(color: _textSec, fontSize: 13))),
        ),
        Text('$share%',
            style: const TextStyle(color: _textSec, fontSize: 12)),
        const SizedBox(width: 12),
        Text(
          _money(value),
          style: const TextStyle(
              color: _textPri, fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}

/// Six months of spending as stacked bars, home under paid.
class _MonthsChart extends StatelessWidget {
  const _MonthsChart({required this.months});
  final List<MonthTotal> months;

  static const double _barArea = 96;

  @override
  Widget build(BuildContext context) {
    final peak = months.fold<double>(
        0, (m, e) => e.total > m ? e.total : m);

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 16, 14, 12),
      decoration: BoxDecoration(
        color: _bgCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _bgSurface),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 14),
            child: Text(
              AppStrings.expensesByMonth,
              style: AppStrings.font(const TextStyle(
                  color: _textSec,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.6)),
            ),
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: months.map((m) {
              // An empty month still shows a 2px stub, so the row reads as a
              // timeline rather than a gap.
              final h = peak <= 0 ? 0.0 : (m.total / peak) * _barArea;
              final homeH = m.total <= 0 ? 0.0 : h * (m.home / m.total);
              final paidH = m.total <= 0 ? 0.0 : h * (m.paid / m.total);
              return Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      height: 16,
                      child: m.total > 0
                          ? FittedBox(
                              child: Text(
                                m.total.toStringAsFixed(0),
                                style: const TextStyle(
                                    color: _textSec, fontSize: 10),
                              ),
                            )
                          : null,
                    ),
                    Container(
                      height: _barArea,
                      alignment: Alignment.bottomCenter,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            if (paidH > 0)
                              Container(
                                height: paidH.clamp(2.0, _barArea).toDouble(),
                                decoration: const BoxDecoration(
                                  color: _blue,
                                  borderRadius: BorderRadius.vertical(
                                      top: Radius.circular(3)),
                                ),
                              ),
                            if (homeH > 0)
                              Container(
                                height: homeH.clamp(2.0, _barArea).toDouble(),
                                decoration: BoxDecoration(
                                  color: _emerald,
                                  // Only the top of the whole bar is rounded,
                                  // so a stacked pair still reads as one bar.
                                  borderRadius: paidH > 0
                                      ? null
                                      : const BorderRadius.vertical(
                                          top: Radius.circular(3)),
                                ),
                              ),
                            if (m.total <= 0)
                              Container(height: 2, color: _bgSurface),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      AppStrings.monthShort(m.month.month),
                      style: AppStrings.font(
                          const TextStyle(color: _textSec, fontSize: 11)),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 60),
        child: Column(
          children: [
            const Icon(Icons.receipt_long_rounded, color: _bgSurface, size: 64),
            const SizedBox(height: 18),
            Text(
              AppStrings.expensesEmptyTitle,
              style: AppStrings.font(const TextStyle(
                  color: _textPri, fontSize: 16, fontWeight: FontWeight.w600)),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                AppStrings.expensesEmptyBody,
                textAlign: TextAlign.center,
                style: AppStrings.font(const TextStyle(
                    color: _textSec, fontSize: 13, height: 1.4)),
              ),
            ),
          ],
        ),
      );
}

// ── One record ────────────────────────────────────────────────────────────────

class _RecordTile extends StatelessWidget {
  const _RecordTile({
    required this.entry,
    required this.onEdit,
    required this.onDelete,
  });
  final ExpenseEntry entry;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final home = entry.isHome;
    final subtitle = StringBuffer(_dateLabel(entry.date));
    if (home && entry.fromPercent != null && entry.toPercent != null) {
      subtitle.write('  ·  ');
      subtitle.write(
          AppStrings.expensesRange(entry.fromPercent!, entry.toPercent!));
      if (entry.kwh != null) {
        subtitle.write('  ·  ');
        subtitle.write(_energy(entry.kwh!));
      }
    }

    return GestureDetector(
      onTap: onEdit,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: _bgCard,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _bgSurface),
        ),
        child: Row(
          children: [
            Container(
              width: 36, height: 36,
              decoration: BoxDecoration(
                color: (home ? _emerald : _blue).withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: Icon(
                home ? Icons.home_rounded : Icons.ev_station_rounded,
                color: home ? _emerald : _blue,
                size: 19,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    home
                        ? AppStrings.expensesHomeTitle
                        : AppStrings.expensesPaidTitle,
                    style: AppStrings.font(const TextStyle(
                        color: _textPri,
                        fontSize: 14,
                        fontWeight: FontWeight.w600)),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle.toString(),
                    style: const TextStyle(color: _textSec, fontSize: 11.5),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              _money(entry.amount),
              style: const TextStyle(
                  color: _textPri, fontSize: 15, fontWeight: FontWeight.w700),
            ),
            PopupMenuButton<String>(
              color: _bgSurface,
              icon: const Icon(Icons.more_vert_rounded,
                  color: _textSec, size: 18),
              onSelected: (v) => v == 'edit' ? onEdit() : onDelete(),
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'edit',
                  child: Text(AppStrings.expensesEdit,
                      style: AppStrings.font(
                          const TextStyle(color: _textPri, fontSize: 14))),
                ),
                PopupMenuItem(
                  value: 'delete',
                  child: Text(AppStrings.delete,
                      style: AppStrings.font(
                          const TextStyle(color: _errorRed, fontSize: 14))),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ── "How did you charge?" ─────────────────────────────────────────────────────

class _KindSheet extends StatelessWidget {
  const _KindSheet();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(
          20, 18, 20, 20 + MediaQuery.of(context).padding.bottom),
      decoration: const BoxDecoration(
        color: _bgCard,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 40, height: 4,
              decoration: BoxDecoration(
                color: _bgSurface,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 18),
          Text(
            AppStrings.expensesAddTitle,
            style: AppStrings.font(const TextStyle(
                color: _textPri, fontSize: 17, fontWeight: FontWeight.w600)),
          ),
          const SizedBox(height: 16),
          _option(
            context,
            icon: Icons.ev_station_rounded,
            color: _blue,
            label: AppStrings.expensesPaidCharge,
            kind: ChargeKind.paid,
          ),
          const SizedBox(height: 10),
          _option(
            context,
            icon: Icons.home_rounded,
            color: _emerald,
            label: AppStrings.expensesHomeCharge,
            kind: ChargeKind.home,
          ),
        ],
      ),
    );
  }

  Widget _option(
    BuildContext context, {
    required IconData icon,
    required Color color,
    required String label,
    required ChargeKind kind,
  }) =>
      GestureDetector(
        onTap: () => Navigator.pop(context, kind),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          decoration: BoxDecoration(
            color: _bgSurface,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              Icon(icon, color: color, size: 22),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  label,
                  style: AppStrings.font(const TextStyle(
                      color: _textPri,
                      fontSize: 15,
                      fontWeight: FontWeight.w600)),
                ),
              ),
              const Icon(Icons.chevron_right_rounded, color: _textSec, size: 20),
            ],
          ),
        ),
      );
}

// ── Add / edit ────────────────────────────────────────────────────────────────

class _EntrySheet extends StatefulWidget {
  const _EntrySheet({required this.kind, this.existing});
  final ChargeKind kind;
  final ExpenseEntry? existing;

  @override
  State<_EntrySheet> createState() => _EntrySheetState();
}

class _EntrySheetState extends State<_EntrySheet> {
  final _amountCtrl = TextEditingController();
  final _fromCtrl   = TextEditingController();
  final _toCtrl     = TextEditingController();

  late DateTime _date;
  String _error = '';
  bool _saving = false;

  bool get _isHome => widget.kind == ChargeKind.home;

  /// The numbers this sheet costs a home charge with. Editing an existing
  /// record reuses the settings it was saved with, so correcting a typo in the
  /// percentages cannot silently reprice an old charge at today's tariff.
  ExpenseSettings get _settings {
    final e = widget.existing;
    if (e != null && e.isHome && e.batteryKwh != null && e.tariff != null) {
      return ExpenseSettings(
        batteryKwh:  e.batteryKwh,
        tariff:      e.tariff,
        lossPercent: e.lossPercent ?? ExpenseSettings.kDefaultLossPercent,
      );
    }
    return ExpensesService.I.settings;
  }

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _date = e?.date ?? DateTime.now();
    if (e != null) {
      _amountCtrl.text = e.amount.toStringAsFixed(2);
      if (e.fromPercent != null) { _fromCtrl.text = '${e.fromPercent}'; }
      if (e.toPercent   != null) { _toCtrl.text   = '${e.toPercent}'; }
    }
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _fromCtrl.dispose();
    _toCtrl.dispose();
    super.dispose();
  }

  /// Parses a typed number, tolerating the comma decimal separator a Georgian
  /// keyboard offers and a separator the driver has not typed digits after yet.
  double? _num(String s) {
    var t = s.trim().replaceAll(',', '.');
    if (t.endsWith('.')) { t = t.substring(0, t.length - 1); }
    return double.tryParse(t);
  }

  int? _percent(String s) {
    final v = int.tryParse(s.trim());
    if (v == null || v < 0 || v > 100) { return null; }
    return v;
  }

  double? get _computedCost {
    final from = _percent(_fromCtrl.text);
    final to   = _percent(_toCtrl.text);
    if (from == null || to == null || to <= from) { return null; }
    return _settings.costFor(from, to);
  }

  double? get _computedKwh {
    final from = _percent(_fromCtrl.text);
    final to   = _percent(_toCtrl.text);
    if (from == null || to == null || to <= from) { return null; }
    return _settings.kwhFor(from, to);
  }

  Future<void> _pickDate() async {
    final now   = DateTime.now();
    final first = DateTime(now.year - 5);
    // A record synced from another device could sit outside the range the
    // picker offers, and showDatePicker asserts rather than coping.
    final initial = _date.isAfter(now)
        ? now
        : (_date.isBefore(first) ? first : _date);
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: first,
      lastDate: now,
      builder: (ctx, child) => Theme(
        data: ThemeData.dark().copyWith(
          colorScheme: const ColorScheme.dark(
            primary: _emerald,
            onPrimary: Colors.black,
            surface: _bgCard,
            onSurface: _textPri,
          ),
        ),
        child: child!,
      ),
    );
    if (picked != null) { setState(() => _date = picked); }
  }

  Future<void> _save() async {
    if (_saving) { return; }
    final existing = widget.existing;

    double amount;
    int? from, to;
    double? kwh;

    if (_isHome) {
      from = _percent(_fromCtrl.text);
      to   = _percent(_toCtrl.text);
      if (from == null || to == null || to <= from) {
        setState(() => _error = AppStrings.expensesNeedPercents);
        return;
      }
      final cost = _settings.costFor(from, to);
      kwh = _settings.kwhFor(from, to);
      if (cost == null || kwh == null) {
        setState(() => _error = AppStrings.expensesSettingsNeeded);
        return;
      }
      amount = cost;
    } else {
      final typed = _num(_amountCtrl.text);
      if (typed == null || typed <= 0) {
        setState(() => _error = AppStrings.expensesNeedAmount);
        return;
      }
      amount = typed;
    }

    setState(() { _saving = true; _error = ''; });

    final entry = ExpenseEntry(
      id: existing?.id ?? ExpensesService.newId(),
      date: DateTime(_date.year, _date.month, _date.day),
      kind: widget.kind,
      amount: amount,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
      fromPercent: _isHome ? from : null,
      toPercent:   _isHome ? to : null,
      // Stamped in, never recomputed: changing the car or the tariff later must
      // not rewrite what an old charge cost.
      batteryKwh:  _isHome ? _settings.batteryKwh : null,
      tariff:      _isHome ? _settings.tariff : null,
      lossPercent: _isHome ? _settings.lossPercent : null,
      kwh:         _isHome ? kwh : null,
    );

    try {
      await ExpensesService.I.upsert(entry);
    } catch (_) {
      // The cache write is the only step that can fail here (the network side
      // is best-effort), and a stuck spinner would hide the record the driver
      // just typed.
      if (mounted) {
        setState(() { _saving = false; _error = AppStrings.expensesSaveFailed; });
      }
      return;
    }
    if (mounted) { Navigator.pop(context, true); }
  }

  @override
  Widget build(BuildContext context) {
    final needsSettings = _isHome && !_settings.isComplete;

    return AppStrings.wrap(Padding(
      // Lifts the sheet above the keyboard.
      padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        padding: EdgeInsets.fromLTRB(
            20, 14, 20, 20 + MediaQuery.of(context).padding.bottom),
        decoration: const BoxDecoration(
          color: _bgCard,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40, height: 4,
                  decoration: BoxDecoration(
                    color: _bgSurface,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                _isHome
                    ? AppStrings.expensesHomeTitle
                    : AppStrings.expensesPaidTitle,
                style: AppStrings.font(const TextStyle(
                    color: _textPri, fontSize: 17, fontWeight: FontWeight.w600)),
              ),
              const SizedBox(height: 6),
              Text(
                _isHome ? AppStrings.expensesHomeHint : AppStrings.expensesPaidHint,
                style: AppStrings.font(const TextStyle(
                    color: _textSec, fontSize: 12.5, height: 1.35)),
              ),
              const SizedBox(height: 18),

              if (needsSettings) ...[
                _SettingsPrompt(onDone: () => setState(() {})),
              ] else if (_isHome) ...[
                Row(
                  children: [
                    Expanded(
                      child: _NumberField(
                        controller: _fromCtrl,
                        label: AppStrings.expensesFromPercent,
                        suffix: '%',
                        icon: Icons.battery_2_bar_rounded,
                        decimal: false,
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _NumberField(
                        controller: _toCtrl,
                        label: AppStrings.expensesToPercent,
                        suffix: '%',
                        icon: Icons.battery_full_rounded,
                        decimal: false,
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                _ResultPreview(kwh: _computedKwh, cost: _computedCost),
              ] else ...[
                _NumberField(
                  controller: _amountCtrl,
                  label: AppStrings.expensesAmount,
                  suffix: '₾',
                  icon: Icons.payments_outlined,
                  decimal: true,
                  autofocus: widget.existing == null,
                  onChanged: (_) => setState(() {}),
                ),
              ],

              if (!needsSettings) ...[
                const SizedBox(height: 16),
                _Label(AppStrings.expensesDate),
                const SizedBox(height: 8),
                GestureDetector(
                  onTap: _pickDate,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 14),
                    decoration: BoxDecoration(
                      color: _bgSurface,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.calendar_today_rounded,
                            color: _textSec, size: 17),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            _dateLabel(_date),
                            style: const TextStyle(
                                color: _textPri, fontSize: 15),
                          ),
                        ),
                        const Icon(Icons.chevron_right_rounded,
                            color: _textSec, size: 20),
                      ],
                    ),
                  ),
                ),
                if (_error.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.error_outline_rounded,
                          color: _errorRed, size: 16),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _error,
                          style: AppStrings.font(const TextStyle(
                              color: _errorRed, fontSize: 12.5, height: 1.3)),
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 20),
                GestureDetector(
                  onTap: _save,
                  child: Container(
                    height: 52,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: _emerald,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: _saving
                        ? const SizedBox(
                            width: 20, height: 20,
                            child: CircularProgressIndicator(
                                color: Colors.black, strokeWidth: 2),
                          )
                        : Text(
                            AppStrings.save,
                            style: AppStrings.font(const TextStyle(
                                color: Colors.black,
                                fontSize: 15,
                                fontWeight: FontWeight.w700)),
                          ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    ));
  }
}

/// Shown inside the home-charge sheet while the battery/tariff are unknown —
/// there is nothing to compute a cost from until they are filled in.
class _SettingsPrompt extends StatelessWidget {
  const _SettingsPrompt({required this.onDone});
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: _bgSurface,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.info_outline_rounded,
                    color: _textSec, size: 18),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    AppStrings.expensesSettingsNeeded,
                    style: AppStrings.font(const TextStyle(
                        color: _textPri, fontSize: 13, height: 1.35)),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          GestureDetector(
            onTap: () async {
              await Navigator.push<void>(
                context,
                MaterialPageRoute(builder: (_) => const ExpenseSettingsScreen()),
              );
              onDone();
            },
            child: Container(
              height: 50,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: _emerald,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Text(
                AppStrings.expensesOpenSettings,
                style: AppStrings.font(const TextStyle(
                    color: Colors.black,
                    fontSize: 15,
                    fontWeight: FontWeight.w700)),
              ),
            ),
          ),
        ],
      );
}

/// Live "this is what it will cost" line under the two percentage fields.
class _ResultPreview extends StatelessWidget {
  const _ResultPreview({required this.kwh, required this.cost});
  final double? kwh;
  final double? cost;

  @override
  Widget build(BuildContext context) {
    final known = kwh != null && cost != null;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: _emerald.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _emerald.withValues(alpha: 0.35)),
      ),
      // Two columns rather than one row of four items: the Georgian labels are
      // long enough to overflow a 360dp phone when they all sit side by side.
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  AppStrings.expensesEnergy,
                  style: AppStrings.font(
                      const TextStyle(color: _textSec, fontSize: 12)),
                ),
                const SizedBox(height: 4),
                Text(
                  known ? _energy(kwh!) : '—',
                  style: const TextStyle(
                      color: _textPri, fontSize: 14, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  AppStrings.expensesEstimated,
                  style: AppStrings.font(
                      const TextStyle(color: _textSec, fontSize: 12)),
                ),
                const SizedBox(height: 2),
                FittedBox(
                  child: Text(
                    known ? _money(cost!) : '—',
                    style: const TextStyle(
                        color: _emerald,
                        fontSize: 20,
                        fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Settings (battery, tariff, loss) ──────────────────────────────────────────

class ExpenseSettingsScreen extends StatefulWidget {
  const ExpenseSettingsScreen({super.key});

  @override
  State<ExpenseSettingsScreen> createState() => _ExpenseSettingsScreenState();
}

class _ExpenseSettingsScreenState extends State<ExpenseSettingsScreen> {
  final _batteryCtrl = TextEditingController();
  final _tariffCtrl  = TextEditingController();
  final _lossCtrl    = TextEditingController();
  String _error = '';
  bool _saved = false;

  @override
  void initState() {
    super.initState();
    final s = ExpensesService.I.settings;
    if (s.batteryKwh != null) { _batteryCtrl.text = _trim(s.batteryKwh!); }
    if (s.tariff != null)     { _tariffCtrl.text  = _trim(s.tariff!); }
    _lossCtrl.text = _trim(s.lossPercent);
  }

  @override
  void dispose() {
    _batteryCtrl.dispose();
    _tariffCtrl.dispose();
    _lossCtrl.dispose();
    super.dispose();
  }

  /// 60.0 → "60", 0.29 → "0.29": no trailing zeros in an editable field.
  static String _trim(double v) {
    final s = v.toStringAsFixed(2);
    return s.endsWith('.00') ? s.substring(0, s.length - 3) : s;
  }

  double? _num(String s) => double.tryParse(s.trim().replaceAll(',', '.'));

  Future<void> _save() async {
    final battery = _num(_batteryCtrl.text);
    final tariff  = _num(_tariffCtrl.text);
    final loss    = _num(_lossCtrl.text) ?? ExpenseSettings.kDefaultLossPercent;

    if (battery == null || battery <= 0 || tariff == null || tariff <= 0) {
      setState(() => _error = AppStrings.expensesNeedSettingsValues);
      return;
    }

    await ExpensesService.I.saveSettings(ExpenseSettings(
      batteryKwh:  battery,
      tariff:      tariff,
      lossPercent: loss.clamp(0, 50).toDouble(),
    ));
    if (!mounted) { return; }
    setState(() { _error = ''; _saved = true; });
    await Future<void>.delayed(const Duration(milliseconds: 700));
    if (mounted) { Navigator.pop(context); }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bgDark,
      appBar: AppBar(
        backgroundColor: _bgCard,
        elevation: 0,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded,
              color: _textPri, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          AppStrings.expensesSettings,
          style: AppStrings.font(const TextStyle(
              color: _textPri, fontSize: 17, fontWeight: FontWeight.w600)),
        ),
      ),
      body: AppStrings.wrap(SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 40),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _NumberField(
              controller: _batteryCtrl,
              label: AppStrings.expensesBattery,
              suffix: 'kWh',
              icon: Icons.battery_charging_full_rounded,
              decimal: true,
            ),
            const SizedBox(height: 6),
            Text(
              AppStrings.expensesBatteryHint,
              style: AppStrings.font(const TextStyle(
                  color: _textSec, fontSize: 12, height: 1.35)),
            ),
            const SizedBox(height: 22),
            _NumberField(
              controller: _tariffCtrl,
              label: AppStrings.expensesTariff,
              suffix: '₾/kWh',
              icon: Icons.bolt_rounded,
              decimal: true,
            ),
            const SizedBox(height: 6),
            Text(
              AppStrings.expensesTariffHint,
              style: AppStrings.font(const TextStyle(
                  color: _textSec, fontSize: 12, height: 1.35)),
            ),
            const SizedBox(height: 22),
            _NumberField(
              controller: _lossCtrl,
              label: AppStrings.expensesLoss,
              suffix: '%',
              icon: Icons.change_circle_outlined,
              decimal: true,
            ),
            const SizedBox(height: 6),
            Text(
              AppStrings.expensesLossHint,
              style: AppStrings.font(const TextStyle(
                  color: _textSec, fontSize: 12, height: 1.35)),
            ),
            if (_error.isNotEmpty) ...[
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.error_outline_rounded,
                      color: _errorRed, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _error,
                      style: AppStrings.font(const TextStyle(
                          color: _errorRed, fontSize: 12.5, height: 1.3)),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 32),
            GestureDetector(
              onTap: _save,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                height: 52,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: _saved ? _bgCard : _emerald,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: _emerald),
                ),
                child: Text(
                  _saved ? AppStrings.savedExclaim : AppStrings.save,
                  style: AppStrings.font(TextStyle(
                      color: _saved ? _emerald : Colors.black,
                      fontSize: 15,
                      fontWeight: FontWeight.w700)),
                ),
              ),
            ),
          ],
        ),
      )),
    );
  }
}

// ── Small shared widgets ──────────────────────────────────────────────────────

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: AppStrings.font(const TextStyle(
          color: _textSec,
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.6,
        )),
      );
}

class _NumberField extends StatelessWidget {
  const _NumberField({
    required this.controller,
    required this.label,
    required this.suffix,
    required this.icon,
    required this.decimal,
    this.onChanged,
    this.autofocus = false,
  });

  final TextEditingController controller;
  final String label;
  final String suffix;
  final IconData icon;
  final bool decimal;
  final ValueChanged<String>? onChanged;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Label(label),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            color: _bgSurface,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              const SizedBox(width: 14),
              Icon(icon, color: _textSec, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: controller,
                  autofocus: autofocus,
                  onChanged: onChanged,
                  keyboardType: TextInputType.numberWithOptions(
                      decimal: decimal),
                  inputFormatters: [
                    // Digits, plus a single decimal separator (either kind, so
                    // both keyboard layouts work).
                    FilteringTextInputFormatter.allow(
                        decimal ? RegExp(r'[0-9.,]') : RegExp(r'[0-9]')),
                    if (decimal) _SingleSeparatorFormatter(),
                    // A whole-number field here is always a percentage, and
                    // "2080" is a slip of the thumb rather than a number.
                    if (!decimal) LengthLimitingTextInputFormatter(3),
                  ],
                  style: const TextStyle(color: _textPri, fontSize: 15),
                  decoration: const InputDecoration(
                    hintText: '0',
                    hintStyle: TextStyle(color: _textSec, fontSize: 15),
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
              Text(suffix,
                  style: const TextStyle(color: _textSec, fontSize: 13)),
              const SizedBox(width: 14),
            ],
          ),
        ),
      ],
    );
  }
}

/// Keeps a decimal field to one separator: "0.2.9" can never be typed, so the
/// value always parses.
class _SingleSeparatorFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    final separators =
        newValue.text.split('').where((c) => c == '.' || c == ',').length;
    return separators > 1 ? oldValue : newValue;
  }
}
