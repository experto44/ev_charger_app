import 'dart:async';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import 'places_service.dart';
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
  final _stops = [RouteStop(), RouteStop()];
  double _batteryPct  = 80.0;
  bool   _isPlanning  = false;

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

  Future<void> _planRoute() async {
    setState(() => _isPlanning = true);
    final waypoints = _stops.map((s) => s.coords!).toList();
    final result = await RoutingService.planRoute(
      waypoints:         waypoints,
      currentBatteryPct: _batteryPct,
      stations:          widget.stations,
    );
    if (!mounted) { return; }
    setState(() => _isPlanning = false);
    if (result == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: _bgCard,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        content: const Text(
          'Could not calculate route. Check your connection.',
          style: TextStyle(color: _textPri),
        ),
      ));
      return;
    }
    Navigator.pop(context, result);
  }

  @override
  Widget build(BuildContext context) {
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
                      index:    i,
                      total:    _stops.length,
                      stop:     _stops[i],
                      onRemove: _stops.length > 2 ? () => _removeStop(i) : null,
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
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
          _BottomBar(
            resolvedCount: _resolvedCount,
            total:         _stops.length,
            isPlanning:    _isPlanning,
            onPlanRoute:   _resolvedCount == _stops.length ? _planRoute : null,
          ),
        ],
      ),
    );
  }
}

// ── Stop row ──────────────────────────────────────────────────────────────────
class _StopRow extends StatelessWidget {
  const _StopRow({
    required this.index, required this.total, required this.stop,
    required this.onPlaceSelected, this.onRemove,
  });
  final int index, total;
  final RouteStop stop;
  final void Function(PlacePrediction, LatLng?) onPlaceSelected;
  final VoidCallback? onRemove;

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
  final int          resolvedCount, total;
  final bool         isPlanning;
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
                        ? 'Plan Route  →'
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
