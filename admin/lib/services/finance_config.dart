import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

/// Editable financial assumptions for the analytics: the store commission rates
/// and the USD→GEL rate used to fold iOS (USD-billed) revenue into a single GEL
/// figure. Defaults reflect the common case for a small app:
///   • Apple  — 15 % (App Store Small Business Program).
///   • Google — 15 % (Play charges 15 % on all subscription revenue).
///   • FX     — a hand-set USD→GEL rate (the store reports no FX, so combining
///              currencies needs one number the admin controls).
///
/// Persisted to the browser's localStorage so the admin's tweaks survive a page
/// reload. A [ChangeNotifier] so editing the config live-refreshes every figure.
class FinanceConfig extends ChangeNotifier {
  FinanceConfig._();
  static final FinanceConfig I = FinanceConfig._().._load();

  static const _kApple = 'fin_apple_rate';
  static const _kGoogle = 'fin_google_rate';
  static const _kFx = 'fin_usd_gel';

  double _appleRate = 0.15; // 15 %
  double _googleRate = 0.15; // 15 %
  double _usdToGel = 2.70;

  double get appleRate => _appleRate;
  double get googleRate => _googleRate;
  double get usdToGel => _usdToGel;

  /// Commission fraction (0..1) for a purchase on [platform].
  double rateFor(String platform) =>
      platform == 'ios' ? _appleRate : _googleRate;

  /// Convert a store [amount] in [currency] into GEL using the configured FX.
  /// GEL passes through; USD is converted; any other currency is assumed to be
  /// already comparable (multiplied by 1) rather than silently dropped.
  double toGel(double amount, String currency) {
    switch (currency.toUpperCase()) {
      case 'GEL':
        return amount;
      case 'USD':
        return amount * _usdToGel;
      default:
        return amount;
    }
  }

  void update({double? appleRate, double? googleRate, double? usdToGel}) {
    if (appleRate != null) _appleRate = appleRate.clamp(0, 1);
    if (googleRate != null) _googleRate = googleRate.clamp(0, 1);
    if (usdToGel != null && usdToGel > 0) _usdToGel = usdToGel;
    _save();
    notifyListeners();
  }

  void _load() {
    try {
      final s = web.window.localStorage;
      final a = s.getItem(_kApple);
      final g = s.getItem(_kGoogle);
      final f = s.getItem(_kFx);
      if (a != null) _appleRate = double.tryParse(a) ?? _appleRate;
      if (g != null) _googleRate = double.tryParse(g) ?? _googleRate;
      if (f != null) _usdToGel = double.tryParse(f) ?? _usdToGel;
    } catch (_) {
      // localStorage unavailable — fall back to the defaults.
    }
  }

  void _save() {
    try {
      final s = web.window.localStorage;
      s.setItem(_kApple, _appleRate.toString());
      s.setItem(_kGoogle, _googleRate.toString());
      s.setItem(_kFx, _usdToGel.toString());
    } catch (_) {
      // best-effort; a failed save just means the tweak won't persist.
    }
  }
}
