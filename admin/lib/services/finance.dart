import '../models/purchase.dart';
import 'finance_config.dart';

/// One aggregated bucket (a platform, a plan, or the grand total): how many
/// purchases, their gross and net (post-commission) value in GEL.
class RevenueBucket {
  RevenueBucket({this.count = 0, this.gross = 0, this.net = 0});
  int count;
  double gross; // GEL, before commission
  double net; // GEL, after commission

  double get commission => gross - net;
}

/// The full financial picture for a (already filtered) list of purchases, with
/// [FinanceConfig]'s commission + FX assumptions applied. Everything is folded
/// into GEL so the KPIs are a single comparable number across iOS and Android.
class FinanceSummary {
  FinanceSummary._({
    required this.total,
    required this.appleFee,
    required this.googleFee,
    required this.byPlatform,
    required this.byPlan,
    required this.dailyNet,
  });

  final RevenueBucket total;

  /// Commission kept by each store (GEL), broken out so the panel can show the
  /// Apple and Google cuts separately — exactly the split the business cares
  /// about.
  final double appleFee;
  final double googleFee;

  /// Net revenue split by platform (`ios`/`android`/`other`) and by plan
  /// (`monthly`/`yearly`).
  final Map<String, RevenueBucket> byPlatform;
  final Map<String, RevenueBucket> byPlan;

  /// Net GEL per calendar day for the last [days] window (index 0 == oldest),
  /// for the revenue-over-time chart.
  final List<double> dailyNet;

  /// Average net revenue per purchase (GEL).
  double get netPerPurchase => total.count == 0 ? 0 : total.net / total.count;

  static FinanceSummary compute(
    List<Purchase> purchases,
    FinanceConfig cfg, {
    int days = 30,
  }) {
    final total = RevenueBucket();
    var appleFee = 0.0;
    var googleFee = 0.0;
    final byPlatform = <String, RevenueBucket>{};
    final byPlan = <String, RevenueBucket>{};

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final daily = List<double>.filled(days, 0);

    for (final p in purchases) {
      final gross = cfg.toGel(p.gross, p.currency);
      final fee = gross * cfg.rateFor(p.platform);
      final net = gross - fee;

      total
        ..count += 1
        ..gross += gross
        ..net += net;

      // `manual` rows carry no fee at all, so they belong to neither store.
      if (p.platform == 'ios') {
        appleFee += fee;
      } else if (p.platform != 'manual') {
        googleFee += fee;
      }

      (byPlatform[p.platform] ??= RevenueBucket())
        ..count += 1
        ..gross += gross
        ..net += net;
      (byPlan[p.plan] ??= RevenueBucket())
        ..count += 1
        ..gross += gross
        ..net += net;

      final c = p.createdAt;
      if (c != null) {
        final day = DateTime(c.year, c.month, c.day);
        final diff = today.difference(day).inDays;
        if (diff >= 0 && diff < days) {
          daily[days - 1 - diff] += net;
        }
      }
    }

    return FinanceSummary._(
      total: total,
      appleFee: appleFee,
      googleFee: googleFee,
      byPlatform: byPlatform,
      byPlan: byPlan,
      dailyNet: daily,
    );
  }
}
