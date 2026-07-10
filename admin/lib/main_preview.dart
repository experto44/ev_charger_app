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
  for (final u in users.where((u) => u.isPremium)) {
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
    return AppUser(
      uid: 'u$i',
      name: names[rnd.nextInt(names.length)],
      email: 'user$i@example.com',
      phone: '+9955${rnd.nextInt(90000000) + 10000000}',
      isPremium: rnd.nextDouble() < 0.28,
      platform: platforms[rnd.nextInt(platforms.length)],
      createdAt: created,
      lastSeenAt: now.subtract(Duration(hours: rnd.nextInt(240))),
      openCount: opens,
    );
  });
}
