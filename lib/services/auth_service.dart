import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import 'purchase_service.dart';
import 'user_activity_service.dart';

class AuthService {
  static final _auth      = FirebaseAuth.instance;
  static final _firestore = FirebaseFirestore.instance;
  static final _google    = GoogleSignIn();
  static final _functions = FirebaseFunctions.instance;

  // ── Session marker ────────────────────────────────────────────────────────────
  // Firebase Auth restores a persisted session asynchronously, and on Android it
  // is NOT finished when Firebase.initializeApp() returns: currentUser reads null
  // and the first authStateChanges event can be a spurious null before the stored
  // session is loaded. Nothing in the SDK distinguishes "still restoring" from
  // "genuinely signed out", which is why waiting on the stream alone kept letting
  // the Login screen through on launch (the reported Android bug — premium stayed
  // on because it comes from the local cache, while auth looked signed out).
  //
  // So we keep our own marker: written true on every successful sign-in and
  // whenever a restored user is observed, false only on an explicit sign-out or
  // account deletion. It tells us whether a session is *expected*, and therefore
  // whether a null currentUser is worth waiting out. iOS never hit this because
  // its restore completes before the first frame.
  static const _kHadSession = 'auth_had_session';

  static Future<void> _rememberSession(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kHadSession, value);
  }

  // One shared wait, so a profile tap during startup joins the restore already
  // running instead of starting a second countdown of its own.
  static Future<User?>? _pendingRestore;

  /// The signed-in user, waiting out the Android restore race first.
  ///
  /// Returns immediately when a user is already present, and immediately with
  /// null when the marker says nobody is signed in (so a genuinely signed-out
  /// user never waits). Otherwise polls until restore lands or [timeout] passes.
  /// A missing marker (a fresh install, or an upgrade from a build before the
  /// marker existed — where a session may well be persisted) is treated as
  /// "maybe" and waits. main() starts this at launch WITHOUT awaiting it, so
  /// that one-off wait is spent in the background rather than on the splash.
  static Future<User?> restoreSession({
    Duration timeout = const Duration(seconds: 4),
  }) {
    final current = _auth.currentUser;
    if (current != null) {
      unawaited(_rememberSession(true));
      return Future<User?>.value(current);
    }
    return _pendingRestore ??= _waitForRestore(timeout)
        .whenComplete(() => _pendingRestore = null);
  }

  static Future<User?> _waitForRestore(Duration timeout) async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_kHadSession) == false) { return null; }

    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final user = _auth.currentUser;
      if (user != null) {
        unawaited(_rememberSession(true));
        return user;
      }
    }
    // Restore had its chance and produced nobody. Record that, so the wait above
    // can't repeat on every launch of a never-signed-in install.
    await _rememberSession(false);
    return null;
  }

  /// Keeps the rest of the app in step with auth state however late it settles.
  /// Called once from main(): when the restored user finally appears, premium is
  /// re-read from that account (replacing whatever the local cache held) and the
  /// open is stamped for analytics. Without this, a launch that lost the restore
  /// race left premium sourced from the device cache alone.
  static void watchSession() {
    String? lastUid;
    _auth.authStateChanges().listen((user) {
      // Null is either the pre-restore blank or a real sign-out; both should let
      // the same account re-sync if it signs back in.
      if (user == null) { lastUid = null; return; }
      if (user.uid == lastUid) { return; }
      lastUid = user.uid;
      unawaited(_rememberSession(true));
      unawaited(PurchaseService.I.syncPremiumFromFirestore());
      unawaited(UserActivityService.I.recordOpen());
    });
  }

  // Sends the branded verification email (noreply@geocharge.ge, Zoho SMTP) via
  // the sendVerificationEmail Cloud Function. Falls back to Firebase's default
  // email if the function is unreachable, so a user is never left unable to
  // verify. Best-effort throw: caller can surface failures on the resend path.
  static Future<void> _sendBrandedVerification() async {
    try {
      await _functions
          .httpsCallable('sendVerificationEmail')
          .call<Map<String, dynamic>>();
    } catch (e) {
      debugPrint('[AuthService] branded verification failed ($e) — '
          'falling back to Firebase default email');
      await _auth.currentUser?.sendEmailVerification();
    }
  }

  static Stream<User?> get authStateChanges => _auth.authStateChanges();
  static User?         get currentUser      => _auth.currentUser;

  // ── Email / password sign-in ─────────────────────────────────────────────────
  static Future<UserCredential> signInWithEmail(
      String email, String password) async {
    final cred = await _auth.signInWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
    // Remember that a session now exists, so a later cold start waits for the
    // restore instead of concluding signed-out (see [restoreSession]).
    await _rememberSession(true);
    // Pull this account's premium status from Firestore into local state.
    await PurchaseService.I.syncPremiumFromFirestore();
    // Best-effort: stamp/refresh usage analytics for the admin panel.
    unawaited(UserActivityService.I.recordOpen());
    return cred;
  }

  // ── Email / password registration + verification email ───────────────────────
  static Future<UserCredential> registerWithEmail(
      String email, String password) async {
    final cred = await _auth.createUserWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
    await _sendBrandedVerification();
    await _rememberSession(true);
    // New account starts with no premium; sync clears any premium the previous
    // user left cached on this device.
    await PurchaseService.I.syncPremiumFromFirestore();
    // Best-effort: stamp/refresh usage analytics for the admin panel.
    unawaited(UserActivityService.I.recordOpen());
    return cred;
  }

  // ── Resend verification email ─────────────────────────────────────────────────
  static Future<void> resendVerificationEmail() async {
    await _sendBrandedVerification();
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
    // Remember that a session now exists, so a later cold start waits for the
    // restore instead of concluding signed-out (see [restoreSession]).
    await _rememberSession(true);
    // Pull this account's premium status from Firestore into local state.
    await PurchaseService.I.syncPremiumFromFirestore();
    // Best-effort: stamp/refresh usage analytics for the admin panel.
    unawaited(UserActivityService.I.recordOpen());
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
    // Best-effort: stamp/refresh usage analytics for the admin panel.
    unawaited(UserActivityService.I.recordOpen());
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

    await _rememberSession(false);
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
    // No session to wait for on the next launch — the Login screen is correct now.
    await _rememberSession(false);
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
