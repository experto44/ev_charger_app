import 'package:cloud_firestore/cloud_firestore.dart';

/// A registered GeoCharge user as shown in the admin panel, built from a
/// `users/{uid}` Firestore document.
///
/// Every analytics field is nullable because it only exists for accounts active
/// since the tracking release — older accounts backfill on their next app open.
class AppUser {
  AppUser({
    required this.uid,
    required this.name,
    required this.email,
    required this.phone,
    required this.isPremium,
    required this.platform,
    required this.createdAt,
    required this.lastSeenAt,
    required this.openCount,
    this.premiumUntil,
    this.premiumSource = '',
    this.premiumPlan = '',
    this.premiumGrantedBy = '',
    this.premiumGrantedAt,
    this.premiumNote = '',
  });

  final String uid;
  final String name;
  final String email;
  final String phone;

  /// The raw flag the mobile app reads. For a store subscription it is owned by
  /// Apple/Google; for a manual grant it is set here and cleared again by the
  /// `expireManualPremium` Cloud Function once [premiumUntil] passes.
  final bool isPremium;

  /// Expiry of a manually granted subscription (`null` for store purchases,
  /// which have no admin-managed end date).
  final DateTime? premiumUntil;

  /// `manual` when premium was activated by hand from this panel; empty (or
  /// anything else) for a normal in-app purchase.
  final String premiumSource;

  /// Plan of the last manual grant: `monthly` / `yearly`.
  final String premiumPlan;

  /// Email of the admin who granted it, and when.
  final String premiumGrantedBy;
  final DateTime? premiumGrantedAt;

  /// Free-text note the admin left with the grant (payment reference, etc.).
  final String premiumNote;

  /// `android` / `ios` / `other`, or empty when never recorded.
  final String platform;

  /// First sighting of the account (≈ registration date).
  final DateTime? createdAt;

  /// Most recent app open.
  final DateTime? lastSeenAt;

  /// Lifetime number of app opens (throttled to once per 10 min in the app).
  final int openCount;

  factory AppUser.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const {};
    return AppUser(
      uid: doc.id,
      name: (d['name'] as String?)?.trim() ?? '',
      email: (d['email'] as String?)?.trim() ?? '',
      phone: (d['phoneNumber'] as String?)?.trim() ?? '',
      isPremium: d['isPremium'] == true,
      platform: (d['platform'] as String?)?.trim() ?? '',
      createdAt: _ts(d['createdAt']),
      lastSeenAt: _ts(d['lastSeenAt']),
      openCount: (d['openCount'] as num?)?.toInt() ?? 0,
      premiumUntil: _ts(d['premiumUntil']),
      premiumSource: (d['premiumSource'] as String?)?.trim() ?? '',
      premiumPlan: (d['premiumPlan'] as String?)?.trim() ?? '',
      premiumGrantedBy: (d['premiumGrantedBy'] as String?)?.trim() ?? '',
      premiumGrantedAt: _ts(d['premiumGrantedAt']),
      premiumNote: (d['premiumNote'] as String?)?.trim() ?? '',
    );
  }

  static DateTime? _ts(dynamic v) => v is Timestamp ? v.toDate() : null;

  // ── Manual (bank-transfer) subscriptions ───────────────────────────────────
  /// True when premium on this account was activated by hand from the panel.
  bool get isManual => premiumSource == 'manual';

  /// True while a manual grant is still within its paid period. The Cloud
  /// Function only sweeps hourly, so the panel decides "expired" from the date
  /// itself and never shows a stale Premium badge in the meantime.
  bool get manualActive =>
      isManual && premiumUntil != null && premiumUntil!.isAfter(DateTime.now());

  /// What the app will actually do for this user right now: a manual grant past
  /// its expiry counts as free even before the sweep clears the flag.
  bool get effectivePremium => isManual ? manualActive : isPremium;

  /// Whole days left on a manual grant (negative once expired, `null` when the
  /// account has no manual subscription).
  int? get daysLeft {
    if (premiumUntil == null) return null;
    final diff = premiumUntil!.difference(DateTime.now());
    // Round up: any part of a day still counts as a day of service.
    return (diff.inSeconds / 86400).ceil();
  }

  /// Short human description of the remaining term (`12 days`, `Expired`, …).
  String get remainingLabel {
    final d = daysLeft;
    if (d == null) return '—';
    if (d <= 0) return 'Expired';
    if (d == 1) return '1 day';
    return '$d days';
  }

  /// Human status label for the subscription tier.
  String get statusLabel {
    if (isManual) return manualActive ? 'Premium (manual)' : 'Free (ads)';
    return isPremium ? 'Premium' : 'Free (ads)';
  }

  /// Average opens per day since registration (null when unknown).
  double? get opensPerDay {
    if (createdAt == null || openCount == 0) return null;
    final days = DateTime.now().difference(createdAt!).inSeconds / 86400.0;
    if (days < 1) return openCount.toDouble(); // < a day old → count as-is
    return openCount / days;
  }
}
