// Dev-only entry point for iterating on the dashboard layout WITHOUT Firebase.
// Run with:  flutter run -d chrome -t lib/main_preview.dart
// It feeds the pure DashboardView a deterministic set of mock users so the
// responsive layout can be checked at any window size. Never shipped — the
// release build always targets lib/main.dart.
import 'dart:math';

import 'package:flutter/material.dart';

import 'models/app_user.dart';
import 'models/maps_usage.dart';
import 'models/purchase.dart';
import 'models/tesla_session.dart';
import 'screens/dashboard_screen.dart';
import 'services/premium_terms.dart';
import 'theme.dart';

void main() => runApp(const _PreviewApp());

class _PreviewApp extends StatelessWidget {
  const _PreviewApp();
  @override
  Widget build(BuildContext context) {
    final users = _mockUsers(64);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildAdminTheme(),
      home: DashboardView(
        email: 'miruashvili.k@gmail.com',
        users: users,
        purchases: _mockPurchases(users),
        sessions: _mockSessions(users),
        mapsUsage: _mockMapsUsage(),
        onSignOut: () {},
        onManageAdmins: () {},
        // No Firestore in the preview: pretend the grant succeeded and report
        // the same expiry the real service would compute.
        onGrantPremium: (user, grant) async =>
            PremiumTerms.extend(user.premiumUntil, grant.plan),
        onRevokePremium: (_) async {},
      ),
    );
  }
}

/// Deterministic mock revenue events for the Finance tab preview: one purchase
/// for each premium user, split across plans/platforms/currencies.
List<Purchase> _mockPurchases(List<AppUser> users) {
  final rnd = Random(11);
  final now = DateTime.now();
  final out = <Purchase>[];
  // Bank-transfer activations: recorded at full value, no store commission.
  for (final u in users.where((u) => u.isManual)) {
    out.add(Purchase(
      id: 'manual_${u.uid}',
      uid: u.uid,
      plan: u.premiumPlan,
      platform: 'manual',
      gross: u.premiumPlan == 'yearly' ? 9.99 : 1.0,
      currency: 'GEL',
      productId: 'manual_${u.premiumPlan}',
      type: 'manual',
      createdAt: u.premiumGrantedAt,
    ));
  }
  for (final u in users.where((u) => u.isPremium && !u.isManual)) {
    final yearly = rnd.nextDouble() < 0.4;
    final ios = u.platform == 'ios';
    out.add(Purchase(
      id: 'txn_${u.uid}',
      uid: u.uid,
      plan: yearly ? 'yearly' : 'monthly',
      platform: ios ? 'ios' : 'android',
      gross: ios
          ? (yearly ? 3.99 : 0.49) // USD on the iOS App Store
          : (yearly ? 9.99 : 1.0), // GEL on Play
      currency: ios ? 'USD' : 'GEL',
      productId: yearly ? 'geocharge_premium_yearly' : 'geocharge_premium_monthly',
      createdAt: now.subtract(Duration(days: rnd.nextInt(30), hours: rnd.nextInt(24))),
    ));
  }
  return out;
}

/// Mock visits to the car app: a handful of accounts, most of them occasional,
/// one of them in the car nearly every day — enough for the chart, the table
/// and the "one person, six sessions" case the two bar colours exist for.
List<TeslaSession> _mockSessions(List<AppUser> users) {
  final rnd = Random(23);
  final now = DateTime.now();
  final drivers = users.take(6).toList();
  final out = <TeslaSession>[];
  for (var day = 29; day >= 0; day--) {
    for (var i = 0; i < drivers.length; i++) {
      // The first driver is in the car most days; the rest now and then.
      final chance = i == 0 ? 0.8 : 0.18 - i * 0.02;
      if (rnd.nextDouble() > chance) continue;
      final visits = 1 + (rnd.nextDouble() < 0.3 ? rnd.nextInt(3) : 0);
      for (var v = 0; v < visits; v++) {
        final started = now.subtract(Duration(days: day, hours: rnd.nextInt(12)));
        final seconds = 120 + rnd.nextInt(2400);
        out.add(TeslaSession(
          id: 's${day}_${i}_$v',
          uid: drivers[i].uid,
          email: drivers[i].email,
          startedAt: started,
          lastSeenAt: started.add(Duration(seconds: seconds)),
          seconds: seconds,
          drives: rnd.nextDouble() < 0.4 ? 1 : 0,
        ));
      }
    }
  }
  return out;
}

/// Mock Google usage, at a rate that puts Directions on course to overrun its
/// free tier — which is the state the gauge exists to make obvious.
List<MapsUsageDay> _mockMapsUsage() {
  final rnd = Random(5);
  final now = DateTime.now();
  return [
    for (var day = 34; day >= 0; day--)
      () {
        final d = now.subtract(Duration(days: day));
        return MapsUsageDay(
          day: '${d.year}-${d.month.toString().padLeft(2, '0')}-'
              '${d.day.toString().padLeft(2, '0')}',
          calls: {
            'maps': 15 + rnd.nextInt(30),
            'directions': 120 + rnd.nextInt(70),
            'places': 180 + rnd.nextInt(200),
            'geocoding': 0,
          },
          updatedAt: now,
        );
      }(),
  ];
}

List<AppUser> _mockUsers(int n) {
  final rnd = Random(7);
  const names = [
    'ნინო ბერიძე', 'გიორგი მაისურაძე', 'თამარ კვარაცხელია', 'ლ. ღონღაძე',
    'David Smith', 'Ana Kapanadze', 'ლევან ჯavakhishvili', 'Mariam T.',
    'Nika Beridze', 'Salome G.', 'Zurab K.', 'Elene M.',
  ];
  const platforms = ['android', 'android', 'ios', ''];
  final now = DateTime.now();
  return List.generate(n, (i) {
    final created = now.subtract(Duration(days: rnd.nextInt(45), hours: rnd.nextInt(24)));
    final opens = rnd.nextInt(120);
    // Every 7th account is a manual (bank-transfer) grant so the Premium tab
    // has something to render: a mix of running, about-to-lapse and expired.
    final manual = i % 7 == 0;
    final yearly = manual && i % 14 == 0;
    final daysLeft = manual ? [-12, 3, 26, 118][(i ~/ 7) % 4] : 0;
    return AppUser(
      uid: 'u$i',
      name: names[rnd.nextInt(names.length)],
      email: 'user$i@example.com',
      phone: '+9955${rnd.nextInt(90000000) + 10000000}',
      isPremium: manual ? daysLeft > 0 : rnd.nextDouble() < 0.28,
      platform: platforms[rnd.nextInt(platforms.length)],
      createdAt: created,
      lastSeenAt: now.subtract(Duration(hours: rnd.nextInt(240))),
      openCount: opens,
      premiumUntil: manual ? now.add(Duration(days: daysLeft)) : null,
      premiumSource: manual ? 'manual' : '',
      premiumPlan: manual ? (yearly ? 'yearly' : 'monthly') : '',
      premiumGrantedBy: manual ? 'miruashvili.k@gmail.com' : '',
      premiumGrantedAt: manual ? now.subtract(const Duration(days: 4)) : null,
      premiumNote: manual ? 'BOG transfer #${1000 + i}' : '',
    );
  });
}
