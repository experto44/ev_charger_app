import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import '../../services/auth_service.dart';
import 'register_screen.dart';

// ── Palette ───────────────────────────────────────────────────────────────────
const _bgDark    = Color(0xFF1A1A1A);
const _bgCard    = Color(0xFF252525);
const _bgSurface = Color(0xFF2E2E2E);
const _emerald   = Color(0xFF00C896);
const _textPri   = Color(0xFFFFFFFF);
const _textSec   = Color(0xFF9E9E9E);
const _errorRed  = Color(0xFFCF6679);

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey   = GlobalKey<FormState>();
  final _emailCtrl = TextEditingController();
  final _passCtrl  = TextEditingController();

  bool   _obscure = true;
  bool   _loading = false;
  String _error   = '';

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  void _setError(String msg) {
    if (mounted) { setState(() { _error = msg; _loading = false; }); }
  }

  Future<void> _signIn() async {
    if (!_formKey.currentState!.validate()) { return; }
    setState(() { _loading = true; _error = ''; });
    try {
      await AuthService.signInWithEmail(_emailCtrl.text, _passCtrl.text);
      // Success → close the auth screens and return to the app. We pop
      // explicitly rather than waiting on authStateChanges, which does NOT
      // re-fire when this account is already the current user (that was the
      // "stuck on the login screen" bug).
      if (mounted) { Navigator.pop(context); }
    } on FirebaseAuthException catch (e) {
      _setError(_authMessage(e.code));
    } catch (_) {
      _setError('Sign in failed. Please try again.');
    }
  }

  Future<void> _googleSignIn() async {
    setState(() { _loading = true; _error = ''; });
    try {
      final cred = await AuthService.signInWithGoogle();
      if (!mounted) { return; }
      if (cred == null) {
        setState(() => _loading = false); // user cancelled the Google sheet
      } else {
        Navigator.pop(context);            // signed in → return to the app
      }
    } on FirebaseAuthException catch (e) {
      _setError(_authMessage(e.code));
    } catch (_) {
      _setError('Google sign-in failed. Please try again.');
    }
  }

  Future<void> _appleSignIn() async {
    setState(() { _loading = true; _error = ''; });
    try {
      await AuthService.signInWithApple();
      if (mounted) { Navigator.pop(context); } // signed in → return to the app
    } on SignInWithAppleAuthorizationException catch (e) {
      // Treat a user-cancelled sheet as a no-op, not an error.
      if (e.code == AuthorizationErrorCode.canceled) {
        if (mounted) { setState(() => _loading = false); }
      } else {
        _setError('Apple sign-in failed. Please try again.');
      }
    } on FirebaseAuthException catch (e) {
      _setError(_authMessage(e.code));
    } catch (_) {
      _setError('Apple sign-in failed. Please try again.');
    }
  }

  String _authMessage(String code) {
    switch (code) {
      case 'user-not-found':     return 'No account found with this email.';
      case 'wrong-password':     return 'Incorrect password.';
      case 'invalid-credential': return 'Incorrect email or password.';
      case 'invalid-email':      return 'Invalid email address.';
      case 'user-disabled':      return 'This account has been disabled.';
      case 'too-many-requests':  return 'Too many attempts. Please try again later.';
      default:                   return 'An error occurred. Please try again.';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bgDark,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 60),

                // ── Logo / brand ─────────────────────────────────────────────
                Column(
                  children: [
                    Container(
                      width: 72, height: 72,
                      decoration: BoxDecoration(
                        color: _bgCard,
                        shape: BoxShape.circle,
                        border: Border.all(color: _emerald, width: 2),
                      ),
                      child: const Icon(Icons.ev_station_rounded,
                          color: _emerald, size: 36),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'GeoCharge',
                      style: TextStyle(
                        color: _textPri,
                        fontSize: 26,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Sign in to your account',
                      style: TextStyle(color: _textSec, fontSize: 14),
                    ),
                  ],
                ),
                const SizedBox(height: 44),

                // ── Email ─────────────────────────────────────────────────────
                _AuthField(
                  controller: _emailCtrl,
                  hint:  'Email',
                  icon:  Icons.email_outlined,
                  type:  TextInputType.emailAddress,
                  validator: (v) {
                    if (v == null || v.trim().isEmpty) {
                      return 'Please enter your email';
                    }
                    if (!v.contains('@')) { return 'Invalid email address'; }
                    return null;
                  },
                ),
                const SizedBox(height: 14),

                // ── Password ──────────────────────────────────────────────────
                _AuthField(
                  controller: _passCtrl,
                  hint:    'Password',
                  icon:    Icons.lock_outline_rounded,
                  obscure: _obscure,
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscure
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                      color: _textSec, size: 20,
                    ),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                  validator: (v) {
                    if (v == null || v.isEmpty) {
                      return 'Please enter your password';
                    }
                    return null;
                  },
                ),

                // ── Error message ─────────────────────────────────────────────
                if (_error.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _ErrorBanner(_error),
                ],
                const SizedBox(height: 24),

                // ── Sign in button ────────────────────────────────────────────
                _PrimaryButton(
                  label:   'Sign In',
                  loading: _loading,
                  onTap:   _signIn,
                ),
                const SizedBox(height: 16),

                // ── Divider ───────────────────────────────────────────────────
                const Row(children: [
                  Expanded(child: Divider(color: _bgSurface)),
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12),
                    child: Text('or', style: TextStyle(color: _textSec, fontSize: 13)),
                  ),
                  Expanded(child: Divider(color: _bgSurface)),
                ]),
                const SizedBox(height: 16),

                // ── Google Sign-In ────────────────────────────────────────────
                _GoogleButton(loading: _loading, onTap: _googleSignIn),

                // ── Sign in with Apple (iOS only — App Store Guideline 4.8) ────
                if (defaultTargetPlatform == TargetPlatform.iOS) ...[
                  const SizedBox(height: 12),
                  Opacity(
                    opacity: _loading ? 0.6 : 1,
                    child: IgnorePointer(
                      ignoring: _loading,
                      child: SignInWithAppleButton(
                        onPressed: _appleSignIn,
                        height: 52,
                        borderRadius: BorderRadius.circular(14),
                        style: SignInWithAppleButtonStyle.white,
                        text: 'Continue with Apple',
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 36),

                // ── Register link ─────────────────────────────────────────────
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  const Text("Don't have an account? ",
                      style: TextStyle(color: _textSec, fontSize: 14)),
                  GestureDetector(
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const RegisterScreen()),
                    ),
                    child: const Text(
                      'Register',
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
class _AuthField extends StatelessWidget {
  const _AuthField({
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

class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({
    required this.label,
    required this.loading,
    required this.onTap,
  });
  final String       label;
  final bool         loading;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: loading ? null : onTap,
      child: Container(
        height: 52,
        decoration: BoxDecoration(
          color: _emerald,
          borderRadius: BorderRadius.circular(14),
          boxShadow: const [
            BoxShadow(color: Colors.black38, blurRadius: 10, offset: Offset(0, 4))
          ],
        ),
        child: Center(
          child: loading
              ? const SizedBox(
                  width: 22, height: 22,
                  child: CircularProgressIndicator(
                      strokeWidth: 2.5, color: Colors.black),
                )
              : Text(label,
                  style: const TextStyle(
                    color: Colors.black,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  )),
        ),
      ),
    );
  }
}

class _GoogleButton extends StatelessWidget {
  const _GoogleButton({required this.loading, required this.onTap});
  final bool         loading;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: loading ? null : onTap,
      child: Container(
        height: 52,
        decoration: BoxDecoration(
          color: _bgCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _bgSurface),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            RichText(
              text: const TextSpan(
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                children: [
                  TextSpan(text: 'G', style: TextStyle(color: Color(0xFF4285F4))),
                  TextSpan(text: 'o', style: TextStyle(color: Color(0xFFEA4335))),
                  TextSpan(text: 'o', style: TextStyle(color: Color(0xFFFBBC05))),
                  TextSpan(text: 'g', style: TextStyle(color: Color(0xFF4285F4))),
                  TextSpan(text: 'l', style: TextStyle(color: Color(0xFF34A853))),
                  TextSpan(text: 'e', style: TextStyle(color: Color(0xFFEA4335))),
                ],
              ),
            ),
            const SizedBox(width: 10),
            const Text(
              'Continue with Google',
              style: TextStyle(
                color: _textPri,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
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
