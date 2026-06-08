import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';

class AuthService {
  static final _auth      = FirebaseAuth.instance;
  static final _firestore = FirebaseFirestore.instance;
  static final _google    = GoogleSignIn();

  static Stream<User?> get authStateChanges => _auth.authStateChanges();
  static User?         get currentUser      => _auth.currentUser;

  // ── Email / password sign-in ─────────────────────────────────────────────────
  static Future<UserCredential> signInWithEmail(
      String email, String password) async {
    return _auth.signInWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
  }

  // ── Email / password registration + verification email ───────────────────────
  static Future<UserCredential> registerWithEmail(
      String email, String password) async {
    final cred = await _auth.createUserWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
    await cred.user?.sendEmailVerification();
    return cred;
  }

  // ── Resend verification email ─────────────────────────────────────────────────
  static Future<void> resendVerificationEmail() async {
    await _auth.currentUser?.sendEmailVerification();
  }

  // ── Reload user to pick up latest emailVerified state ────────────────────────
  static Future<void> reloadUser() async {
    await _auth.currentUser?.reload();
  }

  // ── Google Sign-In ────────────────────────────────────────────────────────────
  static Future<UserCredential?> signInWithGoogle() async {
    final googleUser = await _google.signIn();
    if (googleUser == null) { return null; } // user cancelled

    final googleAuth = await googleUser.authentication;
    final credential = GoogleAuthProvider.credential(
      accessToken: googleAuth.accessToken,
      idToken:     googleAuth.idToken,
    );
    return _auth.signInWithCredential(credential);
  }

  // ── Sign out ──────────────────────────────────────────────────────────────────
  static Future<void> signOut() async {
    await Future.wait([
      _auth.signOut(),
      _google.signOut(),
    ]);
  }

  // ── Save phone number to Firestore users/{uid} ────────────────────────────────
  // Accepts 9 raw digits; stores as "+995XXXXXXXXX" alongside email + timestamp.
  static Future<void> savePhoneNumber(String nineDigits) async {
    final user = _auth.currentUser;
    if (user == null) {
      debugPrint('[AuthService] savePhoneNumber aborted — no signed-in user');
      throw StateError('No signed-in user');
    }
    debugPrint('[AuthService] savePhoneNumber writing users/${user.uid}');
    await _firestore.collection('users').doc(user.uid).set({
      'phoneNumber': '+995${nineDigits.trim()}',
      'email':       user.email ?? '',
      'updatedAt':   FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
    debugPrint('[AuthService] savePhoneNumber write complete');
  }

  // ── Fetch phone number from Firestore ─────────────────────────────────────────
  // Returns only the 9-digit local part (strips +995 prefix) so the UI field
  // shows digits the user can edit without the country code.
  static Future<String?> fetchPhoneNumber() async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) { return null; }
    debugPrint('[AuthService] fetchPhoneNumber reading users/$uid');
    final doc = await _firestore.collection('users').doc(uid).get();
    final raw = doc.data()?['phoneNumber'] as String?;
    debugPrint('[AuthService] fetchPhoneNumber raw="$raw"');
    if (raw == null) { return null; }
    return raw.startsWith('+995') ? raw.substring(4) : raw;
  }
}
