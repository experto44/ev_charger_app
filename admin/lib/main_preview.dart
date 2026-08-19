// Dev-only entry point for iterating on the dashboard layout WITHOUT Firebase.
// Run with:  flutter run -d chrome -t lib/main_preview.dart
// It feeds the pure DashboardView a deterministic set of mock users so the
// responsive layout can be checked at any window size. Never shipped — the
// release build always targets lib/main.dart.
import 'dart:math';

import 'package:flutter/material.dart';

import 'models/app_user.dart';
import 'models/purchase.dart';
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
