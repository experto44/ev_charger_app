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
  });

  final String uid;
  final String name;
  final String email;
  final String phone;
  final bool isPremium;

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
    );
  }

  static DateTime? _ts(dynamic v) => v is Timestamp ? v.toDate() : null;

  /// Human status label for the subscription tier.
  String get statusLabel => isPremium ? 'Premium' : 'Free (ads)';

  /// Average opens per day since registration (null when unknown).
  double? get opensPerDay {
    if (createdAt == null || openCount == 0) return null;
    final days = DateTime.now().difference(createdAt!).inSeconds / 86400.0;
    if (days < 1) return openCount.toDouble(); // < a day old → count as-is
    return openCount / days;
  }
}
