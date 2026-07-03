import 'package:flutter/material.dart';

import '../theme.dart';

/// A small metric tile used in the dashboard's stats row.
class StatCard extends StatelessWidget {
  const StatCard({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    this.accent,
  });

  final String label;
  final String value;
  final IconData icon;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final c = accent ?? Colors.white;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: c),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          const TextStyle(color: kTextSec, fontSize: 13)),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(value,
                style: TextStyle(
                    fontSize: 26, fontWeight: FontWeight.bold, color: c)),
          ],
        ),
      ),
    );
  }
}
