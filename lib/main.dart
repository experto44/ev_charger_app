import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_marker_cluster/flutter_map_marker_cluster.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import 'places_service.dart';
import 'profile_screen.dart';
import 'route_planner_screen.dart';
import 'routing_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
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

// Known providers, in display order. "All selected" is the default (no filter).
const _kAllProviders = ['E-Space', 'mart EV', 'Electrify Georgia', 'EV Power GE'];

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
    title: 'EV Charger Georgia',
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark().copyWith(
      scaffoldBackgroundColor: _bgDark,
      colorScheme: const ColorScheme.dark(primary: _emerald, surface: _bgCard),
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

class _MapScreenState extends State<MapScreen> {
  final _searchCtrl  = TextEditingController();
  final _searchFocus = FocusNode();
  final _mapCtrl     = MapController();

  bool             _filterDC         = false;
  bool             _filterAvail      = false;
  // Multi-select provider filter. Defaults to every known provider selected
  // (= show all). A filter is "active" only when not all providers are selected.
  final Set<String> _selectedProviders = {..._kAllProviders};
  final Set<String> _filterConnectors = {};  // empty = no connector filter

  // Filter is "active" (badge shown) only for a proper, non-empty subset.
  // Empty set or all-selected both mean "show every provider".
  bool get _providerFilterActive =>
      _selectedProviders.isNotEmpty &&
      _selectedProviders.length != _kAllProviders.length;

  LatLng?               _userPos;
  List<Station>         _stations    = const [];
  bool                  _loading     = true;
  List<PlacePrediction> _suggestions = const [];
  Timer?                _debounce;

  @override
  void initState() {
    super.initState();
    // Station data can load independently of the map controller.
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadStations());
    // _initLocation() is called from MapOptions.onMapReady, which fires only
    // after FlutterMap has mounted and the MapController is fully attached.
  }

  List<Station> _parseStations(String raw) => (jsonDecode(raw) as List)
      .map((e) => Station.fromJson(e as Map<String, dynamic>))
      .toList();

  Future<void> _loadStations() async {
    // Capture the asset bundle NOW (synchronously, before any await gap)
    // so we don't access BuildContext after an async suspension.
    final bundle = DefaultAssetBundle.of(context);

    // ── Bundled asset ─────────────────────────────────────────────────────────
    // Always loaded (instant, offline). Doubles as a supplement for the live
    // feed: any provider bundled with the app but not yet published to the Gist
    // (e.g. a newly added network the cron hasn't refreshed) is added in, so the
    // app never hides a provider it ships with. Self-heals once the Gist catches
    // up (the provider then appears in the live feed and the supplement is empty).
    List<Station> assetStations = const [];
    try {
      assetStations = _parseStations(await bundle.loadString('assets/data/chargers.json'));
    } catch (_) {
      // No bundled asset — supplement simply stays empty.
    }

    // ── Live cloud data (Gist) ────────────────────────────────────────────────
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
        if (!mounted) { return; }
        setState(() { _stations = [...live, ...supplement]; _loading = false; });
        return; // success
      }
    } catch (_) {
      // Network unavailable, timeout, or parse error — fall through to offline.
    }

    // ── Offline fallback: bundled asset only ──────────────────────────────────
    if (!mounted) { return; }
    setState(() { _stations = assetStations; _loading = false; });
  }

  Future<void> _initLocation() async {
    try {
      LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) { return; }

      // ── Step 1: instant center using cached last-known position ───────────
      final last = await Geolocator.getLastKnownPosition();
      if (last != null && mounted) {
        final latlng = LatLng(last.latitude, last.longitude);
        setState(() => _userPos = latlng);
        _mapCtrl.move(latlng, 14);
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
      _mapCtrl.move(latlng, 14);
    } catch (_) {
      // Permission denied or GPS timeout — Tbilisi fallback stays in place.
    }
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _searchFocus.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _zoom(double delta) =>
      _mapCtrl.move(_mapCtrl.camera.center, _mapCtrl.camera.zoom + delta);

  // ── Provider filter FAB → multi-select bottom sheet ──────────────────────
  void _openProviderFilter() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
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
      ),
    );
  }

  // Shared push — no sheet-pop side-effect (used by carousel "Plan & Go").
  Future<void> _pushRoutePlannerTo(Station destination) async {
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
    if (coords != null && mounted) { _mapCtrl.move(coords, 15); }
  }

  List<Station> get _filtered {
    final q = _searchCtrl.text.trim().toLowerCase();
    return _stations.where((s) {
      if (q.isNotEmpty &&
          !s.name.toLowerCase().contains(q) &&
          !s.location.toLowerCase().contains(q)) { return false; }
      // Provider filter (applied first): empty OR all-selected => show all;
      // any non-empty subset => keep only those providers. Connector/type
      // filters below then AND on top of this.
      if (_selectedProviders.isNotEmpty &&
          !_selectedProviders.contains(s.provider)) { return false; }
      if (_filterDC    && !s.isDC)          { return false; }
      if (_filterAvail && s.available == 0) { return false; }
      if (_filterConnectors.isNotEmpty &&
          !s.connectors.any((c) => _filterConnectors.contains(c))) { return false; }
      return true;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final stations = _filtered;
    return Scaffold(
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
              // safe moment to call _mapCtrl.move() on startup.
              onMapReady: _initLocation,
            ),
            children: [
              // CartoDB Dark Matter — reliable dark basemap, highways and
              // arterials visible as lighter grey lines, water as dark blue.
              TileLayer(
                urlTemplate: 'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png',
                subdomains: const ['a', 'b', 'c', 'd'],
                userAgentPackageName: 'com.example.ev_charger_app',
                retinaMode: false,
                maxNativeZoom: 18,
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
                      child: Container(
                        decoration: BoxDecoration(
                          color: s.available > 0 ? _emerald : Colors.orangeAccent,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white.withOpacity(0.25), width: 2),
                          boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 6)],
                        ),
                        child: const Icon(Icons.bolt, color: Colors.black, size: 20),
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
                  ),
                  if (_suggestions.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    _SuggestionsList(suggestions: _suggestions, onTap: _onSuggestionSelected),
                  ],
                  const SizedBox(height: 10),
                  _FilterChips(
                    filterDC:         _filterDC,
                    filterAvail:      _filterAvail,
                    onDC:             (v) => setState(() => _filterDC    = v),
                    onAvail:          (v) => setState(() => _filterAvail = v),
                    filterConnectors: _filterConnectors,
                    onConnector:      (ct) => setState(() {
                      if (_filterConnectors.contains(ct)) {
                        _filterConnectors.remove(ct);
                      } else {
                        _filterConnectors.add(ct);
                      }
                    }),
                  ),
                ],
              ),
            ),
          ),

          // ── Provider filter FAB (above the zoom + button) ─────────────────
          Positioned(
            right:  16,
            bottom: 492,
            child: GestureDetector(
              onTap: _openProviderFilter,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    width: 48, height: 48,
                    decoration: BoxDecoration(
                      color: _bgCard,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: _providerFilterActive ? _emerald : _bgSurface,
                      ),
                      boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 10, offset: Offset(0, 4))],
                    ),
                    child: Icon(
                      Icons.layers_rounded,
                      color: _providerFilterActive ? _emerald : _textSec,
                      size: 22,
                    ),
                  ),
                  // Badge shown only while a provider filter is active.
                  if (_providerFilterActive)
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
            ),
          ),

          // ── Zoom +/− buttons ─────────────────────────────────────────────
          Positioned(
            right:  16,
            bottom: 380,
            child: Column(
              children: [
                _ZoomBtn(icon: Icons.add_rounded,    onTap: () => _zoom(1)),
                const SizedBox(height: 8),
                _ZoomBtn(icon: Icons.remove_rounded, onTap: () => _zoom(-1)),
              ],
            ),
          ),

          // ── Route planner FAB ─────────────────────────────────────────────
          Positioned(
            right:  16,
            bottom: 316,
            child: GestureDetector(
              onTap: () => Navigator.push<void>(
                context,
                MaterialPageRoute(
                  builder: (_) => RoutePlannerScreen(stations: _stations),
                ),
              ),
              child: Container(
                width: 48, height: 48,
                decoration: BoxDecoration(
                  color: _bgCard,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: _bgSurface),
                  boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 10, offset: Offset(0, 4))],
                ),
                child: const Icon(Icons.alt_route_rounded, color: _textSec, size: 22),
              ),
            ),
          ),

          // ── Recenter GPS FAB ──────────────────────────────────────────────
          Positioned(
            right:  16,
            bottom: 256,
            child: GestureDetector(
              onTap: _userPos == null ? null : () => _mapCtrl.move(_userPos!, 14),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 48, height: 48,
                decoration: BoxDecoration(
                  color: _userPos == null ? _bgSurface : _bgCard,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: _userPos == null ? _bgSurface : _emerald,
                  ),
                  boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 10, offset: Offset(0, 4))],
                ),
                child: Icon(
                  Icons.my_location_rounded,
                  color: _userPos == null ? _textSec : _emerald,
                  size: 22,
                ),
              ),
            ),
          ),

          // ── Bottom panel: station carousel ────────────────────────────────
          Positioned(
            left: 0, right: 0, bottom: 0,
            child: _loading
                ? const SizedBox(
                    height: 120,
                    child: Center(
                      child: SizedBox(
                        width: 24, height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2, color: _emerald),
                      ),
                    ),
                  )
                : _StationCarousel(
                    stations:    stations,
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
  });
  final TextEditingController controller;
  final FocusNode             focusNode;
  final ValueChanged<String>  onChanged;

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
            icon:  Icons.account_circle_outlined,
            onTap: () => Navigator.push(
              context, MaterialPageRoute(builder: (_) => const ProfileScreen()),
            ),
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
    required this.filterConnectors,
    required this.onConnector,
  });
  final bool              filterDC, filterAvail;
  final ValueChanged<bool> onDC, onAvail;
  final Set<String>        filterConnectors;
  final ValueChanged<String> onConnector;

  // Fixed connector types — always shown regardless of loaded station data.
  static const _kConnectors = ['CCS1', 'CCS2', 'GB/T', 'CHAdeMO', 'Type 2', 'NACS'];

  @override
  Widget build(BuildContext context) {
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
          // Fixed connector-type chips — multi-select
          ..._kConnectors.map((ct) => Padding(
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
    return Container(
      decoration: const BoxDecoration(
        color: _bgCard,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
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
        height: 254, // taller for stacked Navigate + Plan & Go buttons (+ provider line)
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
              avail ? '${s.available} available' : 'Unavailable',
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

// ── Station popup bottom sheet ────────────────────────────────────────────────
class _StationSheet extends StatefulWidget {
  const _StationSheet({required this.station, required this.onGetDirections});
  final Station      station;
  final VoidCallback onGetDirections;

  @override
  State<_StationSheet> createState() => _StationSheetState();
}

class _StationSheetState extends State<_StationSheet> {
  bool _refreshing = false;
  bool _justRefreshed = false;

  Future<void> _refresh() async {
    setState(() { _refreshing = true; _justRefreshed = false; });
    await Future.delayed(const Duration(seconds: 1));
    if (mounted) {
      setState(() { _refreshing = false; _justRefreshed = true; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.station;
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
            ...s.connectors.map((c) => _InfoChip(
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
                'Last verified: ${s.lastUpdated}',
                style: const TextStyle(color: _textSec, fontSize: 11),
              ),
            ]),
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
              avail
                  ? '${s.available} connector${s.available == 1 ? '' : 's'} available'
                  : 'No connectors available',
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
                      color: _justRefreshed ? _emerald : _textSec, size: 19),
            ),
            if (_justRefreshed) ...[
              const SizedBox(width: 6),
              const Text('Updated', style: TextStyle(color: _emerald, fontSize: 11)),
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
