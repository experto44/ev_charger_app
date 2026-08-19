import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../models/app_user.dart';
import '../models/purchase.dart';
import 'premium_terms.dart';

/// Data + auth layer for the admin panel.
///
/// Access control lives in Firestore security rules: a signed-in account may
/// read the whole `users` collection only if an `admins/{email}` document
/// exists for it. This service just surfaces that: sign in with Google, check
/// the admin flag, and (for admins) stream users and manage the admin list.
class AdminService {
  AdminService._();
  static final AdminService I = AdminService._();

  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  User? get currentUser => _auth.currentUser;
  Stream<User?> get authState => _auth.authStateChanges();

  /// Google sign-in via popup (web). Firebase handles the OAuth flow; no extra
  /// package needed.
  Future<UserCredential> signInWithGoogle() {
    final provider = GoogleAuthProvider()
      ..setCustomParameters({'prompt': 'select_account'});
    return _auth.signInWithPopup(provider);
  }

  Future<void> signOut() => _auth.signOut();

  /// Whether the signed-in account is an allow-listed admin. Reads its own
  /// `admins/{email}` document (permitted by the rules for the owner).
  Future<bool> isCurrentUserAdmin() async {
    final email = _auth.currentUser?.email?.toLowerCase();
    if (email == null) return false;
    try {
      final doc = await _db.collection('admins').doc(email).get();
      return doc.exists;
    } catch (_) {
      return false;
    }
  }

  /// Live stream of every registered user, newest registration first.
  ///
  /// Sorting by `createdAt` would drop pre-tracking accounts that lack the
  /// field, so we fetch unordered and sort client-side (the user base is small
  /// enough that this is fine and keeps every account visible).
  Stream<List<AppUser>> usersStream() {
    return _db.collection('users').snapshots().map((snap) {
      final users = snap.docs.map(AppUser.fromDoc).toList();
      users.sort((a, b) {
        final ad = a.createdAt, bd = b.createdAt;
        if (ad == null && bd == null) return 0;
        if (ad == null) return 1; // unknown dates sink to the bottom
        if (bd == null) return -1;
        return bd.compareTo(ad);
      });
      return users;
    });
  }

  /// Live stream of every recorded purchase (revenue event), newest first.
  /// Sorted client-side so purchases still missing a server `createdAt` (the
  /// brief window before the timestamp resolves) aren't dropped.
  Stream<List<Purchase>> purchasesStream() {
    return _db.collection('purchases').snapshots().map((snap) {
      final list = snap.docs.map(Purchase.fromDoc).toList();
      list.sort((a, b) {
        final ad = a.createdAt, bd = b.createdAt;
        if (ad == null && bd == null) return 0;
        if (ad == null) return 1;
        if (bd == null) return -1;
        return bd.compareTo(ad);
      });
      return list;
    });
  }

  // ── Manual premium (bank transfers) ────────────────────────────────────────
  /// Activate premium by hand for [uid] — the path for users who could not use
  /// the in-app purchase and paid us directly.
  ///
  /// Writes the flag the mobile app already reads (`isPremium`) plus an expiry
  /// (`premiumUntil`). No app update is involved: the app syncs `isPremium` from
  /// Firestore on every launch, and the `expireManualPremium` Cloud Function
  /// clears the flag once the date passes, so ads come back by themselves.
  ///
  /// Time is ADDED to whatever is left: re-activating a user who still has 10
  /// days extends them rather than throwing those days away. [amountGel] (when
  /// > 0) also records a revenue row so the Finance tab reflects the money that
  /// actually arrived — at zero commission, since no store was involved.
  ///
  /// Returns the new expiry date.
  Future<DateTime> grantManualPremium({
    required String uid,
    required String plan, // 'monthly' | 'yearly'
    double amountGel = 0,
    String note = '',
  }) async {
    final ref = _db.collection('users').doc(uid);
    final snap = await ref.get();
    final current = snap.data()?['premiumUntil'];
    final now = DateTime.now();

    // Re-read the expiry here (rather than trusting the streamed copy) so two
    // admins granting at the same time can't both extend from the same stale
    // date. Unused time carries over — see [PremiumTerms.extend].
    final until = PremiumTerms.extend(
      current is Timestamp ? current.toDate() : null,
      plan,
      from: now,
    );

    await ref.set({
      'isPremium': true,
      'premiumUntil': Timestamp.fromDate(until),
      'premiumSource': 'manual',
      'premiumPlan': plan,
      'premiumGrantedBy': _auth.currentUser?.email ?? '',
      'premiumGrantedAt': FieldValue.serverTimestamp(),
      'premiumNote': note.trim(),
    }, SetOptions(merge: true));

    if (amountGel > 0) {
      // One row per activation (never overwritten — the id carries the
      // timestamp), mirroring the shape the app writes for store purchases.
      final id = 'manual_${uid}_${now.millisecondsSinceEpoch}';
      await _db.collection('purchases').doc(id).set({
        'uid': uid,
        'plan': plan,
        'platform': 'manual',
        'gross': amountGel,
        'currency': 'GEL',
        'productId': 'manual_$plan',
        'type': 'manual',
        'grantedBy': _auth.currentUser?.email ?? '',
        'note': note.trim(),
        'createdAt': FieldValue.serverTimestamp(),
      });
    }

    return until;
  }

  /// End a manual subscription immediately: the flag goes false and the expiry
  /// is set to now, so the ad-supported version returns on the next app open.
  /// The revenue rows already recorded are left untouched (history is
  /// append-only).
  Future<void> revokeManualPremium(String uid) {
    return _db.collection('users').doc(uid).set({
      'isPremium': false,
      'premiumUntil': Timestamp.fromDate(DateTime.now()),
      'premiumSource': 'manual',
      'premiumExpiredAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  // ── Admin allow-list management ────────────────────────────────────────────
  /// Live stream of admin emails.
  Stream<List<String>> adminsStream() {
    return _db.collection('admins').snapshots().map(
          (snap) => snap.docs.map((d) => d.id).toList()..sort(),
        );
  }

  /// Add another admin by email (lower-cased to match the sign-in token).
  Future<void> addAdmin(String email) async {
    final e = email.trim().toLowerCase();
    if (e.isEmpty) return;
    await _db.collection('admins').doc(e).set({
      'addedBy': _auth.currentUser?.email ?? '',
      'addedAt': FieldValue.serverTimestamp(),
    });
  }

  /// Remove an admin. Guarded in the UI so you can't remove your own access.
  Future<void> removeAdmin(String email) =>
      _db.collection('admins').doc(email.trim().toLowerCase()).delete();
}
