import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/auth_service.dart';

const _bgDark    = Color(0xFF1A1A1A);
const _bgCard    = Color(0xFF252525);
const _bgSurface = Color(0xFF2E2E2E);
const _emerald   = Color(0xFF00C896);
const _textPri   = Color(0xFFFFFFFF);
const _textSec   = Color(0xFF9E9E9E);
const _errorRed  = Color(0xFFCF6679);

class AuthProfileScreen extends StatefulWidget {
  const AuthProfileScreen({super.key});

  @override
  State<AuthProfileScreen> createState() => _AuthProfileScreenState();
}

class _AuthProfileScreenState extends State<AuthProfileScreen> {
  final _phoneCtrl = TextEditingController();
  bool   _loading  = true;
  bool   _saving   = false;
  bool   _saved    = false;
  String _error    = '';

  User? get _user => FirebaseAuth.instance.currentUser;

  @override
  void initState() {
    super.initState();
    _loadPhone();
  }

  @override
  void dispose() {
    _phoneCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadPhone() async {
    final phone = await AuthService.fetchPhoneNumber();
    if (!mounted) { return; }
    setState(() {
      _phoneCtrl.text = phone ?? '';
      _loading = false;
    });
  }

  Future<void> _save() async {
    if (_saving) { return; }
    setState(() { _saving = true; _saved = false; _error = ''; });
    try {
      await AuthService.savePhoneNumber(_phoneCtrl.text);
      if (!mounted) { return; }
      setState(() { _saving = false; _saved = true; });
      await Future.delayed(const Duration(seconds: 2));
      if (mounted) { setState(() => _saved = false); }
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error  = 'Failed to save. Please try again.';
        });
      }
    }
  }

  Future<void> _signOut() async {
    await AuthService.signOut();
    if (mounted) { Navigator.pop(context); }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bgDark,
      appBar: AppBar(
        backgroundColor: _bgCard,
        elevation: 0,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded,
              color: _textPri, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          'Profile',
          style: TextStyle(
              color: _textPri, fontSize: 17, fontWeight: FontWeight.w600),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout_rounded, color: _textSec, size: 22),
            tooltip: 'Sign out',
            onPressed: _signOut,
          ),
        ],
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: _emerald, strokeWidth: 2),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 32, 20, 40),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── Avatar ────────────────────────────────────────────────
                  Center(
                    child: Stack(
                      children: [
                        Container(
                          width: 84, height: 84,
                          decoration: BoxDecoration(
                            color: _bgCard,
                            shape: BoxShape.circle,
                            border: Border.all(color: _emerald, width: 2),
                            boxShadow: const [
                              BoxShadow(color: Colors.black38, blurRadius: 12)
                            ],
                          ),
                          child: _user?.photoURL != null
                              ? ClipOval(
                                  child: Image.network(
                                    _user!.photoURL!,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, __, ___) =>
                                        const Icon(Icons.person_rounded,
                                            color: _emerald, size: 40),
                                  ),
                                )
                              : const Icon(Icons.person_rounded,
                                  color: _emerald, size: 40),
                        ),
                        if (_user?.emailVerified == true)
                          Positioned(
                            right: 0, bottom: 0,
                            child: Container(
                              width: 24, height: 24,
                              decoration: BoxDecoration(
                                color: _emerald,
                                shape: BoxShape.circle,
                                border: Border.all(color: _bgDark, width: 2),
                              ),
                              child: const Icon(Icons.check_rounded,
                                  color: Colors.black, size: 14),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  if (_user?.displayName != null) ...[
                    Center(
                      child: Text(
                        _user!.displayName!,
                        style: const TextStyle(
                          color: _textPri,
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                  ],
                  Center(
                    child: Text(
                      _user?.email ?? '',
                      style: const TextStyle(color: _textSec, fontSize: 13),
                    ),
                  ),
                  const SizedBox(height: 36),

                  // ── Email (read-only) ──────────────────────────────────────
                  const _SectionLabel('EMAIL'),
                  const SizedBox(height: 8),
                  _InfoTile(
                    icon:  Icons.email_outlined,
                    value: _user?.email ?? '—',
                    trailing: _user?.emailVerified == true
                        ? _Badge('Verified', _emerald)
                        : _Badge('Unverified', _errorRed),
                  ),
                  const SizedBox(height: 24),

                  // ── Phone number ──────────────────────────────────────────
                  const _SectionLabel('PHONE NUMBER'),
                  const SizedBox(height: 8),
                  Container(
                    decoration: BoxDecoration(
                      color: _bgCard,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: _bgSurface),
                    ),
                    child: Row(children: [
                      const SizedBox(width: 14),
                      const Icon(Icons.phone_outlined,
                          color: _textSec, size: 20),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: _phoneCtrl,
                          keyboardType: TextInputType.phone,
                          inputFormatters: [
                            FilteringTextInputFormatter.allow(
                                RegExp(r'[0-9+\-\s()]')),
                          ],
                          style: const TextStyle(
                              color: _textPri, fontSize: 15),
                          decoration: const InputDecoration(
                            hintText: '+995 5XX XXX XXX',
                            hintStyle:
                                TextStyle(color: _textSec, fontSize: 15),
                            border: InputBorder.none,
                            isDense: true,
                            contentPadding:
                                EdgeInsets.symmetric(vertical: 16),
                          ),
                        ),
                      ),
                      const SizedBox(width: 14),
                    ]),
                  ),

                  // ── Error ─────────────────────────────────────────────────
                  if (_error.isNotEmpty) ...[
                    const SizedBox(height: 14),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: _errorRed.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                            color: _errorRed.withValues(alpha: 0.4)),
                      ),
                      child: Row(children: [
                        const Icon(Icons.error_outline_rounded,
                            color: _errorRed, size: 17),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(_error,
                              style: const TextStyle(
                                  color: _errorRed, fontSize: 13)),
                        ),
                      ]),
                    ),
                  ],
                  const SizedBox(height: 32),

                  // ── Save button ───────────────────────────────────────────
                  GestureDetector(
                    onTap: (_saving || _saved) ? null : _save,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 250),
                      height: 52,
                      decoration: BoxDecoration(
                        color: _saved ? _bgCard : _emerald,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: _emerald),
                        boxShadow: _saved
                            ? []
                            : const [
                                BoxShadow(
                                    color: Colors.black38,
                                    blurRadius: 10,
                                    offset: Offset(0, 4))
                              ],
                      ),
                      child: Center(
                        child: _saving
                            ? const SizedBox(
                                width: 22, height: 22,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2.5, color: Colors.black),
                              )
                            : Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    _saved
                                        ? Icons.check_circle_rounded
                                        : Icons.save_rounded,
                                    color: _saved ? _emerald : Colors.black,
                                    size: 20,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    _saved ? 'Saved!' : 'Save',
                                    style: TextStyle(
                                      color: _saved ? _emerald : Colors.black,
                                      fontSize: 15,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 32),

                  // ── Sign out ──────────────────────────────────────────────
                  GestureDetector(
                    onTap: _signOut,
                    child: Container(
                      height: 52,
                      decoration: BoxDecoration(
                        color: _bgCard,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                            color: _errorRed.withValues(alpha: 0.5)),
                      ),
                      child: const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.logout_rounded,
                              color: _errorRed, size: 20),
                          SizedBox(width: 8),
                          Text(
                            'Sign Out',
                            style: TextStyle(
                              color: _errorRed,
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────
class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: const TextStyle(
          color: _textSec,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
        ),
      );
}

class _InfoTile extends StatelessWidget {
  const _InfoTile({
    required this.icon,
    required this.value,
    this.trailing,
  });
  final IconData icon;
  final String   value;
  final Widget?  trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      decoration: BoxDecoration(
        color: _bgCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _bgSurface),
      ),
      child: Row(children: [
        Icon(icon, color: _textSec, size: 20),
        const SizedBox(width: 12),
        Expanded(
          child: Text(value,
              style: const TextStyle(color: _textPri, fontSize: 15)),
        ),
        if (trailing != null) trailing!,
      ]),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge(this.label, this.color);
  final String label;
  final Color  color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        label,
        style: TextStyle(
            color: color, fontSize: 11, fontWeight: FontWeight.w700),
      ),
    );
  }
}
