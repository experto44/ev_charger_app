import 'dart:async';
import 'dart:io' show Platform;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';

/// Result of attempting to arm a "notify me when this charger frees up" alert.
enum AlertResult { ok, limitReached, permissionDenied, error }

/// One active "charger freed up" alert, as shown in the profile's
/// "Active Alerts" list.
class ChargerAlert {
  const ChargerAlert({
    required this.stationId,
    required this.name,
    required this.provider,
  });
  final String stationId;
  final String name;
  final String provider;
}

/// Manages the "Notify me!" charger-free push alerts.
///
/// Flow:
///   1. The user taps "Notify me!" on a busy station → [subscribe] writes the
///      station id into this device's Firestore doc (`charger_alerts/{token}`).
///   2. The server-side gist updater (see `.github/workflows/update_gist.yml`)
///      diffs charger availability every cycle; when a subscribed station goes
///      busy → free it sends an FCM push to this device's token and clears the
///      one-shot subscription.
///
/// No login required — subscriptions are keyed by the device's FCM token, so
/// anonymous users get alerts too. At most [_maxAlerts] active alerts per device.
///
/// Singleton: use [NotificationService.I].
class NotificationService {
  NotificationService._();
  static final NotificationService I = NotificationService._();

  /// Maximum simultaneous charger alerts per device.
  static const int _maxAlerts = 4;

  /// Top-level Firestore collection of per-device alert docs.
  static const String _collection = 'charger_alerts';

  /// Shown to the app so foreground pushes can surface an in-app SnackBar.
  final GlobalKey<ScaffoldMessengerState> messengerKey =
      GlobalKey<ScaffoldMessengerState>();

  final FirebaseMessaging _fcm = FirebaseMessaging.instance;
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  String? _token;
  bool _initialized = false;

  /// Active alerts by station id (with name/provider for the profile list).
  /// Cached so the station sheet can render the toggle state instantly
  /// without a round-trip.
  final Map<String, ChargerAlert> _subscribed = <String, ChargerAlert>{};

  /// Rebuilt-on-change flag so any listening widget (the station sheet, the
  /// profile's Active Alerts list) can refresh after a subscribe/unsubscribe.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  bool get ready => _token != null;
  int get count => _subscribed.length;
  bool isSubscribed(String stationId) => _subscribed.containsKey(stationId);

  /// Current alerts, name-sorted, for the profile's "Active Alerts" section.
  List<ChargerAlert> get alerts {
    final list = _subscribed.values.toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    return list;
  }

  // FCM tokens are safe as Firestore doc ids except that ids may not contain
  // '/'. Sanitize for the id; the real token is always stored in the `token`
  // field (which the server reads to actually send the push).
  String _docId(String token) => token.replaceAll('/', '_');

  DocumentReference<Map<String, dynamic>>? get _doc {
    final t = _token;
    if (t == null) return null;
    return _db.collection(_collection).doc(_docId(t));
  }

  /// Request permission, resolve the FCM token, load existing subscriptions and
  /// wire up foreground message handling. Safe to call once at startup; failures
  /// degrade silently (the feature just stays unavailable).
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    try {
      await _fcm.requestPermission(alert: true, badge: true, sound: true);
      // iOS needs the APNs token before an FCM token is available; on Android
      // this returns immediately. Either way, don't let it block startup.
      _token = await _fcm.getToken();
      if (_token != null) {
        await _loadSubscriptions();
      }
      // Keep the stored doc pointing at the current token if it rotates.
      _fcm.onTokenRefresh.listen(_onTokenRefresh);
      // Foreground pushes don't show a system notification — surface them in-app.
      FirebaseMessaging.onMessage.listen(_onForegroundMessage);
    } catch (e) {
      if (kDebugMode) debugPrint('NotificationService.init failed: $e');
    }
  }

  Future<void> _loadSubscriptions() async {
    final doc = _doc;
    if (doc == null) return;
    try {
      final snap = await doc.get();
      final subs = (snap.data()?['subs'] as Map<String, dynamic>?) ?? const {};
      _subscribed.clear();
      subs.forEach((id, value) {
        final v = value is Map<String, dynamic> ? value : const <String, dynamic>{};
        _subscribed[id] = ChargerAlert(
          stationId: id,
          name:      (v['name'] as String?) ?? id,
          provider:  (v['provider'] as String?) ?? '',
        );
      });
      revision.value++;
    } catch (_) {
      // Offline / read error — leave the cache empty; the toggles just show off.
    }
  }

  Future<void> _onTokenRefresh(String newToken) async {
    final old = _token;
    _token = newToken;
    if (old == null || old == newToken || _subscribed.isEmpty) return;
    // Migrate existing alerts to the new token's doc so they still fire, then
    // drop the stale doc.
    try {
      final oldRef = _db.collection(_collection).doc(_docId(old));
      final oldSnap = await oldRef.get();
      final data = oldSnap.data();
      if (data != null) {
        await _db.collection(_collection).doc(_docId(newToken)).set({
          ...data,
          'token': newToken,
          'updatedAt': FieldValue.serverTimestamp(),
        });
        await oldRef.delete();
      }
    } catch (_) {/* best-effort migration */}
  }

  /// Arm an alert for [stationId]. Enforces the per-device cap and requires
  /// notification permission. Returns a typed result the UI can react to.
  Future<AlertResult> subscribe({
    required String stationId,
    required String stationName,
    required String provider,
  }) async {
    if (stationId.isEmpty) return AlertResult.error;
    if (_subscribed.containsKey(stationId)) return AlertResult.ok;
    if (_subscribed.length >= _maxAlerts) return AlertResult.limitReached;

    // Make sure we actually have permission + a token before promising alerts.
    if (_token == null) {
      try {
        _token = await _fcm.getToken();
      } catch (_) {/* handled below */}
    }
    final settings = await _fcm.getNotificationSettings();
    if (settings.authorizationStatus == AuthorizationStatus.denied) {
      return AlertResult.permissionDenied;
    }
    final doc = _doc;
    if (doc == null) return AlertResult.error;

    try {
      await doc.set({
        'token': _token,
        'platform': Platform.isIOS ? 'ios' : 'android',
        'lang': AppStrings.isGeorgian ? 'ka' : 'en',
        'updatedAt': FieldValue.serverTimestamp(),
        'subs': {
          stationId: {
            'name': stationName,
            'provider': provider,
            'createdAt': DateTime.now().toUtc().toIso8601String(),
          },
        },
      }, SetOptions(merge: true));
      _subscribed[stationId] = ChargerAlert(
        stationId: stationId,
        name:      stationName,
        provider:  provider,
      );
      revision.value++;
      return AlertResult.ok;
    } catch (e) {
      if (kDebugMode) debugPrint('subscribe failed: $e');
      return AlertResult.error;
    }
  }

  /// Cancel the alert for [stationId] (removes just that entry from the doc).
  Future<void> unsubscribe(String stationId) async {
    final doc = _doc;
    if (doc == null) return;
    // Optimistic local update so the toggle flips immediately.
    _subscribed.remove(stationId);
    revision.value++;
    try {
      await doc.update({
        'subs.$stationId': FieldValue.delete(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (_) {
      // If the doc doesn't exist yet there's nothing to remove — ignore.
    }
  }

  void _onForegroundMessage(RemoteMessage message) {
    final n = message.notification;
    if (n == null) return;
    final messenger = messengerKey.currentState;
    if (messenger == null) return;
    final title = n.title ?? '';
    final body = n.body ?? '';
    final text = title.isEmpty ? body : '$title — $body';
    messenger
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text(text, style: AppStrings.font()),
        backgroundColor: const Color(0xFF00C896),
        duration: const Duration(seconds: 6),
        behavior: SnackBarBehavior.floating,
      ));
  }
}
