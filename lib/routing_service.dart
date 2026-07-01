import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'profile_screen.dart';

const _kApiKey = 'AIzaSyAF1rz6kk4MpMaHwzCmdmepSJlg8GwcS78';

// ── Road side ───────────────────────────────────────────────────────────────
// Which carriageway a charger sits on, encoded in the station name. Georgian
// highway chargers are named per direction: "…Right"/"…მარჯვენა" for one side
// and "…Left"/"…მარცხენა" for the other. `unknown` = the name carries no side
// suffix, so the charger is treated normally (no side preference, no warning).
enum RoadSide { left, right, unknown }

/// Parses the carriageway side from a station name. Matches a trailing
/// "left"/"right" (English, case-insensitive) or "მარცხენა"/"მარჯვენა"
/// (Georgian: left/right) at the end of the name.
RoadSide parseSideFromName(String name) {
  final n = name.trim().toLowerCase();
  if (n.endsWith('მარჯვენა')) { return RoadSide.right; } // right
  if (n.endsWith('მარცხენა')) { return RoadSide.left;  } // left
  if (n.endsWith('right'))    { return RoadSide.right; }
  if (n.endsWith('left'))     { return RoadSide.left;  }
  return RoadSide.unknown;
}

// ── Connector port (per-plug live status) ─────────────────────────────────────
// One physical connector at a station, with its live status so the detail sheet
// can colour each plug (free/busy/out) and show how long a busy one has charged.
class ConnectorPort {
  const ConnectorPort(
      {required this.type, required this.status, this.since, this.price = ''});

  final String    type;    // canonical chip label, e.g. "CCS2", "GB/T", "Type 2"
  final String    status;  // 'free' | 'busy' | 'out'
  final DateTime? since;    // UTC session start (busy plugs only); null otherwise
  final String    price;   // per-plug price, e.g. "1.00 ₾/kWh" ('' if not published)

  bool get isFree => status == 'free';
  bool get isBusy => status == 'busy';

  factory ConnectorPort.fromJson(Map<String, dynamic> j) => ConnectorPort(
        type:   (j['type'] as String?)?.trim().isNotEmpty == true
            ? (j['type'] as String).trim()
            : '—',
        status: j['status'] as String? ?? 'free',
        since:  j['since'] is String ? DateTime.tryParse(j['since'] as String) : null,
        price:  (j['price'] as String?)?.trim() ?? '',
      );
}

// ── Station (public model shared across screens) ──────────────────────────────
class Station {
  const Station({
    required this.name,
    required this.location,
    required this.available,
    required this.lat,
    required this.lng,
    required this.isDC,
    required this.kw,
    required this.price,
    this.id          = '',
    this.total       = 0,
    this.distance    = '',
    this.provider    = '',
    this.lastUpdated = '',
    this.connectors  = const [],
    this.ports       = const [],
    this.country     = '',
  });

  /// Handles both the production format (available_spots / type / power / city)
  /// and the legacy format (available / isDC / kw / location).
  factory Station.fromJson(Map<String, dynamic> j) {
    if (j.containsKey('available_spots')) {
      // Production schema
      final spots = j['available_spots'] as String; // "4 available"
      final power = j['power']           as String; // "150 kW"
      final isDC  = (j['type'] as String) == 'Fast DC';
      final declared = (j['connectors'] as List<dynamic>? ?? [])
                         .map((e) => e as String)
                         .toList();
      // Some providers (e.g. E-Space) don't publish a connector list. Infer a
      // sensible default from the charger type so the connector-type filter
      // applies consistently across every provider (DC fast → CCS2 + CHAdeMO,
      // AC → Type 2). Providers that do publish connectors keep their own data.
      final connectors = declared.isNotEmpty
          ? declared
          : (isDC ? const ['CCS2', 'CHAdeMO'] : const ['Type 2']);
      final available = int.tryParse(spots.split(' ').first) ?? 0;
      final ports = (j['ports'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(ConnectorPort.fromJson)
          .toList();
      return Station(
        id:          j['id']           as String? ?? '',
        name:        j['name']         as String,
        location:    j['city']         as String,
        available:   available,
        // Total plugs at the location; falls back to the available count for
        // providers that don't publish a total (keeps "x of x").
        total:       (j['total_spots'] as num?)?.toInt() ?? available,
        lat:         (j['lat']         as num).toDouble(),
        lng:         (j['lng']         as num).toDouble(),
        isDC:        isDC,
        kw:          int.tryParse(power.split(' ').first) ?? 0,
        price:       j['price']        as String,
        provider:    j['provider']     as String? ?? '',
        lastUpdated: j['last_updated'] as String? ?? '',
        connectors:  connectors,
        ports:       ports,
        country:     j['country']      as String? ?? '',
      );
    }
    // Legacy schema
    return Station(
      id:          j['id']           as String? ?? '',
      name:        j['name']         as String,
      location:    j['location']     as String,
      available:   j['available']    as int,
      lat:         (j['lat']         as num).toDouble(),
      lng:         (j['lng']         as num).toDouble(),
      isDC:        j['isDC']         as bool,
      kw:          j['kw']           as int,
      price:       j['price']        as String,
      distance:    j['distance']     as String? ?? '',
      lastUpdated: j['last_updated'] as String? ?? '',
    );
  }

  final String id;             // stable unique id, e.g. "martev_98" ('' if absent)
  final String name, location, price;
  final String distance;       // empty for production-schema entries
  final String provider;
  final String lastUpdated;    // ISO date or human string; empty if not present
  final int    available, kw;
  final int    total;            // total plugs/ports at the location
  final double lat, lng;
  final bool   isDC;
  final List<String> connectors; // e.g. ["CCS2", "CHAdeMO"]
  final List<ConnectorPort> ports; // per-plug live status (empty if not published)
  final String country;          // country name for OCM stations ('' = derive from coords)

  /// Copy carrying a formatted [distance] label (e.g. "2.3 km"). Used by the
  /// home carousel to stamp each station's distance from the user before display.
  Station withDistance(String d) => Station(
        name: name, location: location, available: available, lat: lat, lng: lng,
        isDC: isDC, kw: kw, price: price, id: id, total: total, distance: d,
        provider: provider, lastUpdated: lastUpdated, connectors: connectors,
        ports: ports, country: country,
      );
}

// ── Route models ──────────────────────────────────────────────────────────────
class ChargingStop {
  const ChargingStop({
    required this.station,
    required this.batteryOnArrivalPct,
    required this.distanceFromStartKm,
    this.chargeHours,
    this.side          = RoadSide.unknown,
    this.requiresUTurn = false,
  });
  final Station station;
  final double  batteryOnArrivalPct;
  final double  distanceFromStartKm;
  final double? chargeHours; // null = DC fast charge
  final RoadSide side;       // carriageway parsed from the station name
  final bool requiresUTurn;  // chosen charger sits on the opposite carriageway
}

// ── Selectable charger option (one block in the planner list) ─────────────────
// A place along the route where the driver may stop. Co-located chargers (within
// 200 m, possibly different providers) are merged into a single option so the
// list shows one block per place. Battery-on-arrival is NOT stored here: it
// depends on which options the driver has ticked, so the UI computes it live.
class RouteChargerOption {
  const RouteChargerOption({
    required this.location,
    required this.stations,
    required this.alongKm,
    required this.detourKm,
    required this.side,
    required this.requiresUTurn,
    this.recommended = false,
  });

  final LatLng        location;   // representative coordinate (first charger)
  final List<Station> stations;   // every charger merged into this block (≥1)
  final double        alongKm;    // distance along the route to this block
  final double        detourKm;   // how far off the road the block sits
  final RoadSide      side;       // carriageway the block sits on
  final bool          requiresUTurn; // all chargers are on the opposite side
  final bool          recommended;   // part of the minimal recommended plan

  /// Heading shown in bold — the city/area, falling back to the charger name.
  String get title => stations.first.location.trim().isNotEmpty
      ? stations.first.location.trim()
      : stations.first.name;

  /// Distinct provider labels present at this block (in first-seen order).
  List<String> get providers {
    final seen = <String>{};
    final out  = <String>[];
    for (final s in stations) {
      final p = s.provider.trim();
      if (p.isEmpty || !seen.add(p.toLowerCase())) { continue; }
      out.add(p);
    }
    return out;
  }

  /// Distinct connector types across every charger in the block.
  List<String> get connectorTypes {
    final seen = <String>{};
    final out  = <String>[];
    for (final s in stations) {
      for (final c in s.connectors) {
        final t = c.trim();
        if (t.isEmpty || !seen.add(t.toLowerCase())) { continue; }
        out.add(t);
      }
    }
    return out;
  }

  int  get chargerCount   => stations.fold(0, (n, s) => n + (s.total > 0 ? s.total : 1));
  int  get availableCount => stations.fold(0, (n, s) => n + s.available);
  bool get isDC           => stations.any((s) => s.isDC);

  /// Stable key used by the UI to track which options are ticked across rebuilds.
  String get locationKey =>
      '${location.latitude.toStringAsFixed(5)},${location.longitude.toStringAsFixed(5)}';
}

class EVRouteResult {
  const EVRouteResult({
    required this.polylinePoints,
    required this.totalDistanceKm,
    required this.batteryAtArrivalPct,
    required this.chargingStops,
    required this.options,
    required this.effectiveRangeKm,
    required this.maxRangeKm,
  });
  final List<LatLng>       polylinePoints;
  final double             totalDistanceKm;
  final double             batteryAtArrivalPct;
  final List<ChargingStop> chargingStops;          // minimal greedy plan
  final List<RouteChargerOption> options;          // every selectable block
  final double             effectiveRangeKm;
  final double             maxRangeKm;
}

// ── Routing service ───────────────────────────────────────────────────────────
class RoutingService {
  static const _directionsUrl =
      'https://maps.googleapis.com/maps/api/directions/json';

  /// Plans an EV route: calls Directions API, decodes polyline, runs EV math.
  static Future<EVRouteResult?> planRoute({
    required List<LatLng>  waypoints,
    required double        currentBatteryPct,
    required List<Station> stations,
  }) async {
    if (waypoints.length < 2) { return null; }

    // Load driver's max range from SharedPreferences
    final prefs      = await SharedPreferences.getInstance();
    final maxRangeKm = double.tryParse(prefs.getString(kMaxRange) ?? '') ?? 300.0;
    final effectiveKm = maxRangeKm * 0.90; // 90 % usable
    final reserveKm   = maxRangeKm * 0.10; // 10 % safety reserve

    // Build Directions API params
    final mid = waypoints.sublist(1, waypoints.length - 1);
    final params = <String, String>{
      'origin':      '${waypoints.first.latitude},${waypoints.first.longitude}',
      'destination': '${waypoints.last.latitude},${waypoints.last.longitude}',
      'mode':        'driving',
      'key':         _kApiKey,
    };
    if (mid.isNotEmpty) {
      params['waypoints'] =
          mid.map((p) => '${p.latitude},${p.longitude}').join('|');
    }

    try {
      final uri = Uri.parse(_directionsUrl).replace(queryParameters: params);
      final res = await http.get(uri).timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) { return null; }
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      if (body['status'] != 'OK') { return null; }

      final routes = body['routes'] as List;
      if (routes.isEmpty) { return null; }
      final route = routes.first as Map<String, dynamic>;

      // Decode polyline
      final pts = _decodePolyline(
          route['overview_polyline']['points'] as String);

      // Total distance from leg metadata (more accurate than polyline)
      double totalDistKm = 0;
      for (final leg in route['legs'] as List) {
        totalDistKm +=
            ((leg as Map<String, dynamic>)['distance']['value'] as int) / 1000.0;
      }

      // ── Cumulative along-route distance for every polyline point ───────────
      final cum = List<double>.filled(pts.length, 0.0);
      for (int i = 1; i < pts.length; i++) {
        cum[i] = cum[i - 1] + _haversine(pts[i - 1], pts[i]);
      }
      final routeKm = pts.isEmpty ? totalDistKm : cum.last;

      // ── Project every available station onto the route polyline ────────────
      // detourKm = how far the station sits off the road; alongKm = how far
      // along the route its closest point lies. Picking chargers by minimal
      // detour + strictly-ahead progress keeps stops ON the highway corridor
      // and never routes the driver backward or deep into another region.
      final projected = <_StationProjection>[];
      for (final s in stations) {
        if (s.available == 0) { continue; }
        final sp = LatLng(s.lat, s.lng);
        double bestDist = double.infinity, bestAlong = 0;
        for (int i = 0; i < pts.length - 1; i++) {
          final r = _projectToSegment(sp, pts[i], pts[i + 1]);
          if (r[0] < bestDist) {
            bestDist  = r[0];
            bestAlong = cum[i] + r[1] * (cum[i + 1] - cum[i]);
          }
        }
        projected.add(_StationProjection(s, bestDist, bestAlong));
      }

      // ── Greedy EV planning along the corridor ──────────────────────────────
      const corridorKm = 8.0;   // a charger counts as "on the route" within this
      final stops      = <ChargingStop>[];
      double coveredKm = 0.0;                                        // progress along route
      double currentKm = (currentBatteryPct / 100.0) * effectiveKm;  // range remaining
      int    guard     = 0;

      while (coveredKm + currentKm - reserveKm < routeKm && guard++ < 25) {
        final reachKm = coveredKm + currentKm - reserveKm; // farthest along we can reach

        // Candidates: strictly ahead, reachable before the reserve, and within
        // the highway corridor (so we don't dive off into a far-off town).
        var cands = projected.where((p) =>
            p.alongKm > coveredKm + 0.5 &&
            p.alongKm <= reachKm &&
            p.detourKm <= corridorKm).toList();

        // Fallback: nothing in the tight corridor — widen to any reachable
        // station ahead and take the least-detour one (still never backward).
        if (cands.isEmpty) {
          cands = projected.where((p) =>
              p.alongKm > coveredKm + 0.5 && p.alongKm <= reachKm).toList();
          if (cands.isEmpty) { break; } // can't reach a charger — leave rest unplanned
        }

        // Reward progress along the route, penalise detour off the highway,
        // so the chosen stop is far enough to minimise the number of stops
        // while staying as close to the road as possible.
        cands.sort((a, b) => (b.alongKm - 3.0 * b.detourKm)
            .compareTo(a.alongKm - 3.0 * a.detourKm));
        final pick = cands.first;

        // ── Road-side awareness ────────────────────────────────────────────
        // Prefer the charger on the carriageway that matches the travel
        // direction here. If the greedy pick is on the wrong side, swap to the
        // nearest same-side charger within 200 m (a true co-located pair sits
        // ≤50 m apart). If none exists, keep it but flag a required U-turn.
        // Chargers with no side suffix in their name are left untouched.
        final travelBearing = _bearingAlong(pts, cum, pick.alongKm);
        final preferred     = _preferredSide(travelBearing);
        var   chosen        = pick;
        var   requiresUTurn = false;
        final pickSide      = parseSideFromName(pick.station.name);
        if (pickSide != RoadSide.unknown && pickSide != preferred) {
          final loc = LatLng(pick.station.lat, pick.station.lng);
          _StationProjection? alt;
          double altM = double.infinity;
          for (final p in projected) {
            if (parseSideFromName(p.station.name) != preferred) { continue; }
            final m =
                _haversine(loc, LatLng(p.station.lat, p.station.lng)) * 1000.0;
            if (m <= 200.0 && m < altM) { altM = m; alt = p; }
          }
          if (alt != null) {
            chosen = alt;          // swap onto the correct carriageway
          } else {
            requiresUTurn = true;  // only the opposite-side charger is available
          }
        }
        final chosenSide = parseSideFromName(chosen.station.name);

        final arriveKm = currentKm - (chosen.alongKm - coveredKm); // range left on arrival
        final batPct   = (arriveKm / effectiveKm * 100).clamp(0.0, 100.0);
        double? chargeH;
        if (!chosen.station.isDC) {
          final capKwh    = maxRangeKm / 6.0; // rough kWh estimate
          final neededKwh = capKwh * ((effectiveKm - arriveKm) / effectiveKm);
          chargeH = neededKwh / (chosen.station.kw == 0 ? 1 : chosen.station.kw);
        }
        stops.add(ChargingStop(
          station:             chosen.station,
          batteryOnArrivalPct: batPct,
          distanceFromStartKm: chosen.alongKm,
          chargeHours:         chargeH,
          side:                chosenSide,
          requiresUTurn:       requiresUTurn,
        ));
        coveredKm = chosen.alongKm;
        currentKm = effectiveKm; // assume full recharge
      }

      final remainAtDestKm = currentKm - (routeKm - coveredKm);

      // ── Build the selectable charger options (~one block per 50 km) ─────────
      // 1. Keep only chargers inside the highway corridor, ordered along the road.
      final onRoute = projected
          .where((p) => p.detourKm <= corridorKm)
          .toList()
        ..sort((a, b) => a.alongKm.compareTo(b.alongKm));

      // 2. Cluster co-located chargers (≤200 m apart) into single blocks so a
      //    place served by several providers shows as one option.
      final clusters = <List<_StationProjection>>[];
      for (final p in onRoute) {
        if (clusters.isNotEmpty) {
          final anchor = clusters.last.first.station;
          final m = _haversine(LatLng(anchor.lat, anchor.lng),
                  LatLng(p.station.lat, p.station.lng)) *
              1000.0;
          if (m <= 200.0) { clusters.last.add(p); continue; }
        }
        clusters.add([p]);
      }

      // Turns one cluster into an option, resolving carriageway / U-turn from
      // the travel bearing at that point. A block needs a U-turn only when every
      // charger in it carries a side suffix on the *wrong* carriageway.
      RouteChargerOption toOption(List<_StationProjection> cl, bool recommended) {
        final along  = cl.map((e) => e.alongKm).reduce((a, b) => a + b) / cl.length;
        final detour = cl.map((e) => e.detourKm).reduce(min);
        final preferred = _preferredSide(_bearingAlong(pts, cum, along));
        var hasGoodSide = false;
        for (final e in cl) {
          final s = parseSideFromName(e.station.name);
          if (s == RoadSide.unknown || s == preferred) { hasGoodSide = true; break; }
        }
        final requiresUTurn = !hasGoodSide;
        final blockSide = requiresUTurn
            ? (preferred == RoadSide.right ? RoadSide.left : RoadSide.right)
            : preferred;
        return RouteChargerOption(
          location:      LatLng(cl.first.station.lat, cl.first.station.lng),
          stations:      cl.map((e) => e.station).toList(),
          alongKm:       along,
          detourKm:      detour,
          side:          blockSide,
          requiresUTurn: requiresUTurn,
          recommended:   recommended,
        );
      }

      // 3. Mark clusters that contain a greedy-recommended charger (these are
      //    always shown and pre-ticked). A recommended charger outside the
      //    corridor gets its own cluster appended so it is never dropped.
      bool sameStation(Station a, Station b) =>
          a.name == b.name && a.lat == b.lat && a.lng == b.lng;
      final recommendedIdx = <int>{};
      for (final stop in stops) {
        var found = -1;
        for (int i = 0; i < clusters.length; i++) {
          if (clusters[i].any((e) => sameStation(e.station, stop.station))) {
            found = i; break;
          }
        }
        if (found == -1) {
          final proj = projected.firstWhere(
              (p) => sameStation(p.station, stop.station),
              orElse: () => _StationProjection(stop.station, 0, stop.distanceFromStartKm));
          clusters.add([proj]);
          recommendedIdx.add(clusters.length - 1);
        } else {
          recommendedIdx.add(found);
        }
      }

      // 4. Sample ~one cluster per 50 km, always moving forward. Empty windows
      //    naturally roll over to the next reachable cluster ahead.
      const sampleStepKm = 50.0;
      final pickedIdx = <int>{};
      double lastAlong = -1;
      for (double cp = sampleStepKm; cp < routeKm + sampleStepKm; cp += sampleStepKm) {
        var best = -1;
        var bestDelta = double.infinity;
        for (int i = 0; i < clusters.length; i++) {
          if (pickedIdx.contains(i)) { continue; }
          final a = clusters[i].first.alongKm;
          if (a <= lastAlong) { continue; }
          final d = (a - cp).abs();
          if (d < bestDelta) { bestDelta = d; best = i; }
        }
        if (best == -1) { continue; }
        pickedIdx.add(best);
        lastAlong = clusters[best].first.alongKm;
      }
      pickedIdx.addAll(recommendedIdx); // recommended blocks are always present

      final options = pickedIdx
          .map((i) => toOption(clusters[i], recommendedIdx.contains(i)))
          .toList()
        ..sort((a, b) => a.alongKm.compareTo(b.alongKm));

      return EVRouteResult(
        polylinePoints:      pts,
        totalDistanceKm:     totalDistKm,
        batteryAtArrivalPct: (remainAtDestKm / effectiveKm * 100).clamp(0.0, 100.0),
        chargingStops:       stops,
        options:             options,
        effectiveRangeKm:    effectiveKm,
        maxRangeKm:          maxRangeKm,
      );
    } catch (_) {
      return null;
    }
  }

  // ── Google encoded polyline decoder ──────────────────────────────────────
  static List<LatLng> _decodePolyline(String enc) {
    final out = <LatLng>[];
    int idx = 0, lat = 0, lng = 0;
    while (idx < enc.length) {
      int b, shift = 0, r = 0;
      do {
        b = enc.codeUnitAt(idx++) - 63;
        r |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      lat += ((r & 1) != 0) ? ~(r >> 1) : (r >> 1);
      shift = 0; r = 0;
      do {
        b = enc.codeUnitAt(idx++) - 63;
        r |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      lng += ((r & 1) != 0) ? ~(r >> 1) : (r >> 1);
      out.add(LatLng(lat / 1e5, lng / 1e5));
    }
    return out;
  }

  // ── Haversine distance in km ──────────────────────────────────────────────
  static double _haversine(LatLng a, LatLng b) {
    const r    = 6371.0;
    final dLat = _rad(b.latitude  - a.latitude);
    final dLng = _rad(b.longitude - a.longitude);
    final x    = sin(dLat / 2) * sin(dLat / 2) +
        cos(_rad(a.latitude)) * cos(_rad(b.latitude)) *
        sin(dLng / 2) * sin(dLng / 2);
    return 2 * r * asin(sqrt(x));
  }

  static double _rad(double d) => d * pi / 180;

  // ── Distance (km) & projection fraction of a point onto a segment ─────────
  // Uses a local equirectangular projection (accurate over short corridor
  // distances). Returns [perpendicularDistanceKm, tFraction] where t∈[0,1]
  // is how far along [a→b] the closest point lies.
  static List<double> _projectToSegment(LatLng p, LatLng a, LatLng b) {
    final latRef = _rad(a.latitude);
    double px(LatLng q) => _rad(q.longitude - a.longitude) * cos(latRef) * 6371.0;
    double py(LatLng q) => _rad(q.latitude  - a.latitude)               * 6371.0;
    final bx = px(b), by = py(b);
    final qx = px(p), qy = py(p);
    final len2 = bx * bx + by * by;
    double t = len2 == 0 ? 0.0 : (qx * bx + qy * by) / len2;
    t = t.clamp(0.0, 1.0);
    final cx = t * bx, cy = t * by;
    final dist = sqrt((qx - cx) * (qx - cx) + (qy - cy) * (qy - cy));
    return [dist, t];
  }

  // ── Travel bearing (0–360°) of the route at a given along-route distance ──
  static double _bearingAlong(List<LatLng> pts, List<double> cum, double alongKm) {
    if (pts.length < 2) { return 0.0; }
    int seg = pts.length - 2;
    for (int i = 0; i < cum.length - 1; i++) {
      if (alongKm <= cum[i + 1]) { seg = i; break; }
    }
    return _bearing(pts[seg], pts[seg + 1]);
  }

  // ── Initial bearing from a→b in degrees clockwise from north (0–360) ──────
  static double _bearing(LatLng a, LatLng b) {
    final lat1 = _rad(a.latitude), lat2 = _rad(b.latitude);
    final dLon = _rad(b.longitude - a.longitude);
    final y    = sin(dLon) * cos(lat2);
    final x    = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon);
    return (atan2(y, x) * 180 / pi + 360) % 360;
  }

  // ── Carriageway preferred for a travel bearing ────────────────────────────
  // Georgia's main inter-city corridors (E60/E70) run roughly east–west. A
  // westward heading (bearing 180–360) travels the carriageway whose chargers
  // are named "Right/მარჯვენა" — anchored on Tbilisi→Batumi (≈270°), where the
  // "Right" stations are the correct-side ones. An eastward heading (0–180)
  // therefore prefers "Left/მარცხენა".
  static RoadSide _preferredSide(double bearing) {
    final b = (bearing % 360 + 360) % 360;
    return (b > 180.0 && b < 360.0) ? RoadSide.right : RoadSide.left;
  }
}

// A station's relationship to the planned route: how far off the road it is
// (detourKm) and how far along the route its closest point sits (alongKm).
class _StationProjection {
  const _StationProjection(this.station, this.detourKm, this.alongKm);
  final Station station;
  final double  detourKm;
  final double  alongKm;
}
