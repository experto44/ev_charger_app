import 'package:flutter/material.dart';

import '../theme.dart';

/// Pill showing a user's subscription tier. Shared by the desktop table and the
/// mobile user cards so the two views stay visually consistent.
class StatusChip extends StatelessWidget {
  const StatusChip({super.key, required this.isPremium});
  final bool isPremium;

  @override
  Widget build(BuildContext context) {
    final color = isPremium ? kEmerald : kTextSec;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Text(
        isPremium ? 'Premium' : 'Free',
        style: TextStyle(
            color: color, fontSize: 11.5, fontWeight: FontWeight.w600),
      ),
    );
  }
}
