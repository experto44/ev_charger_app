import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'app_constants.dart';
import 'routing_service.dart';

/// Live Open Charge Map (OCM) data source. Fetches international charging
/// stations for a set of ISO country codes and maps them onto our shared
/// [Station] schema. All OCM networks are grouped under a single "International"
/// provider so they never clutter the local Georgian provider filters.
class OcmService {
  static const _key = 'a374a367-c145-4ac1-82d5-91fb9ce52b36';
  static const kProvider = 'International';

  // Viewport (bounding-box) fetch: only loads stations currently on screen, so
  // big countries (France ≈ 16k, Germany ≈ similar) never overload the app.
  // Caller filters the result to the selected countries. maxresults caps a
  // single dense viewport; clustering renders the rest as you pan/zoom.
  static Future<List<Station>> fetchInBounds(
    double swLat, double swLng, double neLat, double neLng) async {
    final uri = Uri.parse('https://api.openchargemap.io/v3/poi/').replace(
      queryParameters: <String, String>{
        'output':      'json',
        'boundingbox': '($neLat,$neLng),($swLat,$swLng)',
        'maxresults':  '1000',
        'key':         _key,
      },
    );
    try {
      final res = await http.get(uri).timeout(const Duration(seconds: 45));
      if (res.statusCode != 200) { return const []; }
      // Decode + map on a background isolate so large payloads never jank the UI.
      final maps = await compute(_parseOcm, res.body);
      return maps.map(Station.fromJson).toList();
    } catch (_) {
      return const [];
    }
  }
}

// ── Isolate-safe parsing (top-level function) ─────────────────────────────────
// Decodes the OCM POI array and maps each entry into our production station
// schema (returned as plain maps so they cross the isolate boundary cheaply).
List<Map<String, dynamic>> _parseOcm(String body) {
  final decoded = jsonDecode(body);
  if (decoded is! List) { return const []; }

  final out = <Map<String, dynamic>>[];
  for (final p in decoded) {
    if (p is! Map) { continue; }
    final ai = p['AddressInfo'];
    if (ai is! Map) { continue; }
    final lat = (ai['Latitude']  as num?)?.toDouble();
    final lng = (ai['Longitude'] as num?)?.toDouble();
    if (lat == null || lng == null) { continue; }

    final conns = <String>{};
    double maxKw = 0;
    bool   anyDc = false;
    int    points = 0;
    final connections = p['Connections'];
    if (connections is List) {
      for (final c in connections) {
        if (c is! Map) { continue; }
        final ct    = c['ConnectionType'];
        final title = (ct is Map ? ct['Title'] : null) as String?;
        final norm  = _normConn(title);
        if (norm != null) { conns.add(norm); }
        final kw = (c['PowerKW'] as num?)?.toDouble() ?? 0;
        if (kw > maxKw) { maxKw = kw; }
        final cur      = c['CurrentType'];
        final curTitle = ((cur is Map ? cur['Title'] : null) as String? ?? '').toUpperCase();
        if (curTitle.contains('DC') || kw >= 43) { anyDc = true; }
        final qty = (c['Quantity'] as num?)?.toInt() ?? 0;
        points += qty;
      }
    }
    final kw = maxKw >= 1000 ? (maxKw / 1000).round() : maxKw.round();

    final country     = ai['Country'];
    final iso         = (country is Map ? country['ISOCode'] : null) as String?;
    final countryName = countryNameForCode(iso) ??
        ((country is Map ? country['Title'] : null) as String? ?? '');

    final nPoints = (p['NumberOfPoints'] as num?)?.toInt();
    final avail   = nPoints ?? (points > 0 ? points
        : (connections is List ? connections.length : 0));

    final cost  = p['UsageCost'];
    final price = (cost is String && cost.trim().isNotEmpty) ? cost.trim() : '';

    final title = (ai['Title'] as String?)?.trim();
    final town  = ((ai['Town'] ?? ai['StateOrProvince'] ?? '') as String?)?.trim() ?? '';

    out.add({
      'id':              'ocm_${p['ID']}',
      'name':            (title != null && title.isNotEmpty) ? title : 'Charging Station',
      'lat':             lat,
      'lng':             lng,
      'power':           kw > 0 ? '$kw kW' : '—',
      'type':            anyDc ? 'Fast DC' : 'AC',
      'price':           price,
      'available_spots': '$avail available',
      'city':            town,
      'provider':        OcmService.kProvider,
      'country':         countryName,
      'connectors':      sortConnectors(conns),
      'last_updated':    'Just now',
    });
  }
  return out;
}

// Map an OCM connection-type title onto our canonical chip labels.
String? _normConn(String? title) {
  if (title == null) { return null; }
  final t = title.toLowerCase();
  if (t.contains('ccs') && t.contains('type 1')) { return 'CCS1'; }
  if (t.contains('ccs') && t.contains('type 2')) { return 'CCS2'; }
  if (t.contains('ccs') || t.contains('combo'))  { return 'CCS2'; }
  if (t.contains('chademo'))                     { return 'CHAdeMO'; }
  if (t.contains('gb'))                          { return 'GB/T'; } // GB-T / GB/T
  if (t.contains('tesla') || t.contains('nacs')) { return 'NACS'; }
  if (t.contains('type 2') || t.contains('mennekes') || t.contains('62196-2')) { return 'Type 2'; }
  if (t.contains('type 1') || t.contains('j1772') || t.contains('j-1772'))     { return 'Type 1'; }
  return null;
}
