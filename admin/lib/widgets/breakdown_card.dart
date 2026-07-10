import 'package:flutter/material.dart';

import '../theme.dart';

/// A single labelled proportion row inside a [BreakdownCard].
class BreakdownRow {
  const BreakdownRow(this.label, this.count, this.color);
  final String label;
  final int count;
  final Color color;
}

/// A small "share of total" card: a title and a list of labelled bars. Used in
/// the desktop side rail to show platform / subscription splits at a glance.
class BreakdownCard extends StatelessWidget {
  const BreakdownCard({super.key, required this.title, required this.rows});

  final String title;
  final List<BreakdownRow> rows;

  @override
  Widget build(BuildContext context) {
    final total = rows.fold<int>(0, (s, r) => s + r.count);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: const TextStyle(
                    fontWeight: FontWeight.w600, fontSize: 14)),
            const SizedBox(height: 14),
            for (final r in rows) ...[
              _Row(row: r, total: total),
              if (r != rows.last) const SizedBox(height: 12),
            ],
          ],
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.row, required this.total});
  final BreakdownRow row;
  final int total;

  @override
  Widget build(BuildContext context) {
    final frac = total == 0 ? 0.0 : row.count / total;
    final pct = (frac * 100).round();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(row.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13)),
            ),
            Text('${row.count}  ·  $pct%',
                style: const TextStyle(color: kTextSec, fontSize: 12.5)),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: frac,
            minHeight: 6,
            backgroundColor: kBgSurface,
            valueColor: AlwaysStoppedAnimation<Color>(row.color),
          ),
        ),
      ],
    );
  }
}
