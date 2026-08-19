import 'package:flutter/foundation.dart';

import 'browser.dart' as browser;

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

  /// Commission fraction (0..1) for a purchase on [platform]. A `manual`
  /// (bank-transfer) activation never passed through a store, so no cut is
  /// taken — gross and net are the same money.
  double rateFor(String platform) {
    if (platform == 'manual') return 0;
    return platform == 'ios' ? _appleRate : _googleRate;
  }

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
    // Missing values (or a non-web build) simply leave the defaults in place.
    final a = browser.readLocal(_kApple);
    final g = browser.readLocal(_kGoogle);
    final f = browser.readLocal(_kFx);
    if (a != null) _appleRate = double.tryParse(a) ?? _appleRate;
    if (g != null) _googleRate = double.tryParse(g) ?? _googleRate;
    if (f != null) _usdToGel = double.tryParse(f) ?? _usdToGel;
  }

  void _save() {
    browser.writeLocal(_kApple, _appleRate.toString());
    browser.writeLocal(_kGoogle, _googleRate.toString());
    browser.writeLocal(_kFx, _usdToGel.toString());
  }
}
