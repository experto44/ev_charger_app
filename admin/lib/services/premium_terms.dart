/// Date arithmetic for manually granted subscriptions.
///
/// Pure (no Firebase) so both the write path ([AdminService.grantManualPremium])
/// and the confirmation dialog's "new expiry" preview compute the exact same
/// date — the admin sees beforehand precisely what will be stored.
class PremiumTerms {
  const PremiumTerms._();

  /// The two terms that can be granted by hand.
  static const String monthly = 'monthly';
  static const String yearly = 'yearly';

  /// Expiry after granting [plan] on top of [currentUntil].
  ///
  /// Unused time is never thrown away: a user with 10 days left who is given
  /// another month ends up with 10 days + 1 month. An expired (or absent)
  /// subscription starts from [from] (defaults to now).
  static DateTime extend(DateTime? currentUntil, String plan,
      {DateTime? from}) {
    final now = from ?? DateTime.now();
    final base = (currentUntil != null && currentUntil.isAfter(now))
        ? currentUntil
        : now;
    return plan == yearly ? addMonths(base, 12) : addMonths(base, 1);
  }

  /// Add [n] calendar months, clamping the day to the target month's length so
  /// 31 Jan + 1 month lands on 28/29 Feb instead of rolling into March.
  static DateTime addMonths(DateTime d, int n) {
    final month = d.month + n;
    final year = d.year + (month - 1) ~/ 12;
    final m = (month - 1) % 12 + 1;
    final lastDay = DateTime(year, m + 1, 0).day; // day 0 = last of previous
    return DateTime(
        year, m, d.day > lastDay ? lastDay : d.day, d.hour, d.minute, d.second);
  }

  /// Default price we charge for [plan], used to prefill the amount field.
  static double defaultPriceGel(String plan) => plan == yearly ? 9.99 : 1.0;

  /// Human label for a plan.
  static String label(String plan) => plan == yearly ? '1 year' : '1 month';
}
