import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'profile_screen.dart';

const _kApiKey = 'AIzaSyAF1rz6kk4MpMaHwzCmdmepSJlg8GwcS78';

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
  final String country;          // country name for OCM stations ('' = derive from coords)
}

// ── Route models ──────────────────────────────────────────────────────────────
class ChargingStop {
  const ChargingStop({
    required this.station,
    required this.batteryOnArrivalPct,
    required this.distanceFromStartKm,
    this.chargeHours,
  });
  final Station station;
  final double  batteryOnArrivalPct;
  final double  distanceFromStartKm;
  final double? chargeHours; // null = DC fast charge
}

class EVRouteResult {
  const EVRouteResult({
    required this.polylinePoints,
    required this.totalDistanceKm,
    required this.batteryAtArrivalPct,
    required this.chargingStops,
    required this.effectiveRangeKm,
    required this.maxRangeKm,
  });
  final List<LatLng>       polylinePoints;
  final double             totalDistanceKm;
  final double             batteryAtArrivalPct;
  final List<ChargingStop> chargingStops;
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

        final arriveKm = currentKm - (pick.alongKm - coveredKm); // range left on arrival
        final batPct   = (arriveKm / effectiveKm * 100).clamp(0.0, 100.0);
        double? chargeH;
        if (!pick.station.isDC) {
          final capKwh    = maxRangeKm / 6.0; // rough kWh estimate
          final neededKwh = capKwh * ((effectiveKm - arriveKm) / effectiveKm);
          chargeH = neededKwh / (pick.station.kw == 0 ? 1 : pick.station.kw);
        }
        stops.add(ChargingStop(
          station:             pick.station,
          batteryOnArrivalPct: batPct,
          distanceFromStartKm: pick.alongKm,
          chargeHours:         chargeH,
        ));
        coveredKm = pick.alongKm;
        currentKm = effectiveKm; // assume full recharge
      }

      final remainAtDestKm = currentKm - (routeKm - coveredKm);

      return EVRouteResult(
        polylinePoints:      pts,
        totalDistanceKm:     totalDistKm,
        batteryAtArrivalPct: (remainAtDestKm / effectiveKm * 100).clamp(0.0, 100.0),
        chargingStops:       stops,
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
}

// A station's relationship to the planned route: how far off the road it is
// (detourKm) and how far along the route its closest point sits (alongKm).
class _StationProjection {
  const _StationProjection(this.station, this.detourKm, this.alongKm);
  final Station station;
  final double  detourKm;
  final double  alongKm;
}
