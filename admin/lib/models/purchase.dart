import 'package:cloud_firestore/cloud_firestore.dart';

/// A single completed in-app purchase, built from a `purchases/{txnId}`
/// Firestore document written by the mobile app on a confirmed purchase.
///
/// This is the raw event: the *gross* amount the store charged, in the
/// storefront's own currency (GEL on Android, USD on the iOS App Store in
/// Georgia). Commission and currency normalisation are applied later, in the
/// finance layer, so the raw record stays a faithful copy of what the store
/// reported.
class Purchase {
  Purchase({
    required this.id,
    required this.uid,
    required this.plan,
    required this.platform,
    required this.gross,
    required this.currency,
    required this.productId,
    required this.createdAt,
    this.type = 'new',
  });

  /// Store transaction id (document id) — unique per purchase.
  final String id;

  /// The buyer's user id (`users/{uid}`).
  final String uid;

  /// `monthly` / `yearly`.
  final String plan;

  /// `ios` / `android` / `other`, plus `manual` for a bank transfer activated
  /// by hand from the admin panel (no store, so no commission).
  final String platform;

  /// `new` for a store purchase, `manual` for an admin-granted subscription.
  final String type;

  /// Amount charged by the store, in [currency] (before commission).
  final double gross;

  /// ISO currency code the store billed in, e.g. `GEL` or `USD`.
  final String currency;

  /// Store product id (e.g. `geocharge_premium_yearly`).
  final String productId;

  /// When the purchase was recorded (server timestamp).
  final DateTime? createdAt;

  factory Purchase.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const {};
    return Purchase(
      id: doc.id,
      uid: (d['uid'] as String?)?.trim() ?? '',
      plan: (d['plan'] as String?)?.trim() ?? 'monthly',
      platform: (d['platform'] as String?)?.trim() ?? 'other',
      gross: (d['gross'] as num?)?.toDouble() ?? 0,
      currency: (d['currency'] as String?)?.trim().toUpperCase() ?? 'GEL',
      productId: (d['productId'] as String?)?.trim() ?? '',
      type: (d['type'] as String?)?.trim() ?? 'new',
      createdAt: d['createdAt'] is Timestamp
          ? (d['createdAt'] as Timestamp).toDate()
          : null,
    );
  }

  /// Human label for the plan.
  String get planLabel => plan == 'yearly' ? 'Yearly' : 'Monthly';

  /// True for a manually granted (bank-transfer) subscription.
  bool get isManual => platform == 'manual' || type == 'manual';
}
