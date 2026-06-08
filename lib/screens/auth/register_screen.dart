import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../services/auth_service.dart';
import 'verify_email_screen.dart';

const _bgDark    = Color(0xFF1A1A1A);
const _bgCard    = Color(0xFF252525);
const _bgSurface = Color(0xFF2E2E2E);
const _emerald   = Color(0xFF00C896);
const _textPri   = Color(0xFFFFFFFF);
const _textSec   = Color(0xFF9E9E9E);
const _errorRed  = Color(0xFFCF6679);

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _formKey     = GlobalKey<FormState>();
  final _emailCtrl   = TextEditingController();
  final _passCtrl    = TextEditingController();
  final _confirmCtrl = TextEditingController();

  bool   _obscurePass    = true;
  bool   _obscureConfirm = true;
  bool   _loading        = false;
  String _error          = '';

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  void _setError(String msg) {
    if (mounted) { setState(() { _error = msg; _loading = false; }); }
  }

  Future<void> _register() async {
    if (!_formKey.currentState!.validate()) { return; }
    setState(() { _loading = true; _error = ''; });
    try {
      await AuthService.registerWithEmail(_emailCtrl.text, _passCtrl.text);
      if (!mounted) { return; }
      // Stop the spinner before navigating to the verify-email screen.
      setState(() => _loading = false);
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const VerifyEmailScreen()),
      );
    } on FirebaseAuthException catch (e) {
      _setError(_authMessage(e.code));
    } catch (_) {
      _setError('Registration failed. Please try again.');
    }
  }

  String _authMessage(String code) {
    switch (code) {
      case 'email-already-in-use':  return 'An account with this email already exists.';
      case 'invalid-email':         return 'Invalid email address.';
      case 'weak-password':         return 'Password must be at least 6 characters.';
      case 'operation-not-allowed': return 'Email registration is currently disabled.';
      default:                      return 'An error occurred. Please try again.';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bgDark,
      appBar: AppBar(
        backgroundColor: _bgDark,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded,
              color: _textPri, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 12),

                // ── Header ───────────────────────────────────────────────────
                const Text(
                  'Create an account',
                  style: TextStyle(
                    color: _textPri,
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Enter your details to get started',
                  style: TextStyle(color: _textSec, fontSize: 14),
                ),
                const SizedBox(height: 36),

                // ── Email ────────────────────────────────────────────────────
                _Field(
                  controller: _emailCtrl,
                  hint: 'Email',
                  icon: Icons.email_outlined,
                  type: TextInputType.emailAddress,
                  validator: (v) {
                    if (v == null || v.trim().isEmpty) {
                      return 'Please enter your email';
                    }
                    if (!v.contains('@')) { return 'Invalid email address'; }
                    return null;
                  },
                ),
                const SizedBox(height: 14),

                // ── Password ─────────────────────────────────────────────────
                _Field(
                  controller: _passCtrl,
                  hint:    'Password',
                  icon:    Icons.lock_outline_rounded,
                  obscure: _obscurePass,
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscurePass
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                      color: _textSec, size: 20,
                    ),
                    onPressed: () =>
                        setState(() => _obscurePass = !_obscurePass),
                  ),
                  validator: (v) {
                    if (v == null || v.isEmpty) {
                      return 'Please enter a password';
                    }
                    if (v.length < 6) {
                      return 'Password must be at least 6 characters';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 14),

                // ── Confirm password ──────────────────────────────────────────
                _Field(
                  controller: _confirmCtrl,
                  hint:    'Confirm password',
                  icon:    Icons.lock_outline_rounded,
                  obscure: _obscureConfirm,
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscureConfirm
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                      color: _textSec, size: 20,
                    ),
                    onPressed: () =>
                        setState(() => _obscureConfirm = !_obscureConfirm),
                  ),
                  validator: (v) {
                    if (v != _passCtrl.text) { return 'Passwords do not match'; }
                    return null;
                  },
                ),

                // ── Error ─────────────────────────────────────────────────────
                if (_error.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  _ErrorBanner(_error),
                ],
                const SizedBox(height: 32),

                // ── Register button ───────────────────────────────────────────
                GestureDetector(
                  onTap: _loading ? null : _register,
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
                      child: _loading
                          ? const SizedBox(
                              width: 22, height: 22,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2.5, color: Colors.black),
                            )
                          : const Text(
                              'Create Account',
                              style: TextStyle(
                                color: Colors.black,
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                    ),
                  ),
                ),
                const SizedBox(height: 28),

                // ── Back to login ─────────────────────────────────────────────
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  const Text('Already have an account? ',
                      style: TextStyle(color: _textSec, fontSize: 14)),
                  GestureDetector(
                    onTap: () => Navigator.pop(context),
                    child: const Text(
                      'Sign In',
                      style: TextStyle(
                        color: _emerald,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ]),
                const SizedBox(height: 40),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Shared widgets ─────────────────────────────────────────────────────────────
class _Field extends StatelessWidget {
  const _Field({
    required this.controller,
    required this.hint,
    required this.icon,
    this.type       = TextInputType.text,
    this.obscure    = false,
    this.suffixIcon,
    this.validator,
  });
  final TextEditingController      controller;
  final String                     hint;
  final IconData                   icon;
  final TextInputType              type;
  final bool                       obscure;
  final Widget?                    suffixIcon;
  final String? Function(String?)? validator;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: _bgCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _bgSurface),
      ),
      child: TextFormField(
        controller:   controller,
        keyboardType: type,
        obscureText:  obscure,
        style:        const TextStyle(color: _textPri, fontSize: 15),
        validator:    validator,
        decoration: InputDecoration(
          hintText:       hint,
          hintStyle:      const TextStyle(color: _textSec, fontSize: 15),
          prefixIcon:     Icon(icon, color: _textSec, size: 20),
          suffixIcon:     suffixIcon,
          border:         InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(vertical: 16),
          errorStyle:     const TextStyle(color: _errorRed, fontSize: 11),
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
