import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/app_user.dart';
import '../services/admin_service.dart';
import '../services/export_service.dart';
import '../theme.dart';
import '../widgets/registrations_chart.dart';
import '../widgets/stat_card.dart';
import 'admins_screen.dart';

/// Subscription-tier filter.
enum StatusFilter { all, premium, free }

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final _search = TextEditingController();

  StatusFilter _status = StatusFilter.all;
  String _platform = 'all'; // all / android / ios / other
  DateTimeRange? _range; // filters on registration date
  String _query = '';

  static final DateFormat _fmt = DateFormat('yyyy-MM-dd HH:mm');
  static final DateFormat _dfmt = DateFormat('yyyy-MM-dd');

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
          if (!u.isPremium) return false;
          break;
        case StatusFilter.free:
          if (u.isPremium) return false;
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
        // Inclusive of the whole end day.
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
    final email = AdminService.I.currentUser?.email ?? '';
    return Scaffold(
      appBar: AppBar(
        backgroundColor: kBgCard,
        title: Row(
          children: [
            const Icon(Icons.bolt, color: kEmerald),
            const SizedBox(width: 8),
            const Text('GeoCharge Admin',
                style: TextStyle(fontWeight: FontWeight.bold)),
          ],
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Center(
              child: Text(email,
                  style: const TextStyle(color: kTextSec, fontSize: 13)),
            ),
          ),
          IconButton(
            tooltip: 'Manage admins',
            icon: const Icon(Icons.admin_panel_settings_outlined),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const AdminsScreen()),
            ),
          ),
          IconButton(
            tooltip: 'Sign out',
            icon: const Icon(Icons.logout),
            onPressed: () => AdminService.I.signOut(),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: StreamBuilder<List<AppUser>>(
        stream: AdminService.I.usersStream(),
        builder: (context, snap) {
          if (snap.hasError) {
            return _ErrorView(error: snap.error.toString());
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final all = snap.data!;
          final filtered = _apply(all);
          return LayoutBuilder(
            builder: (context, constraints) {
              return SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _StatsRow(users: all),
                    const SizedBox(height: 20),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('New registrations (last 30 days)',
                                style: TextStyle(
                                    fontWeight: FontWeight.w600, fontSize: 15)),
                            const SizedBox(height: 16),
                            SizedBox(
                              height: 180,
                              child: RegistrationsChart(users: all),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    _buildFilters(filtered, all.length),
                    const SizedBox(height: 12),
                    _buildTable(filtered),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildFilters(List<AppUser> filtered, int total) {
    final shown = filtered.length;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Wrap(
          spacing: 12,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: 240,
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
              label: 'Status',
              items: const {
                StatusFilter.all: 'All statuses',
                StatusFilter.premium: 'Premium',
                StatusFilter.free: 'Free (ads)',
              },
              onChanged: (v) => setState(() => _status = v!),
            ),
            _dropdown<String>(
              value: _platform,
              label: 'Platform',
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
            const Spacer(),
            Text('$shown / $total',
                style: const TextStyle(color: kTextSec, fontSize: 13)),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: shown == 0
                  ? null
                  : () => ExportService.exportUsers(filtered),
              icon: const Icon(Icons.download, size: 18),
              label: const Text('Export Excel'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTable(List<AppUser> users) {
    if (users.isEmpty) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(40),
          child: Center(
            child: Text('No users match the current filters.',
                style: TextStyle(color: kTextSec)),
          ),
        ),
      );
    }
    return Card(
      child: SizedBox(
        width: double.infinity,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            headingRowColor: WidgetStatePropertyAll(kBgSurface),
            columns: const [
              DataColumn(label: Text('Name')),
              DataColumn(label: Text('Phone')),
              DataColumn(label: Text('Email')),
              DataColumn(label: Text('Status')),
              DataColumn(label: Text('Platform')),
              DataColumn(label: Text('Registered')),
              DataColumn(label: Text('Last active')),
              DataColumn(label: Text('Opens/day'), numeric: true),
            ],
            rows: users.map((u) {
              return DataRow(cells: [
                DataCell(Text(u.name.isEmpty ? '—' : u.name)),
                DataCell(Text(u.phone.isEmpty ? '—' : u.phone)),
                DataCell(Text(u.email.isEmpty ? '—' : u.email)),
                DataCell(_StatusChip(isPremium: u.isPremium)),
                DataCell(Text(u.platform.isEmpty ? '—' : u.platform)),
                DataCell(Text(
                    u.createdAt == null ? '—' : _fmt.format(u.createdAt!))),
                DataCell(Text(
                    u.lastSeenAt == null ? '—' : _fmt.format(u.lastSeenAt!))),
                DataCell(Text(u.opensPerDay == null
                    ? '—'
                    : u.opensPerDay!.toStringAsFixed(1))),
              ]);
            }).toList(),
          ),
        ),
      ),
    );
  }

  Widget _dropdown<T>({
    required T value,
    required String label,
    required Map<T, String> items,
    required ValueChanged<T?> onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: kBgSurface,
        borderRadius: BorderRadius.circular(10),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          dropdownColor: kBgCard,
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
}

// ── Stats row ─────────────────────────────────────────────────────────────────
class _StatsRow extends StatelessWidget {
  const _StatsRow({required this.users});
  final List<AppUser> users;

  @override
  Widget build(BuildContext context) {
    final total = users.length;
    final premium = users.where((u) => u.isPremium).length;
    final free = total - premium;
    final android = users.where((u) => u.platform == 'android').length;
    final ios = users.where((u) => u.platform == 'ios').length;

    final cards = [
      StatCard(label: 'Total users', value: '$total', icon: Icons.people),
      StatCard(
          label: 'Premium',
          value: '$premium',
          icon: Icons.workspace_premium,
          accent: kEmerald),
      StatCard(label: 'Free (ads)', value: '$free', icon: Icons.ondemand_video),
      StatCard(label: 'Android', value: '$android', icon: Icons.android),
      StatCard(label: 'iOS', value: '$ios', icon: Icons.phone_iphone),
    ];

    return LayoutBuilder(builder: (context, c) {
      final perRow = c.maxWidth > 900 ? 5 : (c.maxWidth > 560 ? 3 : 2);
      final width = (c.maxWidth - (perRow - 1) * 12) / perRow;
      return Wrap(
        spacing: 12,
        runSpacing: 12,
        children:
            cards.map((w) => SizedBox(width: width, child: w)).toList(),
      );
    });
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.isPremium});
  final bool isPremium;
  @override
  Widget build(BuildContext context) {
    final color = isPremium ? kEmerald : kTextSec;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        isPremium ? 'Premium' : 'Free',
        style: TextStyle(
            color: color, fontSize: 12, fontWeight: FontWeight.w600),
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
