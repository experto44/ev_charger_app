import 'package:flutter/material.dart';

import '../theme.dart';

/// Pill showing a user's subscription tier. Shared by the desktop table and the
/// mobile user cards so the two views stay visually consistent.
///
/// [manual] marks a subscription activated by hand from the panel (bank
/// transfer) rather than bought through the store — worth telling apart, since
/// only those have an admin-managed expiry date.
class StatusChip extends StatelessWidget {
  const StatusChip({super.key, required this.isPremium, this.manual = false});
  final bool isPremium;
  final bool manual;

  @override
  Widget build(BuildContext context) {
    final color = isPremium ? kEmerald : kTextSec;
    final label = isPremium
        ? (manual ? 'Premium · manual' : 'Premium')
        : (manual ? 'Expired' : 'Free');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Text(
        label,
        style: TextStyle(
            color: color, fontSize: 11.5, fontWeight: FontWeight.w600),
      ),
    );
  }
}
