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
    required this.name,      required this.location,  required this.distance,
    required this.available, required this.lat,        required this.lng,
    required this.isDC,      required this.kw,         required this.price,
  });

  factory Station.fromJson(Map<String, dynamic> j) => Station(
    name:      j['name']      as String,
    location:  j['location']  as String,
    distance:  j['distance']  as String,
    available: j['available'] as int,
    lat:       (j['lat']      as num).toDouble(),
    lng:       (j['lng']      as num).toDouble(),
    isDC:      j['isDC']      as bool,
    kw:        j['kw']        as int,
    price:     j['price']     as String,
  );

  final String name, location, distance, price;
  final int    available, kw;
  final double lat, lng;
  final bool   isDC;
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

      // ── EV range math ─────────────────────────────────────────────────────
      final stops      = <ChargingStop>[];
      double currentKm = (currentBatteryPct / 100.0) * effectiveKm;
      double distSoFar = 0.0;

      for (int i = 0; i < pts.length - 1; i++) {
        final seg = _haversine(pts[i], pts[i + 1]);
        distSoFar += seg;
        currentKm -= seg;

        // Insert charging stop when range drops to 2× reserve
        if (currentKm <= reserveKm * 2) {
          final nearest = _findNearest(pts[i + 1], stations);
          if (nearest == null) { continue; }

          final batPct = (currentKm / effectiveKm * 100).clamp(0.0, 100.0);
          double? chargeH;
          if (!nearest.isDC) {
            final capKwh    = maxRangeKm / 6.0; // rough kWh estimate
            final neededKwh = capKwh * ((effectiveKm - currentKm) / effectiveKm);
            chargeH = neededKwh / nearest.kw;
          }
          stops.add(ChargingStop(
            station:             nearest,
            batteryOnArrivalPct: batPct,
            distanceFromStartKm: distSoFar,
            chargeHours:         chargeH,
          ));
          currentKm = effectiveKm; // assume full recharge
        }
      }

      return EVRouteResult(
        polylinePoints:      pts,
        totalDistanceKm:     totalDistKm,
        batteryAtArrivalPct: (currentKm / effectiveKm * 100).clamp(0.0, 100.0),
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

  // ── Nearest available station to a point ─────────────────────────────────
  static Station? _findNearest(LatLng pt, List<Station> stations) {
    Station? best;
    double   minD = double.infinity;
    for (final s in stations) {
      if (s.available == 0) { continue; }
      final d = _haversine(pt, LatLng(s.lat, s.lng));
      if (d < minD) { minD = d; best = s; }
    }
    return best;
  }
}
