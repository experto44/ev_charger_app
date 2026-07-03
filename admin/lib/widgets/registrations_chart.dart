import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/app_user.dart';
import '../theme.dart';

/// Bar chart of new registrations per day over the last 30 days, derived from
/// each user's `createdAt`. Accounts without a registration date (pre-tracking)
/// are simply not plotted.
class RegistrationsChart extends StatelessWidget {
  const RegistrationsChart({super.key, required this.users});
  final List<AppUser> users;

  static const int _days = 30;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    // Bucket index 0 == 29 days ago … index 29 == today.
    final counts = List<int>.filled(_days, 0);
    for (final u in users) {
      final c = u.createdAt;
      if (c == null) continue;
      final day = DateTime(c.year, c.month, c.day);
      final diff = today.difference(day).inDays;
      if (diff >= 0 && diff < _days) {
        counts[_days - 1 - diff]++;
      }
    }

    final maxCount = counts.fold<int>(0, (m, v) => v > m ? v : m);
    final maxY = (maxCount == 0 ? 1 : maxCount).toDouble();

    return BarChart(
      BarChartData(
        alignment: BarChartAlignment.spaceBetween,
        maxY: maxY,
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: maxY <= 5 ? 1 : (maxY / 4).ceilToDouble(),
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
              reservedSize: 28,
              interval: maxY <= 5 ? 1 : (maxY / 4).ceilToDouble(),
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
                // Label roughly every 5 days to avoid crowding.
                if (i % 5 != 0) return const SizedBox.shrink();
                final day = today.subtract(Duration(days: _days - 1 - i));
                return Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(DateFormat('d/M').format(day),
                      style: const TextStyle(color: kTextSec, fontSize: 10)),
                );
              },
            ),
          ),
        ),
        barGroups: [
          for (var i = 0; i < _days; i++)
            BarChartGroupData(x: i, barRods: [
              BarChartRodData(
                toY: counts[i].toDouble(),
                color: kEmerald,
                width: 6,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(2)),
              ),
            ]),
        ],
      ),
    );
  }
}
