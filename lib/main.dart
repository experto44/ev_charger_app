import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import 'firebase_options.dart';
import 'l10n/app_strings.dart';
import 'profile_screen.dart';
import 'screens/auth/login_screen.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_marker_cluster/flutter_map_marker_cluster.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:shared_preferences/shared_preferences.dart';

import 'app_constants.dart';
import 'ocm_service.dart';
import 'places_service.dart';
import 'route_planner_screen.dart';
import 'routing_service.dart';
import 'services/ad_service.dart';
import 'services/purchase_service.dart';
import 'settings_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  await AppStrings.load(); // restore saved language (English/Georgian)
  // Subscriptions first (sets isPremium from cache), then ads — the ad layer
  // reads isPremium to decide whether to load anything at all.
  await PurchaseService.I.init();
  await AdService.I.init();
  PaintingBinding.instance.imageCache.maximumSize = 30;
  PaintingBinding.instance.imageCache.maximumSizeBytes = 10 * 1024 * 1024;
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

// Approx vertical space the top banner ad occupies (AdSize.banner 50dp + the
// 10dp gap above it). Used to push the right control column down so its top
// buttons never overlap the filter chips when the ad is shown.
const double _kTopBannerHeight = 60;

// Known providers, in display order. "All selected" is the default (no filter).
// Local Georgian providers + a single "International" group for all Open Charge
// Map networks (so international chargers never clutter the local provider list).
const _kAllProviders = [
  'E-Space', 'mart EV', 'Electrify Georgia', 'EV Power GE', 'Da-Tene', 'Gadatene', 'EcoCars', 'Solar Station',
  OcmService.kProvider, // 'International'
];

// CartoDB basemaps (free, retina-capable, great coverage for Georgia).
//  • Voyager     — bright, colourful streets + labels (Light Mode, default)
//  • Dark Matter — dark theme with clear, high-contrast roads & city names
const _kTileLight = 'https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}{r}.png';
const _kTileDark  = 'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png';

// Cloud data source — always points to latest revision (no pinned commit hash)
const _kGistUrl =
    'https://gist.githubusercontent.com/experto44/36f39392ce7a4abe14ab065aa8e846bd'
    '/raw/chargers.json';

// ── Navigate to coordinates in Google Maps ────────────────────────────────────
Future<void> _navigate(double lat, double lng) async {
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
  AnimationController? _moveAnim;

  bool             _filterDC         = false;
  bool             _filterAvail      = false;
  // Multi-select provider filter. Defaults to every LOCAL provider selected;
  // "International" (OCM) is intentionally OFF at launch — the user opts in.
  final Set<String> _selectedProviders = {
    for (final p in _kAllProviders) if (p != OcmService.kProvider) p,
  };
  final Set<String> _filterConnectors = {};  // empty = no connector filter

  // International (OCM) viewport loading is on only while the user has the
  // "International" provider chip checked.
  bool get _internationalOn => _selectedProviders.contains(OcmService.kProvider);

  // Filter is "active" (badge shown) only for a proper, non-empty subset.
  // Empty set or all-selected both mean "show every provider".
  bool get _providerFilterActive =>
      _selectedProviders.isNotEmpty &&
      _selectedProviders.length != _kAllProviders.length;

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
  StreamSubscription<MapEvent>? _mapEventSub;
  int           _ocmGen = 0;   // guards against stale / superseded responses
  bool          _centerInGeorgia = true; // carousel only shows over Georgia

  // Periodic background refresh of the station feed. The Gist itself is updated
  // server-side, so the app must re-poll to surface new availability while it
  // stays open — otherwise data is frozen at whatever was fetched on launch.
  Timer? _refreshTimer;
  static const _kRefreshInterval = Duration(minutes: 3);

  @override
  void initState() {
    super.initState();
    // Observe app lifecycle so we can refresh the GPS fix on resume — the
    // device may have moved while the app was backgrounded.
    WidgetsBinding.instance.addObserver(this);
    _loadPrefs();
    // Station data can load independently of the map controller.
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadStations());
    // Re-poll the live feed every few minutes so availability stays current
    // without requiring an app restart. Uses the non-clobbering refresh so a
    // transient network failure never wipes the stations already on screen.
    _refreshTimer = Timer.periodic(_kRefreshInterval, (_) => _refreshStations());
    // _locateMe() is called from MapOptions.onMapReady, which fires only
    // after FlutterMap has mounted and the MapController is fully attached.
  }

  // Apply the profile's default connector + the saved country selection. The
  // connector default seeds the active map filter each launch; manual changes
  // on the map are session-only and reset to this on next launch.
  Future<void> _loadPrefs() async {
    final p = await SharedPreferences.getInstance();
    final defConn  = p.getString(kDefaultConnector);
    final rawCntry = p.getString(kActiveCountries);
    if (!mounted) { return; }
    setState(() {
      _filterConnectors
        ..clear()
        ..addAll(defConn != null && defConn.isNotEmpty ? [defConn] : const []);
      if (rawCntry != null) {
        try {
          _activeCountries =
              (jsonDecode(rawCntry) as List).map((e) => e as String).toSet();
        } catch (_) {/* keep default */}
      }
    });
    // OCM loads viewport-first; the map's onMapReady kicks off the initial load.
  }

  // Re-read the saved country selection after returning from Settings, then
  // refresh the live OCM data for the current viewport under the new selection.
  Future<void> _reloadCountries() async {
    final p   = await SharedPreferences.getInstance();
    final raw = p.getString(kActiveCountries);
    if (!mounted) { return; }
    setState(() {
      _activeCountries = raw == null
          ? {'Georgia'}
          : (jsonDecode(raw) as List).map((e) => e as String).toSet();
    });
    _loadOcmCountries();
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
      if (mounted && (_ocmStations.isNotEmpty || _ocmLoading)) {
        setState(() { _ocmStations = const []; _ocmLoading = false; });
      }
      return;
    }
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

  // Fetch the live Gist and merge in any bundled-only providers as a supplement.
  // Returns null on any network/parse failure so callers can decide whether to
  // fall back (initial load) or keep existing data (background refresh).
  Future<List<Station>?> _fetchLiveStations() async {
    final assetStations = await _loadBundled();
    try {
      final res = await http
          .get(Uri.parse(_kGistUrl))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final live = _parseStations(res.body);
        final liveProviders = live.map((s) => s.provider).toSet();
        final supplement = assetStations
            .where((s) => !liveProviders.contains(s.provider))
            .toList();
        return [...live, ...supplement];
      }
    } catch (_) {
      // Network unavailable, timeout, or parse error.
    }
    return null;
  }

  // Initial load: show live data, or fall back to the bundled asset offline.
  Future<void> _loadStations() async {
    final fresh = await _fetchLiveStations();
    if (!mounted) { return; }
    if (fresh != null) {
      setState(() { _stations = fresh; _loading = false; });
    } else {
      // Offline / first launch with no network — bundled snapshot only.
      final bundled = await _loadBundled();
      if (!mounted) { return; }
      setState(() { _stations = bundled; _loading = false; });
    }
  }

  // Background / on-demand refresh. Re-fetches live data and swaps it in.
  // Crucially, on failure it KEEPS the existing data (never clobbers good live
  // stations with a stale bundled snapshot on a transient blip). Returns the
  // fresh list on success, or null if the fetch failed.
  Future<List<Station>?> _refreshStations() async {
    final fresh = await _fetchLiveStations();
    if (fresh == null || !mounted) { return null; }
    setState(() => _stations = fresh);
    return fresh;
  }

  // Re-fetch and return the latest data for a single station (matched by stable
  // id, falling back to coordinates for any legacy row without an id). Powers
  // the station sheet's manual Refresh button. Returns null if the refresh
  // failed or the station is no longer present in the feed.
  Future<Station?> _refreshStation(Station target) async {
    final fresh = await _refreshStations();
    if (fresh == null) { return null; }
    for (final s in fresh) {
      final sameId = target.id.isNotEmpty && s.id == target.id;
      final sameCoords = target.id.isEmpty &&
          s.lat == target.lat && s.lng == target.lng;
      if (sameId || sameCoords) { return s; }
    }
    return null;
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
  Future<void> _locateMe({bool recenter = false, bool animate = false}) async {
    try {
      LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) { return; }

      void center(LatLng p) {
        if (!recenter) { return; }
        if (animate) { _animatedMove(p, 14); } else { _mapCtrl.move(p, 14); }
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
    _mapEventSub?.cancel();
    _refreshTimer?.cancel();
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
          all:      _kAllProviders,
          selected: _selectedProviders,
          onToggle: (p) {
            setState(() {
              if (_selectedProviders.contains(p)) {
                _selectedProviders.remove(p);
              } else {
                _selectedProviders.add(p);
              }
            });
            setSheet(() {});
            // Toggling "International" loads/clears the OCM stations for the
            // user's selected countries.
            if (p == OcmService.kProvider) { _loadOcmCountries(); }
          },
        ),
      ),
    );
  }

  // ── Station marker tap → bottom sheet ────────────────────────────────────
  void _showStationSheet(Station s) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _StationSheet(
        station: s,
        onGetDirections: () => _openRoutePlannerTo(s),
        onRefresh: _refreshStation,
      ),
    );
  }

  // Shared push — no sheet-pop side-effect (used by carousel "Plan & Go").
  Future<void> _pushRoutePlannerTo(Station destination) async {
    AdService.I.maybeShowInterstitial(); // free-tier only; no-op for premium
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => RoutePlannerScreen(
          stations:           _stations,
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
      final r = await PlacesService.autocomplete(query);
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

  // Local Gist stations + live OCM international stations.
  List<Station> get _allStations =>
      _ocmStations.isEmpty ? _stations : [..._stations, ..._ocmStations];

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
      if (_selectedProviders.isNotEmpty &&
          !_selectedProviders.contains(s.provider)) { return false; }
      if (_filterDC    && !s.isDC)          { return false; }
      if (_filterAvail && s.available == 0) { return false; }
      // Connector filter — case-insensitive match so label/data casing never
      // hides a station (e.g. "CCS2" vs "ccs2").
      if (_filterConnectors.isNotEmpty &&
          !s.connectors.any((c) => _filterConnectors
              .any((f) => f.toLowerCase() == c.toLowerCase()))) { return false; }
      return true;
    }).toList();
  }

  // Connector types actually present in the loaded data (local + OCM) — used to
  // build the filter chips so we never show a dead chip and any new connector
  // type (incl. international ones) appears automatically.
  Set<String> get _availableConnectors {
    final out = <String>{};
    for (final s in _allStations) { out.addAll(s.connectors); }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final stations = _filtered;
    // The bottom carousel lists LOCAL Georgian stations, so it only makes sense
    // while the map is centred on Georgia. Panning to an international view hides
    // it entirely (the international pins live on the map, not the carousel).
    final localStations = _centerInGeorgia
        ? stations.where((s) => s.provider != OcmService.kProvider).toList()
        : const <Station>[];
    // Lift the right control column above the bottom carousel so the GPS
    // button is never hidden. The carousel is taller when station cards are
    // shown than when it's loading / empty, so adjust dynamically.
    final navBottom        = MediaQuery.of(context).padding.bottom;
    final carouselVisible  = !_loading && _centerInGeorgia && localStations.isNotEmpty;
    final controlsBottom   = (carouselVisible ? 300.0 : 130.0) + navBottom;
    // Bound the right control column below the search-bar/chips block (plus the
    // top banner ad when it's shown) so its top buttons never overlap the chips.
    // The column stays bottom-anchored and scrolls if vertical space is tight.
    final topAdShown       = AdService.I.topBanner() != null;
    final topControlsBound = MediaQuery.of(context).padding.top +
        140 + (topAdShown ? _kTopBannerHeight : 0);
    return Scaffold(
      // Free-tier banner — rebuilds (and disappears) when premium is granted.
      // Returns an empty box when premium or no ad unit is configured.
      bottomNavigationBar: ValueListenableBuilder<bool>(
        valueListenable: PurchaseService.I.isPremium,
        builder: (_, __, ___) =>
            AdService.I.bottomBanner() ?? const SizedBox.shrink(),
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
                });
                _locateMe(recenter: true);
                _loadOcmCountries();
              },
            ),
            children: [
              // CartoDB basemap — Voyager (light) or Dark Matter (dark).
              // retinaMode pulls @2x tiles on high-DPI screens so streets and
              // city names stay crisp and easy to read.
              TileLayer(
                key: ValueKey(_darkMap),
                urlTemplate: _darkMap ? _kTileDark : _kTileLight,
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
                      ),
                    ),
                  )).toList(),
                  // Cluster bubble — themed teal circle with the station count.
                  builder: (context, markers) => Container(
                    decoration: BoxDecoration(
                      color: _emerald,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white.withOpacity(0.4), width: 2),
                      boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 6)],
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      '${markers.length}',
                      style: const TextStyle(
                        color: Colors.black, fontWeight: FontWeight.bold, fontSize: 15),
                    ),
                  ),
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
                    onSettings: () async {
                      await Navigator.push<void>(
                        context,
                        MaterialPageRoute(builder: (_) => const SettingsScreen()),
                      );
                      await _reloadCountries(); // apply country changes immediately
                    },
                  ),
                  if (_suggestions.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    _SuggestionsList(suggestions: _suggestions, onTap: _onSuggestionSelected),
                  ],
                  // Free-tier top banner, just below the search bar. Hidden for
                  // premium users (and before the SDK loads); rebuilds when
                  // premium changes, mirroring the bottom banner.
                  ValueListenableBuilder<bool>(
                    valueListenable: PurchaseService.I.isPremium,
                    builder: (_, __, ___) {
                      final banner = AdService.I.topBanner();
                      return banner == null
                          ? const SizedBox.shrink()
                          : Padding(
                              padding: const EdgeInsets.only(top: 10),
                              child: banner,
                            );
                    },
                  ),
                  const SizedBox(height: 10),
                  _FilterChips(
                    filterDC:         _filterDC,
                    filterAvail:      _filterAvail,
                    onDC:             (v) => setState(() => _filterDC    = v),
                    onAvail:          (v) => setState(() => _filterAvail = v),
                    availableConnectors: _availableConnectors,
                    filterConnectors: _filterConnectors,
                    onConnector:      (ct) => setState(() {
                      if (_filterConnectors.contains(ct)) {
                        _filterConnectors.remove(ct);
                      } else {
                        _filterConnectors.add(ct);
                      }
                    }),
                  ),
                  // Live OCM fetch indicator (international countries).
                  if (_ocmLoading) ...[
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
                        child: const Row(mainAxisSize: MainAxisSize.min, children: [
                          SizedBox(
                            width: 13, height: 13,
                            child: CircularProgressIndicator(strokeWidth: 2, color: _emerald),
                          ),
                          SizedBox(width: 8),
                          Text('Loading international stations…',
                              style: TextStyle(color: _textSec, fontSize: 12)),
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
              child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Map style toggle (Light ↔ Dark)
                _MapCtrlButton(
                  onTap: () => setState(() => _darkMap = !_darkMap),
                  icon:  _darkMap ? Icons.dark_mode_rounded : Icons.light_mode_rounded,
                  iconColor: _darkMap ? _textPri : Colors.amber,
                ),
                const SizedBox(height: 8),
                // Provider filter (badge also lights when country filtering is on)
                _MapCtrlButton(
                  onTap: _openProviderFilter,
                  icon:  Icons.layers_rounded,
                  iconColor:   _providerFilterActive ? _emerald : _textSec,
                  borderColor: _providerFilterActive ? _emerald : _bgSurface,
                  showBadge:   _providerFilterActive || _countryFilterActive,
                ),
                const SizedBox(height: 8),
                // Zoom in / out
                _ZoomBtn(icon: Icons.add_rounded,    onTap: () => _zoom(1)),
                const SizedBox(height: 8),
                _ZoomBtn(icon: Icons.remove_rounded, onTap: () => _zoom(-1)),
                const SizedBox(height: 8),
                // Route planner
                _MapCtrlButton(
                  onTap: () {
                    AdService.I.maybeShowInterstitial(); // free-tier only
                    Navigator.push<void>(
                      context,
                      MaterialPageRoute(
                        builder: (_) => RoutePlannerScreen(stations: _stations),
                      ),
                    );
                  },
                  icon: Icons.alt_route_rounded,
                  iconColor: _textSec,
                ),
                const SizedBox(height: 8),
                // Recenter GPS
                _MapCtrlButton(
                  onTap: () => _locateMe(recenter: true, animate: true),
                  icon: Icons.my_location_rounded,
                  iconColor:   _userPos == null ? _textSec : _emerald,
                  borderColor: _userPos == null ? _bgSurface : _emerald,
                  bgColor:     _userPos == null ? _bgSurface : _bgCard,
                ),
              ],
              ),
            ),
          ),

          // ── Bottom panel: local station carousel ──────────────────────────
          // Only shown while loading or while centred on Georgia with local
          // stations to list — hidden entirely on international/away views.
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
            )
          else if (carouselVisible)
            Positioned(
              left: 0, right: 0, bottom: 0,
              child: _StationCarousel(
                stations:    localStations,
                onPlanAndGo: _pushRoutePlannerTo,
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
    required this.onSettings,
  });
  final TextEditingController controller;
  final FocusNode             focusNode;
  final ValueChanged<String>  onChanged;
  final VoidCallback          onSettings;

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
          _IconBtn(
            icon:  Icons.settings_outlined,
            onTap: onSettings,
          ),
          const SizedBox(width: 8),
          _IconBtn(
            icon:  Icons.account_circle_outlined,
            onTap: () {
              final user = FirebaseAuth.instance.currentUser;
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => user == null
                      ? const LoginScreen()
                      : const ProfileScreen(),
                ),
              );
            },
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
    required this.onDC,
    required this.onAvail,
    required this.availableConnectors,
    required this.filterConnectors,
    required this.onConnector,
  });
  final bool              filterDC, filterAvail;
  final ValueChanged<bool> onDC, onAvail;
  final Set<String>        availableConnectors;  // present in loaded data
  final Set<String>        filterConnectors;
  final ValueChanged<String> onConnector;

  // Canonical connector types in the shared display order (kConnectorOrder).
  // Only those actually present in the loaded data are shown, so there's never
  // a dead chip; new types appear automatically.
  static const _kConnectors = kConnectorOrder;

  @override
  Widget build(BuildContext context) {
    // Data-driven (canonical order): show a connector chip when data is still
    // loading, when it's present in the loaded data, OR when it's the active
    // filter (so a default connector with no matches is still toggle-able and
    // never strands the user on an empty map with no chip to clear).
    final conns = _kConnectors
        .where((c) =>
            availableConnectors.isEmpty ||
            filterConnectors.contains(c) ||
            availableConnectors.any((a) => a.toLowerCase() == c.toLowerCase()))
        .toList();
    return SizedBox(
      height: 36,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          _Chip(icon: Icons.bolt, label: 'Fast DC',
              active: filterDC, onTap: () => onDC(!filterDC)),
          const SizedBox(width: 8),
          _Chip(icon: Icons.check_circle_outline, label: 'Available',
              active: filterAvail, onTap: () => onAvail(!filterAvail)),
          // Connector-type chips — multi-select, data-driven
          ...conns.map((ct) => Padding(
            padding: const EdgeInsets.only(left: 8),
            child: _Chip(
              label:  ct,
              active: filterConnectors.contains(ct),
              onTap:  () => onConnector(ct),
            ),
          )),
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
  });
  final List<String>       all;
  final Set<String>        selected;
  final ValueChanged<String> onToggle;

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
                      // One checkbox row per known provider — toggles apply immediately.
                      ...all.map((p) {
                        final on = selected.contains(p);
                        return InkWell(
                          onTap: () => onToggle(p),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
                            child: Row(children: [
                              Icon(
                                on ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded,
                                color: on ? _emerald : _textSec, size: 24,
                              ),
                              const SizedBox(width: 12),
                              Text(p,
                                  style: const TextStyle(
                                      color: _textPri, fontSize: 15, fontWeight: FontWeight.w500)),
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

// ── Station carousel ──────────────────────────────────────────────────────────
class _StationCarousel extends StatelessWidget {
  const _StationCarousel({
    required this.stations,
    this.onPlanAndGo,
  });
  final List<Station>           stations;
  final void Function(Station)? onPlanAndGo;

  @override
  Widget build(BuildContext context) {
    if (stations.isEmpty) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 28),
        alignment: Alignment.center,
        child: const Text('No stations match your filters',
            style: TextStyle(color: _textSec, fontSize: 13)),
      );
    }
    // Extra bottom inset so "Plan & Go" clears the Android gesture / button nav bar.
    final navBarHeight = MediaQuery.of(context).padding.bottom;
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end:   Alignment.topCenter,
          colors: [_bgDark, Colors.transparent],
          stops:  [0.6, 1.0],
        ),
      ),
      padding: EdgeInsets.only(top: 32, bottom: 24 + navBarHeight),
      child: SizedBox(
        height: 264, // taller for stacked Navigate + Plan & Go buttons (+ provider line); +10 to clear a 9px bottom overflow
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: stations.length,
          separatorBuilder: (_, __) => const SizedBox(width: 12),
          itemBuilder: (_, i) => _StationCard(
            stations[i],
            onPlanAndGo: onPlanAndGo != null
                ? () => onPlanAndGo!(stations[i])
                : null,
          ),
        ),
      ),
    );
  }
}

// ── Station card ──────────────────────────────────────────────────────────────
class _StationCard extends StatelessWidget {
  const _StationCard(this.s, {this.onPlanAndGo});
  final Station      s;
  final VoidCallback? onPlanAndGo;

  Color get _statusColor {
    if (s.available == 0) { return _textSec; }
    if (s.available == 1) { return Colors.orangeAccent; }
    return _emerald;
  }

  @override
  Widget build(BuildContext context) {
    final avail = s.available > 0;
    return Container(
      width: 170,
      padding: const EdgeInsets.all(14),
      clipBehavior: Clip.hardEdge,
      decoration: BoxDecoration(
        color: _bgCard,
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 10, offset: Offset(0, 4))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Container(width: 8, height: 8,
                decoration: BoxDecoration(color: _statusColor, shape: BoxShape.circle)),
            const SizedBox(width: 6),
            Text(
              avail
                  ? (s.total > s.available
                      ? '${s.available} of ${s.total} available'
                      : '${s.available} available')
                  : 'Unavailable',
              style: TextStyle(color: _statusColor, fontSize: 11, fontWeight: FontWeight.w600),
            ),
          ]),
          const SizedBox(height: 6),
          Text(s.name,
              style: const TextStyle(color: _textPri, fontSize: 14, fontWeight: FontWeight.bold),
              maxLines: 1, overflow: TextOverflow.ellipsis),
          Text(s.location, style: const TextStyle(color: _textSec, fontSize: 12)),
          if (s.provider.isNotEmpty)
            Text(s.provider,
                style: const TextStyle(color: Color(0xFF666666), fontSize: 10),
                maxLines: 1, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 8),
          Row(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: s.isDC ? _emerald.withOpacity(0.15) : _bgSurface,
                borderRadius: BorderRadius.circular(5),
              ),
              child: Text('${s.kw} kW',
                  style: TextStyle(
                      color: s.isDC ? _emerald : _textSec,
                      fontSize: 11, fontWeight: FontWeight.w700)),
            ),
            const SizedBox(width: 6),
            Flexible(child: Text(s.price,
                style: const TextStyle(color: _textSec, fontSize: 11),
                overflow: TextOverflow.ellipsis)),
          ]),
          const Spacer(),
          Row(children: [
            if (s.distance.isNotEmpty) ...[
              const Icon(Icons.near_me_outlined, color: _textSec, size: 13),
              const SizedBox(width: 4),
              Text(s.distance, style: const TextStyle(color: _textSec, fontSize: 12)),
            ],
            const Spacer(),
            const Icon(Icons.bolt, color: _emerald, size: 16),
          ]),
          const SizedBox(height: 10),
          // ── Stacked full-width action buttons ─────────────────────────────
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Primary — Navigate (direct Google Maps launch)
              GestureDetector(
                onTap: () => _navigate(s.lat, s.lng),
                child: Container(
                  height: 34,
                  decoration: BoxDecoration(
                    color: _emerald,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.navigation_rounded, color: Colors.black, size: 14),
                      SizedBox(width: 5),
                      Text('Navigate',
                          style: TextStyle(
                              color: Colors.black, fontSize: 12,
                              fontWeight: FontWeight.w700)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              // Secondary — Plan & Go (Route Planner pre-filled)
              GestureDetector(
                onTap: onPlanAndGo,
                child: Container(
                  height: 34,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(9),
                    border: Border.all(color: _emerald, width: 1.5),
                  ),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.alt_route_rounded, color: _emerald, size: 14),
                      SizedBox(width: 5),
                      Text('Plan & Go',
                          style: TextStyle(
                              color: _emerald, fontSize: 12,
                              fontWeight: FontWeight.w700)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
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
class _AvailabilityPin extends StatelessWidget {
  const _AvailabilityPin({required this.available, required this.total});
  final int available;
  final int total;

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
        painter: _AvailabilityPainter(freeFraction),
        child: const Center(child: Icon(Icons.bolt, color: Colors.black, size: 20)),
      ),
    );
  }
}

class _AvailabilityPainter extends CustomPainter {
  const _AvailabilityPainter(this.freeFraction);
  final double freeFraction; // 0..1 portion of the circle drawn green

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.width / 2;
    final green  = Paint()..color = _emerald..style = PaintingStyle.fill;
    final orange = Paint()..color = Colors.orangeAccent..style = PaintingStyle.fill;

    if (freeFraction >= 1.0) {
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
      old.freeFraction != freeFraction;
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
  });
  final Station      station;
  final VoidCallback onGetDirections;
  // Re-fetches live data for this station; returns the updated row or null on
  // failure / removal. Supplied by _MapScreenState so the button hits the feed.
  final Future<Station?> Function(Station) onRefresh;

  @override
  State<_StationSheet> createState() => _StationSheetState();
}

class _StationSheetState extends State<_StationSheet> {
  late Station _station = widget.station; // mutable copy, swapped in on refresh
  bool _refreshing   = false;
  bool _justRefreshed = false;
  bool _refreshFailed = false;

  Future<void> _refresh() async {
    if (_refreshing) { return; }
    setState(() {
      _refreshing    = true;
      _justRefreshed = false;
      _refreshFailed = false;
    });
    final updated = await widget.onRefresh(_station);
    if (!mounted) { return; }
    setState(() {
      _refreshing = false;
      if (updated != null) {
        _station       = updated; // live availability/price/etc. now reflected
        _justRefreshed = true;
      } else {
        _refreshFailed = true;    // network failed or station no longer listed
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = _station;
    final avail = s.available > 0;
    final statusColor = avail ? _emerald : Colors.orangeAccent;

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
              label: '${s.kw} kW · ${s.isDC ? 'Fast DC' : 'AC'}',
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
            ...sortConnectors(s.connectors).map((c) => _InfoChip(
              icon:  Icons.power_outlined,
              label: c,
              color: Colors.blueAccent,
            )),
          ]),
          const SizedBox(height: 16),

          // Last-updated timestamp
          if (s.lastUpdated.isNotEmpty) ...[
            const SizedBox(height: 6),
            Row(children: [
              const Icon(Icons.history_rounded, color: _textSec, size: 13),
              const SizedBox(width: 5),
              Text(
                'Last verified: ${_formatVerified(s.lastUpdated)}',
                style: const TextStyle(color: _textSec, fontSize: 11),
              ),
            ]),
            Padding(
              padding: const EdgeInsets.only(left: 18, top: 2),
              child: Text(
                AppStrings.providerLastCheck,
                style: AppStrings.font(
                    const TextStyle(color: _textSec, fontSize: 9.5)),
              ),
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
              !avail
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
                      color: _justRefreshed
                          ? _emerald
                          : (_refreshFailed ? Colors.orangeAccent : _textSec),
                      size: 19),
            ),
            if (_justRefreshed) ...[
              const SizedBox(width: 6),
              const Text('Updated', style: TextStyle(color: _emerald, fontSize: 11)),
            ] else if (_refreshFailed) ...[
              const SizedBox(width: 6),
              const Text('Update failed',
                  style: TextStyle(color: Colors.orangeAccent, fontSize: 11)),
            ],
          ]),
          const SizedBox(height: 22),

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
