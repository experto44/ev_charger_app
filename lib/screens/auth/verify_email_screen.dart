import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../l10n/app_strings.dart';
import '../../services/auth_service.dart';
import '../../utils/responsive.dart';

const _bgDark    = Color(0xFF1A1A1A);
const _bgCard    = Color(0xFF252525);
const _bgSurface = Color(0xFF2E2E2E);
const _emerald   = Color(0xFF00C896);
const _textPri   = Color(0xFFFFFFFF);
const _textSec   = Color(0xFF9E9E9E);
const _errorRed  = Color(0xFFCF6679);

class VerifyEmailScreen extends StatefulWidget {
  const VerifyEmailScreen({super.key});

  @override
  State<VerifyEmailScreen> createState() => _VerifyEmailScreenState();
}

class _VerifyEmailScreenState extends State<VerifyEmailScreen> {
  bool   _resending       = false;
  bool   _resent          = false;
  bool   _checking        = false;
  String _error           = '';
  // 30-second cooldown between resend attempts.
  int    _cooldownSeconds = 0;
  Timer? _cooldownTimer;

  String get _email =>
      FirebaseAuth.instance.currentUser?.email ?? '';

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    super.dispose();
  }

  void _startCooldown() {
    setState(() => _cooldownSeconds = 30);
    _cooldownTimer?.cancel();
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) { t.cancel(); return; }
      setState(() {
        _cooldownSeconds--;
        if (_cooldownSeconds <= 0) { t.cancel(); }
      });
    });
  }

  Future<void> _resend() async {
    if (_cooldownSeconds > 0 || _resending) { return; }
    setState(() { _resending = true; _resent = false; _error = ''; });
    try {
      await AuthService.resendVerificationEmail();
      if (mounted) {
        setState(() { _resending = false; _resent = true; });
        _startCooldown();
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _resending = false;
          _error = 'Failed to resend. Please try again.';
        });
      }
    }
  }

  Future<void> _checkVerified() async {
    setState(() { _checking = true; _error = ''; });
    try {
      await AuthService.reloadUser();
      final verified =
          FirebaseAuth.instance.currentUser?.emailVerified ?? false;
      if (!mounted) { return; }
      if (!verified) {
        setState(() {
          _checking = false;
          _error = "Email not verified yet. Please check your inbox and click the link.";
        });
      }
      // If verified, the FirebaseAuth stream fires → AuthWrapper navigates to the app.
    } catch (_) {
      if (mounted) {
        setState(() {
          _checking = false;
          _error = 'Verification check failed. Please try again.';
        });
      }
    }
  }

  Future<void> _signOut() async {
    await AuthService.signOut();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bgDark,
      body: SafeArea(
        child: CenteredConstrained(
          maxWidth: 400,
          child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(),

              // ── Illustration ─────────────────────────────────────────────
              Center(
                child: Container(
                  width: 88, height: 88,
                  decoration: BoxDecoration(
                    color: _bgCard,
                    shape: BoxShape.circle,
                    border: Border.all(color: _emerald, width: 2),
                  ),
                  child: const Icon(Icons.mark_email_unread_outlined,
                      color: _emerald, size: 42),
                ),
              ),
              const SizedBox(height: 28),

              // ── Title ────────────────────────────────────────────────────
              const Text(
                'Verify your email',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: _textPri,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 12),

              // ── Description ──────────────────────────────────────────────
              Text(
                'A verification link was sent to:\n$_email\n\nOpen your inbox and click the link to continue.',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: _textSec,
                  fontSize: 14,
                  height: 1.6,
                ),
              ),

              // ── Error ────────────────────────────────────────────────────
              if (_error.isNotEmpty) ...[
                const SizedBox(height: 20),
                _ErrorBanner(_error),
              ],

              // ── Resent confirmation ──────────────────────────────────────
              if (_resent && _error.isEmpty) ...[
                const SizedBox(height: 20),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: _emerald.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                    border:
                        Border.all(color: _emerald.withValues(alpha: 0.4)),
                  ),
                  child: Row(children: [
                    const Icon(Icons.check_circle_outline_rounded,
                        color: _emerald, size: 17),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        AppStrings.verificationEmailSent,
                        style: AppStrings.font(
                            const TextStyle(color: _emerald, fontSize: 13)),
                      ),
                    ),
                  ]),
                ),
              ],

              const Spacer(),

              // ── Continue button ──────────────────────────────────────────
              GestureDetector(
                onTap: _checking ? null : _checkVerified,
                child: Container(
                  height: 52,
                  decoration: BoxDecoration(
                    color: _emerald,
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: const [
                      BoxShadow(
                          color: Colors.black38,
                          blurRadius: 10,
                          offset: Offset(0, 4))
                    ],
                  ),
                  child: Center(
                    child: _checking
                        ? const SizedBox(
                            width: 22, height: 22,
                            child: CircularProgressIndicator(
                                strokeWidth: 2.5, color: Colors.black),
                          )
                        : const Text(
                            "I've verified — Continue",
                            style: TextStyle(
                              color: Colors.black,
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                  ),
                ),
              ),
              const SizedBox(height: 14),

              // ── Resend button ────────────────────────────────────────────
              GestureDetector(
                onTap: (_cooldownSeconds > 0 || _resending) ? null : _resend,
                child: Container(
                  height: 52,
                  decoration: BoxDecoration(
                    color: _bgCard,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: _bgSurface),
                  ),
                  child: Center(
                    child: _resending
                        ? const SizedBox(
                            width: 20, height: 20,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: _emerald),
                          )
                        : Text(
                            _cooldownSeconds > 0
                                ? 'Resend email ($_cooldownSeconds s)'
                                : 'Resend email',
                            style: TextStyle(
                              color: _cooldownSeconds > 0
                                  ? _textSec
                                  : _textPri,
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                  ),
                ),
              ),
              const SizedBox(height: 20),

              // ── Sign out link ────────────────────────────────────────────
              Center(
                child: GestureDetector(
                  onTap: _signOut,
                  child: const Text(
                    'Use a different account',
                    style: TextStyle(
                      color: _textSec,
                      fontSize: 13,
                      decoration: TextDecoration.underline,
                      decorationColor: _textSec,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 40),
            ],
          ),
        ),
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner(this.message);
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: _errorRed.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _errorRed.withValues(alpha: 0.4)),
      ),
      child: Row(children: [
        const Icon(Icons.error_outline_rounded, color: _errorRed, size: 17),
        const SizedBox(width: 8),
        Expanded(
          child: Text(message,
              style: const TextStyle(color: _errorRed, fontSize: 13)),
        ),
      ]),
    );
  }
}
