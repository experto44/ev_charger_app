import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'places_service.dart';
import 'profile_screen.dart';
import 'routing_service.dart';

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
  double _batteryPct = 80.0;
  double _maxRangeKm = 300.0;
  bool   _isPlanning = false;

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
  }

  Future<void> _loadMaxRange() async {
    final prefs = await SharedPreferences.getInstance();
    final val   = double.tryParse(prefs.getString(kMaxRange) ?? '') ?? 300.0;
    if (mounted) { setState(() => _maxRangeKm = val); }
  }

  @override
  void dispose() {
    for (final s in _stops) { s.dispose(); }
    super.dispose();
  }

  void _addStop() {
    if (_stops.length >= 5) { return; }
    setState(() => _stops.insert(_stops.length - 1, RouteStop()));
  }

  void _removeStop(int i) {
    setState(() {
      _stops[i].dispose();
      _stops.removeAt(i);
    });
  }

  int get _resolvedCount => _stops.where((s) => s.coords != null).length;

  bool get _canPreview =>
      _stops.first.coords != null && _stops.last.coords != null;

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

  // ── Linear progress of a point along origin→destination (0.0–1.0) ─────────
  // Used to sort all waypoints (manual + charging) into the correct visit order
  // before handing them to the Google Maps URL.
  static double _linearProgress(LatLng pt, LatLng origin, LatLng dest) {
    final total = _haversine(origin, dest);
    if (total == 0) { return 0; }
    return (_haversine(origin, pt) / total).clamp(0.0, 1.0);
  }

  // ── Find N charging-station waypoints evenly spaced along origin→dest ──────
  // Interpolates N intermediate positions along the straight-line route and
  // picks the nearest *available* station to each position (each station can
  // only be picked once).  Returns them in geographic order (already sorted
  // by interpolation parameter t, so no extra sort needed here).
  List<Station> _chargingStationWaypoints(int count) {
    if (count <= 0) { return <Station>[]; }
    final origin = _stops.first.coords;
    final dest   = _stops.last.coords;
    if (origin == null || dest == null) { return <Station>[]; }

    final available = widget.stations
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
  // Waypoint build order:
  //   1. Manual intermediate stops the user added (RouteStop entries 1..n-2)
  //   2. EV charging stops derived from _evPreview (nearest available station
  //      to each evenly-spaced position along the route)
  // All waypoints are sorted by their linear progress from origin→destination
  // so Google Maps always receives them in the correct geographic visit order.
  Future<void> _planRoute() async {
    setState(() => _isPlanning = true);
    try {
      final origin      = _stops.first.coords!;
      final destination = _stops.last.coords!;

      String urlStr =
          'https://www.google.com/maps/dir/?api=1'
          '&origin=${origin.latitude},${origin.longitude}'
          '&destination=${destination.latitude},${destination.longitude}'
          '&travelmode=driving';

      // ── Collect every waypoint with its route-progress fraction ───────────
      // Using a positional record (progress, coord-string) for lightweight sorting.
      final wps = <(double, String)>[];

      // 1. Manual intermediate stops (user-added via the +/stop UI)
      if (_stops.length > 2) {
        for (final s in _stops.sublist(1, _stops.length - 1)) {
          if (s.coords == null) { continue; }
          wps.add((
            _linearProgress(s.coords!, origin, destination),
            '${s.coords!.latitude},${s.coords!.longitude}',
          ));
        }
      }

      // 2. EV charging-station waypoints from the route preview
      final chargingStops = _chargingStationWaypoints(_evPreview.stopsNeeded);
      for (final s in chargingStops) {
        final ll = LatLng(s.lat, s.lng);
        wps.add((
          _linearProgress(ll, origin, destination),
          '${s.lat},${s.lng}',
        ));
      }

      // Sort by progress so the order is always origin→…→destination
      if (wps.isNotEmpty) {
        wps.sort((a, b) => a.$1.compareTo(b.$1));
        urlStr += '&waypoints=${wps.map((w) => w.$2).join('|')}';
      }

      final uri = Uri.parse(urlStr);
      if (!mounted) { return; }

      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        if (mounted) { Navigator.pop(context); }
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
        title: const Text(
          'Route Planner',
          style: TextStyle(color: _textPri, fontSize: 17, fontWeight: FontWeight.w600),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
              child: Column(
                children: [
                  // Stop rows
                  for (int i = 0; i < _stops.length; i++) ...[
                    _StopRow(
                      index:        i,
                      total:        _stops.length,
                      stop:         _stops[i],
                      onRemove:     _stops.length > 2 ? () => _removeStop(i) : null,
                      onMyLocation: i == 0 ? _fillMyLocation : null,
                      onPlaceSelected: (pred, coords) => setState(() {
                        _stops[i].coords = coords;
                        _stops[i].controller.text = pred.description;
                      }),
                    ),
                    if (i < _stops.length - 1)
                      _StopConnector(
                        canAdd: i == 0 && _stops.length < 5,
                        onAdd:  _addStop,
                      ),
                  ],
                  const SizedBox(height: 28),
                  // Battery slider
                  _BatterySlider(
                    value:     _batteryPct,
                    onChanged: (v) => setState(() => _batteryPct = v),
                  ),
                  const SizedBox(height: 12),
                  // Live EV route preview — reactive to slider changes
                  _RoutePreviewStats(
                    distanceKm:          _totalDistanceKm,
                    batteryAtArrivalPct: preview.batteryAtArrivalPct,
                    stopsNeeded:         preview.stopsNeeded,
                    hasRoute:            _canPreview,
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
          _BottomBar(
            resolvedCount: _resolvedCount,
            total:         _stops.length,
            isPlanning:    _isPlanning,
            onPlanRoute:   allResolved ? _planRoute : null,
          ),
        ],
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
  });
  final int index, total;
  final RouteStop stop;
  final void Function(PlacePrediction, LatLng?) onPlaceSelected;
  final VoidCallback? onRemove;
  final VoidCallback? onMyLocation; // shown only for index == 0

  String get _label {
    if (index == 0)         { return 'Start'; }
    if (index == total - 1) { return 'End'; }
    return 'Stop $index';
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
      ],
    );
  }
}

// ── Connector line between stops ──────────────────────────────────────────────
class _StopConnector extends StatelessWidget {
  const _StopConnector({required this.canAdd, required this.onAdd});
  final bool canAdd;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 5),
      child: Row(
        children: [
          Column(children: [
            for (int i = 0; i < 3; i++) ...[
              Container(width: 2, height: 5, color: _bgSurface),
              const SizedBox(height: 3),
            ],
          ]),
          const SizedBox(width: 24),
          if (canAdd)
            GestureDetector(
              onTap: onAdd,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: _bgCard,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: _bgSurface),
                ),
                child: const Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.add_rounded, color: _textSec, size: 14),
                  SizedBox(width: 4),
                  Text('Add stop', style: TextStyle(color: _textSec, fontSize: 12)),
                ]),
              ),
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
            const Text(
              'CURRENT BATTERY',
              style: TextStyle(color: _textSec, fontSize: 11,
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
                      ? '${batteryAtArrivalPct.toStringAsFixed(0)}% arrival'
                      : '–% arrival',
                  color: hasRoute ? _batColor(batteryAtArrivalPct) : _textSec,
                ),
                _StatChip(
                  icon:  Icons.bolt,
                  label: hasRoute
                      ? '$stopsNeeded stop${stopsNeeded == 1 ? '' : 's'}'
                      : '– stops',
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

// ── Autocomplete place field ──────────────────────────────────────────────────
class _PlaceField extends StatefulWidget {
  const _PlaceField({
    required this.controller,
    required this.hint,
    required this.isResolved,
    required this.onPlaceSelected,
  });
  final TextEditingController controller;
  final String hint;
  final bool isResolved;
  final void Function(PlacePrediction, LatLng?) onPlaceSelected;

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
      final r = await PlacesService.autocomplete(q);
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
                        ? 'Open in Google Maps  →'
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
