/// Everything that decides HOW STALE the availability number on screen is.
///
/// Availability reaches the app through a Gist that a GitHub Actions loop
/// rewrites every ~2.5 min. Three further delays used to stack on top of that
/// and leave the app up to ~11 minutes behind reality — a driver watched a plug
/// he had just seen taken read "free" for ten more minutes:
///
///  1. Fastly serves the raw Gist URL with `Cache-Control: max-age=300`, so the
///     app could be handed a five-minute-old copy however often it asked, and
///     re-opening the app did not help because it asked for the same URL.
///     Every request from here carries a cache-busting query parameter.
///  2. Asking again meant re-downloading 529 KB, so the app could not afford to
///     ask often and had no way to tell whether anything had actually changed.
///     Requests now send `If-None-Match`; a 304 answers "nothing changed" in a
///     couple of hundred bytes, which is also the honest answer for the button.
///  3. Even a successful re-read only returned the pipeline's snapshot, taken up
///     to a full cycle earlier. For the four Georgian networks running AMPECO
///     the app can now read the operator's own API for a single station instead:
///     one request, ~1s old, rather than ~10 min.
///
/// The direct reads in (3) go to reverse-engineered endpoints. If an operator
/// ever gates or blocks them, every user's refresh button breaks at once and an
/// app release takes weeks of store review — so the feed also carries a
/// `config.json` kill-switch that routes everyone back through the Gist within
/// one poll. See [LiveConfig].
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;

import '../routing_service.dart' show ConnectorPort, Station;

// ── Feed location ────────────────────────────────────────────────────────────
// Always the latest revision (no pinned commit hash).
const _kGistBase =
    'https://gist.githubusercontent.com/experto44/36f39392ce7a4abe14ab065aa8e846bd/raw';
const _kFeedUrl   = '$_kGistBase/chargers.json';
const _kConfigUrl = '$_kGistBase/config.json';

/// AMPECO networks the app may read directly, keyed by the prefix their station
/// ids carry (`martev_220` → `cp.martev.io`, location `220`).
///
/// Mirrors `AMPECO_HOSTS` in `.github/workflows/update_gist.yml`. The two are
/// the same table in two languages and must be edited together.
const _kAmpecoHosts = <String, String>{
  'martev':    'cp.martev.io',
  'moveo':     'cp.moveo.ge',
  'electrify': 'cp.electrify.ge',
  'evpower':   'cp.evpower.ge',
};

/// Headers the operators' own apps send. Matching them keeps our traffic
/// indistinguishable from ordinary app traffic.
const _kAmpecoHeaders = <String, String>{
  'Accept': 'application/json',
  'Accept-Language': 'ka',
  'App-Version': '3.130.0',
  'X-Internal-App-Version': '3.130.0',
};

/// EVSE statuses that mean a session is under way. Mirrors `SESSION` in the
/// updater workflow.
const _kSessionStatuses = <String>{
  'charging', 'preparing', 'finishing', 'occupied', 'reserved',
  'suspendedev', 'suspendedevse', 'inuse', 'intransaction',
};

/// Connector aliases → the chip labels the filters use. Mirrors `CONN_MAP`.
const _kConnectorAliases = <String, String>{
  'ccs': 'CCS2', 'ccs2': 'CCS2', 'combo2': 'CCS2', 'iec62196t2combo': 'CCS2',
  'ccs1': 'CCS1', 'combo1': 'CCS1',
  'chademo': 'CHAdeMO',
  'type2': 'Type 2', 'mennekes': 'Type 2', 'iec62196t2': 'Type 2',
  'type1': 'Type 1', 'j1772': 'Type 1',
  'gbt': 'GB/T', 'gbtdc': 'GB/T', 'gbtac': 'GB/T',
  'gbtdccable': 'GB/T', 'chinese': 'GB/T', 'gbtgb': 'GB/T',
  'nacs': 'NACS', 'tesla': 'NACS',
};

String? _normalizeConnector(String? raw) {
  if (raw == null || raw.trim().isEmpty) { return null; }
  final k = raw
      .toLowerCase()
      .replaceAll(' ', '')
      .replaceAll('-', '')
      .replaceAll('_', '')
      .replaceAll('/', '');
  return _kConnectorAliases[k];
}

// ── Feed fetch outcome ───────────────────────────────────────────────────────
/// What a feed request actually achieved. [unchanged] exists because a request
/// that correctly found nothing new is a success, not a failure — conflating the
/// two is what made the refresh button claim "Updated" every single time.
enum FeedStatus { updated, unchanged, failed }

class FeedResponse {
  const FeedResponse(this.status, [this.body]);
  final FeedStatus status;

  /// Raw feed JSON. Non-null only when [status] is [FeedStatus.updated].
  final String? body;
}

/// How a station-level refresh went, in the same three flavours.
enum RefreshOutcome { updated, unchanged, failed }

class StationRefresh {
  const StationRefresh(this.outcome, [this.station, this.direct = false]);
  const StationRefresh.failed()
      : outcome = RefreshOutcome.failed, station = null, direct = false;
  final RefreshOutcome outcome;

  /// The station as it stands now. Null only on [RefreshOutcome.failed].
  final Station? station;

  /// True when this came from the operator's own API rather than the feed. The
  /// difference is worth surfacing: a feed reading is a pipeline snapshot that
  /// can be a couple of minutes old, a direct one is a second old, and telling
  /// the user "not real-time" under a reading that IS real-time is exactly the
  /// kind of wrong caption this work exists to remove.
  final bool direct;
}

// ── Remote configuration ─────────────────────────────────────────────────────
/// Settings the feed can change without an app release, read from `config.json`
/// next to the station data. Hand-editing that file in the Gist takes effect for
/// every user within one poll.
class LiveConfig {
  const LiveConfig({required this.directFetchEnabled, required this.directProviders});

  final bool directFetchEnabled;
  final Set<String> directProviders;

  /// Used until the file has been read, and whenever it cannot be parsed. Direct
  /// reads default to ON: the switch exists for the case where an operator
  /// blocks us while the Gist is perfectly reachable, and in that case the real
  /// file will have been read anyway.
  static const fallback = LiveConfig(
    directFetchEnabled: true,
    directProviders: {'mart EV', 'MOVEO', 'Electrify Georgia', 'EV Power GE'},
  );

  factory LiveConfig.fromJson(Map<String, dynamic> j) {
    final d = j['direct_fetch'];
    if (d is! Map<String, dynamic>) { return fallback; }
    return LiveConfig(
      directFetchEnabled: d['enabled'] as bool? ?? fallback.directFetchEnabled,
      directProviders: (d['providers'] as List?)
              ?.whereType<String>()
              .toSet() ??
          fallback.directProviders,
    );
  }
}

// ── Service ──────────────────────────────────────────────────────────────────
class LiveStatusService {
  LiveStatusService._();
  static final LiveStatusService I = LiveStatusService._();

  /// Fingerprint of the feed body we last parsed, replayed as `If-None-Match`.
  String? _feedETag;
  String? _configETag;

  LiveConfig _config = LiveConfig.fallback;
  LiveConfig get config => _config;
  DateTime _configCheckedAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Last direct read per station id, so repeat taps are answered from memory
  /// instead of from the operator. These are reverse-engineered endpoints; a
  /// user holding the button down must not turn into a burst against them.
  final Map<String, ({DateTime at, Station station})> _directCache = {};

  static const _kDirectCooldown = Duration(seconds: 15);
  static const _kConfigInterval = Duration(minutes: 5);

  /// Feed URL, cache-busted.
  ///
  /// Background polls bucket the parameter to the current minute so that every
  /// user in that minute shares one CDN entry: staleness drops from five minutes
  /// to one, while the origin still serves roughly one request per minute no
  /// matter how many people have the app open. A user-initiated refresh gets a
  /// unique value, because that person is standing at the charger and a fresh
  /// answer is worth one uncached fetch.
  String _feedUrl({required bool unique}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final t = unique ? now : now ~/ 60000;
    return '$_kFeedUrl?t=$t';
  }

  /// Fetch the station feed. Never throws.
  ///
  /// Set [requireBody] when the caller has nothing to fall back on (a cold
  /// start): a 304 is a useful answer only to someone already holding the data
  /// it refers to, and answering an empty app with one would leave it showing
  /// the bundled snapshot for no reason.
  Future<FeedResponse> fetchFeed({
    bool userInitiated = false,
    bool requireBody = false,
  }) async {
    unawaited(_refreshConfig());
    try {
      final res = await http.get(
        Uri.parse(_feedUrl(unique: userInitiated)),
        headers: {
          if (!requireBody && _feedETag != null) 'If-None-Match': _feedETag!,
        },
      ).timeout(const Duration(seconds: 8));
      if (res.statusCode == 304) {
        return const FeedResponse(FeedStatus.unchanged);
      }
      if (res.statusCode == 200) {
        // Only remember the tag once the caller has a body it can parse; a tag
        // stored for content we failed on would suppress the retry.
        _feedETag = res.headers['etag'];
        return FeedResponse(FeedStatus.updated, res.body);
      }
    } catch (_) {
      // Offline, timeout, DNS — the caller keeps whatever it already had.
    }
    return const FeedResponse(FeedStatus.failed);
  }

  /// Drop the cached fingerprint so the next fetch is guaranteed to return a
  /// body. Used when parsing failed and the caller has nothing to show.
  void forgetFeedETag() => _feedETag = null;

  /// Re-read `config.json`, at most once every [_kConfigInterval]. Best effort:
  /// a failure leaves the previous settings in place.
  Future<void> _refreshConfig() async {
    if (DateTime.now().difference(_configCheckedAt) < _kConfigInterval) { return; }
    _configCheckedAt = DateTime.now();
    try {
      final res = await http.get(
        Uri.parse('$_kConfigUrl?t=${DateTime.now().millisecondsSinceEpoch ~/ 60000}'),
        headers: {if (_configETag != null) 'If-None-Match': _configETag!},
      ).timeout(const Duration(seconds: 6));
      if (res.statusCode != 200) { return; }
      final j = jsonDecode(res.body);
      if (j is Map<String, dynamic>) {
        _config = LiveConfig.fromJson(j);
        _configETag = res.headers['etag'];
      }
    } catch (_) {
      // Keep the settings we already have.
    }
  }

  // ── Direct-from-operator reads ─────────────────────────────────────────────
  /// Splits `martev_220` into its operator host and location id.
  (String host, String locId)? _target(String stationId) {
    final i = stationId.indexOf('_');
    if (i <= 0 || i == stationId.length - 1) { return null; }
    final host = _kAmpecoHosts[stationId.substring(0, i)];
    if (host == null) { return null; }
    return (host, stationId.substring(i + 1));
  }

  /// True when [s] can be read straight from its operator right now.
  bool canFetchDirect(Station s) =>
      _target(s.id) != null &&
      _config.directFetchEnabled &&
      _config.directProviders.contains(s.provider);

  /// Re-read one station from its operator's own API, ~1s instead of waiting for
  /// the pipeline's next cycle.
  ///
  /// Returns a copy of [station] carrying live availability, or null when the
  /// call failed, the response did not describe this station, or the operator
  /// reported no plugs at all. Every null means "fall back to the feed", so this
  /// path can never leave the user worse off than before it existed.
  Future<Station?> fetchDirect(Station station) async {
    final t = _target(station.id);
    if (t == null) { return null; }

    final cached = _directCache[station.id];
    if (cached != null &&
        DateTime.now().difference(cached.at) < _kDirectCooldown) {
      return cached.station;
    }

    try {
      final res = await http.get(
        Uri.parse('https://${t.$1}/api/v1/app/locations/${t.$2}'),
        headers: _kAmpecoHeaders,
      ).timeout(const Duration(seconds: 6));
      if (res.statusCode != 200) { return null; }
      final updated = _applyAmpeco(station, res.body, t.$2);
      if (updated != null) {
        _directCache[station.id] = (at: DateTime.now(), station: updated);
      }
      return updated;
    } catch (_) {
      return null;
    }
  }

  /// Test seam for [_applyAmpeco]. The counting rules it implements are shared
  /// with the updater pipeline and are the one place these two codebases can
  /// silently disagree, so they are worth pinning directly.
  @visibleForTesting
  Station? applyAmpecoForTest(Station station, String body, String locId) =>
      _applyAmpeco(station, body, locId);

  /// Rebuild [station]'s live fields from an AMPECO location response, leaving
  /// every descriptive field as the feed published it.
  ///
  /// This mirrors the counting rules in `fetch_ampeco` in the updater workflow.
  /// The two must agree: if they drift, the map and this sheet start showing
  /// different statuses for the same charger, which is worse than either being
  /// a little stale. `test/ampeco_direct_test.dart` pins the shared rules.
  Station? _applyAmpeco(Station station, String body, String locId) {
    final Object? root;
    try {
      root = jsonDecode(body);
    } catch (_) {
      return null;
    }
    if (root is! Map<String, dynamic>) { return null; }
    final locations = root['locations'];
    if (locations is! List) { return null; }

    var available = 0;
    var total = 0;
    final ports = <ConnectorPort>[];
    var matched = false;

    for (final loc in locations.whereType<Map<String, dynamic>>()) {
      // One call can answer for several linked locations (AMPECO's
      // underlyingLocationIds); only the one this station's id points at
      // describes THIS station.
      if ('${loc['id']}' != locId) { continue; }
      matched = true;

      for (final zone in (loc['zones'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()) {
        for (final e in (zone['evses'] as List? ?? const [])
            .whereType<Map<String, dynamic>>()) {
          final cs = (e['connectors'] as List? ?? const [])
              .whereType<Map<String, dynamic>>()
              .toList();
          final plugs = cs.isEmpty ? 1 : cs.length; // an EVSE has >= 1 plug
          total += plugs;

          final st = (e['status'] as String? ?? '').trim().toLowerCase();
          // On a dual-connector DC cabinet (CCS2 + GB/T sharing one power
          // module) AMPECO marks the idle sibling status=unavailable while the
          // other charges. That means "sibling busy", never a broken unit —
          // those report out of order — so it counts as free, exactly as the
          // pipeline counts it.
          final isFree = e['isAvailable'] == true || st == 'unavailable';
          if (isFree) { available += plugs; }

          final status = isFree
              ? 'free'
              : (_kSessionStatuses.contains(st) ? 'busy' : 'out');
          final since = status == 'busy'
              ? DateTime.tryParse(e['startedAt'] as String? ?? '')
              : null;

          for (final c in cs) {
            final type = _normalizeConnector(
                    c['icon'] as String? ?? c['name'] as String?) ??
                (c['name'] as String? ?? '?');
            ports.add(ConnectorPort(type: type, status: status, since: since));
          }
        }
      }
    }

    // No matching location, or an operator answering with an empty rig, is not
    // something to render — let the caller fall back to the feed.
    if (!matched || total == 0) { return null; }

    return station.withLiveStatus(
      available: available,
      total: total,
      ports: ports,
      lastUpdated: _stampNow(),
    );
  }

  /// A "YYYY-MM-DD HH:MM UTC" stamp in the same shape the feed publishes, so the
  /// sheet's existing "Last verified" formatting keeps working unchanged.
  static String _stampNow() {
    final n = DateTime.now().toUtc();
    String p(int v) => v.toString().padLeft(2, '0');
    return '${n.year}-${p(n.month)}-${p(n.day)} ${p(n.hour)}:${p(n.minute)} UTC';
  }
}

/// True when two readings of the same station carry the same live state, i.e.
/// there is genuinely nothing new to show. Descriptive fields are ignored: the
/// question this answers is "did availability move?", which is the only thing
/// the refresh button is claiming when it says something changed.
bool sameLiveState(Station a, Station b) {
  if (a.available != b.available || a.total != b.total) { return false; }
  if (a.ports.length != b.ports.length) { return false; }
  for (var i = 0; i < a.ports.length; i++) {
    if (a.ports[i].type != b.ports[i].type ||
        a.ports[i].status != b.ports[i].status) {
      return false;
    }
  }
  return true;
}
