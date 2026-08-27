import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/app_user.dart';
import '../services/premium_terms.dart';
import '../theme.dart';

/// What the admin filled in on the activation dialog.
class PremiumGrant {
  const PremiumGrant({
    required this.plan,
    required this.amountGel,
    required this.note,
  });

  /// `monthly` (1 month) or `yearly` (1 year).
  final String plan;

  /// Money actually received, in GEL. `0` records no revenue row.
  final double amountGel;

  /// Optional payment reference / reason.
  final String note;
}

/// Dialog for granting premium by hand to a user who paid outside the store
/// (bank transfer). Pure UI — it only collects and previews; the caller does the
/// writing, so this can be exercised without Firebase.
///
/// Shows the exact resulting expiry before anything is saved, including the
/// remaining days it is stacked on top of.
class GrantPremiumDialog extends StatefulWidget {
  const GrantPremiumDialog({super.key, required this.user});

  final AppUser user;

  /// Returns the filled-in grant, or `null` if the admin cancelled.
  static Future<PremiumGrant?> show(BuildContext context, AppUser user) {
    return showDialog<PremiumGrant>(
      context: context,
      builder: (_) => GrantPremiumDialog(user: user),
    );
  }

  @override
  State<GrantPremiumDialog> createState() => _GrantPremiumDialogState();
}

class _GrantPremiumDialogState extends State<GrantPremiumDialog> {
  static final DateFormat _dfmt = DateFormat('yyyy-MM-dd');

  String _plan = PremiumTerms.monthly;
  late final TextEditingController _amount = TextEditingController(
      text: PremiumTerms.defaultPriceGel(_plan).toStringAsFixed(2));
  final TextEditingController _note = TextEditingController();

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  /// Switch plan and, unless the admin typed their own figure, follow the new
  /// plan's list price.
  void _setPlan(String plan) {
    final wasDefault = _amount.text.trim() ==
        PremiumTerms.defaultPriceGel(_plan).toStringAsFixed(2);
    setState(() {
      _plan = plan;
      if (wasDefault) {
        _amount.text = PremiumTerms.defaultPriceGel(plan).toStringAsFixed(2);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final u = widget.user;
    final until = PremiumTerms.extend(u.premiumUntil, _plan);
    final extendsExisting = u.manualActive;

    return AlertDialog(
      backgroundColor: kBgCard,
      title: const Text('Activate premium manually'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _userHeader(u),
              const SizedBox(height: 16),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(
                      value: PremiumTerms.monthly, label: Text('1 month')),
                  ButtonSegment(
                      value: PremiumTerms.yearly, label: Text('1 year')),
                ],
                selected: {_plan},
                showSelectedIcon: false,
                onSelectionChanged: (s) => _setPlan(s.first),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _amount,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: 'Amount received (GEL)',
                  prefixIcon: Icon(Icons.payments_outlined, size: 18),
                  helperText:
                      'Recorded in Finance with no store commission. 0 = don\'t record.',
                  helperMaxLines: 2,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _note,
                decoration: const InputDecoration(
                  labelText: 'Note (optional)',
                  hintText: 'Bank transfer ref, reason…',
                  prefixIcon: Icon(Icons.sticky_note_2_outlined, size: 18),
                ),
              ),
              const SizedBox(height: 16),
              _preview(until, extendsExisting),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: () => Navigator.pop(
            context,
            PremiumGrant(
              plan: _plan,
              amountGel: double.tryParse(_amount.text.trim().replaceAll(',', '.')) ?? 0,
              note: _note.text,
            ),
          ),
          icon: const Icon(Icons.workspace_premium, size: 18),
          label: const Text('Activate'),
        ),
      ],
    );
  }

  Widget _userHeader(AppUser u) {
    final identity = [u.email, u.phone].where((s) => s.isNotEmpty).join('  ·  ');
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: kBgSurface,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(u.name.isEmpty ? '(no name)' : u.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600)),
          if (identity.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(identity,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: kTextSec, fontSize: 12.5)),
          ],
          const SizedBox(height: 8),
          Text(
            u.manualActive
                ? 'Currently premium (manual) · ${u.remainingLabel} left, until ${_dfmt.format(u.premiumUntil!)}'
                : (u.isPremium && !u.isManual
                    ? 'Currently premium via an in-app purchase'
                    : 'Currently on the free, ad-supported version'),
            style: const TextStyle(color: kTextSec, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _preview(DateTime until, bool extendsExisting) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: kEmerald.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: kEmerald.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          const Icon(Icons.event_available, color: kEmerald, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Premium until ${_dfmt.format(until)}',
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 13.5)),
                const SizedBox(height: 2),
                Text(
                  extendsExisting
                      ? 'Added on top of the remaining time.'
                      : 'Ads stop immediately and come back on this date.',
                  style: const TextStyle(color: kTextSec, fontSize: 11.5),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Picker used when activating premium from the Premium tab: search the whole
/// user base by name / email / phone and choose who to grant.
class UserPickerDialog extends StatefulWidget {
  const UserPickerDialog({super.key, required this.users});

  final List<AppUser> users;

  static Future<AppUser?> show(BuildContext context, List<AppUser> users) {
    return showDialog<AppUser>(
      context: context,
      builder: (_) => UserPickerDialog(users: users),
    );
  }

  @override
  State<UserPickerDialog> createState() => _UserPickerDialogState();
}

class _UserPickerDialogState extends State<UserPickerDialog> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<AppUser> get _matches {
    if (_query.isEmpty) return widget.users.take(30).toList();
    final q = _query.toLowerCase();
    return widget.users
        .where((u) =>
            '${u.name} ${u.email} ${u.phone}'.toLowerCase().contains(q))
        .take(50)
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final matches = _matches;
    return AlertDialog(
      backgroundColor: kBgCard,
      title: const Text('Choose a user'),
      content: SizedBox(
        width: 460,
        height: 420,
        child: Column(
          children: [
            TextField(
              controller: _search,
              autofocus: true,
              onChanged: (v) => setState(() => _query = v.trim()),
              decoration: const InputDecoration(
                hintText: 'Search name, email, phone…',
                prefixIcon: Icon(Icons.search, size: 20),
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: matches.isEmpty
                  ? const Center(
                      child: Text('No match.',
                          style: TextStyle(color: kTextSec)))
                  : ListView.separated(
                      itemCount: matches.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, i) {
                        final u = matches[i];
                        return ListTile(
                          dense: true,
                          title: Text(u.name.isEmpty ? '(no name)' : u.name,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(
                            [u.email, u.phone]
                                .where((s) => s.isNotEmpty)
                                .join('  ·  '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12),
                          ),
                          trailing: u.effectivePremium
                              ? const Icon(Icons.workspace_premium,
                                  color: kEmerald, size: 18)
                              : null,
                          onTap: () => Navigator.pop(context, u),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
      ],
    );
  }
}
