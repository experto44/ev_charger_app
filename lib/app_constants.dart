// Shared constants & helpers used across the map, profile and settings screens.

// ── SharedPreferences keys ────────────────────────────────────────────────────
const kDefaultConnector = 'default_connector';   // String: one connector label
const kActiveCountries  = 'active_countries';     // JSON list of country names

// ── Connector display order ───────────────────────────────────────────────────
// Canonical order used EVERYWHERE connectors are shown (filter chips, profile
// chips, station detail). Anything not listed sorts after these, alphabetically.
const kConnectorOrder = <String>[
  'CCS2', 'GB/T', 'CHAdeMO', 'Type 2', 'NACS', 'CCS1', 'Type 1',
];

/// Returns [conns] sorted by [kConnectorOrder]; unknown types go last (A→Z).
List<String> sortConnectors(Iterable<String> conns) {
  int rank(String c) {
    final i = kConnectorOrder.indexOf(c);
    return i == -1 ? kConnectorOrder.length : i;
  }
  final list = conns.toList();
  list.sort((a, b) {
    final ra = rank(a), rb = rank(b);
    return ra != rb ? ra.compareTo(rb) : a.compareTo(b);
  });
  return list;
}

// ── Countries (coordinate bounding boxes) ─────────────────────────────────────
class CountryDef {
  const CountryDef(
      this.name, this.flag, this.latMin, this.latMax, this.lngMin, this.lngMax);
  final String name, flag;
  final double latMin, latMax, lngMin, lngMax;

  bool contains(double lat, double lng) =>
      lat >= latMin && lat <= latMax && lng >= lngMin && lng <= lngMax;
}

const kCountries = <CountryDef>[
  CountryDef('Georgia', '🇬🇪', 41.0, 43.6, 40.0, 46.7),
  CountryDef('Armenia', '🇦🇲', 38.8, 41.3, 43.4, 46.6),
  CountryDef('Turkey',  '🇹🇷', 35.8, 42.1, 26.0, 44.8),
];

/// The country a coordinate falls in (first matching box), or null if it sits
/// outside every known box (such stations are always shown — never filtered).
String? countryOf(double lat, double lng) {
  for (final c in kCountries) {
    if (c.contains(lat, lng)) { return c.name; }
  }
  return null;
}
