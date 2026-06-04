import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'app_constants.dart';
import 'routing_service.dart';

/// Live Open Charge Map (OCM) data source. Fetches international charging
/// stations for the user's selected ISO country codes and maps them onto our
/// shared [Station] schema. All OCM networks are grouped under a single
/// "International" provider so they never clutter the local Georgian provider
/// filters.
class OcmService {
  static const _key = 'a374a367-c145-4ac1-82d5-91fb9ce52b36';
  static const kProvider = 'International';

  // OCM blocks requests that carry the default Dart/dart:io User-Agent with a
  // 503 "API requests by robots are temporarily disabled". A real User-Agent
  // (plus the key in the X-API-Key header) is required or every fetch fails
  // silently. This was the root cause of international stations never loading.
  static const _headers = <String, String>{
    'User-Agent': 'ev_charger_app/1.0 (Flutter; +https://evchargergeorgia.app)',
    'X-API-Key':  _key,
  };

  // Session cache: ISO alpha-2 country code -> mapped stations. Populated on the
  // first fetch for a country and reused for the rest of the session, so
  // toggling the International chip or panning the map never refetches. OCM
  // covers 100+ countries, so we fetch per country live (on demand) rather than
  // bundling every country into the app.
  static final Map<String, List<Station>> _cache = {};

  /// Fetch every OCM charge point for one ISO 3166-1 alpha-2 [countryCode]
  /// (e.g. "AT" for Austria), mapped onto our shared [Station] schema and
  /// grouped under the single "International" provider. Cached in memory for the
  /// session; returns the cached list immediately on subsequent calls.
  static Future<List<Station>> fetchByCountry(String countryCode) async {
    final code = countryCode.toUpperCase();
    final hit  = _cache[code];
    if (hit != null) { return hit; }

    final uri = Uri.parse('https://api.openchargemap.io/v3/poi/').replace(
      queryParameters: <String, String>{
        'key':         _key,
        'countrycode': code,
        'maxresults':  '500',
        'compact':     'true',
        'verbose':     'false',
        'output':      'json',
      },
    );
    try {
      final res = await http.get(uri, headers: _headers)
          .timeout(const Duration(seconds: 45));
      if (res.statusCode != 200) { return const []; }
      // Decode + map on a background isolate so large payloads never jank the
      // UI. We already know the country (we fetched by code), so we pass its
      // display name in — each station is tagged correctly even though
      // verbose=false strips the expanded Country object from the payload.
      final name = countryNameForCode(code) ?? '';
      final maps = await compute(_parseOcm, <String>[res.body, name]);
      final list = maps.map(Station.fromJson).toList();
      _cache[code] = list;
      return list;
    } catch (_) {
      return const [];
    }
  }
}

// ── Isolate-safe parsing (top-level function) ─────────────────────────────────
// Decodes the OCM POI array and maps each entry into our production station
// schema (returned as plain maps so they cross the isolate boundary cheaply).
// [args] is [body, countryName]: the raw JSON plus the known country display
// name (we fetch one country at a time, so it's resolved on the caller side).
List<Map<String, dynamic>> _parseOcm(List<String> args) {
  final body        = args[0];
  final countryName = args[1];
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
        // DC detection: CurrentTypeID 30 == DC (10=AC1, 20=AC3, 30=DC). With
        // verbose=false the expanded CurrentType object is usually absent, so we
        // key off the numeric ID, falling back to the title (when present) and a
        // power heuristic so obvious fast chargers are still flagged.
        final curId    = (c['CurrentTypeID'] as num?)?.toInt();
        final cur      = c['CurrentType'];
        final curTitle = ((cur is Map ? cur['Title'] : null) as String? ?? '').toUpperCase();
        if (curId == 30 || curTitle.contains('DC') || kw >= 43) { anyDc = true; }
        final qty = (c['Quantity'] as num?)?.toInt() ?? 0;
        points += qty;
      }
    }
    final kw = maxKw >= 1000 ? (maxKw / 1000).round() : maxKw.round();

    // Country: prefer the known name from the fetch (robust under verbose=false);
    // fall back to whatever the payload carries if it wasn't supplied.
    final country  = p['Country'] ?? ai['Country'];
    final iso      = (country is Map ? country['ISOCode'] : null) as String?;
    final resolved = countryName.isNotEmpty
        ? countryName
        : (countryNameForCode(iso) ??
            ((country is Map ? country['Title'] : null) as String? ?? ''));

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
      'total_spots':     avail, // OCM exposes total points, not live free count
      'city':            town,
      'provider':        OcmService.kProvider,
      'country':         resolved,
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
