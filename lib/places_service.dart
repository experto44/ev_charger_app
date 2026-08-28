import 'dart:convert';
import 'dart:math';

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
  static Future<List<PlacePrediction>> autocomplete(
    String query, {
    LatLng? bias,
    PlacesSession? session,
  }) async {
    if (query.trim().length < 2) { return const []; }
    try {
      final uri = Uri.parse(_autocompleteUrl).replace(queryParameters: {
        'input':    query,
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
      final res = await http.get(uri).timeout(const Duration(seconds: 5));
      if (res.statusCode != 200) { return const []; }
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      if (body['status'] != 'OK') { return const []; }
      return (body['predictions'] as List)
          .map((e) => PlacePrediction.fromJson(e as Map<String, dynamic>))
          .take(5)
          .toList();
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
      final res = await http.get(uri).timeout(const Duration(seconds: 5));
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
