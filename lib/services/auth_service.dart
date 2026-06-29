import 'dart:convert';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import 'purchase_service.dart';

class AuthService {
  static final _auth      = FirebaseAuth.instance;
  static final _firestore = FirebaseFirestore.instance;
  static final _google    = GoogleSignIn();

  static Stream<User?> get authStateChanges => _auth.authStateChanges();
  static User?         get currentUser      => _auth.currentUser;

  // ── Email / password sign-in ─────────────────────────────────────────────────
  static Future<UserCredential> signInWithEmail(
      String email, String password) async {
    final cred = await _auth.signInWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
    // Pull this account's premium status from Firestore into local state.
    await PurchaseService.I.syncPremiumFromFirestore();
    return cred;
  }

  // ── Email / password registration + verification email ───────────────────────
  static Future<UserCredential> registerWithEmail(
      String email, String password) async {
    final cred = await _auth.createUserWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
    await cred.user?.sendEmailVerification();
    // New account starts with no premium; sync clears any premium the previous
    // user left cached on this device.
    await PurchaseService.I.syncPremiumFromFirestore();
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
    final cred = await _auth.signInWithCredential(credential);
    // Pull this account's premium status from Firestore into local state.
    await PurchaseService.I.syncPremiumFromFirestore();
    return cred;
  }

  // ── Sign in with Apple ────────────────────────────────────────────────────────
  // iOS-only (required by App Store Guideline 4.8 since Google sign-in is offered).
  // Uses a SHA-256-hashed nonce: the hash is sent to Apple, the raw nonce to
  // Firebase, which lets Firebase verify the credential wasn't replayed.
  static Future<UserCredential?> signInWithApple() async {
    final rawNonce = _generateNonce();
    final hashedNonce = sha256.convert(utf8.encode(rawNonce)).toString();

    final appleCred = await SignInWithApple.getAppleIDCredential(
      scopes: const [
        AppleIDAuthorizationScopes.email,
        AppleIDAuthorizationScopes.fullName,
      ],
      nonce: hashedNonce,
    );

    final oauthCred = OAuthProvider('apple.com').credential(
      idToken:     appleCred.identityToken,
      rawNonce:    rawNonce,
      // firebase_auth 5.2.0+ rejects the Apple credential as "Invalid OAuth
      // response from apple.com" (invalid-credential) unless the authorization
      // code is also supplied as the access token.
      accessToken: appleCred.authorizationCode,
    );
    final cred = await _auth.signInWithCredential(oauthCred);

    // Apple returns the user's name only on the very first authorization. Persist
    // it to the Firebase profile while we have it, if not already set.
    final fullName = [appleCred.givenName, appleCred.familyName]
        .whereType<String>()
        .join(' ')
        .trim();
    if (fullName.isNotEmpty && (cred.user?.displayName?.isEmpty ?? true)) {
      await cred.user?.updateDisplayName(fullName);
    }

    await PurchaseService.I.syncPremiumFromFirestore();
    return cred;
  }

  // Cryptographically-secure random string for the Apple sign-in nonce.
  static String _generateNonce([int length = 32]) {
    const chars =
        '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._';
    final rnd = Random.secure();
    return List.generate(length, (_) => chars[rnd.nextInt(chars.length)]).join();
  }

  // ── Delete account (App Store Guideline 5.1.1(v): in-app deletion) ────────────
  // Removes the user's Firestore data and the Firebase Auth account. If the
  // session is too old Firebase requires a fresh re-authentication first, which
  // we do transparently for Google/Apple; email accounts surface a re-login hint.
  static Future<void> deleteAccount() async {
    final user = _auth.currentUser;
    if (user == null) { return; }

    Future<void> wipeAndDelete() async {
      try {
        await _firestore.collection('users').doc(user.uid).delete();
      } catch (_) {/* no data / offline — proceed to auth deletion anyway */}
      await user.delete();
    }

    try {
      await wipeAndDelete();
    } on FirebaseAuthException catch (e) {
      if (e.code != 'requires-recent-login') { rethrow; }
      await _reauthenticate(user); // fresh credential, then retry
      await wipeAndDelete();
    }

    await PurchaseService.I.clearLocalPremium();
    try { await _google.signOut(); } catch (_) {}
  }

  // Re-authenticates [user] with whichever provider they signed in with, so a
  // sensitive op (deletion) can proceed. Email/password can't be re-auth'd
  // silently, so we ask the caller to have the user sign in again.
  static Future<void> _reauthenticate(User user) async {
    final providers = user.providerData.map((p) => p.providerId).toSet();
    if (providers.contains('google.com')) {
      final g = await _google.signIn();
      if (g == null) { throw FirebaseAuthException(code: 'reauth-cancelled'); }
      final ga = await g.authentication;
      await user.reauthenticateWithCredential(GoogleAuthProvider.credential(
        accessToken: ga.accessToken, idToken: ga.idToken,
      ));
    } else if (providers.contains('apple.com')) {
      final rawNonce   = _generateNonce();
      final hashedNonce = sha256.convert(utf8.encode(rawNonce)).toString();
      final apple = await SignInWithApple.getAppleIDCredential(
        scopes: const [AppleIDAuthorizationScopes.email],
        nonce: hashedNonce,
      );
      await user.reauthenticateWithCredential(OAuthProvider('apple.com').credential(
        idToken: apple.identityToken, rawNonce: rawNonce,
        accessToken: apple.authorizationCode,
      ));
    } else {
      // Email/password or unknown — needs a manual fresh sign-in.
      throw FirebaseAuthException(code: 'requires-recent-login');
    }
  }

  // ── Sign out ──────────────────────────────────────────────────────────────────
  static Future<void> signOut() async {
    await Future.wait([
      _auth.signOut(),
      _google.signOut(),
    ]);
    // Premium is per-account: drop the local cache so the next user on this
    // device doesn't inherit it. The account's Firestore record is untouched.
    await PurchaseService.I.clearLocalPremium();
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
