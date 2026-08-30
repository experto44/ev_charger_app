import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

const _kApiKey = 'AIzaSyAF1rz6kk4MpMaHwzCmdmepSJlg8GwcS78';

// ── Model ─────────────────────────────────────────────────────────────────────
class PlacePrediction {
  const PlacePrediction({
    required this.placeId,
    required this.description,
    required this.mainText,
    required this.secondaryText,
  });

  factory PlacePrediction.fromJson(Map<String, dynamic> j) {
    final sf = j['structured_formatting'] as Map<String, dynamic>? ?? {};
    return PlacePrediction(
      placeId:       j['place_id']   as String,
      description:   j['description'] as String,
      mainText:      sf['main_text']      as String? ?? j['description'] as String,
      secondaryText: sf['secondary_text'] as String? ?? '',
    );
  }

  final String placeId, description, mainText, secondaryText;
}

// ── Billing session ───────────────────────────────────────────────────────────
/// Ties one user search together: every keystroke plus the Place Details call
/// that ends it share a token, so Google bills the whole burst once with the
/// Details request instead of charging per Autocomplete request. Without it a
/// six-letter destination is six billable calls.
///
/// One session per input field. Picking a prediction ends the session, so the
/// next keystroke starts a fresh one — [PlacesService.getCoordinates] resets
/// the token itself.
class PlacesSession {
  PlacesSession() : token = _newToken();

  String token;

  void reset() { token = _newToken(); }

  // Google only asks for a unique string per session; a 32-char random hex is
  // well inside the 36-character limit.
  static String _newToken() {
    final r = Random.secure();
    return List.generate(32, (_) => r.nextInt(16).toRadixString(16)).join();
  }
}

// ── Service ───────────────────────────────────────────────────────────────────
class PlacesService {
  static const _autocompleteUrl =
      'https://maps.googleapis.com/maps/api/place/autocomplete/json';
  static const _detailsUrl =
      'https://maps.googleapis.com/maps/api/place/details/json';

  /// Shortest query worth asking Google about. Two characters matched half the
  /// country and cost a request for every search that passed through them; by
  /// the third character the predictions are about the place the driver has in
  /// mind. Both search fields use this so the list clears at the same point the
  /// requests stop.
  static const int kMinQueryChars = 3;

  /// How long a field stays quiet before it asks. At 400 ms an ordinarily typed
  /// word asked three or four questions on the way to its answer; 600 ms is
  /// still under the pause between words, so the list appears while the driver
  /// is looking at the keyboard rather than after it.
  static const Duration kDebounce = Duration(milliseconds: 600);

  // ── Prediction cache ────────────────────────────────────────────────────────
  // Typing repeats itself in a way that costs requests: every backspace re-asks
  // a question answered a second ago, and reopening the planner to change one
  // stop retypes the other from scratch. Twenty answers cover both.
  //
  // In memory only, gone with the process — Google's Places policy allows
  // caching content briefly (place IDs indefinitely), and a cache that outlived
  // the session would start showing places that have since moved.
  static const int _kCacheMax = 20;

  /// Insertion-ordered, so the oldest key is simply the first one. Deliberately
  /// not a true LRU: at twenty entries the bookkeeping would cost more than the
  /// occasional early eviction.
  static final Map<String, List<PlacePrediction>> _cache = {};

  /// Queries Google had nothing for. Autocomplete matches from the front, so a
  /// longer query beginning with one of these has nothing either and is
  /// answered without a request — this is what stops a mistyped destination
  /// from billing a request per remaining keystroke.
  ///
  /// No bias in the key: the request sets no country component, so location
  /// only RANKS predictions. Nothing means nothing wherever the driver stands.
  static final Set<String> _emptyQueries = {};

  static String _normalise(String s) =>
      s.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  /// Bias is bucketed to ~11 km. It reorders predictions rather than filtering
  /// them, so the cache has to notice a driver who has moved to another city
  /// and ignore every metre of the drive there.
  static String _cacheKey(String q, LatLng? bias) => bias == null
      ? q
      : '$q|${bias.latitude.toStringAsFixed(1)},'
        '${bias.longitude.toStringAsFixed(1)}';

  static void _remember(String key, List<PlacePrediction> predictions) {
    if (_cache.length >= _kCacheMax) { _cache.remove(_cache.keys.first); }
    _cache[key] = predictions;
  }

  static void _rememberEmpty(String q) {
    if (_emptyQueries.length >= _kCacheMax) {
      _emptyQueries.remove(_emptyQueries.first);
    }
    _emptyQueries.add(q);
  }

  /// The one call that leaves the phone. It is a field rather than a direct
  /// `http.get` so a test can count requests — which is the only way to check
  /// work that is defined by the requests it does NOT make.
  @visibleForTesting
  static Future<http.Response> Function(Uri) send =
      (uri) => http.get(uri).timeout(const Duration(seconds: 5));

  /// Empties the caches between tests. Nothing in the app calls this: the
  /// caches are meant to live as long as the process.
  @visibleForTesting
  static void resetCache() {
    _cache.clear();
    _emptyQueries.clear();
  }

  /// Returns up to 5 autocomplete predictions for [query], ranked around
  /// [bias] (the user's position, or the map centre) when one is given.
  ///
  /// Deliberately NOT restricted to one country any more: the app covers
  /// Turkey and the rest of Europe, and a hard `components=country:ge` meant a
  /// driver planning Tbilisi → İstanbul could not even type the destination.
  /// Location bias keeps nearby Georgian places on top where it matters,
  /// without hiding everything across the border.
  ///
  /// Pass the field's [session] so the keystroke burst is billed once with the
  /// following Place Details call (see [PlacesSession]).
  ///
  /// May answer without calling Google at all — see the prediction cache and
  /// [kMinQueryChars].
  static Future<List<PlacePrediction>> autocomplete(
    String query, {
    LatLng? bias,
    PlacesSession? session,
  }) async {
    final q = _normalise(query);
    if (q.length < kMinQueryChars) { return const []; }

    // Already answered, or provably empty. Either way no request goes out, and
    // the session token is untouched — a search served from the cache still
    // bills as the one Place Details call that ends it.
    final key = _cacheKey(q, bias);
    final hit = _cache[key];
    if (hit != null) { return hit; }
    if (_emptyQueries.any(q.startsWith)) { return const []; }

    try {
      final uri = Uri.parse(_autocompleteUrl).replace(queryParameters: {
        'input':    q,
        'key':      _kApiKey,
        'language': 'ka',
        if (session != null) 'sessiontoken': session.token,
        if (bias != null) ...{
          'location': '${bias.latitude},${bias.longitude}',
          // Wide enough to cover the whole country the driver is in, so the
          // bias ranks results without excluding a cross-border destination.
          'radius':   '300000',
        },
      });
      final res = await send(uri);
      if (res.statusCode != 200) { return const []; }
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final status = body['status'] as String?;
      // ZERO_RESULTS is an answer, not a failure — remember it. Every other
      // non-OK status is a transient the next keystroke should retry, so it
      // must NOT be recorded as "Google has nothing".
      if (status == 'ZERO_RESULTS') { _rememberEmpty(q); return const []; }
      if (status != 'OK') { return const []; }

      final out = (body['predictions'] as List)
          .map((e) => PlacePrediction.fromJson(e as Map<String, dynamic>))
          .take(5)
          .toList();
      if (out.isEmpty) { _rememberEmpty(q); } else { _remember(key, out); }
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// Resolves a [placeId] to its geographic coordinates.
  ///
  /// `fields=geometry` alone keeps this on the cheap location-only Details
  /// tier — asking for a Pro field such as `name` triples the price, and the
  /// label already comes from the prediction. Closes [session] on the way out.
  static Future<LatLng?> getCoordinates(String placeId, {PlacesSession? session}) async {
    try {
      final uri = Uri.parse(_detailsUrl).replace(queryParameters: {
        'place_id': placeId,
        'fields':   'geometry',
        'key':      _kApiKey,
        if (session != null) 'sessiontoken': session.token,
      });
      // The token is spent whatever comes back; the next search needs a new one.
      session?.reset();
      final res = await send(uri);
      if (res.statusCode != 200) { return null; }
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      if (body['status'] != 'OK') { return null; }
      final loc =
          body['result']['geometry']['location'] as Map<String, dynamic>;
      return LatLng(
        (loc['lat'] as num).toDouble(),
        (loc['lng'] as num).toDouble(),
      );
    } catch (_) {
      return null;
    }
  }
}
