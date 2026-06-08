import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_constants.dart';
import 'services/auth_service.dart';

// ── Palette (mirrors main.dart) ───────────────────────────────────────────────
const _bgDark    = Color(0xFF1A1A1A);
const _bgCard    = Color(0xFF252525);
const _bgSurface = Color(0xFF2E2E2E);
const _emerald   = Color(0xFF00C896);
const _textPri   = Color(0xFFFFFFFF);
const _textSec   = Color(0xFF9E9E9E);
const _errorRed  = Color(0xFFCF6679);

// ── Prefs keys ────────────────────────────────────────────────────────────────
const kCarModel = 'car_model';
const kMaxRange = 'max_range_km';

// ── Screen ────────────────────────────────────────────────────────────────────
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  // ── Vehicle prefs ─────────────────────────────────────────────────────────
  final _carCtrl   = TextEditingController();
  final _rangeCtrl = TextEditingController();
  String? _connector;
  bool _saved = false;

  // ── Auth / phone ──────────────────────────────────────────────────────────
  final _phoneCtrl  = TextEditingController();
  bool  _phoneSaving  = false;
  bool  _phoneSaved   = false;
  String _phoneError  = '';

  User? get _user => FirebaseAuth.instance.currentUser;

  @override
  void initState() {
    super.initState();
    _loadVehiclePrefs();
    _loadPhone();
  }

  @override
  void dispose() {
    _carCtrl.dispose();
    _rangeCtrl.dispose();
    _phoneCtrl.dispose();
    super.dispose();
  }

  // ── Vehicle prefs ─────────────────────────────────────────────────────────
  Future<void> _loadVehiclePrefs() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) { return; }
    setState(() {
      _carCtrl.text   = p.getString(kCarModel) ?? '';
      _rangeCtrl.text = p.getString(kMaxRange) ?? '';
      _connector      = p.getString(kDefaultConnector);
    });
  }

  Future<void> _saveVehiclePrefs() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(kCarModel, _carCtrl.text.trim());
    await p.setString(kMaxRange, _rangeCtrl.text.trim());
    if (_connector == null) {
      await p.remove(kDefaultConnector);
    } else {
      await p.setString(kDefaultConnector, _connector!);
    }
    if (!mounted) { return; }
    setState(() => _saved = true);
    await Future.delayed(const Duration(seconds: 2));
    if (mounted) { setState(() => _saved = false); }
  }

  // ── Phone number ──────────────────────────────────────────────────────────
  Future<void> _loadPhone() async {
    debugPrint('[ProfileScreen] _loadPhone start, user=${_user?.uid}');
    if (_user == null) { return; }
    try {
      final digits = await AuthService.fetchPhoneNumber(); // already stripped of +995
      debugPrint('[ProfileScreen] _loadPhone fetched: "$digits"');
      if (!mounted) { return; }
      setState(() => _phoneCtrl.text = digits ?? '');
    } catch (e) {
      // A fetch failure must NOT block saving — log it and leave the field empty.
      debugPrint('[ProfileScreen] _loadPhone ERROR: $e');
    }
  }

  // Returns null if valid, error string if not.
  String? _validatePhone(String value) {
    final digits = value.trim();
    if (digits.isEmpty) { return null; } // optional field — allow empty
    if (!RegExp(r'^5\d{8}$').hasMatch(digits)) {
      return 'Please enter a valid Georgian mobile number (9 digits)';
    }
    return null;
  }

  Future<void> _savePhone() async {
    debugPrint('[ProfileScreen] _savePhone tapped, raw="${_phoneCtrl.text}"');
    if (_phoneSaving) {
      debugPrint('[ProfileScreen] _savePhone ignored — already saving');
      return;
    }
    final digits = _phoneCtrl.text.trim();
    final validationError = _validatePhone(digits);
    if (validationError != null) {
      debugPrint('[ProfileScreen] _savePhone validation failed: $validationError');
      setState(() => _phoneError = validationError);
      return;
    }
    debugPrint('[ProfileScreen] _savePhone saving "+995$digits" for ${_user?.uid}');
    setState(() { _phoneSaving = true; _phoneSaved = false; _phoneError = ''; });
    try {
      await AuthService.savePhoneNumber(digits);
      debugPrint('[ProfileScreen] _savePhone success');
      if (!mounted) { return; }
      setState(() { _phoneSaving = false; _phoneSaved = true; });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Phone number saved!'),
          backgroundColor: Color(0xFF00C896),
          behavior: SnackBarBehavior.floating,
        ),
      );
      await Future.delayed(const Duration(seconds: 2));
      if (mounted) { setState(() => _phoneSaved = false); }
    } catch (e) {
      debugPrint('[ProfileScreen] _savePhone ERROR: $e');
      if (!mounted) { return; }
      setState(() { _phoneSaving = false; _phoneError = ''; });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Error saving phone number'),
          backgroundColor: Color(0xFFCF6679),
          behavior: SnackBarBehavior.floating,
        ),
      );
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
          'My Profile',
          style: TextStyle(
              color: _textPri, fontSize: 17, fontWeight: FontWeight.w600),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 28, 20, 40),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [

            // ══ AUTH SECTION (only when signed in) ═══════════════════════════
            if (_user != null) ...[
              // Avatar + name/email
              Center(
                child: Stack(
                  children: [
                    Container(
                      width: 80, height: 80,
                      decoration: BoxDecoration(
                        color: _bgCard,
                        shape: BoxShape.circle,
                        border: Border.all(color: _emerald, width: 2),
                        boxShadow: const [
                          BoxShadow(color: Colors.black38, blurRadius: 12)
                        ],
                      ),
                      child: _user!.photoURL != null
                          ? ClipOval(
                              child: Image.network(
                                _user!.photoURL!,
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => const Icon(
                                    Icons.person_rounded,
                                    color: _emerald, size: 38),
                              ),
                            )
                          : const Icon(Icons.person_rounded,
                              color: _emerald, size: 38),
                    ),
                    if (_user!.emailVerified)
                      Positioned(
                        right: 0, bottom: 0,
                        child: Container(
                          width: 22, height: 22,
                          decoration: BoxDecoration(
                            color: _emerald,
                            shape: BoxShape.circle,
                            border: Border.all(color: _bgDark, width: 2),
                          ),
                          child: const Icon(Icons.check_rounded,
                              color: Colors.black, size: 13),
                        ),
                      ),
                  ],
                ),
              ),
              if (_user!.displayName != null) ...[
                const SizedBox(height: 8),
                Center(
                  child: Text(
                    _user!.displayName!,
                    style: const TextStyle(
                        color: _textPri,
                        fontSize: 16,
                        fontWeight: FontWeight.w700),
                  ),
                ),
              ],
              const SizedBox(height: 4),
              Center(
                child: Text(
                  _user!.email ?? '',
                  style: const TextStyle(color: _textSec, fontSize: 13),
                ),
              ),
              const SizedBox(height: 24),

              // Email tile
              const _Label('EMAIL'),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 14),
                decoration: BoxDecoration(
                  color: _bgCard,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: _bgSurface),
                ),
                child: Row(children: [
                  const Icon(Icons.email_outlined,
                      color: _textSec, size: 18),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _user!.email ?? '—',
                      style: const TextStyle(
                          color: _textPri, fontSize: 15),
                    ),
                  ),
                  _StatusBadge(
                    label: _user!.emailVerified
                        ? 'Verified'
                        : 'Unverified',
                    color: _user!.emailVerified ? _emerald : _errorRed,
                  ),
                ]),
              ),
              const SizedBox(height: 16),

              // Phone number field
              const _Label('PHONE NUMBER'),
              const SizedBox(height: 8),
              Container(
                decoration: BoxDecoration(
                  color: _bgCard,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: _phoneError.isNotEmpty ? _errorRed : _bgSurface,
                  ),
                ),
                child: Row(children: [
                  const SizedBox(width: 14),
                  const Icon(Icons.phone_outlined, color: _textSec, size: 18),
                  const SizedBox(width: 8),
                  // Static +995 prefix
                  const Text('+995',
                      style: TextStyle(color: _textSec, fontSize: 15)),
                  const SizedBox(width: 4),
                  Expanded(
                    child: TextField(
                      controller: _phoneCtrl,
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(9),
                      ],
                      style: const TextStyle(color: _textPri, fontSize: 15),
                      onChanged: (_) {
                        if (_phoneError.isNotEmpty) {
                          setState(() => _phoneError = '');
                        }
                      },
                      decoration: const InputDecoration(
                        hintText: '5XXXXXXXX',
                        hintStyle: TextStyle(color: _textSec, fontSize: 15),
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(vertical: 14),
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                ]),
              ),
              if (_phoneError.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(_phoneError,
                    style: const TextStyle(color: _errorRed, fontSize: 12)),
              ],
              const SizedBox(height: 8),
              // Privacy notice
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text(
                    'By saving your number you agree to receive service updates from GeoCharge. ',
                    style: TextStyle(color: _textSec, fontSize: 12),
                  ),
                  GestureDetector(
                    onTap: () => launchUrl(
                      Uri.parse('https://experto44.github.io/ev_charger_app/privacy-policy.html'),
                      mode: LaunchMode.externalApplication,
                    ),
                    child: const Text(
                      'Privacy Policy',
                      style: TextStyle(
                        color: _emerald,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        decoration: TextDecoration.underline,
                        decorationColor: _emerald,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              GestureDetector(
                // Only block taps while an actual save is in flight. Gating on
                // _phoneLoading/_phoneSaved previously left the button dead if
                // the initial Firestore load ever failed or hung.
                onTap: _phoneSaving ? null : _savePhone,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  height: 44,
                  decoration: BoxDecoration(
                    color: _phoneSaved ? _bgCard : _emerald,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: _emerald),
                  ),
                  child: Center(
                    child: _phoneSaving
                        ? const SizedBox(
                            width: 20, height: 20,
                            child: CircularProgressIndicator(
                                strokeWidth: 2.5, color: Colors.black),
                          )
                        : Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                _phoneSaved
                                    ? Icons.check_circle_rounded
                                    : Icons.save_rounded,
                                color: _phoneSaved
                                    ? _emerald
                                    : Colors.black,
                                size: 18,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                _phoneSaved ? 'Saved!' : 'Save',
                                style: TextStyle(
                                  color: _phoneSaved
                                      ? _emerald
                                      : Colors.black,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                  ),
                ),
              ),
              const SizedBox(height: 28),
              const Divider(color: _bgSurface, thickness: 1),
              const SizedBox(height: 20),
            ],

            // ══ VEHICLE SECTION ═══════════════════════════════════════════════
            // Avatar icon (shown when NOT signed in, replaced by user photo above)
            if (_user == null) ...[
              Center(
                child: Container(
                  width: 80, height: 80,
                  decoration: BoxDecoration(
                    color: _bgCard,
                    shape: BoxShape.circle,
                    border: Border.all(color: _emerald, width: 2),
                    boxShadow: const [
                      BoxShadow(color: Colors.black38, blurRadius: 12)
                    ],
                  ),
                  child: const Icon(Icons.directions_car_rounded,
                      color: _emerald, size: 38),
                ),
              ),
              const SizedBox(height: 8),
              const Center(
                child: Text(
                  'Vehicle & Driver Info',
                  style: TextStyle(color: _textSec, fontSize: 13),
                ),
              ),
              const SizedBox(height: 32),
            ] else ...[
              const _Label('VEHICLE & DRIVER INFO'),
              const SizedBox(height: 16),
            ],

            // Car model
            const _Label('Car Model'),
            const SizedBox(height: 8),
            _Field(
              controller: _carCtrl,
              hint: 'e.g. Tesla Model 3',
              icon: Icons.directions_car_outlined,
              type: TextInputType.text,
            ),
            const SizedBox(height: 20),

            // Connector selector
            const _Label('My Connector'),
            const SizedBox(height: 4),
            const Text(
              'Used as your default filter on the map',
              style: TextStyle(color: _textSec, fontSize: 12),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: kConnectorOrder.map((c) {
                final on = _connector == c;
                return GestureDetector(
                  onTap: () =>
                      setState(() => _connector = on ? null : c),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 9),
                    decoration: BoxDecoration(
                      color: on ? _emerald : _bgCard,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                          color: on ? _emerald : _bgSurface),
                    ),
                    child: Text(
                      c,
                      style: TextStyle(
                        color: on ? Colors.black : _textSec,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 20),

            // Max range
            const _Label('Max Range at 100% Battery'),
            const SizedBox(height: 8),
            _Field(
              controller: _rangeCtrl,
              hint: 'e.g. 450',
              suffix: 'km',
              icon: Icons.battery_full_rounded,
              type: TextInputType.number,
              formatters: [FilteringTextInputFormatter.digitsOnly],
            ),
            const SizedBox(height: 36),

            // Save vehicle prefs
            GestureDetector(
              onTap: _saveVehiclePrefs,
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
                child: Row(
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

            // Sign out (only when signed in, below the save button)
            if (_user != null) ...[
              const SizedBox(height: 20),
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
          ],
        ),
      ),
    );
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────
class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: const TextStyle(
          color: _textSec,
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.6,
        ),
      );
}

class _Field extends StatelessWidget {
  const _Field({
    required this.controller,
    required this.hint,
    required this.icon,
    required this.type,
    this.suffix,
    this.formatters,
  });
  final TextEditingController         controller;
  final String                        hint;
  final IconData                      icon;
  final TextInputType                 type;
  final String?                       suffix;
  final List<TextInputFormatter>?     formatters;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: _bgCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _bgSurface),
      ),
      child: Row(
        children: [
          const SizedBox(width: 14),
          Icon(icon, color: _textSec, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller:      controller,
              keyboardType:    type,
              inputFormatters: formatters,
              style: const TextStyle(color: _textPri, fontSize: 15),
              decoration: InputDecoration(
                hintText:        hint,
                hintStyle:       const TextStyle(
                    color: _textSec, fontSize: 15),
                border:          InputBorder.none,
                isDense:         true,
                contentPadding:
                    const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ),
          if (suffix != null) ...[
            Text(suffix!,
                style: const TextStyle(
                    color: _textSec, fontSize: 13)),
            const SizedBox(width: 14),
          ],
        ],
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.label, required this.color});
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
