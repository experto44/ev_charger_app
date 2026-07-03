import 'dart:io' show Platform;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Records lightweight usage analytics for the signed-in user into their
/// `users/{uid}` Firestore document, so the admin panel (admin.geocharge.ge)
/// can show who the registered users are and how they engage.
///
/// Fields written (all merged, never clobbering existing app data):
///   • `name`       — mirror of the Firebase Auth display name, so the panel can
///                    show a name even for email/password accounts (whose name
///                    lives only in Auth, not Firestore).
///   • `email`      — kept in sync with the Auth email.
///   • `platform`   — `android` / `ios` (device the account is used on).
///   • `createdAt`  — first time we ever see this account (≈ registration date).
///                    Written once; never overwritten on later opens.
///   • `lastSeenAt` — refreshed on every app open / resume.
///   • `openCount`  — total number of app opens, so the panel can derive
///                    "opens per day" = openCount / days-since-createdAt.
///
/// Only signed-in users are tracked — anonymous/guest sessions have no account
/// document. Data accrues only from this release forward; existing accounts
/// backfill `createdAt`/`platform` on their next open.
///
/// Singleton: use [UserActivityService.I].
class UserActivityService {
  UserActivityService._();
  static final UserActivityService I = UserActivityService._();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  /// SharedPreferences key holding the epoch-ms of the last counted open, used
  /// to throttle [openCount] so a quick background→foreground bounce (e.g. the
  /// user tabbing away for a moment) isn't counted as a fresh open.
  static const String _kLastOpenKey = 'activity_last_open_ms';

  /// An open is counted at most once per this window. `lastSeenAt` still updates
  /// every time regardless, so "last active" stays accurate to the second.
  static const Duration _kOpenThrottle = Duration(minutes: 10);

  /// Record an app open for the current user. Safe to call anytime — a no-op
  /// when signed out, on web, or if Firestore is unreachable (best-effort).
  Future<void> recordOpen() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || kIsWeb) { return; }

    final ref = _firestore.collection('users').doc(user.uid);
    try {
      // Read once to decide whether this is the account's first sighting (so we
      // stamp createdAt exactly once) and whether the throttle allows counting
      // this open.
      final snap = await ref.get();
      final data = snap.data();

      final prefs = await SharedPreferences.getInstance();
      final nowMs  = DateTime.now().millisecondsSinceEpoch;
      final lastMs = prefs.getInt(_kLastOpenKey) ?? 0;
      final countThisOpen = nowMs - lastMs >= _kOpenThrottle.inMilliseconds;

      final update = <String, dynamic>{
        'email':      user.email ?? '',
        'platform':   _platformName(),
        'lastSeenAt': FieldValue.serverTimestamp(),
      };

      // Only mirror the name when Auth actually has one, so we never wipe a
      // previously-captured name with an empty string.
      final name = user.displayName?.trim() ?? '';
      if (name.isNotEmpty) { update['name'] = name; }

      // Stamp the registration date once, on the first open we ever record for
      // this account (covers both brand-new signups and pre-existing accounts).
      if (data == null || data['createdAt'] == null) {
        update['createdAt'] = FieldValue.serverTimestamp();
      }

      if (countThisOpen) {
        update['openCount'] = FieldValue.increment(1);
      }

      await ref.set(update, SetOptions(merge: true));

      if (countThisOpen) {
        await prefs.setInt(_kLastOpenKey, nowMs);
      }
    } catch (_) {
      // Offline / Firestore error — analytics is best-effort; retry next open.
    }
  }

  String _platformName() {
    if (Platform.isIOS)     { return 'ios'; }
    if (Platform.isAndroid) { return 'android'; }
    return 'other';
  }
}
