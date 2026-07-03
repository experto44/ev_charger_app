import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../models/app_user.dart';

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
