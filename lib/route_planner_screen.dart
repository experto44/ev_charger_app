import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_constants.dart';
import 'l10n/app_strings.dart';
import 'places_service.dart';
import 'profile_screen.dart';
import 'provider_logos.dart';
import 'routing_service.dart';
import 'turkey_service.dart';

// ── Palette ───────────────────────────────────────────────────────────────────
const _bgDark    = Color(0xFF1A1A1A);
const _bgCard    = Color(0xFF252525);
const _bgSurface = Color(0xFF2E2E2E);
const _emerald   = Color(0xFF00C896);
const _textPri   = Color(0xFFFFFFFF);
const _textSec   = Color(0xFF9E9E9E);

// ── Stop model ────────────────────────────────────────────────────────────────
class RouteStop {
  RouteStop() : controller = TextEditingController();
  final TextEditingController controller;
  LatLng? coords;

  void dispose() => controller.dispose();
}

// ── Screen ────────────────────────────────────────────────────────────────────
class RoutePlannerScreen extends StatefulWidget {
  const RoutePlannerScreen({
    super.key,
    required this.stations,
    this.initialOrigin,
    this.initialDestination,
  });

  final List<Station> stations;
  /// Pre-fills the Start stop with the user's current GPS position.
  final LatLng?   initialOrigin;
  /// Pre-fills the End stop with a station chosen via "Get Directions".
  final Station?  initialDestination;

  @override
  State<RoutePlannerScreen> createState() => _RoutePlannerScreenState();
}

class _RoutePlannerScreenState extends State<RoutePlannerScreen> {
  final _stops       = [RouteStop(), RouteStop()];
  // Chargers fetched on demand because the route reaches a country the map
  // wasn't showing. Today that means Turkey: a driver planning Tbilisi →
  // İstanbul must not have to go and tick Turkey in Settings first, or the
  // plan would simply run out of chargers at the border.
  List<Station> _extraStations = const [];
  bool _loadingCountryData = false;
  double _batteryPct = 80.0;
  double _maxRangeKm = 300.0;
  bool   _isPlanning = false;

  // Per-planning charger filters. Deliberately NOT persisted: every time the
  // planner opens they start clean (all connectors, any power), so a filter
  // from a previous trip never silently hides chargers on the next one.
  final Set<String> _routeConnectors = {}; // empty = any connector
  int               _routeMinKw      = 0;  // 0 = any power

  // Real-road route result from RoutingService.planRoute, recomputed (debounced)
  // whenever the stops or battery change. Drives the preview stats and the
  // charging-options list (including any U-turn warnings).
  EVRouteResult? _routeResult;
  Timer?         _routeDebounce;

  // Which charger blocks the driver has ticked, by RouteChargerOption.locationKey.
  // Seeded from the recommended plan on a fresh route, then preserved while only
  // the battery slider changes (same _routeSignature) so manual ticks survive.
  Set<String> _selectedKeys = <String>{};
  String?     _routeSignature;

  @override
  void initState() {
    super.initState();
    // Pre-fill Start with user GPS if available
    if (widget.initialOrigin != null) {
      _stops.first.coords = widget.initialOrigin;
      _stops.first.controller.text = 'My Location';
    }
    // Pre-fill End with tapped station
    if (widget.initialDestination != null) {
      final d = widget.initialDestination!;
      _stops.last.coords = LatLng(d.lat, d.lng);
      _stops.last.controller.text = d.name;
    }
    _loadMaxRange();
    _scheduleRouteCompute();
  }

  Future<void> _loadMaxRange() async {
    final prefs = await SharedPreferences.getInstance();
    final val   = double.tryParse(prefs.getString(kMaxRange) ?? '') ?? 300.0;
    if (mounted) { setState(() => _maxRangeKm = val); }
  }

  @override
  void dispose() {
    _routeDebounce?.cancel();
    for (final s in _stops) { s.dispose(); }
    super.dispose();
  }

  // ── Debounced real-road route computation ─────────────────────────────────
  // Coalesces rapid changes (typing, slider drags) into a single Directions
  // call. Clears the result when the route is incomplete.
  void _scheduleRouteCompute() {
    _routeDebounce?.cancel();
    if (!_canPreview) {
      if (_routeResult != null) { setState(() => _routeResult = null); }
      return;
    }
    _routeDebounce = Timer(const Duration(milliseconds: 500), _computeRoute);
  }

  // Stations eligible for THIS planning session, per the charger filters above.
  // Connector match is case-insensitive (mirrors the map filter); a station
  // with an unknown power rating (kw == 0) is never excluded by the kW filter.
  List<Station> get _filteredStations =>
      [...widget.stations, ..._extraStations].where((s) {
        if (_routeConnectors.isNotEmpty &&
            !s.connectors.any((c) => _routeConnectors
                .any((f) => f.toLowerCase() == c.toLowerCase()))) {
          return false;
        }
        if (_routeMinKw > 0 && s.kw > 0 && s.kw < _routeMinKw) { return false; }
        return true;
      }).toList();

  /// Pulls in the chargers for a country the route reaches but the map wasn't
  /// showing. Only Turkey needs this today: it is the one neighbour with its
  /// own dataset, and it is the country Georgian drivers actually drive into.
  /// No-op once loaded, and silent if the download fails — the plan then just
  /// falls back to whatever chargers we already had.
  Future<void> _ensureCountryData(List<LatLng> waypoints) async {
    if (_extraStations.isNotEmpty || _loadingCountryData) { return; }
    // The map may already have handed us Turkey (user has it switched on).
    if (widget.stations.any((s) => s.country == TurkeyService.kCountry)) {
      return;
    }
    if (!_routeTouches(TurkeyService.kCountry, waypoints)) { return; }

    setState(() => _loadingCountryData = true);
    final list = await TurkeyService.fetchAll();
    if (!mounted) { return; }
    setState(() {
      _extraStations      = list;
      _loadingCountryData = false;
    });
  }

  /// True when any waypoint sits in [country], or a straight leg between two
  /// waypoints passes through it — so Tbilisi → Sofia still picks up Turkish
  /// chargers even though neither end is Turkish. Sampling the legs is coarse
  /// on purpose: it runs before the Directions call, so there is no real road
  /// geometry yet, and a false positive only costs one cached download.
  bool _routeTouches(String country, List<LatLng> waypoints) {
    final def = kCountries.where((c) => c.name == country).firstOrNull;
    if (def == null || !def.hasBox) { return false; }
    for (var i = 0; i < waypoints.length; i++) {
      final a = waypoints[i];
      if (def.contains(a.latitude, a.longitude)) { return true; }
      if (i + 1 >= waypoints.length) { break; }
      final b = waypoints[i + 1];
      const samples = 24;
      for (var k = 1; k < samples; k++) {
        final t = k / samples;
        if (def.contains(a.latitude + (b.latitude - a.latitude) * t,
                         a.longitude + (b.longitude - a.longitude) * t)) {
          return true;
        }
      }
    }
    return false;
  }

  Future<void> _computeRoute() async {
    if (!_canPreview) { return; }
    final stops = _stops.map((s) => s.coords).whereType<LatLng>().toList();
    await _ensureCountryData(stops);
    if (!mounted) { return; }
    final res = await RoutingService.planRoute(
      waypoints:         stops,
      currentBatteryPct: _batteryPct,
      stations:          _filteredStations,
    );
    if (!mounted) { return; }
    setState(() {
      _routeResult = res;
      // Signature = waypoint coords + charger filters (battery excluded). A
      // change means a genuinely different set of options → reseed ticks from
      // the recommendation; an unchanged signature (battery nudge) keeps the
      // driver's manual ticks.
      final wpSig = _stops
          .map((s) => s.coords == null
              ? '-'
              : '${s.coords!.latitude},${s.coords!.longitude}')
          .join('|');
      final sig =
          '$wpSig#${(_routeConnectors.toList()..sort()).join(',')}#$_routeMinKw';
      final valid = res?.options.map((o) => o.locationKey).toSet() ?? <String>{};
      if (sig != _routeSignature) {
        _routeSignature = sig;
        _selectedKeys = res?.options
                .where((o) => o.recommended)
                .map((o) => o.locationKey)
                .toSet() ??
            <String>{};
      } else {
        _selectedKeys = _selectedKeys.intersection(valid);
      }
    });
  }

  void _toggleOption(String key) {
    setState(() {
      if (!_selectedKeys.remove(key)) { _selectedKeys.add(key); }
    });
  }

  // ── Dynamic battery % at a point [alongKm] along the route ────────────────
  // Drains from the current battery, resetting to a full charge at every ticked
  // charger passed so far. This is why arrival %s jump up as the driver ticks
  // more stops.
  double _arrivalPctAt(double alongKm, EVRouteResult r) {
    final eff = r.effectiveRangeKm;
    if (eff <= 0) { return 0; }
    double anchorAlong = 0;
    double anchorRange = (_batteryPct / 100.0) * eff;
    for (final o in r.options) {
      if (o.alongKm >= alongKm) { break; }
      if (_selectedKeys.contains(o.locationKey)) {
        anchorAlong = o.alongKm;
        anchorRange = eff; // assume a full charge here
      }
    }
    final range = anchorRange - (alongKm - anchorAlong);
    return (range / eff * 100).clamp(0.0, 100.0);
  }

  void _addStop() {
    if (_stops.length >= 5) { return; }
    // Appends a new final destination; drag any stop to rearrange afterwards.
    setState(() => _stops.add(RouteStop()));
    _scheduleRouteCompute();
  }

  void _removeStop(int i) {
    setState(() {
      _stops[i].dispose();
      _stops.removeAt(i);
    });
    _scheduleRouteCompute();
  }

  // Drag-handle reorder. RouteStop objects move whole (controller + coords),
  // and the From/Stop N/To labels + dot colours re-derive from position.
  // Wired to onReorderItem, so newIndex arrives already adjusted for removal.
  void _onReorder(int oldIndex, int newIndex) {
    setState(() {
      final s = _stops.removeAt(oldIndex);
      _stops.insert(newIndex, s);
    });
    _scheduleRouteCompute();
  }

  // Canonical connector types actually present in the supplied station data —
  // keeps the filter chips honest (no dead chips), in the shared display order.
  List<String> get _availableConnectors {
    final present = <String>{};
    for (final s in widget.stations) {
      for (final c in s.connectors) { present.add(c.toLowerCase()); }
    }
    return kConnectorOrder
        .where((c) => present.contains(c.toLowerCase()))
        .toList();
  }

  int get _resolvedCount => _stops.where((s) => s.coords != null).length;

  bool get _canPreview =>
      _stops.first.coords != null && _stops.last.coords != null;

  /// Point to rank stop [i]'s place search around: the nearest earlier stop
  /// that's already pinned, else the first pinned stop anywhere, else the
  /// driver's own position. Place search covers every country now, so without
  /// a bias a short query ("Merkez") could suggest anywhere in Europe.
  LatLng? _biasForStop(int i) {
    for (var j = i - 1; j >= 0; j--) {
      final c = _stops[j].coords;
      if (c != null) { return c; }
    }
    for (final s in _stops) {
      if (s.coords != null) { return s.coords; }
    }
    return widget.initialOrigin;
  }

  // ── GPS auto-fill for the Start field ────────────────────────────────────
  Future<void> _fillMyLocation() async {
    try {
      LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) { return; }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 10),
        ),
      );
      if (!mounted) { return; }
      setState(() {
        _stops.first.coords = LatLng(pos.latitude, pos.longitude);
        _stops.first.controller.text = 'My Current Location';
      });
      _scheduleRouteCompute();
    } catch (_) {}
  }

  // ── Haversine distance between two points (km) ────────────────────────────
  static double _haversine(LatLng a, LatLng b) {
    const r    = 6371.0;
    final dLat = (b.latitude  - a.latitude)  * pi / 180;
    final dLng = (b.longitude - a.longitude) * pi / 180;
    final x    = sin(dLat / 2) * sin(dLat / 2) +
        cos(a.latitude * pi / 180) * cos(b.latitude * pi / 180) *
        sin(dLng / 2) * sin(dLng / 2);
    return 2 * r * asin(sqrt(x));
  }

  // ── Find N charging-station waypoints evenly spaced along origin→dest ──────
  // DEAD CODE: superseded by RoutingService.planRoute, which snaps chargers to
  // the real Directions road polyline instead of a straight line. Kept only as
  // an offline fallback for when the Directions API call fails. The old
  // straight-line approach mis-picked chargers whenever the geodesic line
  // diverged from the actual highway (e.g. Tbilisi→Batumi cutting across the
  // Borjomi/Goderdzi mountains instead of following the E60 via Kutaisi).
  // Interpolates N intermediate positions along the straight-line route and
  // picks the nearest *available* station to each position (each station can
  // only be picked once).  Returns them in geographic order (already sorted
  // by interpolation parameter t, so no extra sort needed here).
  List<Station> _chargingStationWaypoints(int count) {
    if (count <= 0) { return <Station>[]; }
    final origin = _stops.first.coords;
    final dest   = _stops.last.coords;
    if (origin == null || dest == null) { return <Station>[]; }

    final available = _filteredStations
        .where((s) => s.available > 0)
        .toList();
    if (available.isEmpty) { return <Station>[]; }

    final result = <Station>[];
    final used   = <String>{}; // station name used as a unique key

    for (int i = 1; i <= count; i++) {
      // Evenly-spaced fraction along the straight-line origin→dest
      final t   = i / (count + 1);
      final lat = origin.latitude  + (dest.latitude  - origin.latitude)  * t;
      final lng = origin.longitude + (dest.longitude - origin.longitude) * t;
      final pt  = LatLng(lat, lng);

      // Nearest unused available station to this interpolated point
      Station? best;
      double   minD = double.infinity;
      for (final s in available) {
        if (used.contains(s.name)) { continue; }
        final d = _haversine(pt, LatLng(s.lat, s.lng));
        if (d < minD) { minD = d; best = s; }
      }
      if (best != null) {
        result.add(best);
        used.add(best.name);
      }
    }
    return result;
  }

  // ── Haversine chain across all resolved stops ─────────────────────────────
  // A 1.25× road-distance multiplier converts straight-line km to an estimate
  // that closely matches real driving distance shown by Google Maps.
  // (Average detour factor for Georgian roads ≈ 1.20–1.30.)
  double get _totalDistanceKm {
    double total = 0;
    for (int i = 0; i < _stops.length - 1; i++) {
      final a = _stops[i].coords;
      final b = _stops[i + 1].coords;
      if (a != null && b != null) { total += _haversine(a, b); }
    }
    return total * 1.25; // road-distance estimate
  }

  // ── Real-time EV preview (updates as slider moves) ───────────────────────
  ({double batteryAtArrivalPct, int stopsNeeded}) get _evPreview {
    final effectiveKm = _maxRangeKm * 0.90;
    final totalDist   = _totalDistanceKm;
    final startKm     = (_batteryPct / 100.0) * effectiveKm;
    final int stops   = totalDist <= startKm
        ? 0
        : ((totalDist - startKm) / effectiveKm).ceil();
    final double leftover = startKm + stops * effectiveKm - totalDist;
    final double pct = effectiveKm > 0
        ? (leftover / effectiveKm * 100.0).clamp(0.0, 100.0)
        : 0.0;
    return (batteryAtArrivalPct: pct, stopsNeeded: stops);
  }

  // ── Open complete multi-stop route in native Google Maps ─────────────────
  // Waypoint order rule: the user's manual stops ALWAYS keep the order they
  // chose in the UI (a Tbilisi→Kutaisi→Batumi→Zugdidi→Tbilisi round trip must
  // never be re-sorted geographically — the old progress-sort did exactly that
  // and collapsed round trips entirely). Ticked charging stops are interleaved
  // between the manual stops using their true along-route distance (alongKm)
  // against the Directions legs' cumulative distances (legEndsKm).
  Future<void> _planRoute() async {
    setState(() => _isPlanning = true);
    try {
      final origin      = _stops.first.coords!;
      final destination = _stops.last.coords!;

      // Every resolved stop in UI order — passed to the routing service so the
      // Directions request (and therefore the road polyline chargers snap to)
      // runs through any manual intermediate stops too.
      final resolvedStops =
          _stops.map((s) => s.coords).whereType<LatLng>().toList();

      // Reuse the preview's result only when it matches the CURRENT stop list
      // (a tap within the debounce window could otherwise pair fresh stops with
      // a stale route); otherwise recompute against the actual road right now.
      var routeResult = _routeResult;
      if (routeResult == null ||
          routeResult.legEndsKm.length != resolvedStops.length - 1) {
        routeResult = await RoutingService.planRoute(
          waypoints:         resolvedStops,
          currentBatteryPct: _batteryPct,
          stations:          _filteredStations,
        );
      }

      String urlStr =
          'https://www.google.com/maps/dir/?api=1'
          '&origin=${origin.latitude},${origin.longitude}'
          '&destination=${destination.latitude},${destination.longitude}'
          '&travelmode=driving';

      // Ordered waypoint coordinate strings for the Google Maps URL.
      final ordered = <String>[];

      if (routeResult != null && routeResult.legEndsKm.isNotEmpty) {
        // Manual stop i (1..n-2) sits at the end of Directions leg i-1; ticked
        // chargers carry their own along-route km. Sorting the combined list by
        // that single axis interleaves chargers into the right legs while the
        // manual stops keep their user-chosen order (their leg-end distances
        // are monotonically increasing by construction, even on round trips).
        final entries = <(double, String)>[];
        for (int i = 1; i < resolvedStops.length - 1; i++) {
          final p = resolvedStops[i];
          entries.add((
            routeResult.legEndsKm[i - 1],
            '${p.latitude},${p.longitude}',
          ));
        }
        for (final o in routeResult.options) {
          if (!_selectedKeys.contains(o.locationKey)) { continue; }
          entries.add((o.alongKm, '${o.location.latitude},${o.location.longitude}'));
        }
        entries.sort((a, b) => a.$1.compareTo(b.$1));
        ordered.addAll(entries.map((e) => e.$2));
      } else {
        // Directions failed (offline / API error): keep manual stops in user
        // order and slot each straight-line-estimated charger into the leg
        // where it adds the least detour, ordered outward from the leg start.
        final chargers = _chargingStationWaypoints(_evPreview.stopsNeeded);
        final perLeg = List.generate(
            resolvedStops.length - 1, (_) => <(double, String)>[]);
        for (final s in chargers) {
          final pt = LatLng(s.lat, s.lng);
          var bestLeg = 0;
          var bestExtra = double.infinity;
          for (int i = 0; i < resolvedStops.length - 1; i++) {
            final a = resolvedStops[i], b = resolvedStops[i + 1];
            final extra =
                _haversine(a, pt) + _haversine(pt, b) - _haversine(a, b);
            if (extra < bestExtra) { bestExtra = extra; bestLeg = i; }
          }
          perLeg[bestLeg].add((
            _haversine(resolvedStops[bestLeg], pt),
            '${s.lat},${s.lng}',
          ));
        }
        for (int i = 0; i < resolvedStops.length - 1; i++) {
          perLeg[i].sort((a, b) => a.$1.compareTo(b.$1));
          ordered.addAll(perLeg[i].map((e) => e.$2));
          if (i < resolvedStops.length - 2) {
            final p = resolvedStops[i + 1];
            ordered.add('${p.latitude},${p.longitude}');
          }
        }
      }

      if (ordered.isNotEmpty) {
        urlStr += '&waypoints=${ordered.join('|')}';
      }

      final uri = Uri.parse(urlStr);
      if (!mounted) { return; }

      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        // Deliberately DON'T pop the planner: Google Maps opens in a separate
        // app, and when the driver hits back they land right here with the route,
        // stops and ticked chargers intact — ready to tweak or add a stop.
      } else {
        if (!mounted) { return; }
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          backgroundColor: _bgCard,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          content: const Text(
            'Could not open Google Maps. Please install Google Maps.',
            style: TextStyle(color: _textPri),
          ),
        ));
      }
    } finally {
      if (mounted) { setState(() => _isPlanning = false); }
    }
  }

  @override
  Widget build(BuildContext context) {
    final allResolved = _resolvedCount == _stops.length;
    final preview     = _evPreview;
    return Scaffold(
      backgroundColor: _bgDark,
      appBar: AppBar(
        backgroundColor: _bgCard,
        elevation: 0,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: _textPri, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          'Route Planner',
          style: AppStrings.font(const TextStyle(
              color: _textPri, fontSize: 17, fontWeight: FontWeight.w600)),
        ),
      ),
      // Rebuild on language change — this screen may sit beneath the profile
      // screen (where the toggle lives) in the navigation stack.
      body: ValueListenableBuilder<bool>(
        valueListenable: AppStrings.notifier,
        builder: (context, _, __) => AppStrings.wrap(Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
              child: Column(
                children: [
                  // Stop rows — drag the ≡ handle to reorder; labels (From /
                  // Stop N / To) and dot colours re-derive from the new order.
                  ReorderableListView(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    buildDefaultDragHandles: false,
                    onReorderItem: _onReorder,
                    proxyDecorator: (child, _, __) => Material(
                      color: Colors.transparent,
                      child: child,
                    ),
                    children: [
                      for (int i = 0; i < _stops.length; i++)
                        Padding(
                          key: ObjectKey(_stops[i]),
                          padding: EdgeInsets.only(
                              bottom: i < _stops.length - 1 ? 12 : 0),
                          child: _StopRow(
                            index:        i,
                            total:        _stops.length,
                            stop:         _stops[i],
                            onRemove:     _stops.length > 2
                                ? () => _removeStop(i)
                                : null,
                            onMyLocation: i == 0 ? _fillMyLocation : null,
                            // Bias each field to the last stop already pinned,
                            // so typing "Bursa" after İstanbul ranks Turkish
                            // results first instead of Georgian ones.
                            searchBias: _biasForStop(i),
                            onPlaceSelected: (pred, coords) {
                              setState(() {
                                _stops[i].coords = coords;
                                _stops[i].controller.text = pred.description;
                              });
                              _scheduleRouteCompute();
                            },
                          ),
                        ),
                    ],
                  ),
                  if (_stops.length < 5) ...[
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: GestureDetector(
                        onTap: _addStop,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            color: _bgCard,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: _bgSurface),
                          ),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            const Icon(Icons.add_rounded,
                                color: _emerald, size: 16),
                            const SizedBox(width: 6),
                            Text(AppStrings.addStop,
                                style: AppStrings.font(const TextStyle(
                                    color: _textPri, fontSize: 13,
                                    fontWeight: FontWeight.w600))),
                          ]),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  // Charger filters for THIS trip — connector types + min power.
                  // Reset to "any" every time the planner opens (not persisted).
                  _RouteFilterCard(
                    availableConnectors: _availableConnectors,
                    selectedConnectors:  _routeConnectors,
                    minKw:               _routeMinKw,
                    onConnectorToggle: (c) {
                      setState(() {
                        if (!_routeConnectors.remove(c)) {
                          _routeConnectors.add(c);
                        }
                      });
                      _scheduleRouteCompute();
                    },
                    onMinKw: (kw) {
                      setState(() => _routeMinKw = kw);
                      _scheduleRouteCompute();
                    },
                  ),
                  const SizedBox(height: 12),
                  // Battery slider
                  _BatterySlider(
                    value:     _batteryPct,
                    onChanged: (v) {
                      setState(() => _batteryPct = v);
                      _scheduleRouteCompute();
                    },
                  ),
                  const SizedBox(height: 12),
                  // Live EV route preview — uses the real-road result when ready,
                  // otherwise the instant straight-line estimate. Stops count and
                  // arrival % follow the driver's current ticks (dynamic).
                  _RoutePreviewStats(
                    distanceKm:          _routeResult?.totalDistanceKm
                                            ?? _totalDistanceKm,
                    batteryAtArrivalPct: _routeResult != null
                        ? _arrivalPctAt(_routeResult!.totalDistanceKm, _routeResult!)
                        : preview.batteryAtArrivalPct,
                    stopsNeeded:         _routeResult != null
                        ? _routeResult!.options
                            .where((o) => _selectedKeys.contains(o.locationKey))
                            .length
                        : preview.stopsNeeded,
                    hasRoute:            _canPreview,
                  ),
                  // Selectable charger blocks along the route (~one per 50 km),
                  // with dynamic arrival %, inter-stop distances and U-turn info.
                  if (_routeResult != null) ...[
                    const SizedBox(height: 12),
                    _ChargingOptionsList(
                      options:       _routeResult!.options,
                      selectedKeys:  _selectedKeys,
                      arrivalPctFor: (o) =>
                          _arrivalPctAt(o.alongKm, _routeResult!).round(),
                      onToggle:      _toggleOption,
                    ),
                  ],
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
          _BottomBar(
            resolvedCount: _resolvedCount,
            total:         _stops.length,
            isPlanning:    _isPlanning || _loadingCountryData,
            onPlanRoute:   allResolved ? _planRoute : null,
          ),
        ],
      )),
      ),
    );
  }
}

// ── Stop row ──────────────────────────────────────────────────────────────────
class _StopRow extends StatelessWidget {
  const _StopRow({
    required this.index,
    required this.total,
    required this.stop,
    required this.onPlaceSelected,
    this.onRemove,
    this.onMyLocation,
    this.searchBias,
  });
  final int index, total;
  final RouteStop stop;
  final void Function(PlacePrediction, LatLng?) onPlaceSelected;
  final LatLng? searchBias;
  final VoidCallback? onRemove;
  final VoidCallback? onMyLocation; // shown only for index == 0

  String get _label {
    if (index == 0)         { return AppStrings.from; }
    if (index == total - 1) { return AppStrings.to; }
    return '${AppStrings.stopN} $index';
  }

  Color get _dotColor {
    if (index == 0)         { return _emerald; }
    if (index == total - 1) { return const Color(0xFFFF6B6B); }
    return const Color(0xFF2196F3);
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 12, height: 12,
          decoration: BoxDecoration(
            color: _dotColor,
            shape: BoxShape.circle,
            boxShadow: [BoxShadow(color: _dotColor.withOpacity(0.4), blurRadius: 6)],
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _PlaceField(
            controller:      stop.controller,
            hint:            _label,
            isResolved:      stop.coords != null,
            onPlaceSelected: onPlaceSelected,
            searchBias:      searchBias,
          ),
        ),
        // GPS shortcut — only for the Start (index 0) field
        if (onMyLocation != null) ...[
          const SizedBox(width: 8),
          GestureDetector(
            onTap: onMyLocation,
            child: Container(
              width: 34, height: 34,
              decoration: BoxDecoration(
                color: _bgCard,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: _bgSurface),
              ),
              child: const Icon(Icons.my_location_rounded, color: _emerald, size: 17),
            ),
          ),
        ],
        if (onRemove != null) ...[
          const SizedBox(width: 8),
          GestureDetector(
            onTap: onRemove,
            child: const Icon(Icons.close_rounded, color: _textSec, size: 18),
          ),
        ],
        // Drag handle — press and drag to move this stop up/down the list.
        const SizedBox(width: 8),
        ReorderableDragStartListener(
          index: index,
          child: Container(
            width: 34, height: 34,
            decoration: BoxDecoration(
              color: _bgCard,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: _bgSurface),
            ),
            child: const Icon(Icons.drag_indicator_rounded,
                color: _textSec, size: 18),
          ),
        ),
      ],
    );
  }
}

// ── Charger filter card (per-trip connector types + minimum power) ───────────
// Sits between the stop rows and the battery slider. Both filters reset every
// time the planner opens; the hint line explains that the route is planned
// only through stations matching the selection.
class _RouteFilterCard extends StatelessWidget {
  const _RouteFilterCard({
    required this.availableConnectors,
    required this.selectedConnectors,
    required this.minKw,
    required this.onConnectorToggle,
    required this.onMinKw,
  });
  final List<String>         availableConnectors;
  final Set<String>          selectedConnectors;
  final int                  minKw;
  final ValueChanged<String> onConnectorToggle;
  final ValueChanged<int>    onMinKw;

  Widget _chip({
    required String label,
    required bool on,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: on ? _emerald : _bgSurface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: on ? _emerald : Colors.transparent),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: on ? Colors.black : _textSec,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _bgCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _bgSurface),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            AppStrings.routeFiltersTitle,
            style: const TextStyle(color: _textSec, fontSize: 11,
                fontWeight: FontWeight.w600, letterSpacing: 0.6),
          ),
          const SizedBox(height: 12),
          Text(AppStrings.routeConnectorsLabel,
              style: const TextStyle(color: _textPri, fontSize: 12,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final c in availableConnectors)
                _chip(
                  label: c,
                  on:    selectedConnectors.contains(c),
                  onTap: () => onConnectorToggle(c),
                ),
            ],
          ),
          const SizedBox(height: 14),
          Text(AppStrings.routeMinPowerLabel,
              style: const TextStyle(color: _textPri, fontSize: 12,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _chip(
                label: AppStrings.anyLabel,
                on:    minKw == 0,
                onTap: () => onMinKw(0),
              ),
              for (final kw in kMinPowerSteps)
                _chip(
                  label: '$kw kW',
                  on:    minKw == kw,
                  onTap: () => onMinKw(kw),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            AppStrings.routeFiltersHint,
            style: const TextStyle(color: _textSec, fontSize: 11, height: 1.35),
          ),
        ],
      ),
    );
  }
}

// ── Battery % slider ──────────────────────────────────────────────────────────
class _BatterySlider extends StatelessWidget {
  const _BatterySlider({required this.value, required this.onChanged});
  final double value;
  final ValueChanged<double> onChanged;

  Color get _color {
    if (value >= 50) { return _emerald; }
    if (value >= 20) { return Colors.orangeAccent; }
    return Colors.redAccent;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _bgCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _bgSurface),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Text(
              AppStrings.currentBattery,
              style: const TextStyle(color: _textSec, fontSize: 11,
                  fontWeight: FontWeight.w600, letterSpacing: 0.6),
            ),
            const Spacer(),
            Icon(Icons.battery_charging_full_rounded, color: _color, size: 15),
            const SizedBox(width: 4),
            Text(
              '${value.round()}%',
              style: TextStyle(color: _color, fontSize: 14, fontWeight: FontWeight.w700),
            ),
          ]),
          const SizedBox(height: 6),
          SliderTheme(
            data: SliderThemeData(
              activeTrackColor:   _color,
              inactiveTrackColor: _bgSurface,
              thumbColor:         _color,
              overlayColor:       _color.withOpacity(0.2),
              trackHeight:        4,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
            ),
            child: Slider(
              value:     value,
              min:       5,
              max:       100,
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Reactive EV route preview stats ──────────────────────────────────────────
class _RoutePreviewStats extends StatelessWidget {
  const _RoutePreviewStats({
    required this.distanceKm,
    required this.batteryAtArrivalPct,
    required this.stopsNeeded,
    required this.hasRoute,
  });
  final double distanceKm;
  final double batteryAtArrivalPct;
  final int    stopsNeeded;
  final bool   hasRoute; // true once origin + destination are both resolved

  Color _batColor(double pct) {
    if (pct >= 50) { return _emerald; }
    if (pct >= 20) { return Colors.orangeAccent; }
    return Colors.redAccent;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: hasRoute ? 1.0 : 0.38,
      duration: const Duration(milliseconds: 250),
      child: Container(
        // Explicit full-width so this block is always the same size as
        // the _BatterySlider container directly above it.
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: _bgCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _bgSurface),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'ROUTE PREVIEW',
              style: TextStyle(color: _textSec, fontSize: 11,
                  fontWeight: FontWeight.w600, letterSpacing: 0.6),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _StatChip(
                  icon:  Icons.route_rounded,
                  label: hasRoute
                      ? '${distanceKm.toStringAsFixed(1)} km'
                      : '– km',
                  color: _emerald,
                ),
                _StatChip(
                  icon:  Icons.battery_charging_full_rounded,
                  label: hasRoute
                      ? '${batteryAtArrivalPct.toStringAsFixed(0)}% ${AppStrings.arrival}'
                      : '–% ${AppStrings.arrival}',
                  color: hasRoute ? _batColor(batteryAtArrivalPct) : _textSec,
                ),
                _StatChip(
                  icon:  Icons.bolt,
                  label: hasRoute
                      ? '$stopsNeeded ${AppStrings.stops}'
                      : '– ${AppStrings.stops}',
                  color: hasRoute
                      ? (stopsNeeded == 0 ? _emerald : Colors.orangeAccent)
                      : _textSec,
                ),
              ],
            ),
            if (!hasRoute) ...[
              const SizedBox(height: 10),
              const Text(
                'Set start & destination to see EV stats',
                style: TextStyle(color: _textSec, fontSize: 11),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ── Stat chip (used by route preview) ────────────────────────────────────────
class _StatChip extends StatelessWidget {
  const _StatChip({required this.icon, required this.label, required this.color});
  final IconData icon;
  final String   label;
  final Color    color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: _bgSurface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withOpacity(0.35)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, color: color, size: 13),
        const SizedBox(width: 5),
        Text(label,
            style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600)),
      ]),
    );
  }
}

// ── Charging options list (chargers grouped into 50 km collapsible segments) ──
// Every charger on the route is a selectable block, but on a long trip that is a
// very long list — so blocks are grouped into 50 km segments, each a collapsible
// dropdown. A collapsed segment header already shows whether a recommended /
// ticked stop sits inside it (green ✓ + station name), so the driver knows which
// dropdown to open. Expanding shows the detailed blocks (with provider logos).
class _ChargingOptionsList extends StatelessWidget {
  const _ChargingOptionsList({
    required this.options,
    required this.selectedKeys,
    required this.arrivalPctFor,
    required this.onToggle,
  });
  final List<RouteChargerOption> options;
  final Set<String>              selectedKeys;
  final int Function(RouteChargerOption) arrivalPctFor;
  final void Function(String)            onToggle;

  static const double _segmentKm = 50.0;

  // Group the options into consecutive 50 km windows along the route, in order.
  List<({int startKm, List<RouteChargerOption> items})> get _segments {
    final byWindow = <int, List<RouteChargerOption>>{};
    for (final o in options) {
      final idx = o.alongKm ~/ _segmentKm;
      (byWindow[idx] ??= <RouteChargerOption>[]).add(o);
    }
    final keys = byWindow.keys.toList()..sort();
    return [
      for (final k in keys)
        (startKm: (k * _segmentKm).round(), items: byWindow[k]!),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final segments = _segments;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _bgCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _bgSurface),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            AppStrings.chargersOnRoute,
            style: const TextStyle(color: _textSec, fontSize: 11,
                fontWeight: FontWeight.w600, letterSpacing: 0.6),
          ),
          if (options.isEmpty) ...[
            const SizedBox(height: 12),
            Text(AppStrings.noChargersOnRoute,
                style: const TextStyle(color: _textSec, fontSize: 12)),
          ] else ...[
            const SizedBox(height: 4),
            Text(AppStrings.segmentsHint,
                style: const TextStyle(color: _textSec, fontSize: 11, height: 1.35)),
            const SizedBox(height: 14),
            for (int i = 0; i < segments.length; i++) ...[
              if (i > 0) const SizedBox(height: 8),
              _RouteSegmentTile(
                startKm:       segments[i].startKm,
                endKm:         segments[i].startKm + _segmentKm.round(),
                options:       segments[i].items,
                selectedKeys:  selectedKeys,
                arrivalPctFor: arrivalPctFor,
                onToggle:      onToggle,
              ),
            ],
          ],
        ],
      ),
    );
  }
}

// One 50 km segment: a tappable header that expands to the detailed charger
// blocks. The header surfaces the ticked stop(s) inside (green ✓ + name) while
// collapsed, so the recommended plan stays visible without opening anything.
class _RouteSegmentTile extends StatefulWidget {
  const _RouteSegmentTile({
    required this.startKm,
    required this.endKm,
    required this.options,
    required this.selectedKeys,
    required this.arrivalPctFor,
    required this.onToggle,
  });
  final int                      startKm, endKm;
  final List<RouteChargerOption> options;
  final Set<String>              selectedKeys;
  final int Function(RouteChargerOption) arrivalPctFor;
  final void Function(String)            onToggle;

  @override
  State<_RouteSegmentTile> createState() => _RouteSegmentTileState();
}

class _RouteSegmentTileState extends State<_RouteSegmentTile> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.options
        .where((o) => widget.selectedKeys.contains(o.locationKey))
        .toList();
    final hasSelected = selected.isNotEmpty;

    return Container(
      decoration: BoxDecoration(
        color: _bgSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: hasSelected ? _emerald.withOpacity(0.55) : Colors.transparent,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header — tap to expand / collapse.
          GestureDetector(
            onTap: () => setState(() => _expanded = !_expanded),
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(children: [
                AnimatedRotation(
                  turns: _expanded ? 0.25 : 0.0,
                  duration: const Duration(milliseconds: 180),
                  child: const Icon(Icons.chevron_right_rounded,
                      color: _textSec, size: 22),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        AppStrings.segmentKmRange(widget.startKm, widget.endKm),
                        style: const TextStyle(color: _textPri, fontSize: 14,
                            fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 2),
                      if (hasSelected)
                        Row(children: [
                          const Icon(Icons.check_circle_rounded,
                              color: _emerald, size: 13),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              selected.map((o) => o.title).join(', '),
                              style: const TextStyle(color: _emerald, fontSize: 11,
                                  fontWeight: FontWeight.w600),
                              maxLines: 1, overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ])
                      else
                        Text(AppStrings.chargersCount(widget.options.length),
                            style: const TextStyle(color: _textSec, fontSize: 11)),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                // Right badge: a green ✓N pill when a stop inside is ticked,
                // otherwise the charger count.
                if (hasSelected)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: _emerald,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.check_rounded, color: Colors.black, size: 12),
                      const SizedBox(width: 2),
                      Text('${selected.length}',
                          style: const TextStyle(color: Colors.black, fontSize: 11,
                              fontWeight: FontWeight.w700)),
                    ]),
                  )
                else
                  Text(AppStrings.chargersCount(widget.options.length),
                      style: const TextStyle(color: _textSec, fontSize: 11)),
              ]),
            ),
          ),
          // Expanded body — the detailed charger blocks for this segment.
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (int i = 0; i < widget.options.length; i++) ...[
                    if (i > 0)
                      _DistanceDivider(
                          km: widget.options[i].alongKm -
                              widget.options[i - 1].alongKm),
                    _OptionBlock(
                      index:      i + 1,
                      option:     widget.options[i],
                      selected:   widget.selectedKeys
                          .contains(widget.options[i].locationKey),
                      arrivalPct: widget.arrivalPctFor(widget.options[i]),
                      onToggle:   () =>
                          widget.onToggle(widget.options[i].locationKey),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// Centered "↓ NN km" gap label drawn between two consecutive blocks.
class _DistanceDivider extends StatelessWidget {
  const _DistanceDivider({required this.km});
  final double km;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(children: [
        const SizedBox(width: 10),
        Container(width: 1, height: 16, color: _bgSurface),
        const SizedBox(width: 12),
        const Icon(Icons.south_rounded, color: _textSec, size: 13),
        const SizedBox(width: 4),
        Text(AppStrings.kmLabel(km),
            style: const TextStyle(color: _textSec, fontSize: 11)),
      ]),
    );
  }
}

class _OptionBlock extends StatelessWidget {
  const _OptionBlock({
    required this.index,
    required this.option,
    required this.selected,
    required this.arrivalPct,
    required this.onToggle,
  });
  final int                index;
  final RouteChargerOption option;
  final bool               selected;
  final int                arrivalPct;
  final VoidCallback       onToggle;

  Color _batColor(int pct) {
    if (pct >= 50) { return _emerald; }
    if (pct >= 20) { return Colors.orangeAccent; }
    return Colors.redAccent;
  }

  void _showOppositeInfo(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AppStrings.wrap(AlertDialog(
        backgroundColor: _bgCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        content: Row(children: [
          const Icon(Icons.u_turn_left_rounded, color: Colors.amber, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Text(AppStrings.oppositeSideInfo,
                style: const TextStyle(color: _textPri, fontSize: 13, height: 1.35)),
          ),
        ]),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(AppStrings.gotIt,
                style: const TextStyle(color: _emerald, fontWeight: FontWeight.w600)),
          ),
        ],
      )),
    );
  }

  @override
  Widget build(BuildContext context) {
    final providerPowers = option.providerPowers;
    final connectors     = option.connectorTypes.join(', ');
    // Meta pieces, joined by "·" below. "N stations" only when several charger
    // units are merged into this one location block.
    final metaParts = <String>[
      if (connectors.isNotEmpty) connectors,
      if (option.stationCount > 1)
        AppStrings.stationsCount(option.stationCount),
      AppStrings.portsCount(option.chargerCount),
    ];
    // Live availability colour — green when any plug is free here, orange when
    // the whole block is currently busy (still shown, just flagged busy).
    final availColor =
        option.availableCount > 0 ? _emerald : Colors.orangeAccent;
    return GestureDetector(
      onTap: onToggle,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          // Sits inside a _bgSurface segment tile, so use the darker _bgCard for
          // an unticked block to keep the two layers visually distinct.
          color: selected ? _emerald.withOpacity(0.10) : _bgCard,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? _emerald.withOpacity(0.55) : Colors.transparent,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Tick box
            Container(
              width: 22, height: 22,
              margin: const EdgeInsets.only(top: 1),
              decoration: BoxDecoration(
                color: selected ? _emerald : Colors.transparent,
                borderRadius: BorderRadius.circular(7),
                border: Border.all(
                  color: selected ? _emerald : _textSec.withOpacity(0.6),
                  width: 1.5,
                ),
              ),
              child: selected
                  ? const Icon(Icons.check_rounded, color: Colors.black, size: 15)
                  : null,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Title row: city + recommended badge + info + DC/AC icon
                  Row(children: [
                    Flexible(
                      child: Text(option.title,
                          style: const TextStyle(
                              color: _textPri, fontSize: 14, fontWeight: FontWeight.w600),
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                    if (option.recommended) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: _emerald.withOpacity(0.18),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(AppStrings.recommendedBadge,
                            style: const TextStyle(
                                color: _emerald, fontSize: 9, fontWeight: FontWeight.w700)),
                      ),
                    ],
                    const Spacer(),
                    if (option.requiresUTurn)
                      GestureDetector(
                        onTap: () => _showOppositeInfo(context),
                        behavior: HitTestBehavior.opaque,
                        child: const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 4),
                          child: Icon(Icons.info_outline_rounded,
                              color: Colors.amber, size: 17),
                        ),
                      ),
                    const SizedBox(width: 2),
                    Icon(option.isDC ? Icons.bolt : Icons.battery_charging_full_rounded,
                        color: _emerald, size: 16),
                  ]),
                  // One line per provider at this block, with its power beside
                  // it — a range (e.g. "50–160 kW") when ratings differ.
                  if (providerPowers.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    for (final pp in providerPowers)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: Row(children: [
                          Flexible(
                            child: Text(pp.name,
                                style: const TextStyle(
                                    color: _textPri, fontSize: 12),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis),
                          ),
                          if (pp.power.isNotEmpty) ...[
                            const SizedBox(width: 6),
                            Text(pp.power,
                                style: const TextStyle(
                                    color: _emerald, fontSize: 12,
                                    fontWeight: FontWeight.w600)),
                          ],
                        ]),
                      ),
                  ],
                  const SizedBox(height: 4),
                  // Meta row: connectors · [N stations ·] N ports
                  // Station count only appears when several units are merged into
                  // this one location block; ports = total plugs across them.
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      for (int mi = 0; mi < metaParts.length; mi++) ...[
                        if (mi > 0)
                          Text('·',
                              style: TextStyle(
                                  color: _textSec.withOpacity(0.6), fontSize: 11)),
                        Text(metaParts[mi],
                            style: const TextStyle(color: _textSec, fontSize: 11)),
                      ],
                      Text('·',
                          style: TextStyle(
                              color: _textSec.withOpacity(0.6), fontSize: 11)),
                      Text(
                        AppStrings.plugsFree(
                            option.availableCount, option.chargerCount),
                        style: TextStyle(
                            color: availColor,
                            fontSize: 11,
                            fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(children: [
                    Icon(Icons.battery_charging_full_rounded,
                        color: _batColor(arrivalPct), size: 13),
                    const SizedBox(width: 4),
                    Text(AppStrings.onArrivalPct(arrivalPct),
                        style: TextStyle(
                            color: _batColor(arrivalPct),
                            fontSize: 11,
                            fontWeight: FontWeight.w600)),
                  ]),
                ],
              ),
            ),
            // Provider logo(s) on the right — which company operates this
            // charger. Each block is a single charger now, so this is normally
            // one logo (co-located providers are no longer merged).
            if (option.providers.isNotEmpty) ...[
              const SizedBox(width: 10),
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (final p in option.providers)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: ProviderLogo(provider: p),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ── Autocomplete place field ──────────────────────────────────────────────────
class _PlaceField extends StatefulWidget {
  const _PlaceField({
    required this.controller,
    required this.hint,
    required this.isResolved,
    required this.onPlaceSelected,
    this.searchBias,
  });
  final TextEditingController controller;
  final String hint;
  final bool isResolved;
  final void Function(PlacePrediction, LatLng?) onPlaceSelected;
  // Ranks predictions around a known point (the previous stop, or the driver).
  // Place search is no longer country-locked, so an unbiased query for a short
  // name would happily suggest the other side of Europe.
  final LatLng? searchBias;

  @override
  State<_PlaceField> createState() => _PlaceFieldState();
}

class _PlaceFieldState extends State<_PlaceField> {
  final _focus  = FocusNode();
  Timer? _timer;
  List<PlacePrediction> _suggestions = const [];

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) { setState(() => _suggestions = const []); }
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    _timer?.cancel();
    super.dispose();
  }

  void _onChanged(String q) {
    _timer?.cancel();
    if (q.trim().length < 2) { setState(() => _suggestions = const []); return; }
    _timer = Timer(const Duration(milliseconds: 400), () async {
      final r = await PlacesService.autocomplete(q, bias: widget.searchBias);
      if (mounted) { setState(() => _suggestions = r); }
    });
  }

  Future<void> _onSelect(PlacePrediction p) async {
    _focus.unfocus();
    setState(() => _suggestions = const []);
    final coords = await PlacesService.getCoordinates(p.placeId);
    widget.onPlaceSelected(p, coords);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Input
        Container(
          height: 48,
          decoration: BoxDecoration(
            color: _bgCard,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: widget.isResolved ? _emerald.withOpacity(0.5) : _bgSurface,
            ),
          ),
          child: Row(children: [
            const SizedBox(width: 12),
            Icon(
              widget.isResolved ? Icons.check_circle_rounded : Icons.location_on_outlined,
              color: widget.isResolved ? _emerald : _textSec,
              size: 18,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: widget.controller,
                focusNode:  _focus,
                onChanged:  _onChanged,
                style: const TextStyle(color: _textPri, fontSize: 14),
                decoration: InputDecoration(
                  hintText:  widget.hint,
                  hintStyle: const TextStyle(color: _textSec, fontSize: 14),
                  border:    InputBorder.none,
                  isDense:   true,
                ),
              ),
            ),
            if (widget.controller.text.isNotEmpty)
              GestureDetector(
                onTap: () {
                  widget.controller.clear();
                  setState(() => _suggestions = const []);
                  widget.onPlaceSelected(
                    const PlacePrediction(
                        placeId: '', description: '', mainText: '', secondaryText: ''),
                    null,
                  );
                },
                child: const Padding(
                  padding: EdgeInsets.only(right: 10),
                  child: Icon(Icons.close_rounded, color: _textSec, size: 16),
                ),
              ),
          ]),
        ),
        // Suggestions dropdown
        if (_suggestions.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(top: 3),
            decoration: BoxDecoration(
              color: _bgCard,
              borderRadius: BorderRadius.circular(12),
              boxShadow: const [
                BoxShadow(color: Colors.black45, blurRadius: 14, offset: Offset(0, 4)),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: _suggestions.asMap().entries.map((e) {
                final isLast = e.key == _suggestions.length - 1;
                final p      = e.value;
                return GestureDetector(
                  onTap:    () => _onSelect(p),
                  behavior: HitTestBehavior.opaque,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                    decoration: BoxDecoration(
                      border: isLast ? null : const Border(
                        bottom: BorderSide(color: _bgSurface, width: 0.5),
                      ),
                    ),
                    child: Row(children: [
                      const Icon(Icons.location_on_outlined, color: _emerald, size: 16),
                      const SizedBox(width: 10),
                      Expanded(child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(p.mainText,
                              style: const TextStyle(
                                  color: _textPri, fontSize: 13, fontWeight: FontWeight.w500),
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          if (p.secondaryText.isNotEmpty)
                            Text(p.secondaryText,
                                style: const TextStyle(color: _textSec, fontSize: 11),
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                        ],
                      )),
                    ]),
                  ),
                );
              }).toList(),
            ),
          ),
      ],
    );
  }
}

// ── Bottom action bar ─────────────────────────────────────────────────────────
class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.resolvedCount,
    required this.total,
    required this.isPlanning,
    this.onPlanRoute,
  });
  final int           resolvedCount, total;
  final bool          isPlanning;
  final VoidCallback? onPlanRoute;

  @override
  Widget build(BuildContext context) {
    final ready = resolvedCount == total && !isPlanning;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
      color: _bgCard,
      child: GestureDetector(
        onTap: ready ? onPlanRoute : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          height: 52,
          decoration: BoxDecoration(
            color: ready ? _emerald : _bgSurface,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Center(
            child: isPlanning
                ? const SizedBox(
                    width: 22, height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                  )
                : Text(
                    resolvedCount == total
                        ? '${AppStrings.openInGoogleMaps}  →'
                        : 'Set all stops  ($resolvedCount / $total)',
                    style: TextStyle(
                      color: ready ? Colors.black : _textSec,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}
