import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_constants.dart';

// ── Palette (mirrors main.dart) ───────────────────────────────────────────────
const _bgDark    = Color(0xFF1A1A1A);
const _bgCard    = Color(0xFF252525);
const _bgSurface = Color(0xFF2E2E2E);
const _emerald   = Color(0xFF00C896);
const _textPri   = Color(0xFFFFFFFF);
const _textSec   = Color(0xFF9E9E9E);

class CountriesScreen extends StatefulWidget {
  const CountriesScreen({super.key});

  @override
  State<CountriesScreen> createState() => _CountriesScreenState();
}

class _CountriesScreenState extends State<CountriesScreen> {
  // Default: only Georgia selected. Users opt into other countries (which then
  // load live from Open Charge Map).
  Set<String> _active = {'Georgia'};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p   = await SharedPreferences.getInstance();
    final raw = p.getString(kActiveCountries);
    if (raw != null) {
      try {
        final list = (jsonDecode(raw) as List).map((e) => e as String).toSet();
        if (mounted) { setState(() => _active = list); }
      } catch (_) {/* keep default */}
    }
  }

  Future<void> _toggle(String name) async {
    setState(() {
      if (_active.contains(name)) {
        _active.remove(name);
      } else {
        _active.add(name);
      }
    });
    final p = await SharedPreferences.getInstance();
    await p.setString(kActiveCountries, jsonEncode(_active.toList()));
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
        title: const Text('Countries',
            style: TextStyle(color: _textPri, fontSize: 17, fontWeight: FontWeight.w600)),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 40),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // No premium tile here: this page is only ever reached from the
            // profile, which shows that card one tap earlier. It carried its own
            // copy back when a gear on the map opened it directly.
            const Text('COUNTRIES',
                style: TextStyle(
                    color: _textSec, fontSize: 12,
                    fontWeight: FontWeight.w600, letterSpacing: 0.6)),
            const SizedBox(height: 6),
            const Text('Show charging stations in these countries',
                style: TextStyle(color: _textSec, fontSize: 12)),
            const SizedBox(height: 14),
            ...kCountries.map((c) {
              final on = _active.contains(c.name);
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: GestureDetector(
                  onTap: () => _toggle(c.name),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    decoration: BoxDecoration(
                      color: _bgCard,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: on ? _emerald : _bgSurface),
                    ),
                    child: Row(children: [
                      Text(c.flag, style: const TextStyle(fontSize: 22)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(c.name,
                            style: const TextStyle(
                                color: _textPri, fontSize: 15, fontWeight: FontWeight.w500)),
                      ),
                      Icon(
                        on ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded,
                        color: on ? _emerald : _textSec, size: 24,
                      ),
                    ]),
                  ),
                ),
              );
            }),
          ],
        ),
      ),
    );
  }
}
