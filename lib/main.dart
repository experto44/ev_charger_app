import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:app_tracking_transparency/app_tracking_transparency.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart' show ValueListenable, kIsWeb;
import 'package:flutter/gestures.dart' show TapGestureRecognizer;
import 'package:flutter/material.dart';

import 'firebase_options.dart';
import 'l10n/app_strings.dart';
import 'profile_screen.dart';
import 'screens/auth/login_screen.dart';
import 'screens/charger_alert_popup.dart';
import 'screens/support_popup.dart';
import 'services/auth_service.dart';
import 'services/notification_service.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_marker_cluster/flutter_map_marker_cluster.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:shared_preferences/shared_preferences.dart';

import 'app_constants.dart';
import 'ocm_service.dart';
import 'places_service.dart';
import 'provider_logos.dart';
import 'route_planner_screen.dart';
import 'routing_service.dart';
import 'services/ad_service.dart';
import 'services/live_status_service.dart';
import 'services/purchase_service.dart';
import 'turkey_service.dart';
import 'services/user_activity_service.dart';

/// Background/terminated FCM handler. The "charger freed up" pushes carry a
/// `notification` payload, so the OS displays them itself — nothing to do here.
/// Must be a top-level function annotated for the Flutter engine entrypoint.
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // No work needed: the notification block is rendered by the system.
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  // Firebase Auth restores a persisted session asynchronously AFTER
  // initializeApp returns. On Android that restore is still in flight here, and
  // the FIRST authStateChanges event can be a spurious null — so waiting on the
  // stream returned instantly with "signed out" and the app asked a signed-in
  // user to log in again on every launch, while premium (read from the local
  // cache) stayed on. AuthService keeps a persisted marker of whether a session
  // is expected and waits only then. Started here but NOT awaited — the wait
  // belongs in the background, not on the splash screen; whatever needs the
  // answer (the profile button, arming a charger alert) joins this same
  // in-flight restore rather than starting a countdown of its own.
  unawaited(AuthService.restoreSession());
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
  await AppStrings.load(); // restore saved language (English/Georgian)
  // Subscriptions first (sets isPremium from cache), then ads — the ad layer
  // reads isPremium to decide whether to load anything at all. init() only
  // awaits the local cached-flag read; the store connection runs in the
  // background, so this never blocks launch on Play Billing.
  await PurchaseService.I.init();
  // Registered after init() has seeded isPremium from the cache, so the two
  // never race over the same flag. Auth can settle well after launch on a slow
  // Android device; the watcher re-reads premium from the account the moment it
  // does, so the device cache is never the last word on who is premium.
  AuthService.watchSession();
  // Android initialises ads now — but UNAWAITED. MobileAds.initialize() talks
  // to Play Services and can be slow (or hang) when Play Services is unhealthy;
  // awaiting it here froze the whole launch on the splash screen. The bottom
  // banner listens to AdService.ready, so it appears the moment the SDK is
  // actually ready. iOS defers ads until AFTER the ATT prompt (post-frame
  // callback below) so the first requests can carry the IDFA. google_mobile_ads
  // is mobile-only, so no other platform initialises it.
  if (!kIsWeb && Platform.isAndroid) {
    unawaited(AdService.I.init());
  }
  // Push alerts ("notify me when this charger frees up"). Unawaited — it may
  // prompt for notification permission and resolve the FCM token, neither of
  // which should delay first paint.
  unawaited(NotificationService.I.init());
  // Record an app open for analytics (no-op when signed out). Unawaited so it
  // never delays first paint; auth persistence has already restored any user.
  unawaited(UserActivityService.I.recordOpen());
  PaintingBinding.instance.imageCache.maximumSize = 30;
  PaintingBinding.instance.imageCache.maximumSizeBytes = 10 * 1024 * 1024;
  // iOS only: after the first frame (app active), ask for tracking permission so
  // AdMob may use the IDFA for higher-value personalized ads. A denied/undetermined
  // status simply yields non-personalized ads — nothing else changes.
  WidgetsBinding.instance.addPostFrameCallback((_) async {
    if (kIsWeb || !Platform.isIOS) { return; }
    // iOS: resolve App Tracking Transparency consent BEFORE initialising the ad
    // SDK, so the first banner/interstitial requests can use the IDFA (better
    // fill + eCPM). The ATT prompt can only appear once the app is active, hence
    // the post-frame timing and the short settle delay before requesting it.
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final status = await AppTrackingTransparency.trackingAuthorizationStatus;
    if (status == TrackingStatus.notDetermined) {
      await AppTrackingTransparency.requestTrackingAuthorization();
    }
    // Now that consent is resolved (granted, denied, or restricted), bring up
    // the ad SDK; AdService.ready flips true and the banner appears.
    await AdService.I.init();
  });
  runApp(const EVChargerApp());
}

// ── Theme ─────────────────────────────────────────────────────────────────────
const _bgDark    = Color(0xFF1A1A1A);
const _bgCard    = Color(0xFF252525);
const _bgSurface = Color(0xFF2E2E2E);
const _emerald   = Color(0xFF00C896);
const _textPri   = Color(0xFFFFFFFF);
const _textSec   = Color(0xFF9E9E9E);

// Fallback centre used only when GPS is unavailable
const _tbilisi = LatLng(41.7151, 44.8271);

// Known providers, in display order. "All selected" is the default (no filter).
// Local Georgian providers + a single "International" group for all Open Charge
// Map networks (so international chargers never clutter the local provider list).
const _kAllProviders = [
  'E-Space', 'mart EV', 'MOVEO', 'Electrify Georgia', 'EV Power GE', 'Da-Tene', 'Gadatene', 'EcoCars', 'Solar Station', 'Tegeta', 'Charger Plus',
  TurkeyService.kProvider,  // 'Turkey'        — the EPDK registry, one row for ~200 brands
  OcmService.kProvider,     // 'International' — every other OCM network
];

// Provider selection a fresh install starts with: the Georgian providers only.
// The two group rows are opt-in — "International" because it streams Open Charge
// Map live, "Turkey" because it is a multi-megabyte registry that is only
// offered once the user has added Turkey to their countries in Settings.
final _kDefaultProviders = <String>[
  for (final p in _kAllProviders)
    if (p != OcmService.kProvider && p != TurkeyService.kProvider) p,
];

// CartoDB basemaps (retina-capable, great coverage for Georgia).
//  • Voyager     — bright, colourful streets + labels (Light Mode, default)
//  • Dark Matter — dark theme with clear, high-contrast roads & city names
//
// These endpoints were open until 2026-08-26, when CARTO started requiring an
// API key on them. Unauthenticated requests still answer 200 — they just return
// tiles with "API KEY REQUIRED" printed across them, which is why every build
// then in the wild broke at once with nothing to log. Key from
// carto.com/basemaps/apikey; free up to 5M tiles/month.
//
// This is only what a build SHIPS with. `config.json` in the live feed can
// replace either template at runtime (LiveConfig.tileLight/tileDark), so
// rotating the key or moving to another provider is a Gist edit rather than a
// store release. Prefer that path when this breaks again — and it will, since
// CARTO's own docs say these raster tiles are being retired.
const _kCartoKey  = 'cb1_284y_1_2a3597d5d012ed38ef23ec83';
const _kTileLight =
    'https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}{r}.png?key=$_kCartoKey';
const _kTileDark  =
    'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png?key=$_kCartoKey';

// The cloud feed's URL, its CDN-cache handling and its ETag bookkeeping all
// live in LiveStatusService — fetching it from here directly would go back to
// being served a copy up to five minutes old.

// ── Navigate to coordinates in Google Maps ────────────────────────────────────
Future<void> _navigate(double lat, double lng) async {
  // Free tier sees an interstitial right before the navigation flow begins;
  // premium users are never shown one (respects the existing premium logic).
  if (!PurchaseService.I.isPremium.value) {
    AdService.I.maybeShowInterstitial();
  }
  final uri = Uri.parse('https://www.google.com/maps/search/?api=1&query=$lat,$lng');
  if (await canLaunchUrl(uri)) {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}

// ── App root ──────────────────────────────────────────────────────────────────
class EVChargerApp extends StatelessWidget {
  const EVChargerApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'GeoCharge',
    debugShowCheckedModeBanner: false,
    // Lets foreground "charger freed up" pushes surface an in-app SnackBar.
    scaffoldMessengerKey: NotificationService.I.messengerKey,
    theme: ThemeData.dark().copyWith(
      scaffoldBackgroundColor: _bgDark,
      colorScheme: const ColorScheme.dark(primary: _emerald, surface: _bgCard),
      textTheme: ThemeData.dark().textTheme.apply(fontFamily: 'Noto Sans Georgian'),
    ),
    home: const MapScreen(),
  );
}

// ── MapScreen ─────────────────────────────────────────────────────────────────
class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  final _searchCtrl  = TextEditingController();
  final _searchFocus = FocusNode();
  final _mapCtrl     = MapController();

  // Basemap style. Defaults to the bright CartoDB Voyager tiles; the top-right
  // toggle switches to CartoDB Dark Matter.
  bool             _darkMap          = false;

  /// Tile template for the style currently selected. The live feed's
  /// `config.json` wins over the compiled-in default when it carries a usable
  /// one, which is how a broken or retired basemap gets fixed for phones that
  /// are never going to install another build.
  String get _tileUrl {
    final cfg = LiveStatusService.I.config;
    return _darkMap ? cfg.tileDark ?? _kTileDark : cfg.tileLight ?? _kTileLight;
  }

  AnimationController? _moveAnim;

  bool             _filterDC         = false;
  bool             _filterAvail      = false;
  // Multi-select provider filter, persisted in SharedPreferences (kSelectedProviders)
  // so the last choice is still in force after the app is killed and reopened.
  // The default is every GEORGIAN provider selected; the two opt-in group rows
  // ("International" / OCM and "Turkey" / EPDK) start OFF — they each pull a
  // large remote dataset, so the user turns them on deliberately.
  final Set<String> _selectedProviders = {..._kDefaultProviders};
  final Set<String> _filterConnectors = {};  // empty = no connector filter

  // Minimum-power filter, configured in the profile ("Minimum Charger Power").
  // When on, stations with a KNOWN rating below the threshold are hidden;
  // stations that don't publish a kW rating (kw == 0) stay visible.
  bool _minPowerOn = false;
  int  _minPowerKw = 0;

  // International (OCM) viewport loading is on only while the user has the
  // "International" provider chip checked.
  bool get _internationalOn => _selectedProviders.contains(OcmService.kProvider);

  // The Turkey row exists only once Turkey is one of the user's countries
  // (Settings → Countries) — the EPDK registry is multi-megabyte, so nobody
  // should be able to pull it without having asked for Turkey first.
  bool get _turkeyAvailable => _activeCountries.contains(TurkeyService.kCountry);

  // "International" exists only once a country we do NOT ship local provider
  // data for is selected. _loadOcmCountries skips every localCovered country,
  // so with just Georgia (or Armenia, or Turkey) picked the row would be an
  // opt-in to an empty dataset: it offered a switch that could not do anything.
  bool get _internationalAvailable => kCountries.any(
      (c) => !c.localCovered && _activeCountries.contains(c.name));

  // Providers the user can actually see and pick right now. The two group rows
  // are absent — not greyed out — until their countries are selected, so the
  // sheet only ever lists things that will actually put pins on the map. Drives
  // the sheet, "Select all" and the filter badge alike.
  List<String> get _availableProviders => [
        for (final p in _kAllProviders)
          if (p != TurkeyService.kProvider || _turkeyAvailable)
            if (p != OcmService.kProvider || _internationalAvailable) p,
      ];

  // Keep the two group rows in step with the country selection, and report
  // whether anything changed (so the caller knows to persist).
  //
  // Adding a country IS the decision to see its stations — making the user go
  // and tick a second box in another sheet before anything appears is just a
  // hidden second step. Removing the last country a row depends on retires that
  // row again, so a checkbox can never stay ticked behind a row that is gone.
  // Only the TRANSITION acts: someone who deliberately unticks Turkey while
  // keeping the country selected stays unticked.
  bool _syncGroupProviders({required bool hadTurkey, required bool hadIntl}) {
    var changed = false;
    void sync(String provider, bool before, bool now) {
      if (now && !before) {
        if (_selectedProviders.add(provider)) { changed = true; }
      } else if (!now) {
        if (_selectedProviders.remove(provider)) { changed = true; }
      }
    }
    sync(TurkeyService.kProvider, hadTurkey, _turkeyAvailable);
    sync(OcmService.kProvider, hadIntl, _internationalAvailable);
    return changed;
  }

  // The Turkish (EPDK) dataset loads only when the user both selected Turkey in
  // Settings and left its provider row checked — it's a multi-megabyte file, so
  // we never pull it for someone who is not looking at Turkey.
  bool get _turkeyOn =>
      _selectedProviders.contains(TurkeyService.kProvider) && _turkeyAvailable;

  // Filter is "active" (badge shown) only for a proper, non-empty subset.
  // Empty set or all-selected both mean "show every provider".
  bool get _providerFilterActive =>
      _selectedProviders.isNotEmpty &&
      _selectedProviders.length != _availableProviders.length;

  LatLng?               _userPos;
  // Live GPS subscription so the location pin follows the device as it moves;
  // updates _userPos (but never moves the camera — the recenter button does
  // that on demand). Cancelled in dispose.
  StreamSubscription<Position>? _posSub;
  LatLng?               _searchDest;          // dropped pin from Places search
  String                _searchDestLabel = '';
  List<Station>         _stations    = const [];
  bool                  _loading     = true;
  List<PlacePrediction> _suggestions = const [];
  Timer?                _debounce;

  // Country filter (Settings). Defaults to Georgia only; other countries load
  // live from Open Charge Map when selected.
  Set<String> _activeCountries = {'Georgia'};
  bool get _countryFilterActive => _activeCountries.length != kCountries.length;

  // International stations loaded live from OCM for the user's SELECTED
  // countries (fetched by ISO code, cached per-country for the session). A
  // loading flag drives the "Loading international stations…" pill.
  List<Station> _ocmStations = const [];
  bool          _ocmLoading  = false;

  // Turkish stations from the EPDK registry (TurkeyService). Same pattern as
  // the OCM list: loaded on demand, cleared when the user turns Turkey off.
  List<Station> _trStations = const [];
  bool          _trLoading  = false;
  int           _trGen      = 0;
  StreamSubscription<MapEvent>? _mapEventSub;
  int           _ocmGen = 0;   // guards against stale / superseded responses

  // Viewport top-up: while panning abroad with the International chip on, the
  // stations visible on screen are fetched live from OCM (keyed by id so
  // repeats merge) — big countries are capped in the per-country download, so
  // this fills in full local density wherever the user actually looks.
  final Map<String, Station> _ocmViewport = {};
  Timer? _ocmViewportDebounce;
  static const _kOcmViewportMinZoom = 9.0;   // below this a box is too huge
  static const _kOcmViewportCap     = 4000;  // keep marker building sane
  bool          _centerInGeorgia = true; // carousel only shows over Georgia

  // Periodic background refresh of the station feed. The Gist itself is updated
  // server-side, so the app must re-poll to surface new availability while it
  // stays open — otherwise data is frozen at whatever was fetched on launch.
  // Two minutes rather than three because a poll that finds nothing new is now
  // answered with a 304 and a couple of hundred bytes instead of a 529 KB
  // download, so asking more often costs almost nothing and shaves a minute off
  // the worst case. The updater's own cycle is ~2.5 min, so polling faster than
  // this would only re-ask for data that cannot have changed yet.
  Timer? _refreshTimer;
  static const _kRefreshInterval = Duration(minutes: 2);

  // The station shown in the open detail sheet, if any, kept in step with each
  // background poll so a sheet left open does not silently go stale. Null
  // whenever no sheet is up.
  final ValueNotifier<Station?> _openSheetStation = ValueNotifier<Station?>(null);

  // Rapid multi-tap detection for the recenter (GPS) button. A single tap
  // re-centres at the normal overview zoom; tapping 2–3 times in quick
  // succession zooms in close (~150 m radius) so nearby chargers are easy to
  // see. Taps within _kMultiTapWindow of each other count as one burst.
  DateTime? _lastLocateTap;
  int       _locateTapCount = 0;
  static const _kMultiTapWindow = Duration(milliseconds: 600);
  static const double _kOverviewZoom = 14.0; // single-tap recenter
  static const double _kCloseZoom    = 17.0; // 2+ taps → ~150 m radius

  // Recenter button handler: counts rapid taps and zooms in close on the
  // second (and further) tap of a burst, otherwise recenters at overview zoom.
  void _onLocateTap() {
    final now = DateTime.now();
    _locateTapCount =
        (_lastLocateTap != null && now.difference(_lastLocateTap!) < _kMultiTapWindow)
            ? _locateTapCount + 1
            : 1;
    _lastLocateTap = now;
    final zoom = _locateTapCount >= 2 ? _kCloseZoom : _kOverviewZoom;
    _locateMe(recenter: true, animate: true, zoom: zoom);
  }

  @override
  void initState() {
    super.initState();
    // Observe app lifecycle so we can refresh the GPS fix on resume — the
    // device may have moved while the app was backgrounded.
    WidgetsBinding.instance.addObserver(this);
    _loadPrefs();
    // Station data can load independently of the map controller. The daily
    // support/premium popup is also kicked off here, once the first frame is up.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadStations();
      _maybeShowSupportPopup();
    });
    // Re-poll the live feed every few minutes so availability stays current
    // without requiring an app restart. Uses the non-clobbering refresh so a
    // transient network failure never wipes the stations already on screen.
    _refreshTimer = Timer.periodic(_kRefreshInterval, (_) => _refreshStations());
    // config.json is read in the background, so a basemap override lands after
    // the map is already drawn. Repaint when it does, otherwise a build whose
    // compiled-in tiles are dead would keep showing them for the whole session.
    LiveStatusService.I.configListenable.addListener(_onRemoteConfig);
    // Tapping a "new charger" push should land on that charger. The tap can
    // arrive before this screen exists (it cold-started the app), so the
    // service holds it and this drains it once the map can actually move.
    NotificationService.I.openStation.addListener(_onPushOpenStation);
    _onPushOpenStation();
    // _locateMe() is called from MapOptions.onMapReady, which fires only
    // after FlutterMap has mounted and the MapController is fully attached.
  }

  void _onRemoteConfig() {
    if (mounted) { setState(() {}); }
  }

  // ── "New charger" push → show that charger ────────────────────────────────
  /// Set once FlutterMap has attached its controller. Moving the camera before
  /// that throws, and a cold start from a notification is exactly the case that
  /// gets there first.
  bool _mapReady = false;

  /// A tap waiting to be honoured. Held rather than dropped because the feed
  /// lands seconds after the map does, and a station that is not in `_stations`
  /// yet has no sheet to open.
  ({String id, double lat, double lng})? _pendingPush;

  /// Whether the camera has already been sent to [_pendingPush]. The request
  /// outlives the move, because it is retried until the station shows up in the
  /// feed, and re-flying the map on each retry would drag a driver who has
  /// panned away right back.
  bool _pushMoved = false;

  void _onPushOpenStation() {
    final req = NotificationService.I.openStation.value;
    if (req == null) { return; }
    NotificationService.I.openStation.value = null;
    _pendingPush = req;
    _pushMoved   = false;
    _consumePendingPush();
  }

  void _consumePendingPush() {
    final req = _pendingPush;
    if (req == null || !mounted || !_mapReady) { return; }
    // Move on the coordinates from the push itself, so the driver lands in the
    // right place even if the feed has not caught up with the station yet.
    if (!_pushMoved) {
      _pushMoved = true;
      _animatedMove(LatLng(req.lat, req.lng), 15);
    }
    Station? hit;
    for (final s in _stations) {
      if (s.id == req.id) { hit = s; break; }
    }
    // Keep the request pending when the station is not loaded yet; the next
    // feed load calls back in.
    if (hit == null) { return; }
    _pendingPush = null;
    _showStationSheet(hit);
  }

  // Friendly daily Support/Premium prompt. Shown ONLY to non-premium users, and
  // at most once every 24h (the last-shown epoch ms is persisted in
  // SharedPreferences). The timestamp is written when we decide to show, so a
  // quick dismiss still suppresses it for the next 24h.
  Future<void> _maybeShowSupportPopup() async {
    // Eligibility: never for premium users.
    if (PurchaseService.I.isPremium.value) { return; }
    final p      = await SharedPreferences.getInstance();
    final lastMs = p.getInt(kSupportPopupLastShown) ?? 0;
    final nowMs  = DateTime.now().millisecondsSinceEpoch;
    if (nowMs - lastMs < const Duration(hours: 24).inMilliseconds) { return; }
    if (!mounted) { return; }
    await p.setInt(kSupportPopupLastShown, nowMs);
    if (!mounted) { return; }
    await showSupportPopup(context);
  }

  // Apply the profile's default connector + the saved country selection. The
  // connector default seeds the active map filter each launch; manual changes
  // on the map are session-only and reset to this on next launch.
  Future<void> _loadPrefs() async {
    final p = await SharedPreferences.getInstance();
    final rawConn  = p.getString(kDefaultConnector);
    final rawCntry = p.getString(kActiveCountries);
    final rawProv  = p.getString(kSelectedProviders);
    if (!mounted) { return; }
    // Back-compat: older versions stored a single connector as a plain string
    // (not JSON). Try the new list format first, then fall back.
    var defConns = <String>[];
    if (rawConn != null && rawConn.isNotEmpty) {
      try {
        defConns = (jsonDecode(rawConn) as List).map((e) => e as String).toList();
      } catch (_) {
        defConns = [rawConn];
      }
    }
    setState(() {
      _filterConnectors
        ..clear()
        ..addAll(defConns);
      _minPowerOn = p.getBool(kMinPowerEnabled) ?? false;
      _minPowerKw = p.getInt(kMinPowerKw) ?? 0;
      if (rawCntry != null) {
        try {
          _activeCountries =
              (jsonDecode(rawCntry) as List).map((e) => e as String).toSet();
        } catch (_) {/* keep default */}
      }
      // Restore the saved provider selection. Anything not currently available
      // is dropped — a stale entry must never resurrect a row the user cannot
      // see, and the countries were restored just above, so this is measured
      // against the selection actually in force. Note this restores exactly what
      // was saved: a group row the user deliberately unticked stays unticked
      // across restarts, since only a country CHANGE re-ticks one.
      if (rawProv != null) {
        try {
          final available = _availableProviders.toSet();
          final saved = (jsonDecode(rawProv) as List)
              .map((e) => e as String)
              .where(available.contains)
              .toSet();
          _selectedProviders
            ..clear()
            ..addAll(saved);
        } catch (_) {/* keep default */}
      }
    });
    // Both datasets are also kicked off by the map's onMapReady, but that can
    // fire BEFORE this async prefs read completes — in which case it ran against
    // the defaults and would leave a restored "International"/"Turkey" selection
    // with no data until the user reopened a sheet. Re-run them here now that the
    // saved selection is in; both entry points are idempotent (results cached).
    _loadOcmCountries();
    _loadTurkey();
  }

  // Re-read the profile-owned filters (min power + selected connectors) after
  // returning from the profile screen so changes apply to the map immediately
  // (not just on next launch). Connectors matter here because the map no longer
  // has its own connector chips — the profile's "My Ports" is the only source.
  Future<void> _reloadProfileFilters() async {
    final p = await SharedPreferences.getInstance();
    final rawConn = p.getString(kDefaultConnector);
    if (!mounted) { return; }
    var defConns = <String>[];
    if (rawConn != null && rawConn.isNotEmpty) {
      try {
        defConns = (jsonDecode(rawConn) as List).map((e) => e as String).toList();
      } catch (_) {
        defConns = [rawConn];
      }
    }
    setState(() {
      _filterConnectors
        ..clear()
        ..addAll(defConns);
      _minPowerOn = p.getBool(kMinPowerEnabled) ?? false;
      _minPowerKw = p.getInt(kMinPowerKw) ?? 0;
    });
  }

  // Opens Profile (or Login when signed out) — shared by the search-bar avatar
  // and the "My Ports" filter chip.
  //
  // Auth restore is NOT reliably finished by the time this runs — a profile tap
  // right after launch used to demand a fresh Google login on Android because
  // currentUser was still null. restoreSession() waits that out (only when a
  // session is actually expected), so Login is shown to signed-out users only.
  Future<void> _openProfile() async {
    final user = await AuthService.restoreSession();
    if (!mounted) { return; }
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => user == null ? const LoginScreen() : const ProfileScreen(),
      ),
    );
    await _reloadProfileFilters();
    // The country picker is reached from inside the profile now, so returning
    // from it is the moment a country change has to reach the map.
    await _reloadCountries();
  }

  // "Fast DC" chip tap → pick the minimum charger power for the map filter.
  // The chosen threshold is persisted to the SAME prefs the profile screen
  // edits (kMinPowerEnabled/kMinPowerKw), so map and profile never disagree.
  Future<void> _showFastDcSheet() async {
    // Sentinel values for the sheet result alongside real kW steps.
    const off = -1, dcAny = 0;
    final current = !_filterDC && !_minPowerOn
        ? off
        : (_minPowerOn ? _minPowerKw : dcAny);
    final picked = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: _bgCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => AppStrings.wrap(SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 14),
            Container(
              width: 36, height: 4,
              decoration: BoxDecoration(
                color: _bgSurface, borderRadius: BorderRadius.circular(2)),
            ),
            const SizedBox(height: 14),
            Text(AppStrings.fastDcSheetTitle,
                style: AppStrings.font(const TextStyle(
                    color: _textPri, fontSize: 15, fontWeight: FontWeight.w700))),
            const SizedBox(height: 10),
            for (final (value, label) in <(int, String)>[
              (off,   AppStrings.filterOff),
              (dcAny, AppStrings.dcAnyPower),
              for (final kw in kMinPowerSteps) (kw, '≥ $kw kW'),
            ])
              ListTile(
                dense: true,
                onTap: () => Navigator.pop(ctx, value),
                leading: Icon(
                  value == current
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_off_rounded,
                  color: value == current ? _emerald : _textSec,
                  size: 20,
                ),
                title: Text(label,
                    style: AppStrings.font(TextStyle(
                      color: value == current ? _emerald : _textPri,
                      fontSize: 14,
                      fontWeight:
                          value == current ? FontWeight.w700 : FontWeight.w500,
                    ))),
              ),
            const SizedBox(height: 10),
          ],
        ),
      )),
    );
    if (picked == null || !mounted) { return; }
    final p = await SharedPreferences.getInstance();
    if (!mounted) { return; }
    setState(() {
      _filterDC   = picked != off;
      _minPowerOn = picked > 0;
      if (picked > 0) { _minPowerKw = picked; }
    });
    await p.setBool(kMinPowerEnabled, picked > 0);
    if (picked > 0) { await p.setInt(kMinPowerKw, picked); }
  }

  // Persist the provider selection so it survives the app being killed. Written
  // on every toggle — the sheet has no "apply" button, each tap is the decision.
  Future<void> _saveProviders() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(kSelectedProviders, jsonEncode(_selectedProviders.toList()));
  }

  // Re-read the saved country selection after returning from Settings, then
  // refresh the live OCM data for the current viewport under the new selection.
  Future<void> _reloadCountries() async {
    final p   = await SharedPreferences.getInstance();
    final raw = p.getString(kActiveCountries);
    if (!mounted) { return; }
    final hadTurkey = _turkeyAvailable;
    final hadIntl   = _internationalAvailable;
    var changed = false;
    setState(() {
      _activeCountries = raw == null
          ? {'Georgia'}
          : (jsonDecode(raw) as List).map((e) => e as String).toSet();
      // Newly added countries switch their group row on; removed ones switch it
      // back off and take it out of the sheet. See _syncGroupProviders.
      changed = _syncGroupProviders(hadTurkey: hadTurkey, hadIntl: hadIntl);
    });
    if (changed) { await _saveProviders(); }
    _loadOcmCountries();
    _loadTurkey();
  }

  // Track whether the map is centred on Georgia — the local station carousel is
  // only relevant there; it's hidden when panning to international views.
  void _updateCenterInGeorgia() {
    final c     = _mapCtrl.camera.center;
    final inGeo = countryOf(c.latitude, c.longitude) == 'Georgia';
    if (inGeo != _centerInGeorgia && mounted) {
      setState(() => _centerInGeorgia = inGeo);
    }
  }

  // Load live OCM international stations for every SELECTED country (Settings)
  // that we don't already cover with local provider data. Each country is
  // fetched once by ISO code and cached for the session, so toggling providers
  // or panning the map never refetches. Active only while the "International"
  // provider chip is on; otherwise OCM pins are cleared. A generation guard
  // discards superseded responses so the loading pill can never stick on.
  Future<void> _loadOcmCountries() async {
    if (!_internationalOn) {
      if (mounted &&
          (_ocmStations.isNotEmpty || _ocmViewport.isNotEmpty || _ocmLoading)) {
        setState(() {
          _ocmStations = const [];
          _ocmViewport.clear();
          _ocmLoading  = false;
        });
      }
      return;
    }
    // Top up the current viewport too (no-op over Georgia/Armenia or when
    // zoomed way out) so toggling the chip abroad shows local pins at once.
    _scheduleOcmViewportFetch();
    // ISO codes of the selected countries we load from OCM. Locally-covered
    // countries (Georgia, Armenia) ship richer provider data, so they're skipped
    // here and never duplicated by international pins.
    final codes = kCountries
        .where((c) => _activeCountries.contains(c.name) && !c.localCovered)
        .map((c) => c.code)
        .toList();
    if (codes.isEmpty) {                      // no international country selected
      if (mounted && (_ocmStations.isNotEmpty || _ocmLoading)) {
        setState(() { _ocmStations = const []; _ocmLoading = false; });
      }
      return;
    }
    final gen = ++_ocmGen;
    if (mounted) { setState(() => _ocmLoading = true); }
    final results = await Future.wait(codes.map(OcmService.fetchByCountry));
    if (!mounted || gen != _ocmGen) { return; } // superseded by a newer load
    setState(() {
      _ocmStations = [for (final list in results) ...list];
      _ocmLoading  = false;
    });
  }

  // Load (or drop) the Turkish EPDK dataset for the current selection. Called
  // alongside _loadOcmCountries on every country/provider change; cheap after
  // the first call because TurkeyService caches in memory and on disk.
  Future<void> _loadTurkey() async {
    if (!_turkeyOn) {
      if (mounted && (_trStations.isNotEmpty || _trLoading)) {
        setState(() { _trStations = const []; _trLoading = false; });
      }
      return;
    }
    final gen = ++_trGen;
    if (mounted) { setState(() => _trLoading = true); }
    final list = await TurkeyService.fetchAll();
    if (!mounted || gen != _trGen) { return; }  // superseded by a newer load
    setState(() {
      _trStations = list;
      _trLoading  = false;
    });
  }

  // Debounced viewport top-up: fires ~0.7s after the map settles so a fling
  // across Europe doesn't spray a request per frame. Silent (no loading pill)
  // — it's a background enrichment, not a user-initiated load.
  void _scheduleOcmViewportFetch() {
    if (!_internationalOn) { return; }
    _ocmViewportDebounce?.cancel();
    _ocmViewportDebounce =
        Timer(const Duration(milliseconds: 700), _fetchOcmViewport);
  }

  Future<void> _fetchOcmViewport() async {
    if (!mounted || !_internationalOn) { return; }
    // Reading the camera throws until FlutterMap has attached the controller.
    // Restoring a saved "International" selection can schedule this before the
    // first layout, so treat "no camera yet" as nothing to fetch — onMapReady
    // runs the same load again the moment the map is up.
    final MapCamera cam;
    try {
      cam = _mapCtrl.camera;
    } catch (_) {
      return;
    }
    if (cam.zoom < _kOcmViewportMinZoom) { return; }
    // Locally-covered countries (Georgia, Armenia) ship richer provider data —
    // never overlay OCM pins on top of them.
    final c = cam.center;
    final inLocal = kCountries.any(
        (k) => k.localCovered && k.contains(c.latitude, c.longitude));
    if (inLocal) { return; }
    final b    = cam.visibleBounds;
    final list = await OcmService.fetchViewport(
      south: b.south, west: b.west, north: b.north, east: b.east,
    );
    if (!mounted || !_internationalOn || list.isEmpty) { return; }
    setState(() {
      // Bound the accumulated set: past the cap, keep only the fresh viewport
      // (older, off-screen pins are the cheapest thing to shed).
      if (_ocmViewport.length > _kOcmViewportCap) { _ocmViewport.clear(); }
      for (final s in list) { _ocmViewport[s.id] = s; }
    });
  }

  List<Station> _parseStations(String raw) => (jsonDecode(raw) as List)
      .map((e) => Station.fromJson(e as Map<String, dynamic>))
      .toList();

  // Load the bundled asset (instant, offline). Doubles as a supplement for the
  // live feed: any provider bundled with the app but not yet published to the
  // Gist is added in, so the app never hides a provider it ships with.
  Future<List<Station>> _loadBundled() async {
    try {
      // Capture the bundle synchronously (before the await) so we never touch
      // BuildContext after an async suspension.
      final bundle = DefaultAssetBundle.of(context);
      return _parseStations(await bundle.loadString('assets/data/chargers.json'));
    } catch (_) {
      return const [];
    }
  }

  // Parse a feed body and merge in any bundled-only providers as a supplement,
  // so the app never hides a provider it ships with. Returns null if the body
  // could not be parsed.
  Future<List<Station>?> _mergeFeed(String body) async {
    final assetStations = await _loadBundled();
    try {
      final live = _parseStations(body);
      final liveProviders = live.map((s) => s.provider).toSet();
      final supplement = assetStations
          .where((s) => !liveProviders.contains(s.provider))
          .toList();
      return [...live, ...supplement];
    } catch (_) {
      // Malformed feed. Drop the cached fingerprint so the next attempt is
      // answered with a body instead of a 304 against content we never used.
      LiveStatusService.I.forgetFeedETag();
      return null;
    }
  }

  // Initial load: show live data, or fall back to the bundled asset offline.
  Future<void> _loadStations() async {
    final res = await LiveStatusService.I.fetchFeed(requireBody: true);
    final fresh =
        res.body == null ? null : await _mergeFeed(res.body!);
    if (!mounted) { return; }
    if (fresh != null) {
      setState(() { _stations = fresh; _loading = false; });
    } else {
      // Offline / first launch with no network — bundled snapshot only.
      final bundled = await _loadBundled();
      if (!mounted) { return; }
      setState(() { _stations = bundled; _loading = false; });
    }
    // A push tapped before the feed arrived has been waiting for these.
    _consumePendingPush();
  }

  // Background / on-demand refresh. Re-fetches live data and swaps it in.
  // Crucially, on failure it KEEPS the existing data (never clobbers good live
  // stations with a stale bundled snapshot on a transient blip), and a feed that
  // has not changed since last time is reported as such rather than as a
  // failure — the two used to be indistinguishable to the caller.
  Future<FeedStatus> _refreshStations({bool userInitiated = false}) async {
    final res = await LiveStatusService.I.fetchFeed(userInitiated: userInitiated);
    if (res.status != FeedStatus.updated || res.body == null) {
      return res.status;
    }
    final fresh = await _mergeFeed(res.body!);
    if (fresh == null) { return FeedStatus.failed; }
    if (!mounted) { return FeedStatus.updated; }
    setState(() => _stations = fresh);
    _syncOpenSheet(fresh);
    // Cheap no-op unless a tapped push is still waiting for its station. The
    // announcement and the feed come from the same pipeline, so it is normally
    // present on the first load; a poll is the only other chance it gets, and
    // only once the rows above have actually landed.
    _consumePendingPush();
    return FeedStatus.updated;
  }

  // Push the newest row for the open sheet's station into its notifier, so a
  // sheet the user left open follows the background polls instead of freezing on
  // whatever was true when they tapped the marker.
  void _syncOpenSheet(List<Station> fresh) {
    final open = _openSheetStation.value;
    if (open == null || open.id.isEmpty) { return; }
    for (final s in fresh) {
      if (s.id == open.id) {
        _openSheetStation.value = s;
        return;
      }
    }
  }

  // Latest data for a single station, for the sheet's refresh button.
  //
  // Prefers reading the station straight from its operator (~1s old) over the
  // feed (a pipeline snapshot up to a cycle old); see LiveStatusService. Any
  // failure on that path falls through to the feed, so the button is never worse
  // than it was before the direct path existed.
  Future<StationRefresh> _refreshStation(Station target) async {
    if (LiveStatusService.I.canFetchDirect(target)) {
      final direct = await LiveStatusService.I.fetchDirect(target);
      if (direct != null) {
        if (mounted) {
          setState(() => _stations = [
                for (final s in _stations) s.id == direct.id ? direct : s,
              ]);
        }
        return StationRefresh(
          sameLiveState(target, direct)
              ? RefreshOutcome.unchanged
              : RefreshOutcome.updated,
          direct,
          true,
        );
      }
    }

    final status = await _refreshStations(userInitiated: true);
    if (status == FeedStatus.failed) { return const StationRefresh.failed(); }
    // Nothing new was published; the row on screen is still the current one.
    if (status == FeedStatus.unchanged) {
      return StationRefresh(RefreshOutcome.unchanged, target);
    }
    for (final s in _stations) {
      final sameId = target.id.isNotEmpty && s.id == target.id;
      final sameCoords = target.id.isEmpty &&
          s.lat == target.lat && s.lng == target.lng;
      if (sameId || sameCoords) {
        return StationRefresh(
          sameLiveState(target, s)
              ? RefreshOutcome.unchanged
              : RefreshOutcome.updated,
          s,
        );
      }
    }
    // The station has dropped out of the feed entirely.
    return const StationRefresh.failed();
  }

  // Acquire (or refresh) the device location and update the user pin. Called on
  // cold start (onMapReady), on app resume, and by the recenter button — so the
  // pin and the button always reflect the current position, not a stale fix
  // from launch. Also starts the live position stream the first time it runs.
  //
  //  • recenter — move the camera onto the fix (button + cold start). When false
  //               (resume) we update the pin only, so we don't yank the user's
  //               view away from wherever they were looking.
  //  • animate  — animate the camera move (button) vs. an instant jump (cold
  //               start, before the map has settled).
  Future<void> _locateMe({
    bool recenter = false,
    bool animate = false,
    double zoom = _kOverviewZoom,
  }) async {
    try {
      LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) { return; }

      void center(LatLng p) {
        if (!recenter) { return; }
        if (animate) { _animatedMove(p, zoom); } else { _mapCtrl.move(p, zoom); }
      }

      // Keep the live stream running so the pin tracks the device as it moves.
      _startLocationStream();

      // ── Step 1: instant feedback using the cached last-known position ─────
      final last = await Geolocator.getLastKnownPosition();
      if (last != null && mounted) {
        final latlng = LatLng(last.latitude, last.longitude);
        setState(() => _userPos = latlng);
        center(latlng);
      }

      // ── Step 2: refine with a fresh high-accuracy fix ─────────────────────
      final pos    = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 10),
        ),
      );
      if (!mounted) { return; }
      final latlng = LatLng(pos.latitude, pos.longitude);
      setState(() => _userPos = latlng);
      center(latlng);
    } catch (_) {
      // Permission denied or GPS timeout — keep whatever fix we already have.
    }
  }

  // Subscribe once to the OS location stream so the pin follows the device as
  // it moves while the app is open. distanceFilter throttles updates to every
  // ~25 m to limit battery use and rebuilds. The camera is left alone — only
  // the pin moves; the recenter button re-centers on demand.
  void _startLocationStream() {
    _posSub ??= Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 25,
      ),
    ).listen(
      (pos) {
        if (!mounted) { return; }
        setState(() => _userPos = LatLng(pos.latitude, pos.longitude));
      },
      onError: (_) {/* transient GPS error — keep the last fix */},
    );
  }

  // Refresh the location fix when the app returns to the foreground; the user
  // may have physically moved while it was backgrounded. We update the pin but
  // don't yank the camera — the recenter button handles that on demand.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _locateMe();
      // Count re-opens (throttled inside the service) so "opens per day" and
      // "last active" stay current for the admin analytics.
      unawaited(UserActivityService.I.recordOpen());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _posSub?.cancel();
    _moveAnim?.dispose();
    _searchCtrl.dispose();
    _searchFocus.dispose();
    _debounce?.cancel();
    _ocmViewportDebounce?.cancel();
    _mapEventSub?.cancel();
    _refreshTimer?.cancel();
    LiveStatusService.I.configListenable.removeListener(_onRemoteConfig);
    NotificationService.I.openStation.removeListener(_onPushOpenStation);
    _openSheetStation.dispose();
    super.dispose();
  }

  void _zoom(double delta) =>
      _mapCtrl.move(_mapCtrl.camera.center, _mapCtrl.camera.zoom + delta);

  // Smoothly pan + zoom the map to a target (used by search-result selection
  // and the recenter button) instead of an abrupt jump.
  void _animatedMove(LatLng dest, double destZoom) {
    final cam     = _mapCtrl.camera;
    final latT    = Tween<double>(begin: cam.center.latitude,  end: dest.latitude);
    final lngT    = Tween<double>(begin: cam.center.longitude, end: dest.longitude);
    final zoomT   = Tween<double>(begin: cam.zoom,             end: destZoom);

    _moveAnim?.dispose();
    final controller = AnimationController(
      duration: const Duration(milliseconds: 700), vsync: this);
    _moveAnim = controller;
    final curve = CurvedAnimation(parent: controller, curve: Curves.easeInOutCubic);

    controller.addListener(() {
      _mapCtrl.move(
        LatLng(latT.evaluate(curve), lngT.evaluate(curve)),
        zoomT.evaluate(curve),
      );
    });
    controller.forward().whenComplete(() {
      controller.dispose();
      if (_moveAnim == controller) { _moveAnim = null; }
    });
  }

  // ── Provider filter FAB → multi-select bottom sheet ──────────────────────
  void _openProviderFilter() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      // Allow the sheet to grow past the default ~half-screen cap and to respect
      // the status bar / system insets, so a long provider list is fully
      // scrollable and reachable (incl. one-handed mode). See _ProviderFilterSheet.
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => StatefulBuilder(
        // setSheet rebuilds the checkbox rows; setState rebuilds the map + badge.
        builder: (_, setSheet) => _ProviderFilterSheet(
          // Only what the user can actually act on: the group rows are absent
          // until their countries are selected, rather than shown disabled.
          all:      _availableProviders,
          selected: _selectedProviders,
          // Master checkbox: every row the sheet is showing. The group rows used
          // to be excluded because they were visible before the user had opted
          // into their countries; now they only appear once that opt-in has
          // happened, so leaving them out would just make "Select all" skip a
          // visible row for no reason the user could see.
          onToggleAll: () {
            final rows  = _availableProviders;
            final allOn = rows.every(_selectedProviders.contains);
            setState(() {
              if (allOn) {
                _selectedProviders.removeAll(rows);
              } else {
                _selectedProviders.addAll(rows);
              }
            });
            setSheet(() {});
            unawaited(_saveProviders());
            // "Select all" can cover both group rows, so their datasets have to
            // load (or clear) with it.
            _loadTurkey();
            _loadOcmCountries();
          },
          onToggle: (p) {
            setState(() {
              if (_selectedProviders.contains(p)) {
                _selectedProviders.remove(p);
              } else {
                _selectedProviders.add(p);
              }
            });
            setSheet(() {});
            unawaited(_saveProviders());
            // Toggling "International" loads/clears the OCM stations for the
            // user's selected countries.
            if (p == OcmService.kProvider)  { _loadOcmCountries(); }
            if (p == TurkeyService.kProvider) { _loadTurkey(); }
          },
        ),
      ),
    );
  }

  // ── Station marker tap → bottom sheet ────────────────────────────────────
  void _showStationSheet(Station s) {
    _openSheetStation.value = s;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _StationSheet(
        station: s,
        onGetDirections: () => _openRoutePlannerTo(s),
        onRefresh: _refreshStation,
        liveStation: _openSheetStation,
      ),
    ).whenComplete(() {
      // The screen can be torn down while the sheet is still closing, and
      // the notifier goes with it.
      if (mounted) { _openSheetStation.value = null; }
    });
  }

  // Shared push — no sheet-pop side-effect (used by carousel "Plan & Go").
  Future<void> _pushRoutePlannerTo(Station destination) async {
    AdService.I.maybeShowInterstitial(); // free-tier only; no-op for premium
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => RoutePlannerScreen(
          // Everything loaded, not just the Georgian feed: a route that crosses
          // into Turkey has to see Turkish chargers (the planner pulls them in
          // itself if they aren't loaded yet).
          stations:           _allStations,
          initialOrigin:      _userPos,
          initialDestination: destination,
        ),
      ),
    );
  }

  // Called from bottom-sheet "Get Directions" — pops the sheet first.
  Future<void> _openRoutePlannerTo(Station destination) async {
    if (mounted) { Navigator.pop(context); }
    await _pushRoutePlannerTo(destination);
  }

  void _onSearchChanged(String query) {
    setState(() {});
    _debounce?.cancel();
    if (query.trim().length < 2) {
      setState(() => _suggestions = const []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 400), () async {
      // Rank around where the driver is (or is looking), now that search is no
      // longer hard-limited to Georgia.
      final r = await PlacesService.autocomplete(query,
          bias: _userPos ?? _mapCtrl.camera.center);
      if (mounted) { setState(() => _suggestions = r); }
    });
  }

  Future<void> _onSuggestionSelected(PlacePrediction p) async {
    _searchCtrl.text = p.description;
    _searchFocus.unfocus();
    setState(() => _suggestions = const []);
    final coords = await PlacesService.getCoordinates(p.placeId);
    if (coords == null || !mounted) { return; }
    final label = p.mainText.isNotEmpty ? p.mainText : p.description;
    setState(() {
      _searchDest      = coords;       // drop a distinct destination pin
      _searchDestLabel = label;
    });
    _animatedMove(coords, 15);         // smooth pan/zoom to it
    _showSearchDestinationSheet(coords, label);  // open Navigate / Plan & Go
  }

  // Action modal for a searched destination — Navigate + Plan & Go.
  void _showSearchDestinationSheet(LatLng dest, String label) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _SearchDestinationSheet(
        label: label,
        onNavigate: () {
          Navigator.pop(context);
          _navigate(dest.latitude, dest.longitude);
        },
        onPlanAndGo: () {
          Navigator.pop(context);
          // Build a lightweight Station for the route planner destination.
          _pushRoutePlannerTo(Station(
            name:      label,
            location:  label,
            available: 0,
            lat:       dest.latitude,
            lng:       dest.longitude,
            isDC:      false,
            kw:        0,
            price:     '',
          ));
        },
      ),
    );
  }

  // Local Gist stations + the Turkish EPDK registry + live OCM international
  // stations (the per-country downloads plus the viewport top-up, deduped by
  // OCM id).
  List<Station> get _allStations {
    if (_ocmStations.isEmpty && _ocmViewport.isEmpty && _trStations.isEmpty) {
      return _stations;
    }
    final seen = <String>{for (final s in _ocmStations) s.id};
    return [
      ..._stations,
      ..._trStations,
      ..._ocmStations,
      for (final s in _ocmViewport.values)
        if (!seen.contains(s.id)) s,
    ];
  }

  List<Station> get _filtered {
    // NOTE: the search bar is a Google Places *destination* search — it must NOT
    // filter the station list (doing so wiped every station off the map once a
    // place was picked, since the place name matches no charger). Stations are
    // filtered only by the chip filters below and stay visible at all times.
    return _allStations.where((s) {
      // Country filter applies ONLY to local stations (classified by
      // coordinates). OCM/International stations are already fetched per the
      // user's selected countries (and gated by the International provider chip),
      // so they carry a non-empty country and skip this coordinate check.
      if (s.country.isEmpty) {
        final country = countryOf(s.lat, s.lng);
        if (country != null && !_activeCountries.contains(country)) { return false; }
      }
      // Provider filter (applied first): empty OR all-selected => show all;
      // any non-empty subset => keep only those providers. "International" is
      // off by default, so OCM pins are hidden until the user opts in.
      // Turkish stations carry their real brand ("ZES", "Eşarj", …) as the
      // provider, but the filter sheet groups all ~200 of them under one
      // "Turkey" row, so match them against that group instead of the brand.
      final filterName = s.country == TurkeyService.kCountry
          ? TurkeyService.kProvider
          : s.provider;
      if (_selectedProviders.isNotEmpty &&
          !_selectedProviders.contains(filterName)) { return false; }
      if (_filterDC    && !s.isDC)          { return false; }
      if (_filterAvail && s.available == 0) { return false; }
      // Minimum-power filter (profile setting): hide stations with a known
      // rating below the threshold; unknown ratings (kw == 0) stay visible.
      if (_minPowerOn && _minPowerKw > 0 &&
          s.kw > 0 && s.kw < _minPowerKw)   { return false; }
      // Connector filter — case-insensitive match so label/data casing never
      // hides a station (e.g. "CCS2" vs "ccs2").
      if (_filterConnectors.isNotEmpty &&
          !s.connectors.any((c) => _filterConnectors
              .any((f) => f.toLowerCase() == c.toLowerCase()))) { return false; }
      return true;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final stations = _filtered;
    // Lookup so the cluster bubble can aggregate the availability of the pins it
    // groups (keyed by the exact LatLng each marker is built from below).
    final stationByPoint = <String, Station>{
      for (final s in stations) '${s.lat},${s.lng}': s,
    };
    final navBottom        = MediaQuery.of(context).padding.bottom;
    final controlsBottom   = 130.0 + navBottom;
    // Bound the right control column below the search-bar/chips block (plus the
    // top banner ad when it's shown) so its top buttons never overlap the chips.
    // The column stays bottom-anchored and scrolls if vertical space is tight.
    final topControlsBound = MediaQuery.of(context).padding.top + 120;
    return Scaffold(
      // Free-tier banner — rebuilds (and disappears) when premium is granted.
      // Returns an empty box when premium or no ad unit is configured.
      bottomNavigationBar: ValueListenableBuilder<bool>(
        // Rebuild when ads finish initialising (on iOS that's after the ATT
        // prompt, i.e. after the first frame) as well as when premium changes,
        // so the banner appears the moment the SDK is ready.
        valueListenable: AdService.I.ready,
        builder: (_, __, ___) => ValueListenableBuilder<bool>(
          valueListenable: PurchaseService.I.isPremium,
          builder: (_, __, ___) =>
              AdService.I.bottomBanner() ?? const SizedBox.shrink(),
        ),
      ),
      body: Stack(
        children: [
          // ── Map ──────────────────────────────────────────────────────────────
          FlutterMap(
            mapController: _mapCtrl,
            options: MapOptions(
              initialCenter: _tbilisi,
              initialZoom:   13,
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.all,
              ),
              // onMapReady fires once the controller is attached — the only
              // safe moment to call _mapCtrl.move() on startup. Also subscribes
              // to map movements to track whether we're centred on Georgia (for
              // the local carousel), and kicks off the initial OCM load. The
              // event stream only emits on real camera changes (never on widget
              // rebuilds), so it can't loop.
              onMapReady: () {
                _mapEventSub ??= _mapCtrl.mapEventStream.listen((_) {
                  _updateCenterInGeorgia();
                  _scheduleOcmViewportFetch();
                });
                _mapReady = true;
                // A tapped push outranks the usual recenter-on-me. _locateMe is
                // async, so letting it run would slide the map to the driver's
                // own position a moment after we moved it to the charger they
                // asked for, undoing the tap.
                final pushPending = _pendingPush != null;
                _consumePendingPush();
                _locateMe(recenter: !pushPending);
                _loadOcmCountries();
                _loadTurkey();
              },
            ),
            children: [
              // CartoDB basemap — Voyager (light) or Dark Matter (dark), unless
              // the feed's config.json names a different one (_tileUrl).
              // retinaMode pulls @2x tiles on high-DPI screens so streets and
              // city names stay crisp and easy to read.
              //
              // Keyed on the URL rather than on _darkMap so that a template
              // arriving from config.json mid-session also rebuilds the layer;
              // keying on the theme alone would leave a dead basemap on screen
              // until the user happened to toggle it.
              TileLayer(
                key: ValueKey(_tileUrl),
                urlTemplate: _tileUrl,
                subdomains: const ['a', 'b', 'c', 'd'],
                userAgentPackageName: 'ge.geocharge.app',
                retinaMode: RetinaMode.isHighDensity(context),
                maxNativeZoom: 20,
                keepBuffer: 0,
                panBuffer: 0,
              ),
              // Station dots — clustered. Markers are built from the already
              // filtered `stations` list, so clustering automatically respects
              // every active filter (provider / connector / Fast DC / Available).
              MarkerClusterLayerWidget(
                options: MarkerClusterLayerOptions(
                  maxClusterRadius: 50,          // px: only group pins this close
                  size: const Size(46, 46),
                  alignment: Alignment.center,
                  padding: const EdgeInsets.all(50),
                  maxZoom: 16,                   // above this, always show singles
                  markerChildBehavior: true,     // let each pin's own onTap fire
                  markers: stations.map((s) => Marker(
                    point:  LatLng(s.lat, s.lng),
                    width:  40,
                    height: 40,
                    child:  GestureDetector(
                      onTap: () => _showStationSheet(s),
                      child: _AvailabilityPin(
                        available: s.available,
                        total:     s.total,
                        isOut:     _stationOutOfOrder(s),
                        unknown:   !s.live,
                      ),
                    ),
                  )).toList(),
                  // Cluster bubble — a proportional availability pie (same green/
                  // orange split as a single pin), so a group of all-busy chargers
                  // reads orange from far out instead of a misleading green.
                  builder: (context, markers) {
                    int avail = 0, tot = 0, count = 0, outCount = 0;
                    int unknownCount = 0;
                    for (final m in markers) {
                      final s = stationByPoint[
                          '${m.point.latitude},${m.point.longitude}'];
                      if (s == null) { continue; }
                      count++;
                      // Stations with no live feed can't be counted as free or
                      // busy — they'd tint the whole bubble on a guess.
                      if (!s.live) { unknownCount++; continue; }
                      if (_stationOutOfOrder(s)) { outCount++; }
                      avail += s.available;
                      tot   += s.total > 0
                          ? s.total
                          : (s.available > 0 ? s.available : 1);
                    }
                    final freeFraction = tot > 0
                        ? (avail / tot).clamp(0.0, 1.0)
                        : (avail > 0 ? 1.0 : 0.0);
                    // Grey only when EVERY charger in the cluster is out of order.
                    final allOut = count > 0 && outCount == count;
                    // Slate when the whole cluster is registry-only data.
                    final allUnknown = count > 0 && unknownCount == count;
                    return Container(
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        boxShadow: [BoxShadow(color: Colors.black54, blurRadius: 6)],
                      ),
                      child: CustomPaint(
                        painter: _AvailabilityPainter(freeFraction,
                            isOut: allOut, unknown: allUnknown),
                        child: Center(
                          child: Text(
                            '${markers.length}',
                            style: const TextStyle(
                              color: Colors.black,
                              fontWeight: FontWeight.bold,
                              fontSize: 15),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              // User location dot
              if (_userPos != null)
                MarkerLayer(markers: [
                  Marker(
                    point:  _userPos!,
                    width:  22,
                    height: 22,
                    child:  Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFF2196F3),
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 3),
                        boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 6)],
                      ),
                    ),
                  ),
                ]),
              // Searched destination pin (rendered above stations & clusters).
              if (_searchDest != null)
                MarkerLayer(markers: [
                  Marker(
                    point:     _searchDest!,
                    width:     46,
                    height:    46,
                    alignment: Alignment.topCenter,  // tip sits on the coordinate
                    child: GestureDetector(
                      onTap: () => _showSearchDestinationSheet(
                        _searchDest!,
                        _searchDestLabel.isEmpty ? 'Destination' : _searchDestLabel),
                      child: const Icon(
                        Icons.location_on,
                        color: Color(0xFFE53935),
                        size: 44,
                        shadows: [Shadow(color: Colors.black54, blurRadius: 6)],
                      ),
                    ),
                  ),
                ]),
              // Attribution for the third-party map tiles and station data.
              // Required by the CARTO / OpenStreetMap and Open Charge Map licences.
              //
              // Deliberately NOT RichAttributionWidget: that one renders only
              // logos and an "i" button permanently and keeps every
              // TextSourceAttribution inside a popup, so these three credits sat
              // one tap away rather than on screen. Visible attribution is the
              // price of CARTO's free basemap tier, so they are drawn onto the
              // map directly.
              _MapAttribution(dark: _darkMap, bottomInset: navBottom),
            ],
          ),

          // ── Search bar + suggestions + filter chips ───────────────────────
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _SearchBarWidget(
                    controller: _searchCtrl,
                    focusNode:  _searchFocus,
                    onChanged:  _onSearchChanged,
                    onProfile:  _openProfile,
                  ),
                  if (_suggestions.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    _SuggestionsList(suggestions: _suggestions, onTap: _onSuggestionSelected),
                  ],
                  // Top banner ad removed — only the bottom banner remains.
                  const SizedBox(height: 10),
                  _FilterChips(
                    filterDC:    _filterDC,
                    filterAvail: _filterAvail,
                    minPowerOn:  _minPowerOn,
                    minPowerKw:  _minPowerKw,
                    portsCount:  _filterConnectors.length,
                    onFastDc:    _showFastDcSheet,
                    onAvail:     (v) => setState(() => _filterAvail = v),
                    onMyPorts:   _openProfile,
                  ),
                  // Live fetch indicator — OCM countries, or the (larger, and
                  // therefore slower) first download of the Turkish registry.
                  if (_ocmLoading || _trLoading) ...[
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                        decoration: BoxDecoration(
                          color: _bgCard,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: _bgSurface),
                        ),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          const SizedBox(
                            width: 13, height: 13,
                            child: CircularProgressIndicator(strokeWidth: 2, color: _emerald),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _trLoading && !_ocmLoading
                                ? 'Loading Turkish stations…'
                                : 'Loading international stations…',
                            style: const TextStyle(color: _textSec, fontSize: 12),
                          ),
                        ]),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),

          // ── Right control column (bottom-anchored, grouped) ───────────────
          // A single bottom-anchored Column keeps the map-style toggle, provider
          // filter, zoom, route and GPS buttons perfectly grouped at uniform
          // spacing on ANY screen height — no fragile hardcoded offsets. The
          // group is anchored just above the station carousel; it grows upward.
          Positioned(
            right:  16,
            top:    topControlsBound,
            bottom: controlsBottom,
            // reverse keeps the group pinned to the bottom; it only scrolls when
            // the screen is too short to fit every button (so none are clipped).
            child: SingleChildScrollView(
              reverse: true,
              // Clip.none so the buttons' drop shadows (and the filter badge)
              // aren't sliced into hard stripes at the scroll viewport edges.
              clipBehavior: Clip.none,
              child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Map style toggle (Light ↔ Dark)
                _MapCtrlButton(
                  onTap: () => setState(() => _darkMap = !_darkMap),
                  icon:  _darkMap ? Icons.dark_mode_rounded : Icons.light_mode_rounded,
                  iconColor: _darkMap ? _textPri : Colors.amber,
                ),
                const SizedBox(height: 6),
                // Provider filter (badge also lights when country filtering is on)
                _MapCtrlButton(
                  onTap: _openProviderFilter,
                  icon:  Icons.layers_rounded,
                  iconColor:   _providerFilterActive ? _emerald : _textSec,
                  borderColor: _providerFilterActive ? _emerald : _bgSurface,
                  showBadge:   _providerFilterActive || _countryFilterActive,
                ),
                const SizedBox(height: 6),
                // Zoom in / out
                _ZoomBtn(icon: Icons.add_rounded,    onTap: () => _zoom(1)),
                const SizedBox(height: 6),
                _ZoomBtn(icon: Icons.remove_rounded, onTap: () => _zoom(-1)),
                const SizedBox(height: 6),
                // Route planner
                _MapCtrlButton(
                  onTap: () {
                    AdService.I.maybeShowInterstitial(); // free-tier only
                    Navigator.push<void>(
                      context,
                      MaterialPageRoute(
                        builder: (_) =>
                            RoutePlannerScreen(stations: _allStations),
                      ),
                    );
                  },
                  icon: Icons.alt_route_rounded,
                  iconColor: _textSec,
                ),
                const SizedBox(height: 6),
                // Recenter GPS — single tap recenters; double/triple tap zooms in close.
                _MapCtrlButton(
                  onTap: _onLocateTap,
                  icon: Icons.my_location_rounded,
                  iconColor:   _userPos == null ? _textSec : _emerald,
                  borderColor: _userPos == null ? _bgSurface : _emerald,
                  bgColor:     _userPos == null ? _bgSurface : _bgCard,
                ),
              ],
              ),
            ),
          ),

          // ── Bottom panel: initial-load indicator ────────────────────────────
          if (_loading)
            const Positioned(
              left: 0, right: 0, bottom: 0,
              child: SizedBox(
                height: 120,
                child: Center(
                  child: SizedBox(
                    width: 24, height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2, color: _emerald),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ── Search bar ────────────────────────────────────────────────────────────────
class _SearchBarWidget extends StatelessWidget {
  const _SearchBarWidget({
    required this.controller, required this.focusNode, required this.onChanged,
    required this.onProfile,
  });
  final TextEditingController controller;
  final FocusNode             focusNode;
  final ValueChanged<String>  onChanged;
  final VoidCallback          onProfile;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 54,
      decoration: BoxDecoration(
        color: _bgCard,
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 12, offset: Offset(0, 4))],
      ),
      child: Row(
        children: [
          const SizedBox(width: 14),
          const Icon(Icons.search, color: _textSec, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: controller,
              focusNode:  focusNode,
              onChanged:  onChanged,
              style: const TextStyle(color: _textPri, fontSize: 15),
              decoration: const InputDecoration(
                hintText:  'Search stations or address…',
                hintStyle: TextStyle(color: _textSec, fontSize: 15),
                border:    InputBorder.none,
                isDense:   true,
              ),
            ),
          ),
          // No settings gear here any more: the only thing behind it was the
          // country picker, which now lives in the profile next to the other
          // per-user choices rather than as a second, competing entry point.
          _IconBtn(
            icon:  Icons.account_circle_outlined,
            onTap: onProfile,
          ),
          const SizedBox(width: 8),
        ],
      ),
    );
  }
}

// ── Suggestions dropdown ──────────────────────────────────────────────────────
class _SuggestionsList extends StatelessWidget {
  const _SuggestionsList({required this.suggestions, required this.onTap});
  final List<PlacePrediction>                    suggestions;
  final Future<void> Function(PlacePrediction)   onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: _bgCard,
        borderRadius: BorderRadius.circular(14),
        boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 16, offset: Offset(0, 6))],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: suggestions.asMap().entries.map((e) {
          final isLast = e.key == suggestions.length - 1;
          final p      = e.value;
          return GestureDetector(
            onTap:     () => onTap(p),
            behavior:  HitTestBehavior.opaque,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                border: isLast ? null : const Border(
                  bottom: BorderSide(color: _bgSurface, width: 0.5),
                ),
              ),
              child: Row(children: [
                const Icon(Icons.location_on_outlined, color: _emerald, size: 18),
                const SizedBox(width: 10),
                Expanded(child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(p.mainText,
                        style: const TextStyle(color: _textPri, fontSize: 14, fontWeight: FontWeight.w500),
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    if (p.secondaryText.isNotEmpty)
                      Text(p.secondaryText,
                          style: const TextStyle(color: _textSec, fontSize: 12),
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                  ],
                )),
              ]),
            ),
          );
        }).toList(),
      ),
    );
  }
}

// ── Filter chips ──────────────────────────────────────────────────────────────
class _FilterChips extends StatelessWidget {
  const _FilterChips({
    required this.filterDC,
    required this.filterAvail,
    required this.minPowerOn,
    required this.minPowerKw,
    required this.portsCount,
    required this.onFastDc,
    required this.onAvail,
    required this.onMyPorts,
  });
  final bool filterDC, filterAvail;
  // Min-power filter state (shared with the profile via prefs) — shown as a
  // "≥N kW" suffix on the Fast DC chip so the active threshold is visible.
  final bool minPowerOn;
  final int  minPowerKw;
  // How many connector types the profile has selected (badge on My Ports).
  final int  portsCount;
  final VoidCallback       onFastDc;   // opens the min-power sheet
  final ValueChanged<bool> onAvail;
  final VoidCallback       onMyPorts;  // opens the profile ("My Ports" lives there)

  @override
  Widget build(BuildContext context) {
    // Connector-type chips were removed on purpose: the connector selection
    // lives in the profile ("My Ports") and having both created conflicting
    // filter states. The profile selection still filters the map silently.
    final fastDcLabel = minPowerOn && minPowerKw > 0
        ? 'Fast DC ≥${minPowerKw}kW'
        : 'Fast DC';
    return SizedBox(
      height: 36,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          _Chip(icon: Icons.bolt, label: fastDcLabel,
              active: filterDC || minPowerOn, onTap: onFastDc),
          const SizedBox(width: 8),
          _Chip(icon: Icons.check_circle_outline, label: 'Available',
              active: filterAvail, onTap: () => onAvail(!filterAvail)),
          const SizedBox(width: 8),
          _Chip(icon: Icons.settings_input_component_rounded,
              label: portsCount > 0 ? 'My Ports ($portsCount)' : 'My Ports',
              active: false, onTap: onMyPorts),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.active, required this.onTap, this.icon});
  final String   label;
  final bool     active;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final fg = active ? Colors.black : _textSec;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: active ? _emerald : _bgCard,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: active ? _emerald : _bgSurface),
          boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 6)],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 15, color: fg),
              const SizedBox(width: 5),
            ],
            Text(
              label,
              style: TextStyle(
                color: fg,
                fontSize: 13, fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _IconBtn extends StatelessWidget {
  const _IconBtn({required this.icon, this.onTap});
  final IconData     icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      width: 38, height: 38,
      decoration: BoxDecoration(color: _bgSurface, borderRadius: BorderRadius.circular(10)),
      child: Icon(icon, color: _textSec, size: 20),
    ),
  );
}

// ── Provider filter sheet ─────────────────────────────────────────────────────
class _ProviderFilterSheet extends StatelessWidget {
  const _ProviderFilterSheet({
    required this.all,
    required this.selected,
    required this.onToggle,
    required this.onToggleAll,
  });
  /// Providers to list. Already filtered to what the user can act on, so every
  /// row here is tappable — nothing is rendered disabled.
  final List<String>       all;
  final Set<String>        selected;
  final ValueChanged<String> onToggle;
  final VoidCallback       onToggleAll;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    // Cap the sheet to the visible window so it never runs off-screen and stays
    // fully interactive even when system insets shrink the usable area (nav bar,
    // keyboard, or Android one-handed mode). The provider list scrolls within
    // this cap, so every row stays reachable on any screen size.
    final maxHeight = mq.size.height - mq.padding.top - mq.viewInsets.bottom - 24;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: Container(
        decoration: const BoxDecoration(
          color: _bgCard,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Fixed header (drag handle + titles).
              Container(
                margin: const EdgeInsets.only(top: 10),
                width: 40, height: 4,
                decoration: BoxDecoration(
                  color: _bgSurface, borderRadius: BorderRadius.circular(2)),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 18, 20, 4),
                child: Row(children: [
                  Icon(Icons.layers_rounded, color: _emerald, size: 20),
                  SizedBox(width: 8),
                  Text('Providers',
                      style: TextStyle(color: _textPri, fontSize: 16, fontWeight: FontWeight.bold)),
                ]),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 0, 20, 6),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Show stations from',
                      style: TextStyle(color: _textSec, fontSize: 12)),
                ),
              ),
              // Scrollable provider list — every item (incl. International and
              // the "more coming soon" row) is reachable however short the sheet.
              Flexible(
                child: SingleChildScrollView(
                  padding: EdgeInsets.only(bottom: mq.viewInsets.bottom),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Master select/deselect-all row, covering every row the
                      // sheet is showing.
                      Builder(builder: (_) {
                        final allOn = all.every(selected.contains);
                        return InkWell(
                          onTap: onToggleAll,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 20, vertical: 13),
                            child: Row(children: [
                              Icon(
                                allOn
                                    ? Icons.check_box_rounded
                                    : Icons.check_box_outline_blank_rounded,
                                color: allOn ? _emerald : _textSec, size: 24,
                              ),
                              const SizedBox(width: 12),
                              const Text('Select all',
                                  style: TextStyle(
                                      color: _textPri, fontSize: 15,
                                      fontWeight: FontWeight.w700)),
                            ]),
                          ),
                        );
                      }),
                      const Divider(
                          color: _bgSurface, height: 1, thickness: 1,
                          indent: 20, endIndent: 20),
                      // One checkbox row per known provider — toggles apply immediately.
                      ...all.map((p) {
                        final on = selected.contains(p);
                        // The two group rows stand for whole networks of
                        // operators rather than one brand, so they say so.
                        final subtitle = p == TurkeyService.kProvider
                            ? 'Every licensed network (EPDK registry)'
                            : p == OcmService.kProvider
                                ? 'Open Charge Map, outside Georgia'
                                : null;
                        return InkWell(
                          onTap: () => onToggle(p),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
                            child: Row(children: [
                              Icon(
                                on ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded,
                                color: on ? _emerald : _textSec,
                                size: 24,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      p == TurkeyService.kProvider ? '🇹🇷 Turkey' : p,
                                      style: const TextStyle(
                                          color: _textPri,
                                          fontSize: 15,
                                          fontWeight: FontWeight.w500),
                                    ),
                                    if (subtitle != null)
                                      Text(subtitle,
                                          style: const TextStyle(
                                              color: _textSec, fontSize: 11)),
                                  ],
                                ),
                              ),
                            ]),
                          ),
                        );
                      }),
                      // Disabled placeholder for providers added in the future.
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 20, vertical: 13),
                        child: Row(children: [
                          Icon(Icons.check_box_outline_blank_rounded,
                              color: Color(0xFF555555), size: 24),
                          SizedBox(width: 12),
                          Text('More providers coming soon…',
                              style: TextStyle(
                                  color: Color(0xFF666666), fontSize: 13, fontStyle: FontStyle.italic)),
                        ]),
                      ),
                      const SizedBox(height: 10),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Searched destination action sheet (Navigate + Plan & Go) ──────────────────
class _SearchDestinationSheet extends StatelessWidget {
  const _SearchDestinationSheet({
    required this.label,
    required this.onNavigate,
    required this.onPlanAndGo,
  });
  final String      label;
  final VoidCallback onNavigate, onPlanAndGo;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: _bgCard,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 40, height: 4,
                  decoration: BoxDecoration(
                    color: _bgSurface, borderRadius: BorderRadius.circular(2)),
                ),
              ),
              const SizedBox(height: 16),
              Row(children: [
                const Icon(Icons.location_on, color: Color(0xFFE53935), size: 22),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    label,
                    style: const TextStyle(
                      color: _textPri, fontSize: 16, fontWeight: FontWeight.bold),
                    maxLines: 2, overflow: TextOverflow.ellipsis,
                  ),
                ),
              ]),
              const SizedBox(height: 16),
              // Primary — Navigate (direct Google Maps launch)
              GestureDetector(
                onTap: onNavigate,
                child: Container(
                  height: 46,
                  decoration: BoxDecoration(
                    color: _emerald, borderRadius: BorderRadius.circular(12)),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.navigation_rounded, color: Colors.black, size: 18),
                      SizedBox(width: 8),
                      Text('Navigate',
                          style: TextStyle(
                              color: Colors.black, fontSize: 15, fontWeight: FontWeight.w700)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
              // Secondary — Plan & Go (route planner pre-filled)
              GestureDetector(
                onTap: onPlanAndGo,
                child: Container(
                  height: 46,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: _emerald, width: 1.5),
                  ),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.alt_route_rounded, color: _emerald, size: 18),
                      SizedBox(width: 8),
                      Text('Plan & Go',
                          style: TextStyle(
                              color: _emerald, fontSize: 15, fontWeight: FontWeight.w700)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Availability pin ──────────────────────────────────────────────────────────
// Map marker whose circle is split proportionally: a green slice sized to the
// free fraction (available / total) with the rest in orange. So a location with
// 1 of 2 plugs free shows half green / half orange; 1 of 4 shows a quarter
// green. Falls back to all-green (any free) or all-orange (none free) when a
// total isn't known. The bolt icon and white ring match the old pin styling.
// A station is fully out of order: no free plug, and every published plug reads
// "out" (neither free nor busy). Such pins are drawn grey, not busy-orange.
// Out of order means every published plug is REPORTED broken. A plug whose
// operator publishes no status at all (Tegeta's Porsche destination chargers)
// says nothing about the charger, so a site made only of those is unknown, not
// broken — and the grey "out" pin would otherwise win over the slate one.
bool _stationOutOfOrder(Station s) =>
    s.available == 0 &&
    s.ports.any((p) => p.isOut) &&
    !s.ports.any((p) => p.isFree || p.isBusy);

// Grey used for out-of-order chargers (mirrors the Tesla map's "out" colour).
const _outGrey = Color(0xFF6B7A85);
// Slate used for stations whose source publishes no live availability.
const _unknownSlate = Color(0xFF4F7C9E);

/// The map's permanent credit line: basemap tiles and station data.
///
/// Kept small and low-contrast so it does not compete with the pins, but always
/// on screen — CARTO's basemap terms and the ODbL both ask for attribution to be
/// visible, not merely reachable.
///
/// Laid out as one wrapping [Text.rich] rather than a Row of tappable labels:
/// the line is long enough that a Row would overflow at large system font
/// scales, and an attribution that throws a layout error is worse than none.
class _MapAttribution extends StatefulWidget {
  const _MapAttribution({required this.dark, required this.bottomInset});

  /// Which basemap is underneath, since one is near-white and the other
  /// near-black and the credit has to stay legible on both.
  final bool dark;

  /// System gesture inset, measured ABOVE the Scaffold and handed down.
  ///
  /// Reading MediaQuery here would give zero: a Scaffold strips the bottom
  /// padding from its body whenever a bottomNavigationBar exists, and this one
  /// always does — it is the free-tier ad banner, which collapses to an empty
  /// box for premium users without giving the space back. The credit would then
  /// sit under the gesture pill, which draws its handle straight through it.
  final double bottomInset;

  @override
  State<_MapAttribution> createState() => _MapAttributionState();
}

class _MapAttributionState extends State<_MapAttribution> {
  /// "OpenStreetMap contributors" is the wording the ODbL asks for; the other
  /// two are the names their own attribution pages use.
  static const _sources = <(String, String)>[
    ('OpenStreetMap contributors', 'https://www.openstreetmap.org/copyright'),
    ('CARTO',                      'https://carto.com/attributions'),
    ('Open Charge Map',            'https://openchargemap.org/'),
  ];

  /// Built once and disposed with the widget: a TapGestureRecognizer holds
  /// resources, so creating them inline in build() would leak one set per frame.
  late final List<TapGestureRecognizer> _taps = [
    for (final (_, url) in _sources)
      TapGestureRecognizer()
        ..onTap = () => launchUrl(
              Uri.parse(url),
              mode: LaunchMode.externalApplication,
            ),
  ];

  @override
  void dispose() {
    for (final t in _taps) { t.dispose(); }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fg = widget.dark ? Colors.white70 : Colors.black87;
    return Align(
      alignment: Alignment.bottomLeft,
      child: Padding(
        padding: EdgeInsets.only(left: 4, right: 4, bottom: 4 + widget.bottomInset),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: (widget.dark ? Colors.black : Colors.white)
                .withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
            child: Text.rich(
              TextSpan(children: [
                const TextSpan(text: '© '),
                for (var i = 0; i < _sources.length; i++) ...[
                  if (i > 0) const TextSpan(text: ' · '),
                  TextSpan(
                    text: _sources[i].$1,
                    style: TextStyle(
                      decoration: TextDecoration.underline,
                      decorationColor: fg,
                    ),
                    recognizer: _taps[i],
                  ),
                ],
              ]),
              style: TextStyle(fontSize: 10, color: fg),
            ),
          ),
        ),
      ),
    );
  }
}

class _AvailabilityPin extends StatelessWidget {
  const _AvailabilityPin({
    required this.available,
    required this.total,
    this.isOut = false,
    this.unknown = false,
  });
  final int  available;
  final int  total;
  final bool isOut;   // fully out of order → grey pin
  final bool unknown; // no live availability published → slate pin

  @override
  Widget build(BuildContext context) {
    // Fraction of plugs free. With no usable total, treat "any available" as
    // fully free so the pin still reads green rather than a misleading split.
    final double freeFraction = total > 0
        ? (available / total).clamp(0.0, 1.0)
        : (available > 0 ? 1.0 : 0.0);
    return Container(
      width: 40, height: 40,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [BoxShadow(color: Colors.black54, blurRadius: 6)],
      ),
      child: CustomPaint(
        painter: _AvailabilityPainter(freeFraction,
            isOut: isOut, unknown: unknown),
        child: const Center(child: Icon(Icons.bolt, color: Colors.black, size: 20)),
      ),
    );
  }
}

class _AvailabilityPainter extends CustomPainter {
  const _AvailabilityPainter(this.freeFraction,
      {this.isOut = false, this.unknown = false});
  final double freeFraction; // 0..1 portion of the circle drawn green
  final bool   isOut;        // fully out of order → solid grey
  // Source publishes no real-time availability (Turkey's EPDK registry, OCM).
  // A green pin there would claim the plugs are free when we simply don't know,
  // so those stations get their own neutral slate colour.
  final bool   unknown;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.width / 2;
    final green  = Paint()..color = _emerald..style = PaintingStyle.fill;
    final orange = Paint()..color = Colors.orangeAccent..style = PaintingStyle.fill;

    if (isOut) {
      canvas.drawCircle(center, radius,
          Paint()..color = _outGrey..style = PaintingStyle.fill);
    } else if (unknown) {
      canvas.drawCircle(center, radius,
          Paint()..color = _unknownSlate..style = PaintingStyle.fill);
    } else if (freeFraction >= 1.0) {
      canvas.drawCircle(center, radius, green);
    } else if (freeFraction <= 0.0) {
      canvas.drawCircle(center, radius, orange);
    } else {
      // Orange base, then a green sector swept from the top (12 o'clock)
      // clockwise, proportional to the free fraction.
      canvas.drawCircle(center, radius, orange);
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        -math.pi / 2,                 // start at top
        freeFraction * 2 * math.pi,   // sweep = free fraction
        true,                         // wedge (include centre)
        green,
      );
    }

    // White ring to match the previous marker border.
    canvas.drawCircle(
      center,
      radius - 1,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.25)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_AvailabilityPainter old) =>
      old.freeFraction != freeFraction ||
      old.isOut != isOut ||
      old.unknown != unknown;
}

// ── Zoom +/- button ───────────────────────────────────────────────────────────
class _ZoomBtn extends StatelessWidget {
  const _ZoomBtn({required this.icon, required this.onTap});
  final IconData     icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 48, height: 48,
        decoration: BoxDecoration(
          color: _bgCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _bgSurface),
          boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 10, offset: Offset(0, 4))],
        ),
        child: Icon(icon, color: _textSec, size: 22),
      ),
    );
  }
}

// Shared 48×48 rounded map-control button used across the right control column.
class _MapCtrlButton extends StatelessWidget {
  const _MapCtrlButton({
    required this.icon,
    required this.iconColor,
    required this.onTap,
    this.bgColor     = _bgCard,
    this.borderColor = _bgSurface,
    this.showBadge   = false,
  });
  final IconData      icon;
  final Color         iconColor, bgColor, borderColor;
  final VoidCallback? onTap;
  final bool          showBadge;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 48, height: 48,
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: borderColor),
              boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 10, offset: Offset(0, 4))],
            ),
            child: Icon(icon, color: iconColor, size: 22),
          ),
          if (showBadge)
            Positioned(
              right: -2, top: -2,
              child: Container(
                width: 12, height: 12,
                decoration: BoxDecoration(
                  color: _emerald,
                  shape: BoxShape.circle,
                  border: Border.all(color: _bgDark, width: 2),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ── "Last verified" formatting ────────────────────────────────────────────────
// Providers publish their last server check as "YYYY-MM-DD HH:MM UTC". Convert
// that to Georgia local time (UTC+4, no DST) and render as "08 Jun, 18:10".
// Any other value (e.g. "Just now") is passed through unchanged.
String _formatVerified(String raw) {
  final m = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})\s+(\d{2}):(\d{2})\s*UTC$',
    caseSensitive: false,
  ).firstMatch(raw.trim());
  if (m == null) { return raw; }
  final utc = DateTime.utc(
    int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!),
    int.parse(m[4]!), int.parse(m[5]!),
  );
  final local = utc.add(const Duration(hours: 4)); // Georgia = UTC+4
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final dd = local.day.toString().padLeft(2, '0');
  final hh = local.hour.toString().padLeft(2, '0');
  final mm = local.minute.toString().padLeft(2, '0');
  return '$dd ${months[local.month - 1]}, $hh:$mm';
}

// ── Station popup bottom sheet ────────────────────────────────────────────────
class _StationSheet extends StatefulWidget {
  const _StationSheet({
    required this.station,
    required this.onGetDirections,
    required this.onRefresh,
    required this.liveStation,
  });
  final Station      station;
  final VoidCallback onGetDirections;
  // Re-reads live data for this station AND says whether anything actually
  // moved. Supplied by _MapScreenState, which reads the operator's own API
  // directly where one is available and falls back to the feed otherwise.
  final Future<StationRefresh> Function(Station) onRefresh;
  // This station as each background poll re-reads it, so a sheet left open
  // keeps up instead of freezing on the tap that opened it.
  final ValueListenable<Station?> liveStation;

  @override
  State<_StationSheet> createState() => _StationSheetState();
}

class _StationSheetState extends State<_StationSheet> {
  late Station _station = widget.station; // mutable copy, swapped in on refresh
  bool _refreshing = false;
  // What the last manual refresh achieved, driving the label beside the button.
  // Null until the user taps it.
  RefreshOutcome? _lastOutcome;
  // When the user last refreshed by hand. A manual refresh may have come
  // straight from the operator, which is newer than anything a background poll
  // of the feed can carry, so those are ignored for a while afterwards.
  DateTime _lastManualRefresh = DateTime.fromMillisecondsSinceEpoch(0);
  static const _kManualHold = Duration(minutes: 2);
  // Whether what is on screen came straight from the operator rather than the
  // feed. Drives the caption under the timestamp, which must not claim a
  // one-second-old reading is "not real-time".
  bool _readDirect = false;
  // Composite alert keys ("id" or "id|connector") currently mid-toggle, so each
  // button shows its own spinner without blocking the others.
  final Set<String> _alertPending = {};

  // Station-level "Notify me!" button — only for providers WITHOUT per-plug
  // data (OCM/International, etc.). Providers that publish ports get a per-
  // connector button on each busy row instead. Needs a stable id and a fully
  // occupied station (no free plug to grab right now).
  bool get _canAlert => _station.id.isNotEmpty &&
      _station.ports.isEmpty && _station.available == 0;
  bool get _alertOn  => NotificationService.I.isSubscribed(_station.id);

  // True if a user is signed in. Auth state can be spuriously null for a moment
  // right after launch while the session restores, so wait out a short, bounded
  // window before concluding signed-out (same guard as _openProfile).
  Future<bool> _hasSession() async =>
      await AuthService.restoreSession() != null;

  // Arm / cancel a "notify me when it frees up" alert. [connector] scopes it to
  // one plug type (from a per-connector button); empty = whole-station alert.
  Future<void> _toggleAlert({String connector = ''}) async {
    final svc = NotificationService.I;
    final key = connector.isEmpty ? _station.id : '${_station.id}|$connector';
    if (_alertPending.contains(key)) { return; }

    // Already watching → cancel (no ad, no popup).
    if (svc.isSubscribed(_station.id, connector)) {
      setState(() => _alertPending.add(key));
      await svc.unsubscribe(key);
      if (!mounted) { return; }
      setState(() => _alertPending.remove(key));
      _showNotice(AppStrings.alertCancelled);
      return;
    }

    // Arming a new alert requires an account. Don't yank the user to a Login
    // screen — just tell them, inline in the sheet, to sign in first.
    setState(() => _alertPending.add(key));
    final loggedIn = await _hasSession();
    if (!mounted) { return; }
    if (!loggedIn) {
      setState(() => _alertPending.remove(key));
      _showNotice(AppStrings.alertLoginRequired);
      return;
    }
    final res = await svc.subscribe(
      stationId:   _station.id,
      stationName: _station.name,
      provider:    _station.provider,
      connector:   connector,
    );
    if (!mounted) { return; }
    setState(() => _alertPending.remove(key));

    switch (res) {
      case AlertResult.ok:
        // Confirmation popup, then — per spec — a full-screen ad on close
        // (free tier only; premium never sees one).
        await showChargerAlertPopup(context);
        if (!PurchaseService.I.isPremium.value) {
          AdService.I.maybeShowInterstitial();
        }
        break;
      case AlertResult.limitReached:
        _showNotice(AppStrings.alertLimitReached);
        break;
      case AlertResult.permissionDenied:
        _showNotice(AppStrings.alertPermissionDenied);
        break;
      case AlertResult.pushUnavailable:
        _showNotice(AppStrings.alertPushUnavailable);
        break;
      case AlertResult.error:
        _showNotice(AppStrings.alertError);
        break;
    }
  }

  @override
  void initState() {
    super.initState();
    widget.liveStation.addListener(_onFeedTick);
  }

  // A background poll re-read this station. Adopt it, unless the user has just
  // pulled a reading themselves that the feed cannot beat.
  void _onFeedTick() {
    final s = widget.liveStation.value;
    if (s == null || s.id != _station.id || !mounted) { return; }
    if (DateTime.now().difference(_lastManualRefresh) < _kManualHold) { return; }
    if (sameLiveState(s, _station) && s.lastUpdated == _station.lastUpdated) {
      return;
    }
    // A background poll is feed data by definition.
    setState(() { _station = s; _readDirect = false; });
  }

  // Inline, always-legible feedback shown INSIDE the sheet (a SnackBar from the
  // app-level messenger renders behind this modal sheet, so it's unreadable).
  // Auto-clears after a few seconds.
  String? _alertNotice;
  Timer?  _noticeTimer;
  void _showNotice(String msg) {
    if (!mounted) { return; }
    setState(() => _alertNotice = msg);
    _noticeTimer?.cancel();
    _noticeTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) { setState(() => _alertNotice = null); }
    });
  }

  @override
  void dispose() {
    widget.liveStation.removeListener(_onFeedTick);
    _noticeTimer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_refreshing) { return; }
    setState(() {
      _refreshing  = true;
      _lastOutcome = null;
    });
    final res = await widget.onRefresh(_station);
    if (!mounted) { return; }
    _lastManualRefresh = DateTime.now();
    setState(() {
      _refreshing  = false;
      _lastOutcome = res.outcome;
      // Present on every outcome except a failure, and never worse than what is
      // already on screen.
      if (res.station != null) {
        _station    = res.station!;
        _readDirect = res.direct;
      }
    });

    // Free tier sees an interstitial for a refresh, but only AFTER the answer is
    // on screen. An ad thrown up over the number the user just asked for is the
    // "unexpected interstitial" pattern AdMob's policies are written about, and
    // it would waste the whole point of making this button fast. AdService keeps
    // a single two-minute gap across every placement in the app, so holding the
    // button down cannot farm ads out of it.
    if (res.outcome == RefreshOutcome.failed) { return; }
    Future.delayed(const Duration(milliseconds: 1400), () {
      if (!mounted) { return; }
      if (!PurchaseService.I.isPremium.value) {
        AdService.I.maybeShowInterstitial();
      }
    });
  }

  // Colour shared by the refresh icon and its label: green only when something
  // genuinely changed, neutral for "nothing to report", amber for a failure.
  Color get _outcomeColor => switch (_lastOutcome) {
        RefreshOutcome.updated   => _emerald,
        RefreshOutcome.failed    => Colors.orangeAccent,
        RefreshOutcome.unchanged => _textSec,
        null                     => _textSec,
      };

  // One large, colour-coded row per physical connector: green = free, red =
  // busy, grey = out of order, slate = the operator publishes nothing for this
  // plug. A busy plug also shows roughly how long it has been charging so the
  // user can guess whether it'll free up soon.
  Widget _portRow(ConnectorPort p) {
    final Color color = p.isFree
        ? _emerald
        : p.isBusy
            ? Colors.redAccent
            : (p.isUnknown ? _unknownSlate : _textSec);
    final String label = p.isFree
        ? AppStrings.portFree
        : p.isBusy
            ? AppStrings.portBusy
            : (p.isUnknown ? AppStrings.portUnknown : AppStrings.portOut);
    final IconData icon = p.isFree
        ? Icons.check_circle_rounded
        : p.isBusy
            ? Icons.bolt_rounded
            : (p.isUnknown ? Icons.help_outline_rounded : Icons.block_rounded);
    String? sub;
    if (p.isBusy && p.since != null) {
      final mins = DateTime.now().toUtc().difference(p.since!.toUtc()).inMinutes;
      if (mins >= 0) { sub = AppStrings.chargingFor(mins); }
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        decoration: BoxDecoration(
          color: color.withOpacity(0.12),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withOpacity(0.45)),
        ),
        child: Row(children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${p.type} — $label',
                  style: AppStrings.font(TextStyle(
                      color: color, fontSize: 15, fontWeight: FontWeight.w700)),
                ),
                if (sub != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      sub,
                      style: AppStrings.font(TextStyle(
                          color: color.withOpacity(0.85), fontSize: 12)),
                    ),
                  ),
              ],
            ),
          ),
          // Per-plug price (providers like Tegeta price each connector
          // differently — DC fast vs AC socket). Empty when not published.
          if (p.price.isNotEmpty) ...[
            const SizedBox(width: 8),
            Text(
              p.price,
              style: AppStrings.font(TextStyle(
                  color: color, fontSize: 13, fontWeight: FontWeight.w600)),
            ),
          ],
          // Per-connector "notify me when THIS plug frees up". Only on a busy
          // plug (a free one needs no alert) and only when the station has a
          // stable id to match against server-side. Matches by connector type,
          // so a station with two CCS2 fires when either frees.
          if (p.isBusy && _station.id.isNotEmpty) ...[
            const SizedBox(width: 8),
            _PortNotifyButton(
              on:   NotificationService.I.isSubscribed(_station.id, p.type),
              busy: _alertPending.contains('${_station.id}|${p.type}'),
              onTap: () => _toggleAlert(connector: p.type),
            ),
          ],
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = _station;
    final avail = s.available > 0;
    // Registry sources (Turkey/EPDK, OCM) publish how many plugs EXIST, not how
    // many are free. Reporting those as "available" would invent live data, so
    // they get a neutral plug count and a neutral dot instead.
    final statusColor = !s.live
        ? _textSec
        : (avail ? _emerald : Colors.orangeAccent);

    return SafeArea(
      top: false,
      child: Container(
      decoration: const BoxDecoration(
        color: _bgCard,
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      padding: EdgeInsets.fromLTRB(
        20, 10, 20,
        20 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Drag handle
          Center(
            child: Container(
              width: 40, height: 4,
              decoration: BoxDecoration(
                color: _bgSurface, borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Station name
          Text(
            s.name,
            style: const TextStyle(color: _textPri, fontSize: 17,
                fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 14),

          // Power + city + provider + connector chips
          Wrap(spacing: 8, runSpacing: 8, children: [
            _InfoChip(
              icon:  s.isDC ? Icons.bolt : Icons.power_rounded,
              // Some providers (e.g. Tegeta) don't publish a kW rating; show the
              // connector-derived charge type alone instead of a bogus "0 kW".
              label: s.kw > 0
                  ? '${s.kw} kW · ${s.isDC ? 'Fast DC' : 'AC'}'
                  : (s.isDC ? 'Fast DC' : 'AC'),
              color: s.isDC ? _emerald : Colors.blueAccent,
            ),
            _InfoChip(
              icon:  Icons.location_on_outlined,
              label: s.location,
              color: _textSec,
            ),
            _InfoChip(
              icon:  Icons.sell_outlined,
              label: s.price,
              color: _textSec,
            ),
            if (s.provider.isNotEmpty)
              _InfoChip(
                icon:  Icons.ev_station_rounded,
                label: s.provider,
                color: _emerald,
              ),
            // Plain connector chips only when there's no per-plug status data
            // (the live status block below replaces them when available).
            if (s.ports.isEmpty)
              ...sortConnectors(s.connectors).map((c) => _InfoChip(
                icon:  Icons.power_outlined,
                label: c,
                color: Colors.blueAccent,
              )),
          ]),
          // Where the price came from, when it isn't a live per-station rate.
          // Turkish stations carry their operator's published tariff, so say so
          // rather than letting it read as this charger's exact quoted price.
          if (s.priceNote.isNotEmpty) ...[
            const SizedBox(height: 8),
            Row(children: [
              const Icon(Icons.info_outline_rounded, color: _textSec, size: 13),
              const SizedBox(width: 5),
              Flexible(
                child: Text(s.priceNote,
                    style: const TextStyle(color: _textSec, fontSize: 11)),
              ),
            ]),
          ],
          const SizedBox(height: 16),

          // Last-updated timestamp, with the provider's logo to its right.
          if (s.lastUpdated.isNotEmpty) ...[
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        const Icon(Icons.history_rounded, color: _textSec, size: 13),
                        const SizedBox(width: 5),
                        Flexible(
                          child: Text(
                            'Last verified: ${_formatVerified(s.lastUpdated)}',
                            style: const TextStyle(color: _textSec, fontSize: 11),
                          ),
                        ),
                      ]),
                      Padding(
                        padding: const EdgeInsets.only(left: 18, top: 2),
                        child: Text(
                          _readDirect
                              ? AppStrings.liveFromProvider
                              : AppStrings.providerLastCheck,
                          style: AppStrings.font(TextStyle(
                              color: _readDirect ? _emerald : _textSec,
                              fontSize: 9.5)),
                        ),
                      ),
                    ],
                  ),
                ),
                // Provider logo (white tile so it reads on the dark sheet).
                if (providerLogoAsset(s.provider) != null) ...[
                  const SizedBox(width: 12),
                  ProviderLogo(provider: s.provider, height: 56),
                ],
              ],
            ),
          ] else if (providerLogoAsset(s.provider) != null) ...[
            // No timestamp to anchor beside — still show the logo, right-aligned.
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerRight,
              child: ProviderLogo(provider: s.provider, height: 56),
            ),
          ],
          const SizedBox(height: 10),

          // Availability row + refresh button
          Row(children: [
            Container(
              width: 9, height: 9,
              decoration: BoxDecoration(color: statusColor, shape: BoxShape.circle),
            ),
            const SizedBox(width: 8),
            Text(
              !s.live
                  ? (s.total > 0
                      ? '${s.total} plug${s.total == 1 ? '' : 's'} · live status not published'
                      : 'Live status not published')
                  : !avail
                      ? (s.total > 0
                          ? '0 of ${s.total} plugs available'
                          : 'No connectors available')
                      : (s.total > s.available
                          ? '${s.available} of ${s.total} plugs available'
                          : '${s.available} plug${s.available == 1 ? '' : 's'} available'),
              style: TextStyle(
                color: statusColor, fontSize: 14, fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 10),
            GestureDetector(
              onTap: _refreshing ? null : _refresh,
              child: _refreshing
                  ? const SizedBox(
                      width: 17, height: 17,
                      child: CircularProgressIndicator(strokeWidth: 2, color: _textSec),
                    )
                  : Icon(Icons.refresh_rounded,
                      color: _outcomeColor, size: 19),
            ),
            // Says what actually happened. This used to read "Updated" after any
            // request that did not error, including the many that came back
            // byte-identical — so a status frozen ten minutes in the past looked
            // like a refresh button doing its job.
            if (_lastOutcome != null) ...[
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  switch (_lastOutcome!) {
                    RefreshOutcome.updated   => AppStrings.refreshUpdated,
                    RefreshOutcome.unchanged => AppStrings.refreshNoChange,
                    RefreshOutcome.failed    => AppStrings.refreshFailed,
                  },
                  style: AppStrings.font(
                      TextStyle(color: _outcomeColor, fontSize: 11)),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ]),

          // ── Per-connector live status ─────────────────────────────────────
          // Colours each plug green (free) / red (busy) / grey (out of order)
          // so it's obvious which connector is taken, with an approximate
          // "charging for ~N" under a busy one. Shown only when the feed carries
          // per-plug data (AMPECO providers); others fall back to the chips above.
          if (s.ports.isNotEmpty) ...[
            const SizedBox(height: 18),
            Text(
              AppStrings.connectorsTitle,
              style: AppStrings.font(const TextStyle(
                  color: _textSec, fontSize: 12, fontWeight: FontWeight.w600)),
            ),
            const SizedBox(height: 10),
            ...s.ports.map(_portRow),
          ],
          const SizedBox(height: 22),

          // ── "Notify me!" — only when the station is fully occupied ──────────
          // Arms a push alert that fires when a plug frees up. Toggles to an
          // "alert is on" state that cancels it on a second tap.
          if (_canAlert) ...[
            _NotifyButton(
              on:      _alertOn,
              busy:    _alertPending.contains(_station.id),
              onTap:   () => _toggleAlert(),
            ),
            const SizedBox(height: 10),
          ],

          // Inline alert feedback (sign-in required, cancelled, limit, …). Shown
          // in the sheet itself so it's always legible — a SnackBar would render
          // behind this modal sheet.
          if (_alertNotice != null) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              margin: const EdgeInsets.only(bottom: 10),
              decoration: BoxDecoration(
                color: _emerald.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: _emerald.withValues(alpha: 0.45)),
              ),
              child: Row(children: [
                const Icon(Icons.info_outline_rounded, color: _emerald, size: 18),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _alertNotice!,
                    style: AppStrings.font(const TextStyle(
                        color: _textPri, fontSize: 13, height: 1.35,
                        fontWeight: FontWeight.w600)),
                  ),
                ),
              ]),
            ),
          ],

          // Get Directions button
          GestureDetector(
            onTap: widget.onGetDirections,
            child: Container(
              width: double.infinity,
              height: 52,
              decoration: BoxDecoration(
                color: _emerald, borderRadius: BorderRadius.circular(14),
              ),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.alt_route_rounded, color: Colors.black, size: 20),
                  SizedBox(width: 8),
                  Text('Get Directions',
                      style: TextStyle(color: Colors.black, fontSize: 15,
                          fontWeight: FontWeight.w700)),
                ],
              ),
            ),
          ),
        ],
      ),
    ), // SafeArea
    );
  }
}

// ── "Notify me!" button (station sheet) ───────────────────────────────────────
// Filled emerald when off (a clear call-to-action); outlined + bell-check when
// the alert is already armed (tap again to cancel). Shows a spinner while a
// subscribe/unsubscribe round-trip is in flight.
class _NotifyButton extends StatelessWidget {
  const _NotifyButton({required this.on, required this.busy, required this.onTap});
  final bool on;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Color fg = on ? _emerald : Colors.black;
    return GestureDetector(
      onTap: busy ? null : onTap,
      child: Container(
        width: double.infinity,
        height: 52,
        decoration: BoxDecoration(
          color: on ? Colors.transparent : _emerald,
          borderRadius: BorderRadius.circular(14),
          border: on ? Border.all(color: _emerald, width: 1.5) : null,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (busy)
              SizedBox(
                width: 20, height: 20,
                child: CircularProgressIndicator(strokeWidth: 2, color: fg),
              )
            else ...[
              Icon(on ? Icons.notifications_active_rounded
                      : Icons.notifications_none_rounded,
                  color: fg, size: 20),
              const SizedBox(width: 8),
              Text(
                on ? AppStrings.alertActive : AppStrings.notifyMe,
                style: AppStrings.font(TextStyle(
                    color: fg, fontSize: 15, fontWeight: FontWeight.w700)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ── Compact per-connector "notify me" button (busy port rows) ─────────────────
// Filled emerald when off; outlined emerald + active bell when armed (tap again
// to cancel). Spinner while a subscribe/unsubscribe round-trip is in flight.
class _PortNotifyButton extends StatelessWidget {
  const _PortNotifyButton(
      {required this.on, required this.busy, required this.onTap});
  final bool on;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: busy ? null : onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: on ? Colors.transparent : _emerald,
          borderRadius: BorderRadius.circular(10),
          border: on ? Border.all(color: _emerald, width: 1.4) : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (busy)
              const SizedBox(
                width: 13, height: 13,
                child: CircularProgressIndicator(strokeWidth: 2, color: _emerald),
              )
            else
              Icon(
                on ? Icons.notifications_active_rounded
                   : Icons.notifications_none_rounded,
                color: on ? _emerald : Colors.black, size: 15),
            const SizedBox(width: 5),
            Text(
              on ? AppStrings.alertOnShort : AppStrings.notifyMe,
              style: AppStrings.font(TextStyle(
                  color: on ? _emerald : Colors.black,
                  fontSize: 12, fontWeight: FontWeight.w700)),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Info chip (used inside station sheet) ─────────────────────────────────────
class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.icon, required this.label, required this.color});
  final IconData icon;
  final String   label;
  final Color    color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: _bgSurface, borderRadius: BorderRadius.circular(8),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, color: color, size: 13),
        const SizedBox(width: 5),
        Text(label, style: TextStyle(color: color, fontSize: 12,
            fontWeight: FontWeight.w500)),
      ]),
    );
  }
}
