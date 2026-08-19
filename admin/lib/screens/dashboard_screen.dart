import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/app_user.dart';
import '../models/purchase.dart';
import '../services/admin_service.dart';
import '../services/export_service.dart';
import '../services/finance.dart';
import '../services/finance_config.dart';
import '../services/premium_terms.dart';
import '../theme.dart';
import '../widgets/breakdown_card.dart';
import '../widgets/grant_premium_dialog.dart';
import '../widgets/kpi_card.dart';
import '../widgets/registrations_chart.dart';
import '../widgets/revenue_chart.dart';
import '../widgets/status_chip.dart';
import '../widgets/user_tile.dart';
import 'admins_screen.dart';

/// Subscription-tier filter.
enum StatusFilter { all, premium, free }

/// Which top-level view is shown: the user directory, the manual-premium
/// register, or the revenue analytics.
enum SectionTab { users, premium, finance }

/// Grants [grant] to [user] and resolves with the new expiry date.
typedef GrantPremiumFn = Future<DateTime> Function(
    AppUser user, PremiumGrant grant);

/// Ends [user]'s manual subscription immediately.
typedef RevokePremiumFn = Future<void> Function(AppUser user);

/// Firebase-backed entry point: streams the user list and hands it to the pure
/// [DashboardView]. Keeping the two apart lets the layout be previewed with mock
/// data (see `main_preview.dart`) without touching Firestore/auth.
class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final email = AdminService.I.currentUser?.email ?? '';
    // Two independent streams so a slow/failed purchases read never blocks the
    // user directory (and vice-versa). The purchases stream is nested inside so
    // both snapshots feed one DashboardView.
    return StreamBuilder<List<AppUser>>(
      stream: AdminService.I.usersStream(),
      builder: (context, usersSnap) {
        return StreamBuilder<List<Purchase>>(
          stream: AdminService.I.purchasesStream(),
          builder: (context, purchasesSnap) {
            return DashboardView(
              email: email,
              users: usersSnap.data,
              error: usersSnap.error?.toString(),
              purchases: purchasesSnap.data,
              purchasesError: purchasesSnap.error?.toString(),
              onSignOut: () => AdminService.I.signOut(),
              onManageAdmins: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const AdminsScreen()),
              ),
              onGrantPremium: (user, grant) => AdminService.I.grantManualPremium(
                uid: user.uid,
                plan: grant.plan,
                amountGel: grant.amountGel,
                note: grant.note,
              ),
              onRevokePremium: (user) =>
                  AdminService.I.revokeManualPremium(user.uid),
            );
          },
        );
      },
    );
  }
}

/// Pure, responsive dashboard. Renders the KPI strip, registrations chart,
/// filters and the users table/cards from a plain list — no Firebase imports —
/// so it can be exercised in isolation.
class DashboardView extends StatefulWidget {
  const DashboardView({
    super.key,
    required this.email,
    required this.users,
    this.error,
    this.purchases,
    this.purchasesError,
    this.initialSection = SectionTab.users,
    required this.onSignOut,
    required this.onManageAdmins,
    required this.onGrantPremium,
    required this.onRevokePremium,
  });

  /// Which tab the view opens on (used by the preview harness to land on
  /// Finance; production always opens on Users).
  final SectionTab initialSection;

  /// Signed-in admin's email (shown in the app bar).
  final String email;

  /// Full user list. `null` means "still loading".
  final List<AppUser>? users;

  /// Non-null when the stream failed.
  final String? error;

  /// All recorded revenue events. `null` means "still loading".
  final List<Purchase>? purchases;

  /// Non-null when the purchases stream failed.
  final String? purchasesError;

  final VoidCallback onSignOut;
  final VoidCallback onManageAdmins;

  /// Manual premium activation / cancellation (bank-transfer customers).
  final GrantPremiumFn onGrantPremium;
  final RevokePremiumFn onRevokePremium;

  @override
  State<DashboardView> createState() => _DashboardViewState();
}

class _DashboardViewState extends State<DashboardView> {
  final _search = TextEditingController();

  late SectionTab _section = widget.initialSection;

  StatusFilter _status = StatusFilter.all;
  String _platform = 'all'; // all / android / ios / other
  DateTimeRange? _range; // filters on registration date
  String _query = '';

  // Finance-tab filters (independent of the user-directory filters above).
  String _finPlatform = 'all'; // all / android / ios
  String _finPlan = 'all'; // all / monthly / yearly
  DateTimeRange? _finRange; // filters on purchase date

  static final DateFormat _fmt = DateFormat('yyyy-MM-dd HH:mm');
  static final DateFormat _dfmt = DateFormat('yyyy-MM-dd');
  static final NumberFormat _money = NumberFormat('#,##0.00');

  String _gel(double v) => '₾${_money.format(v)}';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// Apply the active filters to the full user list.
  List<AppUser> _apply(List<AppUser> all) {
    return all.where((u) {
      switch (_status) {
        case StatusFilter.premium:
          if (!u.effectivePremium) return false;
          break;
        case StatusFilter.free:
          if (u.effectivePremium) return false;
          break;
        case StatusFilter.all:
          break;
      }
      if (_platform != 'all') {
        final p = u.platform.isEmpty ? 'other' : u.platform;
        if (p != _platform) return false;
      }
      if (_range != null) {
        final c = u.createdAt;
        if (c == null) return false;
        final end = DateTime(
            _range!.end.year, _range!.end.month, _range!.end.day, 23, 59, 59);
        if (c.isBefore(_range!.start) || c.isAfter(end)) return false;
      }
      if (_query.isNotEmpty) {
        final q = _query.toLowerCase();
        final hay = '${u.name} ${u.email} ${u.phone}'.toLowerCase();
        if (!hay.contains(q)) return false;
      }
      return true;
    }).toList();
  }

  Future<void> _pickRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2023),
      lastDate: DateTime(now.year + 1),
      initialDateRange: _range,
    );
    if (picked != null) setState(() => _range = picked);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _appBar(),
      body: SafeArea(child: _body()),
    );
  }

  PreferredSizeWidget _appBar() {
    final showEmail = MediaQuery.sizeOf(context).width >= 720;
    return AppBar(
      backgroundColor: kBgCard,
      elevation: 0,
      shape: const Border(bottom: BorderSide(color: kBorder)),
      titleSpacing: 20,
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: kEmerald,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.bolt, color: Colors.black, size: 20),
          ),
          const SizedBox(width: 10),
          const Flexible(
            child: Text('GeoCharge Admin',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
          ),
        ],
      ),
      actions: [
        if (showEmail && widget.email.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Center(
              child: Text(widget.email,
                  style: const TextStyle(color: kTextSec, fontSize: 13)),
            ),
          ),
        IconButton(
          tooltip: 'Manage admins',
          icon: const Icon(Icons.admin_panel_settings_outlined),
          onPressed: widget.onManageAdmins,
        ),
        IconButton(
          tooltip: 'Sign out',
          icon: const Icon(Icons.logout),
          onPressed: widget.onSignOut,
        ),
        const SizedBox(width: 8),
      ],
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(52),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          // Three segments no longer fit on a narrow phone — let the strip
          // scroll sideways instead of overflowing.
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SegmentedButton<SectionTab>(
              segments: const [
                ButtonSegment(
                  value: SectionTab.users,
                  icon: Icon(Icons.people_outline, size: 18),
                  label: Text('Users'),
                ),
                ButtonSegment(
                  value: SectionTab.premium,
                  icon: Icon(Icons.workspace_premium_outlined, size: 18),
                  label: Text('Premium'),
                ),
                ButtonSegment(
                  value: SectionTab.finance,
                  icon: Icon(Icons.payments_outlined, size: 18),
                  label: Text('Finance'),
                ),
              ],
              selected: {_section},
              showSelectedIcon: false,
              onSelectionChanged: (s) => setState(() => _section = s.first),
              style: ButtonStyle(
                visualDensity: VisualDensity.compact,
                backgroundColor: WidgetStateProperty.resolveWith((states) =>
                    states.contains(WidgetState.selected)
                        ? kEmerald.withValues(alpha: 0.18)
                        : kBgSurface),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _body() {
    switch (_section) {
      case SectionTab.users:
        return _usersBody();
      case SectionTab.premium:
        return _premiumBody();
      case SectionTab.finance:
        return _financeBody();
    }
  }

  Widget _usersBody() {
    if (widget.error != null) return _ErrorView(error: widget.error!);
    if (widget.users == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final all = widget.users!;
    final filtered = _apply(all);

    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth;
        final isMobile = w < 680;
        final isDesktop = w >= 1080;
        final pad = isMobile ? 12.0 : 20.0;

        if (isMobile) {
          // Everything scrolls; nothing is pinned, so the data is always
          // reachable by scrolling — the chart is tucked into a collapsed
          // section so it never buries the list.
          return ListView(
            padding: EdgeInsets.all(pad),
            children: [
              _kpiStrip(all, w),
              const SizedBox(height: 16),
              _filtersBar(filtered.length, all.length, filtered, isMobile),
              const SizedBox(height: 8),
              _collapsibleChart(all),
              const SizedBox(height: 12),
              if (filtered.isEmpty)
                _emptyState()
              else
                ...filtered.map((u) => Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: UserTile(
                        user: u,
                        onManagePremium: () => _openGrant(u),
                      ),
                    )),
            ],
          );
        }

        // Tablet / desktop: fixed-height page where the users panel fills the
        // remaining viewport, so the data is the focus rather than buried at
        // the bottom of a long scroll.
        return Padding(
          padding: EdgeInsets.all(pad),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _kpiStrip(all, w),
              const SizedBox(height: 16),
              Expanded(
                child: isDesktop
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(
                            flex: 3,
                            child: _usersPanel(filtered, all.length),
                          ),
                          const SizedBox(width: 16),
                          SizedBox(width: 300, child: _rightRail(all)),
                        ],
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SizedBox(
                            height: 160,
                            child: _chartCard(all),
                          ),
                          const SizedBox(height: 16),
                          Expanded(child: _usersPanel(filtered, all.length)),
                        ],
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ── KPI strip ──────────────────────────────────────────────────────────────
  Widget _kpiStrip(List<AppUser> users, double width) {
    final total = users.length;
    final premium = users.where((u) => u.effectivePremium).length;
    final free = total - premium;
    final android = users.where((u) => u.platform == 'android').length;
    final ios = users.where((u) => u.platform == 'ios').length;

    final cards = <Widget>[
      KpiCard(label: 'Total users', value: '$total', icon: Icons.people),
      KpiCard(
          label: 'Premium',
          value: '$premium',
          icon: Icons.workspace_premium,
          accent: kEmerald),
      KpiCard(
          label: 'Free (ads)',
          value: '$free',
          icon: Icons.ondemand_video,
          accent: kAmber),
      KpiCard(
          label: 'Android',
          value: '$android',
          icon: Icons.android,
          accent: kBlue),
      KpiCard(
          label: 'iOS', value: '$ios', icon: Icons.phone_iphone, accent: kBlue),
    ];

    final perRow = width >= 1080 ? 5 : (width >= 680 ? 3 : 2);
    const gap = 12.0;
    return LayoutBuilder(builder: (context, c) {
      final itemW = (c.maxWidth - (perRow - 1) * gap) / perRow;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children:
            cards.map((w) => SizedBox(width: itemW, child: w)).toList(),
      );
    });
  }

  // ── Users panel (desktop/tablet table) ───────────────────────────────────────
  Widget _usersPanel(List<AppUser> users, int total) {
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            child: _filtersBar(users.length, total, users, false),
          ),
          const Divider(height: 1),
          Expanded(
            child: users.isEmpty
                ? _emptyState()
                : _dataTable(users),
          ),
        ],
      ),
    );
  }

  Widget _dataTable(List<AppUser> users) {
    return LayoutBuilder(builder: (context, c) {
      return Scrollbar(
        child: SingleChildScrollView(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: c.maxWidth),
              child: DataTable(
                headingRowColor:
                    const WidgetStatePropertyAll(kBgSurface),
                headingTextStyle: const TextStyle(
                    color: kTextSec,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600),
                dividerThickness: 0.5,
                columnSpacing: 28,
                columns: const [
                  DataColumn(label: Text('NAME')),
                  DataColumn(label: Text('PHONE')),
                  DataColumn(label: Text('EMAIL')),
                  DataColumn(label: Text('STATUS')),
                  DataColumn(label: Text('PLATFORM')),
                  DataColumn(label: Text('REGISTERED')),
                  DataColumn(label: Text('LAST ACTIVE')),
                  DataColumn(label: Text('OPENS/DAY'), numeric: true),
                  DataColumn(label: Text('PREMIUM')),
                ],
                rows: [
                  for (var i = 0; i < users.length; i++)
                    _row(users[i], i),
                ],
              ),
            ),
          ),
        ),
      );
    });
  }

  DataRow _row(AppUser u, int i) {
    return DataRow(
      color: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.hovered)) {
          return kEmerald.withValues(alpha: 0.06);
        }
        return i.isOdd ? Colors.white.withValues(alpha: 0.02) : null;
      }),
      cells: [
        DataCell(Text(u.name.isEmpty ? '—' : u.name)),
        DataCell(Text(u.phone.isEmpty ? '—' : u.phone)),
        DataCell(Text(u.email.isEmpty ? '—' : u.email)),
        DataCell(StatusChip(isPremium: u.effectivePremium, manual: u.isManual)),
        DataCell(Text(u.platform.isEmpty ? '—' : u.platform)),
        DataCell(Text(u.createdAt == null ? '—' : _fmt.format(u.createdAt!))),
        DataCell(
            Text(u.lastSeenAt == null ? '—' : _fmt.format(u.lastSeenAt!))),
        DataCell(Text(
            u.opensPerDay == null ? '—' : u.opensPerDay!.toStringAsFixed(1))),
        DataCell(_grantButton(u)),
      ],
    );
  }

  /// Entry point for manual activation, available on every user row.
  Widget _grantButton(AppUser u) {
    return IconButton(
      tooltip: u.manualActive
          ? 'Extend manual premium (${u.remainingLabel} left)'
          : 'Activate premium manually',
      icon: Icon(
        u.manualActive ? Icons.workspace_premium : Icons.add_card,
        size: 18,
        color: u.manualActive ? kEmerald : kTextSec,
      ),
      onPressed: () => _openGrant(u),
    );
  }

  // ── Right rail (desktop) ─────────────────────────────────────────────────────
  Widget _rightRail(List<AppUser> all) {
    final total = all.length;
    final premium = all.where((u) => u.effectivePremium).length;
    final manual = all.where((u) => u.manualActive).length;
    final android = all.where((u) => u.platform == 'android').length;
    final ios = all.where((u) => u.platform == 'ios').length;
    final other = total - android - ios;

    return ListView(
      children: [
        SizedBox(height: 220, child: _chartCard(all)),
        const SizedBox(height: 16),
        BreakdownCard(
          // Disjoint rows only — the card turns them into shares of their own
          // sum, so an overlapping "of which…" line would skew every percentage.
          title: 'Subscription',
          rows: [
            BreakdownRow('Premium · store', premium - manual, kEmerald),
            BreakdownRow('Premium · manual', manual, kBlue),
            BreakdownRow('Free (ads)', total - premium, kAmber),
          ],
        ),
        const SizedBox(height: 16),
        BreakdownCard(
          title: 'Platform',
          rows: [
            BreakdownRow('Android', android, kEmerald),
            BreakdownRow('iOS', ios, kBlue),
            BreakdownRow('Other / unknown', other, kTextSec),
          ],
        ),
      ],
    );
  }

  Widget _chartCard(List<AppUser> all) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('New registrations · last 30 days',
                style:
                    TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5)),
            const SizedBox(height: 14),
            Expanded(child: RegistrationsChart(users: all)),
          ],
        ),
      ),
    );
  }

  Widget _collapsibleChart(List<AppUser> all) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 16),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          leading: const Icon(Icons.bar_chart, color: kEmerald, size: 20),
          title: const Text('New registrations · last 30 days',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5)),
          children: [
            SizedBox(height: 170, child: RegistrationsChart(users: all)),
          ],
        ),
      ),
    );
  }

  // ══ Manual premium section ═══════════════════════════════════════════════════
  /// Ask for the term/amount and write the grant. Any user can be activated —
  /// this is the path for customers who couldn't pay through the store and
  /// transferred the money to us directly.
  Future<void> _openGrant(AppUser u) async {
    final grant = await GrantPremiumDialog.show(context, u);
    if (grant == null || !mounted) return;
    try {
      final until = await widget.onGrantPremium(u, grant);
      if (!mounted) return;
      _toast('${u.email.isEmpty ? u.name : u.email} · premium until '
          '${_dfmt.format(until)}');
    } catch (e) {
      if (!mounted) return;
      _toast('Activation failed: $e', error: true);
    }
  }

  Future<void> _confirmRevoke(AppUser u) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kBgCard,
        title: const Text('End premium now?'),
        content: Text(
          '${u.email.isEmpty ? u.name : u.email} loses premium immediately and '
          'the ad-supported version returns on their next app open. '
          'Recorded revenue is kept.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('End now'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await widget.onRevokePremium(u);
      if (!mounted) return;
      _toast('Premium ended for ${u.email.isEmpty ? u.name : u.email}');
    } catch (e) {
      if (!mounted) return;
      _toast('Could not end the subscription: $e', error: true);
    }
  }

  void _toast(String message, {bool error = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: error ? Colors.redAccent : kBgSurface,
      behavior: SnackBarBehavior.floating,
    ));
  }

  /// Every account that has ever been granted premium by hand, most urgent
  /// first: still-running grants ordered by soonest expiry, then the lapsed
  /// ones (most recently expired first).
  List<AppUser> _manualUsers(List<AppUser> all) {
    final list = all.where((u) => u.premiumUntil != null).toList();
    list.sort((a, b) {
      if (a.manualActive != b.manualActive) return a.manualActive ? -1 : 1;
      return a.manualActive
          ? a.premiumUntil!.compareTo(b.premiumUntil!)
          : b.premiumUntil!.compareTo(a.premiumUntil!);
    });
    return list;
  }

  Widget _premiumBody() {
    if (widget.error != null) return _ErrorView(error: widget.error!);
    if (widget.users == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final all = widget.users!;
    final manual = _manualUsers(all);

    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth;
      final isMobile = w < 680;
      final pad = isMobile ? 12.0 : 20.0;

      if (isMobile) {
        return ListView(
          padding: EdgeInsets.all(pad),
          children: [
            _premiumKpiStrip(manual, w),
            const SizedBox(height: 16),
            _premiumActionsBar(all, manual.length),
            const SizedBox(height: 12),
            if (manual.isEmpty)
              _premiumEmptyState()
            else
              ...manual.map((u) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _manualCard(u),
                  )),
          ],
        );
      }

      return Padding(
        padding: EdgeInsets.all(pad),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _premiumKpiStrip(manual, w),
            const SizedBox(height: 16),
            Expanded(
              child: Card(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                      child: _premiumActionsBar(all, manual.length),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: manual.isEmpty
                          ? _premiumEmptyState()
                          : _manualTable(manual),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    });
  }

  Widget _premiumKpiStrip(List<AppUser> manual, double width) {
    final active = manual.where((u) => u.manualActive).toList();
    final soon =
        active.where((u) => (u.daysLeft ?? 999) <= 7).length;
    final expired = manual.length - active.length;
    final manualRevenue = (widget.purchases ?? const <Purchase>[])
        .where((p) => p.isManual)
        .fold<double>(0, (sum, p) => sum + FinanceConfig.I.toGel(p.gross, p.currency));

    final cards = <Widget>[
      KpiCard(
          label: 'Active manual',
          value: '${active.length}',
          icon: Icons.workspace_premium,
          accent: kEmerald),
      KpiCard(
          label: 'Expiring ≤ 7 days',
          value: '$soon',
          icon: Icons.hourglass_bottom,
          accent: kAmber),
      KpiCard(
          label: 'Expired',
          value: '$expired',
          icon: Icons.history_toggle_off,
          accent: kTextSec),
      KpiCard(
          label: 'Collected',
          value: _gel(manualRevenue),
          icon: Icons.account_balance,
          accent: kBlue),
    ];

    final perRow = width >= 1080 ? 4 : (width >= 680 ? 2 : 2);
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

  Widget _premiumActionsBar(List<AppUser> all, int count) {
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        FilledButton.icon(
          onPressed: () => _pickUserAndGrant(all),
          icon: const Icon(Icons.add, size: 18),
          label: const Text('Activate premium'),
        ),
        Text('$count granted',
            style: const TextStyle(color: kTextSec, fontSize: 13)),
        // A plain sized box, NOT Expanded/Flexible: this is a Wrap, and a flex
        // parent-data widget inside one throws (the whole panel then renders as
        // Flutter's grey error box in a release build).
        const SizedBox(
          width: 320,
          child: Text(
            'Expiry is enforced server-side — ads return automatically when the '
            'term runs out.',
            style: TextStyle(color: kTextSec, fontSize: 12),
          ),
        ),
      ],
    );
  }

  Future<void> _pickUserAndGrant(List<AppUser> all) async {
    final user = await UserPickerDialog.show(context, all);
    if (user == null || !mounted) return;
    await _openGrant(user);
  }

  Widget _manualTable(List<AppUser> users) {
    return LayoutBuilder(builder: (context, c) {
      return Scrollbar(
        child: SingleChildScrollView(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: c.maxWidth),
              child: DataTable(
                headingRowColor: const WidgetStatePropertyAll(kBgSurface),
                headingTextStyle: const TextStyle(
                    color: kTextSec,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600),
                dividerThickness: 0.5,
                columnSpacing: 24,
                columns: const [
                  DataColumn(label: Text('USER')),
                  DataColumn(label: Text('PLAN')),
                  DataColumn(label: Text('STATUS')),
                  DataColumn(label: Text('EXPIRES')),
                  DataColumn(label: Text('TIME LEFT')),
                  DataColumn(label: Text('GRANTED BY')),
                  DataColumn(label: Text('NOTE')),
                  DataColumn(label: Text('')),
                ],
                rows: [
                  for (var i = 0; i < users.length; i++)
                    _manualRow(users[i], i),
                ],
              ),
            ),
          ),
        ),
      );
    });
  }

  DataRow _manualRow(AppUser u, int i) {
    final left = u.daysLeft ?? 0;
    final leftColor = !u.manualActive
        ? kTextSec
        : (left <= 7 ? kAmber : kEmerald);
    return DataRow(
      color: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.hovered)) {
          return kEmerald.withValues(alpha: 0.06);
        }
        return i.isOdd ? Colors.white.withValues(alpha: 0.02) : null;
      }),
      cells: [
        DataCell(Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(u.name.isEmpty ? '—' : u.name,
                maxLines: 1, overflow: TextOverflow.ellipsis),
            if (u.email.isNotEmpty)
              Text(u.email,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: kTextSec, fontSize: 11.5)),
          ],
        )),
        DataCell(Text(PremiumTerms.label(u.premiumPlan))),
        DataCell(StatusChip(isPremium: u.manualActive, manual: true)),
        DataCell(Text(
            u.premiumUntil == null ? '—' : _fmt.format(u.premiumUntil!))),
        DataCell(Text(u.remainingLabel,
            style: TextStyle(color: leftColor, fontWeight: FontWeight.w600))),
        DataCell(Text(
            u.premiumGrantedBy.isEmpty ? '—' : u.premiumGrantedBy,
            maxLines: 1,
            overflow: TextOverflow.ellipsis)),
        DataCell(SizedBox(
          width: 140,
          child: Text(u.premiumNote.isEmpty ? '—' : u.premiumNote,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: kTextSec, fontSize: 12)),
        )),
        DataCell(Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: u.manualActive ? 'Extend' : 'Activate again',
              icon: const Icon(Icons.more_time, size: 18, color: kEmerald),
              onPressed: () => _openGrant(u),
            ),
            if (u.manualActive)
              IconButton(
                tooltip: 'End now',
                icon: const Icon(Icons.cancel_outlined,
                    size: 18, color: Colors.redAccent),
                onPressed: () => _confirmRevoke(u),
              ),
          ],
        )),
      ],
    );
  }

  Widget _manualCard(AppUser u) {
    final left = u.daysLeft ?? 0;
    final leftColor =
        !u.manualActive ? kTextSec : (left <= 7 ? kAmber : kEmerald);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(u.name.isEmpty ? '—' : u.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
                StatusChip(isPremium: u.manualActive, manual: true),
              ],
            ),
            if (u.email.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(u.email,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: kTextSec, fontSize: 12.5)),
            ],
            const SizedBox(height: 10),
            Row(
              children: [
                Text(u.remainingLabel,
                    style: TextStyle(
                        color: leftColor,
                        fontWeight: FontWeight.w700,
                        fontSize: 15)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${PremiumTerms.label(u.premiumPlan)} · until '
                    '${u.premiumUntil == null ? '—' : _dfmt.format(u.premiumUntil!)}',
                    style: const TextStyle(color: kTextSec, fontSize: 12.5),
                  ),
                ),
              ],
            ),
            if (u.premiumNote.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(u.premiumNote,
                  style: const TextStyle(color: kTextSec, fontSize: 12)),
            ],
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton.icon(
                  onPressed: () => _openGrant(u),
                  icon: const Icon(Icons.more_time, size: 18),
                  label: Text(u.manualActive ? 'Extend' : 'Activate again'),
                ),
                if (u.manualActive)
                  TextButton.icon(
                    style: TextButton.styleFrom(
                        foregroundColor: Colors.redAccent),
                    onPressed: () => _confirmRevoke(u),
                    icon: const Icon(Icons.cancel_outlined, size: 18),
                    label: const Text('End'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _premiumEmptyState() {
    return Padding(
      padding: const EdgeInsets.all(40),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Icon(Icons.workspace_premium_outlined, color: kTextSec, size: 40),
            SizedBox(height: 12),
            Text('No manual activations yet.',
                style: TextStyle(color: kTextSec)),
            SizedBox(height: 4),
            Text(
              'Use "Activate premium" for users who paid you directly instead '
              'of through the store.',
              textAlign: TextAlign.center,
              style: TextStyle(color: kTextSec, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  // ══ Finance section ══════════════════════════════════════════════════════════
  /// Apply the finance-tab filters (platform / plan / purchase-date) to the raw
  /// purchase list.
  List<Purchase> _applyFinance(List<Purchase> all) {
    return all.where((p) {
      if (_finPlatform != 'all' && p.platform != _finPlatform) return false;
      if (_finPlan != 'all' && p.plan != _finPlan) return false;
      if (_finRange != null) {
        final c = p.createdAt;
        if (c == null) return false;
        final end = DateTime(_finRange!.end.year, _finRange!.end.month,
            _finRange!.end.day, 23, 59, 59);
        if (c.isBefore(_finRange!.start) || c.isAfter(end)) return false;
      }
      return true;
    }).toList();
  }

  Widget _financeBody() {
    if (widget.purchasesError != null) {
      return _ErrorView(error: widget.purchasesError!);
    }
    if (widget.purchases == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final all = widget.purchases!;
    final filtered = _applyFinance(all);
    final summary = FinanceSummary.compute(filtered, FinanceConfig.I);
    // uid → email, so the purchases table can show who paid.
    final emailByUid = {for (final u in (widget.users ?? const <AppUser>[])) u.uid: u.email};

    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth;
      final isMobile = w < 680;
      final isDesktop = w >= 1080;
      final pad = isMobile ? 12.0 : 20.0;

      if (isMobile) {
        return ListView(
          padding: EdgeInsets.all(pad),
          children: [
            _finKpiStrip(summary, w),
            const SizedBox(height: 16),
            _finFiltersBar(filtered.length, all.length, filtered, true),
            const SizedBox(height: 8),
            _finCollapsibleChart(summary),
            const SizedBox(height: 12),
            _finBreakdowns(summary),
            const SizedBox(height: 12),
            if (filtered.isEmpty)
              _financeEmptyState()
            else
              ...filtered.map((p) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _purchaseCard(p, emailByUid),
                  )),
          ],
        );
      }

      return Padding(
        padding: EdgeInsets.all(pad),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _finKpiStrip(summary, w),
            const SizedBox(height: 16),
            Expanded(
              child: isDesktop
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          flex: 3,
                          child: _purchasesPanel(
                              filtered, all.length, emailByUid),
                        ),
                        const SizedBox(width: 16),
                        SizedBox(width: 300, child: _finRightRail(summary)),
                      ],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(height: 180, child: _revenueCard(summary)),
                        const SizedBox(height: 16),
                        Expanded(
                          child: _purchasesPanel(
                              filtered, all.length, emailByUid),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      );
    });
  }

  Widget _finKpiStrip(FinanceSummary s, double width) {
    final cards = <Widget>[
      KpiCard(
          label: 'Gross revenue',
          value: _gel(s.total.gross),
          icon: Icons.account_balance_wallet,
          accent: kEmerald),
      KpiCard(
          label: 'Net revenue',
          value: _gel(s.total.net),
          icon: Icons.savings,
          accent: kEmerald),
      KpiCard(
          label: 'Apple fee',
          value: _gel(s.appleFee),
          icon: Icons.apple,
          accent: kBlue),
      KpiCard(
          label: 'Google fee',
          value: _gel(s.googleFee),
          icon: Icons.android,
          accent: kAmber),
      KpiCard(
          label: 'Purchases',
          value: '${s.total.count}',
          icon: Icons.receipt_long),
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

  Widget _purchasesPanel(
      List<Purchase> purchases, int total, Map<String, String> emailByUid) {
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            child: _finFiltersBar(purchases.length, total, purchases, false),
          ),
          const Divider(height: 1),
          Expanded(
            child: purchases.isEmpty
                ? _financeEmptyState()
                : _purchasesTable(purchases, emailByUid),
          ),
        ],
      ),
    );
  }

  Widget _purchasesTable(
      List<Purchase> purchases, Map<String, String> emailByUid) {
    final cfg = FinanceConfig.I;
    return LayoutBuilder(builder: (context, c) {
      return Scrollbar(
        child: SingleChildScrollView(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: c.maxWidth),
              child: DataTable(
                headingRowColor: const WidgetStatePropertyAll(kBgSurface),
                headingTextStyle: const TextStyle(
                    color: kTextSec,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600),
                dividerThickness: 0.5,
                columnSpacing: 24,
                columns: const [
                  DataColumn(label: Text('DATE')),
                  DataColumn(label: Text('USER')),
                  DataColumn(label: Text('PLAN')),
                  DataColumn(label: Text('PLATFORM')),
                  DataColumn(label: Text('CHARGED')),
                  DataColumn(label: Text('GROSS ₾'), numeric: true),
                  DataColumn(label: Text('NET ₾'), numeric: true),
                ],
                rows: [
                  for (var i = 0; i < purchases.length; i++)
                    _purchaseRow(purchases[i], i, emailByUid, cfg),
                ],
              ),
            ),
          ),
        ),
      );
    });
  }

  DataRow _purchaseRow(
      Purchase p, int i, Map<String, String> emailByUid, FinanceConfig cfg) {
    final grossGel = cfg.toGel(p.gross, p.currency);
    final netGel = grossGel * (1 - cfg.rateFor(p.platform));
    final who = (emailByUid[p.uid]?.isNotEmpty == true)
        ? emailByUid[p.uid]!
        : p.uid;
    return DataRow(
      color: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.hovered)) {
          return kEmerald.withValues(alpha: 0.06);
        }
        return i.isOdd ? Colors.white.withValues(alpha: 0.02) : null;
      }),
      cells: [
        DataCell(
            Text(p.createdAt == null ? '—' : _fmt.format(p.createdAt!))),
        DataCell(Text(who, maxLines: 1, overflow: TextOverflow.ellipsis)),
        DataCell(Text(p.planLabel)),
        DataCell(Text(p.platform)),
        DataCell(Text('${_money.format(p.gross)} ${p.currency}')),
        DataCell(Text(_money.format(grossGel))),
        DataCell(Text(_money.format(netGel))),
      ],
    );
  }

  Widget _finRightRail(FinanceSummary s) {
    return ListView(
      children: [
        SizedBox(height: 220, child: _revenueCard(s)),
        const SizedBox(height: 16),
        _finBreakdowns(s),
      ],
    );
  }

  Widget _finBreakdowns(FinanceSummary s) {
    int net(String key, Map<String, RevenueBucket> m) =>
        (m[key]?.net ?? 0).round();
    return Column(
      children: [
        BreakdownCard(
          title: 'Net revenue · platform',
          rows: [
            BreakdownRow('iOS (Apple)', net('ios', s.byPlatform), kBlue),
            BreakdownRow(
                'Android (Google)', net('android', s.byPlatform), kEmerald),
            if ((s.byPlatform['manual']?.count ?? 0) > 0)
              BreakdownRow('Manual (bank)', net('manual', s.byPlatform), kAmber),
            if ((s.byPlatform['other']?.count ?? 0) > 0)
              BreakdownRow('Other', net('other', s.byPlatform), kTextSec),
          ],
        ),
        const SizedBox(height: 16),
        BreakdownCard(
          title: 'Net revenue · plan',
          rows: [
            BreakdownRow('Monthly', net('monthly', s.byPlan), kEmerald),
            BreakdownRow('Yearly', net('yearly', s.byPlan), kAmber),
          ],
        ),
      ],
    );
  }

  Widget _revenueCard(FinanceSummary s) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Net revenue · last 30 days',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5)),
            const SizedBox(height: 14),
            Expanded(child: RevenueChart(dailyNet: s.dailyNet)),
          ],
        ),
      ),
    );
  }

  Widget _finCollapsibleChart(FinanceSummary s) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 16),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          leading: const Icon(Icons.show_chart, color: kEmerald, size: 20),
          title: const Text('Net revenue · last 30 days',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5)),
          children: [
            SizedBox(height: 170, child: RevenueChart(dailyNet: s.dailyNet)),
          ],
        ),
      ),
    );
  }

  Widget _purchaseCard(Purchase p, Map<String, String> emailByUid) {
    final cfg = FinanceConfig.I;
    final grossGel = cfg.toGel(p.gross, p.currency);
    final netGel = grossGel * (1 - cfg.rateFor(p.platform));
    final who =
        (emailByUid[p.uid]?.isNotEmpty == true) ? emailByUid[p.uid]! : p.uid;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(who,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
                Text(_gel(netGel),
                    style: const TextStyle(
                        color: kEmerald, fontWeight: FontWeight.w700)),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '${p.planLabel} · ${p.platform} · ${_money.format(p.gross)} ${p.currency}'
              '${p.createdAt == null ? '' : ' · ${_fmt.format(p.createdAt!)}'}',
              style: const TextStyle(color: kTextSec, fontSize: 12.5),
            ),
          ],
        ),
      ),
    );
  }

  Widget _finFiltersBar(
      int shown, int total, List<Purchase> filtered, bool isMobile) {
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _dropdown<String>(
          value: _finPlatform,
          items: const {
            'all': 'All platforms',
            'android': 'Android',
            'ios': 'iOS',
            'manual': 'Manual (bank)',
          },
          onChanged: (v) => setState(() => _finPlatform = v!),
        ),
        _dropdown<String>(
          value: _finPlan,
          items: const {
            'all': 'All plans',
            'monthly': 'Monthly',
            'yearly': 'Yearly',
          },
          onChanged: (v) => setState(() => _finPlan = v!),
        ),
        OutlinedButton.icon(
          onPressed: _pickFinRange,
          icon: const Icon(Icons.date_range, size: 18),
          label: Text(_finRange == null
              ? 'Purchase date'
              : '${_dfmt.format(_finRange!.start)} → ${_dfmt.format(_finRange!.end)}'),
        ),
        if (_finRange != null)
          IconButton(
            tooltip: 'Clear date filter',
            icon: const Icon(Icons.clear, size: 18),
            onPressed: () => setState(() => _finRange = null),
          ),
        OutlinedButton.icon(
          onPressed: _openFinanceSettings,
          icon: const Icon(Icons.tune, size: 18),
          label: const Text('Commission / FX'),
        ),
        Text('$shown / $total',
            style: const TextStyle(color: kTextSec, fontSize: 13)),
        FilledButton.icon(
          onPressed: shown == 0
              ? null
              : () => ExportService.exportPurchases(filtered, FinanceConfig.I),
          icon: const Icon(Icons.download, size: 18),
          label: const Text('Export Excel'),
        ),
      ],
    );
  }

  Future<void> _pickFinRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2023),
      lastDate: DateTime(now.year + 1),
      initialDateRange: _finRange,
    );
    if (picked != null) setState(() => _finRange = picked);
  }

  Future<void> _openFinanceSettings() async {
    final cfg = FinanceConfig.I;
    final apple = TextEditingController(
        text: (cfg.appleRate * 100).toStringAsFixed(1));
    final google = TextEditingController(
        text: (cfg.googleRate * 100).toStringAsFixed(1));
    final fx = TextEditingController(text: cfg.usdToGel.toStringAsFixed(2));

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kBgCard,
        title: const Text('Commission & currency'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _settingsField(apple, 'Apple commission %', Icons.apple),
            const SizedBox(height: 12),
            _settingsField(google, 'Google commission %', Icons.android),
            const SizedBox(height: 12),
            _settingsField(fx, 'USD → GEL rate', Icons.currency_exchange),
            const SizedBox(height: 8),
            const Text(
              'iOS revenue in the Georgian App Store is billed in USD and is '
              'converted to GEL with this rate for the combined totals.',
              style: TextStyle(color: kTextSec, fontSize: 11.5),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Save')),
        ],
      ),
    );

    if (saved == true) {
      final a = double.tryParse(apple.text.trim());
      final g = double.tryParse(google.text.trim());
      final f = double.tryParse(fx.text.trim());
      cfg.update(
        appleRate: a == null ? null : a / 100,
        googleRate: g == null ? null : g / 100,
        usdToGel: f,
      );
      setState(() {}); // re-run every finance figure with the new assumptions
    }
    apple.dispose();
    google.dispose();
    fx.dispose();
  }

  Widget _settingsField(
      TextEditingController c, String label, IconData icon) {
    return TextField(
      controller: c,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon, size: 18),
      ),
    );
  }

  Widget _financeEmptyState() {
    return Padding(
      padding: const EdgeInsets.all(40),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Icon(Icons.receipt_long, color: kTextSec, size: 40),
            SizedBox(height: 12),
            Text('No purchases match the current filters.',
                style: TextStyle(color: kTextSec)),
            SizedBox(height: 4),
            Text(
              'Revenue is recorded from the release that ships purchase '
              'tracking onward.',
              textAlign: TextAlign.center,
              style: TextStyle(color: kTextSec, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  // ── Filters bar (shared) ─────────────────────────────────────────────────────
  Widget _filtersBar(
      int shown, int total, List<AppUser> filtered, bool isMobile) {
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SizedBox(
          width: isMobile ? double.infinity : 240,
          child: TextField(
            controller: _search,
            onChanged: (v) => setState(() => _query = v.trim()),
            decoration: const InputDecoration(
              hintText: 'Search name, email, phone…',
              prefixIcon: Icon(Icons.search, size: 20),
            ),
          ),
        ),
        _dropdown<StatusFilter>(
          value: _status,
          items: const {
            StatusFilter.all: 'All statuses',
            StatusFilter.premium: 'Premium',
            StatusFilter.free: 'Free (ads)',
          },
          onChanged: (v) => setState(() => _status = v!),
        ),
        _dropdown<String>(
          value: _platform,
          items: const {
            'all': 'All platforms',
            'android': 'Android',
            'ios': 'iOS',
            'other': 'Other/unknown',
          },
          onChanged: (v) => setState(() => _platform = v!),
        ),
        OutlinedButton.icon(
          onPressed: _pickRange,
          icon: const Icon(Icons.date_range, size: 18),
          label: Text(_range == null
              ? 'Registration date'
              : '${_dfmt.format(_range!.start)} → ${_dfmt.format(_range!.end)}'),
        ),
        if (_range != null)
          IconButton(
            tooltip: 'Clear date filter',
            icon: const Icon(Icons.clear, size: 18),
            onPressed: () => setState(() => _range = null),
          ),
        Text('$shown / $total',
            style: const TextStyle(color: kTextSec, fontSize: 13)),
        FilledButton.icon(
          onPressed:
              shown == 0 ? null : () => ExportService.exportUsers(filtered),
          icon: const Icon(Icons.download, size: 18),
          label: const Text('Export Excel'),
        ),
      ],
    );
  }

  Widget _dropdown<T>({
    required T value,
    required Map<T, String> items,
    required ValueChanged<T?> onChanged,
  }) {
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: kBgSurface,
        borderRadius: BorderRadius.circular(10),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          dropdownColor: kBgSurface,
          borderRadius: BorderRadius.circular(10),
          items: items.entries
              .map((e) =>
                  DropdownMenuItem<T>(value: e.key, child: Text(e.value)))
              .toList(),
          onChanged: onChanged,
        ),
      ),
    );
  }

  Widget _emptyState() {
    return Padding(
      padding: const EdgeInsets.all(40),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Icon(Icons.search_off, color: kTextSec, size: 40),
            SizedBox(height: 12),
            Text('No users match the current filters.',
                style: TextStyle(color: kTextSec)),
          ],
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.error});
  final String error;
  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: Colors.redAccent, size: 48),
            const SizedBox(height: 12),
            const Text('Could not load users',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(error,
                textAlign: TextAlign.center,
                style: const TextStyle(color: kTextSec, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}
