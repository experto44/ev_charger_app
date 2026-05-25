import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
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

// ── Battery colour helper (shared by route summary widgets) ───────────────────
Color _batColor(double pct) {
  if (pct >= 50) { return _emerald; }
  if (pct >= 20) { return Colors.orangeAccent; }
  return Colors.redAccent;
}

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
  static const _tbilisi = LatLng(41.7151, 44.8271);

  final _searchCtrl  = TextEditingController();
  final _searchFocus = FocusNode();
  final _mapCtrl     = MapController();

  bool  _filterDC    = false;
  bool  _filterAvail = false;

  LatLng?               _userPos;
  List<Station>         _stations    = const [];
  bool                  _loading     = true;
  List<PlacePrediction> _suggestions = const [];
  Timer?                _debounce;
  EVRouteResult?        _routeResult;

  @override
  void initState() {
    super.initState();
    _initLocation();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadStations());
  }

  Future<void> _loadStations() async {
    try {
      final raw  = await DefaultAssetBundle.of(context).loadString('assets/data/chargers.json');
      final list = (jsonDecode(raw) as List)
          .map((e) => Station.fromJson(e as Map<String, dynamic>))
          .toList();
      if (!mounted) { return; }
      setState(() { _stations = list; _loading = false; });
    } catch (_) {
      if (!mounted) { return; }
      setState(() => _loading = false);
    }
  }

  Future<void> _initLocation() async {
    try {
      LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) { return; }
      final pos    = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 10),
        ),
      );
      final latlng = LatLng(pos.latitude, pos.longitude);
      if (!mounted) { return; }
      setState(() => _userPos = latlng);
      _mapCtrl.move(latlng, 14);
    } catch (_) {}
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _searchFocus.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _clearRoute() => setState(() => _routeResult = null);

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
      if (_filterDC    && !s.isDC)          { return false; }
      if (_filterAvail && s.available == 0) { return false; }
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
            options: const MapOptions(initialCenter: _tbilisi, initialZoom: 13),
            children: [
              TileLayer(
                urlTemplate: 'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png',
                subdomains: const ['a', 'b', 'c', 'd'],
                userAgentPackageName: 'com.example.ev_charger_app',
                retinaMode: false,
                maxNativeZoom: 18,
                keepBuffer: 0,
                panBuffer: 0,
              ),
              // Route polyline
              if (_routeResult != null)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points:      _routeResult!.polylinePoints,
                      color:       _emerald,
                      strokeWidth: 4.5,
                    ),
                  ],
                ),
              // Station dots
              MarkerLayer(
                markers: stations.map((s) => Marker(
                  point:  LatLng(s.lat, s.lng),
                  width:  36,
                  height: 36,
                  child:  Container(
                    decoration: BoxDecoration(
                      color: s.available > 0 ? _emerald : Colors.orangeAccent,
                      shape: BoxShape.circle,
                      boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 6)],
                    ),
                    child: const Icon(Icons.bolt, color: Colors.black, size: 20),
                  ),
                )).toList(),
              ),
              // Charging-stop markers (route active)
              if (_routeResult != null && _routeResult!.chargingStops.isNotEmpty)
                MarkerLayer(
                  markers: _routeResult!.chargingStops.map((stop) => Marker(
                    point:  LatLng(stop.station.lat, stop.station.lng),
                    width:  46,
                    height: 46,
                    child:  Container(
                      decoration: BoxDecoration(
                        color: Colors.orangeAccent,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 3),
                        boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 8)],
                      ),
                      child: const Icon(Icons.bolt, color: Colors.black, size: 22),
                    ),
                  )).toList(),
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
                    filterDC:    _filterDC,
                    filterAvail: _filterAvail,
                    onDC:        (v) => setState(() => _filterDC    = v),
                    onAvail:     (v) => setState(() => _filterAvail = v),
                  ),
                ],
              ),
            ),
          ),

          // ── Route planner FAB ─────────────────────────────────────────────
          Positioned(
            right:  16,
            bottom: 316,
            child: GestureDetector(
              onTap: () async {
                final result = await Navigator.push<EVRouteResult>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => RoutePlannerScreen(stations: _stations),
                  ),
                );
                if (result != null && mounted) {
                  setState(() => _routeResult = result);
                  if (result.polylinePoints.isNotEmpty) {
                    final mid = result.polylinePoints[result.polylinePoints.length ~/ 2];
                    _mapCtrl.move(mid, 11);
                  }
                }
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 48, height: 48,
                decoration: BoxDecoration(
                  color: _routeResult != null ? _emerald : _bgCard,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: _routeResult != null ? _emerald : _bgSurface,
                  ),
                  boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 10, offset: Offset(0, 4))],
                ),
                child: Icon(
                  Icons.alt_route_rounded,
                  color: _routeResult != null ? Colors.black : _textSec,
                  size: 22,
                ),
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

          // ── Bottom panel: route summary OR station carousel ───────────────
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
                : _routeResult != null
                    ? _RouteSummaryPanel(result: _routeResult!, onClear: _clearRoute)
                    : _StationCarousel(stations: stations),
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
    required this.filterDC, required this.filterAvail,
    required this.onDC,     required this.onAvail,
  });
  final bool filterDC, filterAvail;
  final ValueChanged<bool> onDC, onAvail;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 36,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          _Chip(label: '⚡ Fast DC',   active: filterDC,    onTap: () => onDC(!filterDC)),
          const SizedBox(width: 8),
          _Chip(label: '🟢 Available', active: filterAvail, onTap: () => onAvail(!filterAvail)),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.active, required this.onTap});
  final String   label;
  final bool     active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
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
        child: Text(
          label,
          style: TextStyle(
            color: active ? Colors.black : _textSec,
            fontSize: 13, fontWeight: FontWeight.w600,
          ),
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

// ── Station carousel ──────────────────────────────────────────────────────────
class _StationCarousel extends StatelessWidget {
  const _StationCarousel({required this.stations});
  final List<Station> stations;

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
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end:   Alignment.topCenter,
          colors: [_bgDark, Colors.transparent],
          stops:  [0.6, 1.0],
        ),
      ),
      padding: const EdgeInsets.only(top: 32, bottom: 24),
      child: SizedBox(
        height: 195,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: stations.length,
          separatorBuilder: (_, __) => const SizedBox(width: 12),
          itemBuilder: (_, i) => _StationCard(stations[i]),
        ),
      ),
    );
  }
}

// ── Station card ──────────────────────────────────────────────────────────────
class _StationCard extends StatelessWidget {
  const _StationCard(this.s);
  final Station s;

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
            const Icon(Icons.near_me_outlined, color: _textSec, size: 13),
            const SizedBox(width: 4),
            Text(s.distance, style: const TextStyle(color: _textSec, fontSize: 12)),
            const Spacer(),
            const Icon(Icons.bolt, color: _emerald, size: 16),
          ]),
          const SizedBox(height: 10),
          GestureDetector(
            onTap: () => _navigate(s.lat, s.lng),
            child: Container(
              height: 32,
              decoration: BoxDecoration(color: _emerald, borderRadius: BorderRadius.circular(9)),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.navigation_rounded, color: Colors.black, size: 14),
                  SizedBox(width: 5),
                  Text('Navigate',
                      style: TextStyle(color: Colors.black, fontSize: 12, fontWeight: FontWeight.w700)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Route summary panel ───────────────────────────────────────────────────────
class _RouteSummaryPanel extends StatelessWidget {
  const _RouteSummaryPanel({required this.result, required this.onClear});
  final EVRouteResult result;
  final VoidCallback  onClear;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin:  Alignment.bottomCenter,
          end:    Alignment.topCenter,
          colors: [_bgDark, Colors.transparent],
          stops:  [0.65, 1.0],
        ),
      ),
      padding: const EdgeInsets.only(top: 32, bottom: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Stat chips row
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                _StatChip(
                  icon:  Icons.route_rounded,
                  label: '${result.totalDistanceKm.toStringAsFixed(1)} km',
                  color: _emerald,
                ),
                const SizedBox(width: 8),
                _StatChip(
                  icon:  Icons.battery_charging_full_rounded,
                  label: '${result.batteryAtArrivalPct.toStringAsFixed(0)}% arrival',
                  color: _batColor(result.batteryAtArrivalPct),
                ),
                const SizedBox(width: 8),
                _StatChip(
                  icon:  Icons.bolt,
                  label: '${result.chargingStops.length} stop${result.chargingStops.length == 1 ? '' : 's'}',
                  color: Colors.orangeAccent,
                ),
                const Spacer(),
                GestureDetector(
                  onTap: onClear,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: _bgCard,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: _bgSurface),
                    ),
                    child: const Text('Clear',
                        style: TextStyle(color: _textSec, fontSize: 12)),
                  ),
                ),
              ],
            ),
          ),
          // Charging stop tiles
          if (result.chargingStops.isNotEmpty) ...[
            const SizedBox(height: 10),
            SizedBox(
              height: 90,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: result.chargingStops.length,
                separatorBuilder: (_, __) => const SizedBox(width: 12),
                itemBuilder: (_, i) => _ChargingStopTile(result.chargingStops[i]),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

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
        color: _bgCard,
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

class _ChargingStopTile extends StatelessWidget {
  const _ChargingStopTile(this.stop);
  final ChargingStop stop;

  String _fmtCharge(double h) {
    if (h < 1) { return '~${(h * 60).round()} min charge'; }
    return '~${h.toStringAsFixed(1)} h charge';
  }

  @override
  Widget build(BuildContext context) {
    final s = stop.station;
    return Container(
      width: 162,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: _bgCard,
        borderRadius: BorderRadius.circular(12),
        boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 8, offset: Offset(0, 3))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(s.name,
              style: const TextStyle(color: _textPri, fontSize: 12, fontWeight: FontWeight.bold),
              maxLines: 1, overflow: TextOverflow.ellipsis),
          Text(s.location, style: const TextStyle(color: _textSec, fontSize: 10)),
          const Spacer(),
          Row(children: [
            Icon(Icons.battery_charging_full_rounded,
                color: _batColor(stop.batteryOnArrivalPct), size: 12),
            const SizedBox(width: 3),
            Text('${stop.batteryOnArrivalPct.toStringAsFixed(0)}% on arrival',
                style: TextStyle(
                    color: _batColor(stop.batteryOnArrivalPct),
                    fontSize: 10)),
          ]),
          if (stop.chargeHours != null)
            Text(
              _fmtCharge(stop.chargeHours!),
              style: const TextStyle(color: _textSec, fontSize: 10),
            )
          else
            const Text('Fast DC charge', style: TextStyle(color: _emerald, fontSize: 10)),
        ],
      ),
    );
  }
}
