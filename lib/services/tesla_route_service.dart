import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

/// Handing a route to the car at tesla.geocharge.ge.
///
/// The phone writes one document and the car, which is watching it in realtime,
/// offers the driver the route. A route sent while the car is asleep simply
/// waits there — which is the normal case, since people plan indoors and then
/// walk out to the car.
///
/// Two sources feed the same document: a trip built in this app's own route
/// planner, and a link shared out of Google Maps. The Google link is read by a
/// Cloud Function rather than here, because the URL format is undocumented and
/// a fix must not have to wait on an App Store review.
/// See functions/google-route.js and docs/google_maps_share_links.md.
class TeslaRouteService {
  TeslaRouteService._();

  static FirebaseFirestore get _db => FirebaseFirestore.instance;
  static String? get _uid => FirebaseAuth.instance.currentUser?.uid;

  static HttpsCallable _fn(String name) =>
      FirebaseFunctions.instanceFor(region: 'us-central1').httpsCallable(name);

  /// True when this account has a car paired (users/{uid}/flags/teslaDevice).
  /// Sending to nothing is worth warning about before the driver walks out to
  /// a car that will never show the route.
  static Future<bool> isCarLinked() async {
    final uid = _uid;
    if (uid == null) return false;
    try {
      final snap =
          await _db.doc('users/$uid/flags/teslaDevice').get();
      return snap.exists;
    } catch (_) {
      return false; // offline or rules — let the caller decide what to say
    }
  }

  /// Read a shared Google Maps link. Throws [FirebaseFunctionsException] with a
  /// code the caller can turn into a message.
  static Future<TeslaRoute> readGoogleLink(String url) async {
    final res = await _fn('importGoogleRoute')
        .call<Map<String, dynamic>>({'url': url});
    final d = res.data;

    LatLng? point(dynamic v) {
      if (v is! Map) return null;
      final lat = (v['lat'] as num?)?.toDouble();
      final lng = (v['lng'] as num?)?.toDouble();
      return (lat == null || lng == null) ? null : LatLng(lat, lng);
    }

    final destination = point(d['destination']);
    if (destination == null) {
      throw StateError('no destination'); // the function should have refused
    }
    return TeslaRoute(
      name: (d['destination'] as Map)['name'] as String? ?? '',
      destination: destination,
      waypoints: [
        for (final w in (d['waypoints'] as List? ?? const []))
          if (point(w) != null) point(w)!,
      ],
      avoidTolls: d['avoidTolls'] == true,
      droppedStops: [
        for (final s in (d['dropped'] as List? ?? const [])) s.toString(),
      ],
    );
  }

  /// Put a route in front of the car. Overwrites whatever was there: one
  /// pending route at a time is what the card on the car screen can show, and
  /// the newest one is the one the driver just sent.
  static Future<void> sendToCar(TeslaRoute route, {required String source}) async {
    final uid = _uid;
    if (uid == null) throw StateError('signed out');

    await _db.doc('users/$uid/tesla/inbox').set({
      'name': route.name,
      'destination': {
        'lat': route.destination.latitude,
        'lng': route.destination.longitude,
      },
      'waypoints': [
        for (final w in route.waypoints) {'lat': w.latitude, 'lng': w.longitude},
      ],
      'avoidTolls': route.avoidTolls,
      'dropped': route.droppedStops,
      'source': source, // 'app' | 'gmaps'
      'sentAt': DateTime.now().millisecondsSinceEpoch,
      // Cleared explicitly: a merge write would leave the previous route's
      // consumedAt in place and the car would ignore this one as already dealt
      // with. Same reason the whole document is replaced rather than merged.
      'consumedAt': null,
    });
    debugPrint('[TeslaRoute] sent to car ($source, ${route.waypoints.length} stops)');
  }
}

/// A route on its way to the car: where it ends, what it passes through, and
/// how it was meant to be driven. Never a road — the car works that out itself
/// from wherever it actually is.
class TeslaRoute {
  const TeslaRoute({
    required this.name,
    required this.destination,
    this.waypoints = const [],
    this.avoidTolls = false,
    this.droppedStops = const [],
  });

  final String name;
  final LatLng destination;
  final List<LatLng> waypoints;
  final bool avoidTolls;

  /// Stops the Google link named but gave no coordinates for. The trip is still
  /// drivable without them, and the driver is told rather than left guessing.
  final List<String> droppedStops;
}
