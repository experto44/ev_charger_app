import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_constants.dart';

// ── Palette (mirrors main.dart) ───────────────────────────────────────────────
const _bgDark    = Color(0xFF1A1A1A);
const _bgCard    = Color(0xFF252525);
const _bgSurface = Color(0xFF2E2E2E);
const _emerald   = Color(0xFF00C896);
const _textPri   = Color(0xFFFFFFFF);
const _textSec   = Color(0xFF9E9E9E);

// ── Prefs keys ────────────────────────────────────────────────────────────────
const kCarModel  = 'car_model';
const kMaxRange  = 'max_range_km';

// ── Screen ────────────────────────────────────────────────────────────────────
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final _carCtrl   = TextEditingController();
  final _rangeCtrl = TextEditingController();
  String? _connector;            // default connector (single-select, nullable)
  bool _saved = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _carCtrl.dispose();
    _rangeCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) { return; }
    setState(() {
      _carCtrl.text   = p.getString(kCarModel) ?? '';
      _rangeCtrl.text = p.getString(kMaxRange) ?? '';
      _connector      = p.getString(kDefaultConnector);
    });
  }

  Future<void> _save() async {
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bgDark,
      appBar: AppBar(
        backgroundColor: _bgCard,
        elevation: 0,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: _textPri, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          'My Profile',
          style: TextStyle(color: _textPri, fontSize: 17, fontWeight: FontWeight.w600),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 28, 20, 40),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Avatar ───────────────────────────────────────────────────────
            Center(
              child: Container(
                width: 80, height: 80,
                decoration: BoxDecoration(
                  color: _bgCard,
                  shape: BoxShape.circle,
                  border: Border.all(color: _emerald, width: 2),
                  boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 12)],
                ),
                child: const Icon(Icons.directions_car_rounded, color: _emerald, size: 38),
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

            // ── Car model ─────────────────────────────────────────────────────
            const _Label('Car Model'),
            const SizedBox(height: 8),
            _Field(
              controller: _carCtrl,
              hint: 'e.g. Tesla Model 3',
              icon: Icons.directions_car_outlined,
              type: TextInputType.text,
            ),
            const SizedBox(height: 20),

            // ── My Connector (single-select default) ──────────────────────────
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
                  onTap: () => setState(() => _connector = on ? null : c),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                    decoration: BoxDecoration(
                      color: on ? _emerald : _bgCard,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: on ? _emerald : _bgSurface),
                    ),
                    child: Text(
                      c,
                      style: TextStyle(
                        color: on ? Colors.black : _textSec,
                        fontSize: 13, fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 20),

            // ── Max range ─────────────────────────────────────────────────────
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

            // ── Save button ───────────────────────────────────────────────────
            GestureDetector(
              onTap: _save,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                height: 52,
                decoration: BoxDecoration(
                  color: _saved ? _bgCard : _emerald,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: _emerald),
                  boxShadow: _saved
                      ? []
                      : const [BoxShadow(color: Colors.black38, blurRadius: 10, offset: Offset(0, 4))],
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      _saved ? Icons.check_circle_rounded : Icons.save_rounded,
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
      color: _textSec, fontSize: 12,
      fontWeight: FontWeight.w600, letterSpacing: 0.6,
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
  final TextEditingController controller;
  final String hint;
  final IconData icon;
  final TextInputType type;
  final String? suffix;
  final List<TextInputFormatter>? formatters;

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
              controller: controller,
              keyboardType: type,
              inputFormatters: formatters,
              style: const TextStyle(color: _textPri, fontSize: 15),
              decoration: InputDecoration(
                hintText: hint,
                hintStyle: const TextStyle(color: _textSec, fontSize: 15),
                border: InputBorder.none,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ),
          if (suffix != null) ...[
            Text(suffix!, style: const TextStyle(color: _textSec, fontSize: 13)),
            const SizedBox(width: 14),
          ],
        ],
      ),
    );
  }
}
