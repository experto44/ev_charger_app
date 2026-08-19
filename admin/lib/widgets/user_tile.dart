import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/app_user.dart';
import '../theme.dart';
import 'status_chip.dart';

/// A single user rendered as a card. Used on narrow screens where the 8-column
/// data table can't fit — the phone view the panel is most often opened on.
class UserTile extends StatelessWidget {
  const UserTile({super.key, required this.user, this.onManagePremium});
  final AppUser user;

  /// Opens the manual-activation dialog for this user. Omitted in contexts
  /// where granting isn't offered.
  final VoidCallback? onManagePremium;

  static final DateFormat _fmt = DateFormat('yyyy-MM-dd HH:mm');

  @override
  Widget build(BuildContext context) {
    final u = user;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: kBgCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: kBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  u.name.isEmpty ? '—' : u.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(width: 8),
              StatusChip(isPremium: u.effectivePremium, manual: u.isManual),
              if (onManagePremium != null)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: u.manualActive
                      ? 'Extend manual premium'
                      : 'Activate premium manually',
                  icon: Icon(
                    u.manualActive ? Icons.workspace_premium : Icons.add_card,
                    size: 18,
                    color: u.manualActive ? kEmerald : kTextSec,
                  ),
                  onPressed: onManagePremium,
                ),
            ],
          ),
          if (u.email.isNotEmpty || u.phone.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              [u.email, u.phone].where((s) => s.isNotEmpty).join('  ·  '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: kTextSec, fontSize: 12.5),
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 16,
            runSpacing: 8,
            children: [
              _meta(Icons.smartphone, u.platform.isEmpty ? '—' : u.platform),
              _meta(Icons.event,
                  u.createdAt == null ? '—' : _fmt.format(u.createdAt!)),
              _meta(Icons.bolt,
                  u.opensPerDay == null ? '—' : '${u.opensPerDay!.toStringAsFixed(1)}/day'),
              if (u.manualActive)
                _meta(Icons.hourglass_bottom, '${u.remainingLabel} left'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _meta(IconData icon, String text) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: kTextSec),
        const SizedBox(width: 5),
        Text(text, style: const TextStyle(color: kTextSec, fontSize: 12.5)),
      ],
    );
  }
}
