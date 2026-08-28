import 'package:cloud_firestore/cloud_firestore.dart';

/// One day of Google Maps Platform usage, as read from Cloud Monitoring by the
/// `pullMapsUsage` function and written to `mapsUsage/{YYYY-MM-DD}`.
///
/// Days are Tbilisi days. The counts are successful (2xx) requests per API —
/// what Google actually served, and therefore what it would bill for; a request
/// it refused is not usage.
class MapsUsageDay {
  const MapsUsageDay({
    required this.day,
    this.calls = const {},
    this.stale = const [],
    this.updatedAt,
  });

  /// `YYYY-MM-DD`, Asia/Tbilisi.
  final String day;

  /// Requests per API key: `maps`, `directions`, `places`, `geocoding`.
  final Map<String, int> calls;

  /// APIs the last refresh could not read (almost always a missing IAM grant on
  /// the Maps project). Their numbers on this row are the last good ones, not
  /// today's — the panel says so rather than showing a confident zero.
  final List<String> stale;

  final DateTime? updatedAt;

  int operator [](String api) => calls[api] ?? 0;

  /// The date this row is for, at local midnight.
  DateTime? get date => DateTime.tryParse(day);

  factory MapsUsageDay.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const {};
    final calls = <String, int>{};
    for (final key in const ['maps', 'directions', 'places', 'geocoding']) {
      final v = d[key];
      if (v is num) calls[key] = v.round();
    }
    return MapsUsageDay(
      day: (d['day'] as String?) ?? doc.id,
      calls: calls,
      stale: [for (final s in (d['stale'] as List? ?? const [])) s.toString()],
      updatedAt: d['updatedAt'] is Timestamp
          ? (d['updatedAt'] as Timestamp).toDate()
          : null,
    );
  }
}
