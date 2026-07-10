import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../theme.dart';

/// Bar chart of net revenue (GEL, post-commission) per day over the last N days.
/// Takes the pre-bucketed daily series from [FinanceSummary.dailyNet] so the
/// chart stays a dumb renderer.
class RevenueChart extends StatelessWidget {
  const RevenueChart({super.key, required this.dailyNet});

  /// Net GEL per day; index 0 == (length-1) days ago, last == today.
  final List<double> dailyNet;

  @override
  Widget build(BuildContext context) {
    final days = dailyNet.length;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    final maxVal = dailyNet.fold<double>(0, (m, v) => v > m ? v : m);
    final maxY = (maxVal <= 0 ? 1.0 : maxVal * 1.15);
    final step = (maxY / 4).ceilToDouble();

    return BarChart(
      BarChartData(
        alignment: BarChartAlignment.spaceBetween,
        maxY: maxY,
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: step <= 0 ? 1 : step,
          getDrawingHorizontalLine: (_) =>
              const FlLine(color: kBgSurface, strokeWidth: 1),
        ),
        borderData: FlBorderData(show: false),
        barTouchData: BarTouchData(
          touchTooltipData: BarTouchTooltipData(
            getTooltipColor: (_) => kBgSurface,
            getTooltipItem: (group, _, rod, _) {
              final day = today.subtract(Duration(days: days - 1 - group.x));
              return BarTooltipItem(
                '${DateFormat('d MMM').format(day)}\n₾${rod.toY.toStringAsFixed(2)}',
                const TextStyle(
                    color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600),
              );
            },
          ),
        ),
        titlesData: FlTitlesData(
          topTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 34,
              interval: step <= 0 ? 1 : step,
              getTitlesWidget: (v, _) => Text('₾${v.toInt()}',
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
                if (i % 5 != 0) return const SizedBox.shrink();
                final day = today.subtract(Duration(days: days - 1 - i));
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
          for (var i = 0; i < days; i++)
            BarChartGroupData(x: i, barRods: [
              BarChartRodData(
                toY: dailyNet[i],
                color: kEmerald,
                width: 6,
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(2)),
              ),
            ]),
        ],
      ),
    );
  }
}
