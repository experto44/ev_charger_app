// Manual (bank-transfer) premium: term arithmetic and the derived status the
// panel shows. These are the two places a mistake would cost real money — an
// extension that silently eats the remaining days, or a lapsed grant still
// displayed as Premium.
import 'package:flutter_test/flutter_test.dart';
import 'package:geocharge_admin/models/app_user.dart';
import 'package:geocharge_admin/services/premium_terms.dart';

AppUser _user({
  DateTime? until,
  String source = 'manual',
  bool isPremium = true,
}) {
  return AppUser(
    uid: 'u1',
    name: 'Test',
    email: 't@example.com',
    phone: '',
    isPremium: isPremium,
    platform: 'android',
    createdAt: DateTime(2026, 1, 1),
    lastSeenAt: DateTime(2026, 1, 2),
    openCount: 3,
    premiumUntil: until,
    premiumSource: source,
    premiumPlan: 'monthly',
  );
}

void main() {
  group('PremiumTerms.extend', () {
    final now = DateTime(2026, 8, 5, 12);

    test('starts from now when there is no subscription', () {
      expect(PremiumTerms.extend(null, PremiumTerms.monthly, from: now),
          DateTime(2026, 9, 5, 12));
      expect(PremiumTerms.extend(null, PremiumTerms.yearly, from: now),
          DateTime(2027, 8, 5, 12));
    });

    test('stacks on top of the remaining time instead of resetting', () {
      final left = DateTime(2026, 8, 20, 12); // 15 days still to run
      expect(PremiumTerms.extend(left, PremiumTerms.monthly, from: now),
          DateTime(2026, 9, 20, 12));
    });

    test('restarts from now once the old term has lapsed', () {
      final expired = DateTime(2026, 7, 1, 12);
      expect(PremiumTerms.extend(expired, PremiumTerms.monthly, from: now),
          DateTime(2026, 9, 5, 12));
    });

    test('clamps to the last day of a shorter month', () {
      final jan31 = DateTime(2026, 1, 31, 9);
      expect(PremiumTerms.extend(jan31, PremiumTerms.monthly, from: jan31),
          DateTime(2026, 2, 28, 9));
      // 2028 is a leap year.
      final jan31Leap = DateTime(2028, 1, 31, 9);
      expect(PremiumTerms.extend(jan31Leap, PremiumTerms.monthly, from: jan31Leap),
          DateTime(2028, 2, 29, 9));
    });
  });

  group('AppUser manual status', () {
    test('an unexpired grant reads as active premium', () {
      final u = _user(until: DateTime.now().add(const Duration(days: 12)));
      expect(u.isManual, isTrue);
      expect(u.manualActive, isTrue);
      expect(u.effectivePremium, isTrue);
      expect(u.daysLeft, 12);
      expect(u.remainingLabel, '12 days');
      expect(u.statusLabel, 'Premium (manual)');
    });

    test('a lapsed grant reads as free even before the sweep clears the flag',
        () {
      // isPremium is still true here — exactly the window between expiry and
      // the hourly expireManualPremium run.
      final u = _user(until: DateTime.now().subtract(const Duration(days: 1)));
      expect(u.manualActive, isFalse);
      expect(u.effectivePremium, isFalse);
      expect(u.remainingLabel, 'Expired');
      expect(u.statusLabel, 'Free (ads)');
    });

    test('a store subscription is untouched by the manual logic', () {
      final u = _user(until: null, source: '');
      expect(u.isManual, isFalse);
      expect(u.effectivePremium, isTrue);
      expect(u.daysLeft, isNull);
      expect(u.remainingLabel, '—');
      expect(u.statusLabel, 'Premium');
    });

    test('part of a day still counts as a day of service', () {
      final u = _user(until: DateTime.now().add(const Duration(hours: 5)));
      expect(u.daysLeft, 1);
      expect(u.remainingLabel, '1 day');
    });
  });
}
