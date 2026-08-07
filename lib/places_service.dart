import 'dart:convert';

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
  static Future<List<PlacePrediction>> autocomplete(
    String query, {
    LatLng? bias,
  }) async {
    if (query.trim().length < 2) { return const []; }
    try {
      final uri = Uri.parse(_autocompleteUrl).replace(queryParameters: {
        'input':    query,
        'key':      _kApiKey,
        'language': 'ka',
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
  static Future<LatLng?> getCoordinates(String placeId) async {
    try {
      final uri = Uri.parse(_detailsUrl).replace(queryParameters: {
        'place_id': placeId,
        'fields':   'geometry',
        'key':      _kApiKey,
      });
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
