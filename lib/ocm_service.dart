import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

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

  // Country fetches page through the full national dataset with
  // sortby=id_asc + greaterthanid — the same scheme OCM's own ocm-export
  // mirror uses — instead of a single capped request (the old maxresults=500
  // fetch showed a tiny arbitrary slice of big countries like Germany).
  // _kMaxPerCountry bounds memory and marker-cluster load; the viewport
  // top-up fetch fills in local density wherever the user actually pans.
  static const _kPageSize      = 1000;
  static const _kMaxPerCountry = 10000;
  static const _kPageTimeout   = Duration(seconds: 30);

  // Disk cache: one JSON file per country under the app-support directory so
  // a week of travel doesn't re-download multi-MB national datasets on every
  // launch (roaming data is expensive). Stale files still serve as an offline
  // fallback when the refresh fails.
  static const _kDiskTtl = Duration(days: 7);

  // Session cache: ISO alpha-2 country code -> mapped stations. Populated on
  // the first fetch for a country and reused for the rest of the session, so
  // toggling the International chip or panning the map never refetches.
  static final Map<String, List<Station>> _cache = {};

  // Viewport tile cache: quantised-bounds key -> stations. Keeps repeated
  // pans over the same area from refetching. Bounded; cleared wholesale when
  // it grows past the cap (entries are cheap to refetch).
  static final Map<String, List<Station>> _tileCache = {};
  static const _kMaxTiles = 60;

  /// Fetch every OCM charge point for one ISO 3166-1 alpha-2 [countryCode]
  /// (e.g. "AT" for Austria), mapped onto our shared [Station] schema and
  /// grouped under the single "International" provider. Resolution order:
  /// session memory -> fresh disk cache -> paginated network fetch (saved to
  /// disk) -> stale disk cache as an offline fallback.
  static Future<List<Station>> fetchByCountry(String countryCode) async {
    final code = countryCode.toUpperCase();
    final hit  = _cache[code];
    if (hit != null) { return hit; }

    final disk = await _loadDisk(code);
    if (disk != null && disk.fresh) {
      return _cache[code] = disk.stations;
    }

    final maps = await _fetchCountryPaged(code);
    if (maps != null && maps.isNotEmpty) {
      unawaited(_saveDisk(code, maps));
      return _cache[code] = maps.map(Station.fromJson).toList();
    }

    // Network failed (or returned nothing): a stale cache beats an empty map.
    if (disk != null && disk.stations.isNotEmpty) {
      return _cache[code] = disk.stations;
    }
    return const [];
  }

  /// Fetch the OCM charge points inside a map viewport (all countries),
  /// mapped onto our schema. Used as a live top-up while panning abroad so
  /// dense areas of big countries show full detail even beyond the
  /// per-country cap. Results carry an empty country (compact payloads don't
  /// include ISO codes); the caller treats them as International pins.
  static Future<List<Station>> fetchViewport({
    required double south,
    required double west,
    required double north,
    required double east,
  }) async {
    // Quantise the bounds to a ~0.25° grid so small pans hit the tile cache.
    String lo(double v) => ((v * 4).floor() / 4).toStringAsFixed(2);
    String hi(double v) => ((v * 4).ceil()  / 4).toStringAsFixed(2);
    final key = '${lo(south)},${lo(west)},${hi(north)},${hi(east)}';
    final hit = _tileCache[key];
    if (hit != null) { return hit; }

    final uri = Uri.parse('https://api.openchargemap.io/v3/poi/').replace(
      queryParameters: <String, String>{
        'key':         _key,
        'boundingbox': '(${hi(north)},${lo(west)}),(${lo(south)},${hi(east)})',
        'maxresults':  '$_kPageSize',
        'compact':     'true',
        'verbose':     'false',
        'output':      'json',
      },
    );
    try {
      final res = await http.get(uri, headers: _headers).timeout(_kPageTimeout);
      if (res.statusCode != 200) { return const []; }
      final page = await compute(_parseOcm, <String>[res.body, '']);
      final list = page.stations.map(Station.fromJson).toList();
      if (_tileCache.length >= _kMaxTiles) { _tileCache.clear(); }
      return _tileCache[key] = list;
    } catch (_) {
      return const [];
    }
  }

  // ── Paginated country download ──────────────────────────────────────────

  // Pages through a country's POIs (id-ascending) until the server runs dry
  // or the per-country cap is hit. Returns the accumulated station maps, or
  // null when the very first page fails (so callers can fall back to a stale
  // disk cache). A failure on a later page returns the partial result —
  // partial coverage beats none.
  static Future<List<Map<String, dynamic>>?> _fetchCountryPaged(
      String code) async {
    final name = countryNameForCode(code) ?? '';
    final out  = <Map<String, dynamic>>[];
    var afterId = 0;
    while (out.length < _kMaxPerCountry) {
      final uri = Uri.parse('https://api.openchargemap.io/v3/poi/').replace(
        queryParameters: <String, String>{
          'key':         _key,
          'countrycode': code,
          'maxresults':  '$_kPageSize',
          'compact':     'true',
          'verbose':     'false',
          'output':      'json',
          'sortby':      'id_asc',
          if (afterId > 0) 'greaterthanid': '$afterId',
        },
      );
      _OcmPage page;
      try {
        final res =
            await http.get(uri, headers: _headers).timeout(_kPageTimeout);
        if (res.statusCode != 200) { return out.isEmpty ? null : out; }
        // Decode + map on a background isolate so large payloads never jank
        // the UI. We already know the country (we fetched by code), so we pass
        // its display name in — each station is tagged correctly even though
        // verbose=false strips the expanded Country object from the payload.
        page = await compute(_parseOcm, <String>[res.body, name]);
      } catch (_) {
        return out.isEmpty ? null : out;
      }
      out.addAll(page.stations);
      // Continuation is keyed off the RAW page, not the mapped one: entries
      // without coordinates are dropped by the parser but still advance the
      // id cursor, and a short raw page means the server has no more rows.
      if (page.rawCount < _kPageSize || page.maxId <= afterId) { break; }
      afterId = page.maxId;
    }
    return out;
  }

  // ── Disk cache ────────────────────────────────────────────────────────────

  static Future<File?> _diskFile(String code) async {
    if (kIsWeb) { return null; }
    try {
      final dir = await getApplicationSupportDirectory();
      return File('${dir.path}${Platform.pathSeparator}ocm_$code.json');
    } catch (_) {
      return null;
    }
  }

  static Future<_DiskHit?> _loadDisk(String code) async {
    try {
      final file = await _diskFile(code);
      if (file == null || !await file.exists()) { return null; }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) { return null; }
      final fetchedAt = (decoded['fetchedAt'] as num?)?.toInt() ?? 0;
      final raw       = decoded['stations'];
      if (raw is! List) { return null; }
      final stations = raw
          .whereType<Map<String, dynamic>>()
          .map(Station.fromJson)
          .toList();
      final age = DateTime.now().millisecondsSinceEpoch - fetchedAt;
      return _DiskHit(stations, fresh: age < _kDiskTtl.inMilliseconds);
    } catch (_) {
      return null; // corrupt/unreadable cache is the same as no cache
    }
  }

  static Future<void> _saveDisk(
      String code, List<Map<String, dynamic>> maps) async {
    try {
      final file = await _diskFile(code);
      if (file == null) { return; }
      await file.writeAsString(jsonEncode(<String, dynamic>{
        'fetchedAt': DateTime.now().millisecondsSinceEpoch,
        'stations':  maps,
      }));
    } catch (_) {/* cache write failures are non-fatal */}
  }
}

class _DiskHit {
  const _DiskHit(this.stations, {required this.fresh});
  final List<Station> stations;
  final bool fresh;
}

// ── Isolate-safe parsing (top-level function) ─────────────────────────────────
// Decodes one OCM POI page and maps each entry into our production station
// schema (plain maps so they cross the isolate boundary cheaply), plus the
// pagination cursor data: the raw row count and the highest raw POI id.
// [args] is [body, countryName]: the raw JSON plus the known country display
// name (empty for viewport fetches, where the country isn't known up front).
class _OcmPage {
  const _OcmPage(this.stations, this.rawCount, this.maxId);
  final List<Map<String, dynamic>> stations;
  final int rawCount;
  final int maxId;
}

_OcmPage _parseOcm(List<String> args) {
  final body        = args[0];
  final countryName = args[1];
  final decoded = jsonDecode(body);
  if (decoded is! List) { return const _OcmPage([], 0, 0); }

  var maxId = 0;
  final out = <Map<String, dynamic>>[];
  for (final p in decoded) {
    if (p is! Map) { continue; }
    final rawId = (p['ID'] as num?)?.toInt() ?? 0;
    if (rawId > maxId) { maxId = rawId; }
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
      'id':              'ocm_$rawId',
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
  return _OcmPage(out, decoded.length, maxId);
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
