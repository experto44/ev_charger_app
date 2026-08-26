import 'dart:async';
import 'dart:io' show Platform;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_constants.dart';
import '../l10n/app_strings.dart';

/// Result of attempting to arm a "notify me when this charger frees up" alert.
///
/// [pushUnavailable] specifically means we couldn't obtain an FCM token — on
/// iOS that's usually the APNs handshake failing (no APNs auth key in the
/// Firebase project, or push not provisioned), which is invisible on Android.
/// Kept distinct from [error] (the Firestore write itself failed) so the field
/// symptom tells us which half broke.
enum AlertResult { ok, limitReached, permissionDenied, pushUnavailable, error }

/// One active "charger freed up" alert, as shown in the profile's
/// "Active Alerts" list.
class ChargerAlert {
  const ChargerAlert({
    required this.stationId,
    required this.name,
    required this.provider,
    this.connector = '',
  });
  final String stationId;
  final String name;
  final String provider;

  /// Connector type this alert is scoped to (e.g. "CCS2"). Empty for a
  /// legacy station-level alert (fires when the whole station frees up).
  final String connector;

  /// The composite id this alert is stored under (see [NotificationService].
  /// _alertKey). Station-level alerts key on the station id alone, so old
  /// docs written before per-connector alerts keep working unchanged.
  String get key =>
      connector.isEmpty ? stationId : '$stationId|$connector';
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

  /// Human-readable reason the last token resolution failed. Surfaced on-screen
  /// (TestFlight release builds show no console) so an iOS push failure names
  /// its actual cause — APNs token missing vs a specific getToken() error.
  String? lastDiag;

  /// Active alerts by station id (with name/provider for the profile list).
  /// Cached so the station sheet can render the toggle state instantly
  /// without a round-trip.
  final Map<String, ChargerAlert> _subscribed = <String, ChargerAlert>{};

  /// Rebuilt-on-change flag so any listening widget (the station sheet, the
  /// profile's Active Alerts list) can refresh after a subscribe/unsubscribe.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  bool get ready => _token != null;
  int get count => _subscribed.length;

  /// Composite key an alert is stored under. A [connector] scopes the alert to
  /// one connector type ("notify when a CCS2 here frees up"); an empty
  /// connector is a whole-station alert (the pre-per-connector behaviour, kept
  /// for providers that publish no per-plug data).
  static String _alertKey(String stationId, String connector) =>
      connector.isEmpty ? stationId : '$stationId|$connector';

  bool isSubscribed(String stationId, [String connector = '']) =>
      _subscribed.containsKey(_alertKey(stationId, connector));

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
      _token = await _resolveToken();
      if (_token != null) {
        await _loadSubscriptions();
      }
      // Keep the stored doc pointing at the current token if it rotates.
      _fcm.onTokenRefresh.listen(_onTokenRefresh);
      // Foreground pushes don't show a system notification — surface them in-app.
      FirebaseMessaging.onMessage.listen(_onForegroundMessage);
      await _initNewStationTopic();
      await _initTapHandling();
    } catch (e) {
      if (kDebugMode) debugPrint('NotificationService.init failed: $e');
    }
  }

  // ── "New charger" broadcasts ──────────────────────────────────────────────
  /// Topics the "a provider opened a station" pushes go to, one per language.
  ///
  /// A topic send carries exactly one body and the server has no idea which
  /// language any given phone reads, so the split has to happen here: each
  /// device subscribes to the one topic it can actually read.
  static const _topicEn = 'new_stations_en';
  static const _topicKa = 'new_stations_ka';

  /// Whether this device wants those broadcasts. Defaults ON — in a country
  /// with a few hundred chargers a new one is genuinely news, and this fires a
  /// handful of times a month rather than daily. The profile can turn it off.
  final ValueNotifier<bool> newStationAlerts = ValueNotifier(true);

  Future<void> _initNewStationTopic() async {
    final p = await SharedPreferences.getInstance();
    newStationAlerts.value = p.getBool(kNewStationAlerts) ?? true;
    await _syncNewStationTopic();
    // Which topic is readable depends on the chosen language, so a language
    // switch has to drag the subscription along with it.
    AppStrings.notifier.addListener(_syncNewStationTopic);
  }

  Future<void> setNewStationAlerts(bool on) async {
    newStationAlerts.value = on;
    final p = await SharedPreferences.getInstance();
    await p.setBool(kNewStationAlerts, on);
    await _syncNewStationTopic();
  }

  /// At most one topic at a time. Leaving the other one subscribed is not a
  /// harmless extra: every announcement would arrive twice, once in each
  /// language, which reads as a bug and costs us the opt-in.
  Future<void> _syncNewStationTopic() async {
    final wanted = !newStationAlerts.value
        ? null
        : (AppStrings.isGeorgian ? _topicKa : _topicEn);
    for (final topic in const [_topicEn, _topicKa]) {
      try {
        if (topic == wanted) {
          await _fcm.subscribeToTopic(topic);
        } else {
          await _fcm.unsubscribeFromTopic(topic);
        }
      } catch (e) {
        // No token yet (iOS APNs handshake) or offline. The next init retries.
        if (kDebugMode) debugPrint('topic $topic sync failed: $e');
      }
    }
  }

  // ── Tapping a push ────────────────────────────────────────────────────────
  /// Station a tapped notification wants shown, for the map screen to consume.
  ///
  /// "A new charger opened" is useless if tapping it drops the driver on
  /// whatever screen the app happened to be on, so the push carries the id and
  /// coordinates and this hands them over.
  final ValueNotifier<({String id, double lat, double lng})?> openStation =
      ValueNotifier(null);

  Future<void> _initTapHandling() async {
    // A tap that launched the app cold is waiting here; one that resumed it
    // arrives on the stream. Both look identical to the map screen.
    final initial = await FirebaseMessaging.instance.getInitialMessage();
    if (initial != null) { _handleTap(initial); }
    FirebaseMessaging.onMessageOpenedApp.listen(_handleTap);
  }

  void _handleTap(RemoteMessage message) {
    final d = message.data;
    if (d['type'] != 'new_station') { return; }
    final id  = (d['station_id'] as String?) ?? '';
    final lat = double.tryParse((d['lat'] as String?) ?? '');
    final lng = double.tryParse((d['lng'] as String?) ?? '');
    if (id.isEmpty || lat == null || lng == null) { return; }
    openStation.value = (id: id, lat: lat, lng: lng);
  }

  Future<void> _loadSubscriptions() async {
    final doc = _doc;
    if (doc == null) return;
    try {
      final snap = await doc.get();
      final subs = (snap.data()?['subs'] as Map<String, dynamic>?) ?? const {};
      _subscribed.clear();
      subs.forEach((key, value) {
        final v = value is Map<String, dynamic> ? value : const <String, dynamic>{};
        // Station id + connector come from the stored value; legacy docs
        // (written before per-connector alerts) carry neither, so the doc key
        // is the station id and the connector is empty.
        final stationId = (v['stationId'] as String?) ?? key;
        _subscribed[key] = ChargerAlert(
          stationId: stationId,
          name:      (v['name'] as String?) ?? stationId,
          provider:  (v['provider'] as String?) ?? '',
          connector: (v['connector'] as String?) ?? '',
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
    // Topic membership is a property of the token, and this is also the moment
    // a subscription that failed at startup (iOS with no APNs token yet) can
    // finally be made. Ahead of the early return below, which only cares about
    // per-station alerts.
    unawaited(_syncNewStationTopic());
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

  /// Resolve the FCM token, taking care of the iOS ordering constraint:
  /// `getToken()` throws `apns-token-not-set` until iOS has delivered the APNs
  /// token, which can lag a moment behind launch. So on iOS we first wait
  /// (briefly, bounded) for the APNs token, then ask for the FCM token. On
  /// Android `getAPNSToken()` returns null immediately and we go straight to
  /// `getToken()`. Returns null if the token can't be resolved (offline, push
  /// disabled) — callers surface that as an error.
  Future<String?> _resolveToken() async {
    try {
      if (Platform.isIOS) {
        // Poll for the APNs token — it usually arrives within a second or two
        // of the first launch after permission is granted.
        var apns = await _fcm.getAPNSToken();
        for (var i = 0; apns == null && i < 15; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 400));
          apns = await _fcm.getAPNSToken();
        }
        if (apns == null) {
          // APNs token never arrived. Don't bail — calling getToken() forces
          // APNs registration (which requestPermission may not have kicked) and
          // surfaces the concrete error instead of us guessing. Record the
          // state so the on-screen diagnostic shows how far we got.
          final s = await _fcm.getNotificationSettings();
          lastDiag = 'APNs=null auth=${s.authorizationStatus.name}; ';
        }
      }
      final t = await _fcm.getToken();
      lastDiag = t == null ? '${lastDiag ?? ''}getToken=null' : null;
      return t;
    } catch (e) {
      lastDiag = '${lastDiag ?? ''}err=$e';
      if (kDebugMode) debugPrint('resolveToken failed: $e');
      return null;
    }
  }

  /// Arm an alert for [stationId]. Enforces the per-device cap and requires
  /// notification permission. Returns a typed result the UI can react to.
  Future<AlertResult> subscribe({
    required String stationId,
    required String stationName,
    required String provider,
    String connector = '',
  }) async {
    if (stationId.isEmpty) return AlertResult.error;
    final key = _alertKey(stationId, connector);
    if (_subscribed.containsKey(key)) return AlertResult.ok;
    if (_subscribed.length >= _maxAlerts) return AlertResult.limitReached;

    // Make sure we actually have permission + a token before promising alerts.
    _token ??= await _resolveToken();
    final settings = await _fcm.getNotificationSettings();
    if (settings.authorizationStatus == AuthorizationStatus.denied) {
      return AlertResult.permissionDenied;
    }
    final doc = _doc;
    // No token → no doc. On iOS this is the APNs/FCM handshake failing (see
    // [AlertResult.pushUnavailable]); surface it distinctly from a write error.
    if (doc == null) return AlertResult.pushUnavailable;

    try {
      await doc.set({
        'token': _token,
        'platform': Platform.isIOS ? 'ios' : 'android',
        'lang': AppStrings.isGeorgian ? 'ka' : 'en',
        'updatedAt': FieldValue.serverTimestamp(),
        'subs': {
          key: {
            'stationId': stationId,
            'connector': connector,
            'name': stationName,
            'provider': provider,
            'createdAt': DateTime.now().toUtc().toIso8601String(),
          },
        },
      }, SetOptions(merge: true));
      _subscribed[key] = ChargerAlert(
        stationId: stationId,
        name:      stationName,
        provider:  provider,
        connector: connector,
      );
      revision.value++;
      return AlertResult.ok;
    } catch (e) {
      if (kDebugMode) debugPrint('subscribe failed: $e');
      return AlertResult.error;
    }
  }

  /// Cancel the alert stored under [alertKey] (the composite station|connector
  /// id from [ChargerAlert.key]; for a station-level alert that's just the
  /// station id). Removes only that entry from the doc.
  Future<void> unsubscribe(String alertKey) async {
    final doc = _doc;
    if (doc == null) return;
    // Optimistic local update so the toggle flips immediately.
    _subscribed.remove(alertKey);
    revision.value++;
    try {
      // Escape the key as a single literal path segment: connector types like
      // "GB/T" and "Type 2" contain characters update() would otherwise parse
      // as field-path syntax (a '/' or space), so back-tick quote it.
      await doc.update({
        'subs.`$alertKey`': FieldValue.delete(),
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
