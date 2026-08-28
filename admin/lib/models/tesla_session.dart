import 'package:cloud_firestore/cloud_firestore.dart';

/// One visit to tesla.geocharge.ge, written by the car itself
/// (`tesla/js/usage.js`) into `teslaSessions/{id}`.
///
/// [seconds] is ACTIVE time: the car stops the clock while its browser tab is
/// hidden, so a Tesla parked overnight with the page open does not report a
/// nine-hour session. That makes this the honest answer to "how long did they
/// use it", which is the whole reason the collection exists — GA4 knows how
/// many sessions there were but not whose they were.
class TeslaSession {
  const TeslaSession({
    required this.id,
    required this.uid,
    this.email = '',
    this.startedAt,
    this.lastSeenAt,
    this.seconds = 0,
    this.drives = 0,
  });

  final String id;
  final String uid;

  /// The account's email as the car saw it. Stored on the row so a session
  /// still has a face even if the `users` document is missing.
  final String email;

  final DateTime? startedAt;
  final DateTime? lastSeenAt;

  /// Active seconds in this visit.
  final int seconds;

  /// Navigations started during it — the difference between looking at the map
  /// and actually driving somewhere.
  final int drives;

  Duration get duration => Duration(seconds: seconds);

  static DateTime? _date(dynamic v) =>
      v is Timestamp ? v.toDate() : (v is DateTime ? v : null);

  factory TeslaSession.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const {};
    return TeslaSession(
      id: doc.id,
      uid: (d['uid'] ?? '') as String,
      email: (d['email'] ?? '') as String,
      startedAt: _date(d['startedAt']),
      lastSeenAt: _date(d['lastSeenAt']),
      seconds: (d['seconds'] as num?)?.round() ?? 0,
      drives: (d['drives'] as num?)?.round() ?? 0,
    );
  }
}
