import 'package:flutter/material.dart';

import '../services/admin_service.dart';
import '../theme.dart';

/// Manage the admin allow-list: view current admins, add a new one by email,
/// or remove one (you can't remove your own access).
class AdminsScreen extends StatefulWidget {
  const AdminsScreen({super.key});

  @override
  State<AdminsScreen> createState() => _AdminsScreenState();
}

class _AdminsScreenState extends State<AdminsScreen> {
  final _email = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final email = _email.text.trim().toLowerCase();
    if (!_isValidEmail(email)) {
      setState(() => _error = 'Enter a valid email address.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await AdminService.I.addAdmin(email);
      _email.clear();
    } catch (e) {
      setState(() => _error = 'Could not add admin (permission denied?).');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool _isValidEmail(String s) =>
      RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(s);

  Future<void> _remove(String email) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Remove admin?'),
        content: Text('$email will lose access to this panel.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Remove')),
        ],
      ),
    );
    if (ok == true) {
      try {
        await AdminService.I.removeAdmin(email);
      } catch (_) {
        if (mounted) {
          setState(() => _error = 'Could not remove admin.');
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = AdminService.I.currentUser?.email?.toLowerCase() ?? '';
    return Scaffold(
      appBar: AppBar(
        backgroundColor: kBgCard,
        title: const Text('Manage admins'),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Add an admin',
                            style: TextStyle(
                                fontWeight: FontWeight.w600, fontSize: 15)),
                        const SizedBox(height: 4),
                        const Text(
                            'They must sign in with this exact Google account email.',
                            style: TextStyle(color: kTextSec, fontSize: 12)),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _email,
                                onSubmitted: (_) => _add(),
                                decoration: const InputDecoration(
                                  hintText: 'name@example.com',
                                  prefixIcon: Icon(Icons.mail_outline, size: 20),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            FilledButton(
                              onPressed: _busy ? null : _add,
                              child: _busy
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2, color: Colors.black),
                                    )
                                  : const Text('Add'),
                            ),
                          ],
                        ),
                        if (_error != null) ...[
                          const SizedBox(height: 10),
                          Text(_error!,
                              style: const TextStyle(
                                  color: Colors.redAccent, fontSize: 13)),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                const Text('Current admins',
                    style:
                        TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                const SizedBox(height: 8),
                StreamBuilder<List<String>>(
                  stream: AdminService.I.adminsStream(),
                  builder: (context, snap) {
                    if (!snap.hasData) {
                      return const Padding(
                        padding: EdgeInsets.all(20),
                        child: Center(child: CircularProgressIndicator()),
                      );
                    }
                    final admins = snap.data!;
                    return Card(
                      child: Column(
                        children: [
                          for (final a in admins)
                            ListTile(
                              leading: const Icon(Icons.person_outline),
                              title: Text(a),
                              subtitle: a == me
                                  ? const Text('You',
                                      style: TextStyle(color: kEmerald))
                                  : null,
                              trailing: a == me
                                  ? null
                                  : IconButton(
                                      tooltip: 'Remove',
                                      icon: const Icon(Icons.delete_outline,
                                          color: Colors.redAccent),
                                      onPressed: () => _remove(a),
                                    ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
