import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/app_strings.dart';
import '../services/ad_service.dart';
import '../services/expenses_service.dart';
import '../services/purchase_service.dart';

// ── Palette (mirrors the expenses screen) ────────────────────────────────────
const _bgDark    = Color(0xFF1A1A1A);
const _bgCard    = Color(0xFF252525);
const _bgSurface = Color(0xFF2E2E2E);
const _emerald   = Color(0xFF00C896);
const _blue      = Color(0xFF4C9AFF);
const _textPri   = Color(0xFFFFFFFF);
const _textSec   = Color(0xFF9E9E9E);

/// The power ratings a driver actually meets in Georgia, from the charger feed:
/// 22 kW and 120 kW dominate, 7 kW is the usual home socket. Tapping one only
/// fills the field in, so anything else can still be typed.
const _powerPresets = <int>[7, 22, 60, 120, 160];

/// Median DC tariff across Georgia, the same default the website's calculator
/// opens with. It moves slowly (a few tetri a year), and whatever the driver
/// types over it is remembered, so a constant is honest here.
const _defaultTariff = 0.78;

/// Share of its peak DC rate a pack accepts, per 10 percent band of charge.
/// Flat while the pack is empty, then the taper that every fast charge ends in.
///
/// Kept identical to `chargeProfile()` in tools/build-pages.mjs, which serves
/// both geocharge.ge's calculator pages and the block on its home page. If the
/// curve changes in one place it has to change in the other, or the app and the
/// website will quote different numbers for the same charge.
const _accept = <double>[0.85, 1, 1, 0.95, 0.85, 0.72, 0.6, 0.48, 0.32, 0.18];

/// A modern pack peaks at roughly twice its capacity in kW. This is what makes
/// AC come out right for free: a 7 kW charger never reaches the taper, so it
/// stays flat all the way to 100 percent, which is exactly how AC behaves.
const _peakCRate = 2.0;

/// What one charge costs in time and energy.
class ChargeEstimate {
  const ChargeEstimate({
    required this.minutes,
    required this.kwh,
    required this.avgKw,
  });

  /// Time at the plug.
  final double minutes;

  /// Energy that reaches the battery.
  final double kwh;

  /// Energy drawn divided by time, i.e. the rate actually achieved.
  final double avgKw;
}

/// How long it takes to go from [fromPct] to [toPct], and how much goes in.
///
/// A flat "kWh divided by kW" is wrong by a wide margin near a full battery,
/// so this walks the range in ten bands and in each one takes the lower of what
/// the charger can give and what the pack will accept at that state of charge.
/// DC loses about 6 percent as heat, an onboard AC charger about 11.
///
/// Returns null when the inputs cannot describe a charge.
ChargeEstimate? estimateCharge({
  required double batteryKwh,
  required double chargerKw,
  required double fromPct,
  required double toPct,
}) {
  if (batteryKwh <= 0 || chargerKw <= 0) { return null; }
  final lo = fromPct.clamp(0.0, 100.0);
  final hi = toPct.clamp(0.0, 100.0);
  if (hi <= lo) { return null; }

  final peak = batteryKwh * _peakCRate;
  final eff  = chargerKw > 22 ? 0.94 : 0.89;
  var minutes = 0.0, kwh = 0.0;

  for (var i = 0; i < 10; i++) {
    final a = lo > i * 10 ? lo : (i * 10).toDouble();
    final b = hi < (i + 1) * 10 ? hi : ((i + 1) * 10).toDouble();
    if (b <= a) { continue; }
    final energy    = batteryKwh * (b - a) / 100.0;
    final accepted  = peak * _accept[i];
    final delivered = chargerKw < accepted ? chargerKw : accepted;
    kwh     += energy;
    minutes += (energy / eff) / delivered * 60;
  }
  if (minutes <= 0) { return null; }
  return ChargeEstimate(
    minutes: minutes,
    kwh: kwh,
    avgKw: (kwh / eff) / (minutes / 60),
  );
}

/// "How long will this take and what will it cost" — one set of inputs, both
/// answers, the same pairing the website's home page offers.
///
/// Free for everyone; the banner underneath is what pays for it, and it
/// disappears the moment premium is granted.
class CalculatorScreen extends StatefulWidget {
  const CalculatorScreen({super.key});

  @override
  State<CalculatorScreen> createState() => _CalculatorScreenState();
}

class _CalculatorScreenState extends State<CalculatorScreen> {
  static const _prefsKey = 'calculator_inputs_v1';

  final _battCtrl   = TextEditingController();
  final _powerCtrl  = TextEditingController();
  final _fromCtrl   = TextEditingController();
  final _toCtrl     = TextEditingController();
  final _tariffCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _restore();
  }

  @override
  void dispose() {
    _battCtrl.dispose();
    _powerCtrl.dispose();
    _fromCtrl.dispose();
    _toCtrl.dispose();
    _tariffCtrl.dispose();
    super.dispose();
  }

  /// Opens on the numbers the driver last used. Falling back to the battery
  /// they already told the expenses log about beats making them type it twice.
  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList(_prefsKey);
    final settingsBattery = ExpensesService.I.settings.batteryKwh;

    _battCtrl.text = saved != null && saved.isNotEmpty && saved[0].isNotEmpty
        ? saved[0]
        : (settingsBattery != null && settingsBattery > 0
            ? _trim(settingsBattery)
            : '60');
    _powerCtrl.text  = _pick(saved, 1, '60');
    _fromCtrl.text   = _pick(saved, 2, '20');
    _toCtrl.text     = _pick(saved, 3, '80');
    _tariffCtrl.text = _pick(saved, 4, _defaultTariff.toString());
    if (mounted) { setState(() {}); }
  }

  static String _pick(List<String>? saved, int i, String fallback) =>
      (saved != null && saved.length > i && saved[i].isNotEmpty)
          ? saved[i]
          : fallback;

  static String _trim(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_prefsKey, [
      _battCtrl.text, _powerCtrl.text, _fromCtrl.text,
      _toCtrl.text, _tariffCtrl.text,
    ]);
  }

  /// Commas are what a Georgian keyboard offers for a decimal point.
  double _num(TextEditingController c) =>
      double.tryParse(c.text.trim().replaceAll(',', '.')) ?? 0;

  void _onChanged(String _) {
    setState(() {});
    _save();
  }

  @override
  Widget build(BuildContext context) {
    final battery = _num(_battCtrl);
    final power   = _num(_powerCtrl);
    final tariff  = _num(_tariffCtrl);
    final est = estimateCharge(
      batteryKwh: battery,
      chargerKw: power,
      fromPct: _num(_fromCtrl),
      toPct: _num(_toCtrl),
    );
    final band80  = estimateCharge(
        batteryKwh: battery, chargerKw: power, fromPct: 20, toPct: 80);
    final band100 = estimateCharge(
        batteryKwh: battery, chargerKw: power, fromPct: 80, toPct: 100);

    return Scaffold(
      backgroundColor: _bgDark,
      // Free-tier banner. Rebuilds when the ads SDK finishes initialising (on
      // iOS that is after the ATT prompt) and when premium changes, so it turns
      // up as soon as it can and vanishes the moment it should not be there.
      bottomNavigationBar: ValueListenableBuilder<bool>(
        valueListenable: AdService.I.ready,
        builder: (_, __, ___) => ValueListenableBuilder<bool>(
          valueListenable: PurchaseService.I.isPremium,
          builder: (_, __, ___) =>
              AdService.I.bottomBanner() ?? const SizedBox.shrink(),
        ),
      ),
      appBar: AppBar(
        backgroundColor: _bgCard,
        elevation: 0,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded,
              color: _textPri, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          AppStrings.calcTitle,
          style: AppStrings.font(const TextStyle(
              color: _textPri, fontSize: 17, fontWeight: FontWeight.w600)),
        ),
      ),
      body: AppStrings.wrap(
        ListView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
          children: [
            Text(
              AppStrings.calcIntro,
              style: AppStrings.font(const TextStyle(
                  color: _textSec, fontSize: 14, height: 1.5)),
            ),
            const SizedBox(height: 20),
            _inputCard(),
            const SizedBox(height: 20),
            _TimeCard(estimate: est, band80: band80, band100: band100),
            const SizedBox(height: 14),
            _CostCard(estimate: est, tariff: tariff),
            const SizedBox(height: 20),
            Text(
              AppStrings.calcNote,
              style: AppStrings.font(const TextStyle(
                  color: _textSec, fontSize: 12.5, height: 1.55)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _inputCard() {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: _bgCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _bgSurface),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _NumField(
            controller: _battCtrl,
            label: AppStrings.calcBattery,
            suffix: 'kWh',
            icon: Icons.battery_charging_full_rounded,
            decimal: true,
            onChanged: _onChanged,
          ),
          const SizedBox(height: 16),
          _NumField(
            controller: _powerCtrl,
            label: AppStrings.calcPower,
            suffix: 'kW',
            icon: Icons.bolt_rounded,
            decimal: true,
            onChanged: _onChanged,
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final kw in _powerPresets)
                _PowerChip(
                  kw: kw,
                  selected: _num(_powerCtrl) == kw,
                  onTap: () {
                    _powerCtrl.text = '$kw';
                    _onChanged('');
                  },
                ),
            ],
          ),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(
              child: _NumField(
                controller: _fromCtrl,
                label: AppStrings.calcFrom,
                suffix: '%',
                icon: Icons.battery_2_bar_rounded,
                decimal: false,
                onChanged: _onChanged,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _NumField(
                controller: _toCtrl,
                label: AppStrings.calcTo,
                suffix: '%',
                icon: Icons.battery_full_rounded,
                decimal: false,
                onChanged: _onChanged,
              ),
            ),
          ]),
          const SizedBox(height: 16),
          _NumField(
            controller: _tariffCtrl,
            label: AppStrings.calcTariff,
            suffix: '₾ / kWh',
            icon: Icons.payments_rounded,
            decimal: true,
            onChanged: _onChanged,
          ),
          const SizedBox(height: 8),
          Text(
            AppStrings.calcTariffHint,
            style: AppStrings.font(const TextStyle(
                color: _textSec, fontSize: 12, height: 1.45)),
          ),
        ],
      ),
    );
  }
}

/// The time answer, with the two reference bands underneath: seeing 20 to 80
/// against the last fifth is what makes the taper obvious.
class _TimeCard extends StatelessWidget {
  const _TimeCard({
    required this.estimate,
    required this.band80,
    required this.band100,
  });

  final ChargeEstimate? estimate;
  final ChargeEstimate? band80;
  final ChargeEstimate? band100;

  @override
  Widget build(BuildContext context) {
    final e = estimate;
    return _ResultCard(
      label: AppStrings.calcTimeResult,
      value: e == null ? '—' : AppStrings.duration(e.minutes.round()),
      accent: _emerald,
      subtitle: e == null
          ? AppStrings.calcFillIn
          : '${AppStrings.calcAvgPower} ${e.avgKw.round()} kW',
      rows: e == null
          ? const []
          : [
              if (band80 != null)
                (AppStrings.calcBand80,
                    AppStrings.duration(band80!.minutes.round())),
              if (band100 != null)
                (AppStrings.calcBand100,
                    '+ ${AppStrings.duration(band100!.minutes.round())}'),
            ],
    );
  }
}

/// The cost answer, from the same energy figure the time answer used.
class _CostCard extends StatelessWidget {
  const _CostCard({required this.estimate, required this.tariff});

  final ChargeEstimate? estimate;
  final double tariff;

  @override
  Widget build(BuildContext context) {
    final e = estimate;
    final show = e != null && tariff > 0;
    return _ResultCard(
      label: AppStrings.calcCostResult,
      value: show ? '${(e.kwh * tariff).toStringAsFixed(2)} ₾' : '—',
      accent: _blue,
      subtitle: e == null
          ? AppStrings.calcFillIn
          : '${AppStrings.calcEnergy} ${e.kwh.toStringAsFixed(1)} kWh',
      rows: const [],
    );
  }
}

/// One big number with a caption and optional breakdown rows.
class _ResultCard extends StatelessWidget {
  const _ResultCard({
    required this.label,
    required this.value,
    required this.accent,
    required this.subtitle,
    required this.rows,
  });

  final String label;
  final String value;
  final Color accent;
  final String subtitle;
  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
      decoration: BoxDecoration(
        color: _bgCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _bgSurface),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: AppStrings.font(const TextStyle(
                color: _textSec,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.6)),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: TextStyle(
                color: accent, fontSize: 32, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: AppStrings.font(
                const TextStyle(color: _textSec, fontSize: 13)),
          ),
          if (rows.isNotEmpty) ...[
            const SizedBox(height: 14),
            const Divider(color: _bgSurface, height: 1),
            const SizedBox(height: 12),
            for (var i = 0; i < rows.length; i++) ...[
              if (i > 0) const SizedBox(height: 9),
              Row(children: [
                Expanded(
                  child: Text(
                    rows[i].$1,
                    style: AppStrings.font(
                        const TextStyle(color: _textSec, fontSize: 13)),
                  ),
                ),
                Text(
                  rows[i].$2,
                  style: AppStrings.font(const TextStyle(
                      color: _textPri,
                      fontSize: 14,
                      fontWeight: FontWeight.w600)),
                ),
              ]),
            ],
          ],
        ],
      ),
    );
  }
}

/// A shortcut to one of the ratings that really exist on Georgian chargers.
class _PowerChip extends StatelessWidget {
  const _PowerChip({
    required this.kw,
    required this.selected,
    required this.onTap,
  });

  final int kw;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? _emerald.withValues(alpha: 0.16) : _bgSurface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
              color: selected ? _emerald : Colors.transparent, width: 1),
        ),
        child: Text(
          '$kw kW',
          style: TextStyle(
            color: selected ? _emerald : _textSec,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

/// Label plus a numeric field, matching the expenses screen's fields.
class _NumField extends StatelessWidget {
  const _NumField({
    required this.controller,
    required this.label,
    required this.suffix,
    required this.icon,
    required this.decimal,
    required this.onChanged,
  });

  final TextEditingController controller;
  final String label;
  final String suffix;
  final IconData icon;
  final bool decimal;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: AppStrings.font(const TextStyle(
            color: _textSec,
            fontSize: 12,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.6,
          )),
        ),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            color: _bgSurface,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(children: [
            const SizedBox(width: 12),
            Icon(icon, color: _textSec, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: controller,
                onChanged: onChanged,
                keyboardType: TextInputType.numberWithOptions(decimal: decimal),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(
                      decimal ? RegExp(r'[0-9.,]') : RegExp(r'[0-9]')),
                  if (decimal) _SingleSeparator(),
                  // A whole-number field here is always a percentage, and
                  // "2080" is a slip of the thumb rather than a number.
                  if (!decimal) LengthLimitingTextInputFormatter(3),
                ],
                style: const TextStyle(color: _textPri, fontSize: 15),
                decoration: const InputDecoration(
                  hintText: '0',
                  hintStyle: TextStyle(color: _textSec, fontSize: 15),
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(vertical: 13),
                ),
              ),
            ),
            Text(suffix,
                style: const TextStyle(color: _textSec, fontSize: 12.5)),
            const SizedBox(width: 12),
          ]),
        ),
      ],
    );
  }
}

/// Keeps a decimal field to one separator, so the value always parses.
class _SingleSeparator extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    final separators =
        newValue.text.split('').where((c) => c == '.' || c == ',').length;
    return separators > 1 ? oldValue : newValue;
  }
}
