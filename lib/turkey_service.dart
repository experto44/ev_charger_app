import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'routing_service.dart';

/// Turkish charging network, built from the EPDK registry.
///
/// Turkey is the one country Georgian drivers actually drive into, so it gets
/// its own dataset instead of the generic Open Charge Map feed: every publicly
/// usable charger in Turkey is licensed by EPDK (the energy regulator) and
/// listed in its public registry, which carries roughly five times the stations
/// OCM knows about, plus the operator's registered brand. `tools/build_turkey.py`
/// turns that registry into the same production station schema the Georgian
/// gist uses, stamps each station with its brand's published tariff, and tops
/// the result up with the OCM rows that have no EPDK match.
///
/// The file is big (thousands of stations), so unlike the Georgian feed it is
/// NOT downloaded at launch: it loads the first time the user actually looks at
/// Turkey, then lives in a disk cache. A stale cache still serves when the
/// refresh fails — abroad, on roaming data, old pins beat no pins.
class TurkeyService {
  /// Label the provider filter groups every Turkish network under. Individual
  /// stations still carry their real brand ("ZES", "Eşarj", …) in `provider`;
  /// this is only the single on/off row in the filter sheet, because listing
  /// 200-odd Turkish brands there would be unusable.
  static const kProvider = 'Turkey';

  /// Country name stamped into every row by the builder (matches the app's
  /// CountryDef name, so the country filter and the pins agree).
  static const kCountry = 'Turkey';

  // Its OWN gist, deliberately not a second file inside the Georgian one:
  //  • the app fetches this only when the user looks at Turkey, so a Georgian
  //    driver never pays for a download they'll never use;
  //  • update_gist.yml re-sends every other file it finds in its gist when it
  //    patches chargers.json, and GitHub truncates file content over 1 MB in
  //    that read — sharing a gist would let the 5-minute Georgian job write a
  //    truncated Turkish file back over the good one.
  static const _url =
      'https://gist.githubusercontent.com/experto44/8cb62fc7ad6d86e3172eec6aedd4dba6'
      '/raw/chargers_tr.json';

  // The registry moves slowly (new stations show up over weeks) and there is no
  // live availability in it, so a multi-day cache costs the user nothing.
  static const _kDiskTtl  = Duration(days: 3);
  static const _kTimeout  = Duration(seconds: 45);

  static List<Station>? _cache;
  static Future<List<Station>>? _inFlight;

  /// Every Turkish station. Resolution order: session memory → fresh disk
  /// cache → network (saved to disk) → stale disk cache. Returns an empty list
  /// only when we have never managed to fetch the file.
  ///
  /// Concurrent callers share one fetch — the map can ask on a country change
  /// and on a viewport settle at the same moment.
  static Future<List<Station>> fetchAll() {
    final hit = _cache;
    if (hit != null) { return Future.value(hit); }
    return _inFlight ??= _load().whenComplete(() => _inFlight = null);
  }

  static Future<List<Station>> _load() async {
    final disk = await _loadDisk();
    if (disk != null && disk.fresh) { return _cache = disk.stations; }

    try {
      final res = await http.get(Uri.parse(_url)).timeout(_kTimeout);
      if (res.statusCode == 200) {
        // Decode + map off the UI isolate: this payload is megabytes.
        final list = await compute(_parse, res.body);
        if (list.isNotEmpty) {
          unawaited(_saveDisk(res.body));
          return _cache = list;
        }
      }
    } catch (_) {
      // Offline, timeout, or a malformed file — fall through to the cache.
    }

    if (disk != null && disk.stations.isNotEmpty) {
      return _cache = disk.stations;
    }
    return const [];
  }

  /// Distinct brands present in the loaded data, most stations first. Used by
  /// the station sheet / debug views; empty until [fetchAll] has resolved.
  static List<String> get providers {
    final counts = <String, int>{};
    for (final s in _cache ?? const <Station>[]) {
      counts[s.provider] = (counts[s.provider] ?? 0) + 1;
    }
    final names = counts.keys.toList()
      ..sort((a, b) => counts[b]!.compareTo(counts[a]!));
    return names;
  }

  // ── Disk cache ──────────────────────────────────────────────────────────

  static Future<File?> _file() async {
    if (kIsWeb) { return null; }
    try {
      final dir = await getApplicationSupportDirectory();
      return File('${dir.path}${Platform.pathSeparator}chargers_tr.json');
    } catch (_) {
      return null;
    }
  }

  static Future<_DiskHit?> _loadDisk() async {
    try {
      final file = await _file();
      if (file == null || !await file.exists()) { return null; }
      final stat = await file.stat();
      final age  = DateTime.now().difference(stat.modified);
      final list = await compute(_parse, await file.readAsString());
      if (list.isEmpty) { return null; }
      return _DiskHit(list, fresh: age < _kDiskTtl);
    } catch (_) {
      return null; // corrupt cache is the same as no cache
    }
  }

  static Future<void> _saveDisk(String body) async {
    try {
      final file = await _file();
      if (file != null) { await file.writeAsString(body); }
    } catch (_) {/* cache write failures are non-fatal */}
  }
}

class _DiskHit {
  const _DiskHit(this.stations, {required this.fresh});
  final List<Station> stations;
  final bool fresh;
}

// Isolate entry point: decode the file into stations. Rows the builder emitted
// without usable coordinates are dropped rather than crashing the whole parse.
List<Station> _parse(String body) {
  final decoded = jsonDecode(body);
  if (decoded is! List) { return const []; }
  final out = <Station>[];
  for (final row in decoded) {
    if (row is! Map<String, dynamic>) { continue; }
    try {
      out.add(Station.fromJson(row));
    } catch (_) {
      continue;
    }
  }
  return out;
}
