// Shared constants & helpers used across the map, profile and settings screens.

// ── SharedPreferences keys ────────────────────────────────────────────────────
const kDefaultConnector = 'default_connector';   // JSON list of connector labels
const kActiveCountries  = 'active_countries';     // JSON list of country names
const kSupportPopupLastShown = 'support_popup_last_shown'; // int: epoch ms of last show

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

// ── Countries ─────────────────────────────────────────────────────────────────
// `localCovered` = we already ship rich local provider data for this country
// (the Gist providers), so it is NOT fetched from Open Charge Map. Everything
// else (incl. Turkey + all of Europe) is loaded live from OCM as "International".
// Bounding boxes are only needed to classify our local (coordinate-only) stations.
class CountryDef {
  const CountryDef(
    this.name,
    this.flag,
    this.code, {
    this.latMin,
    this.latMax,
    this.lngMin,
    this.lngMax,
    this.localCovered = false,
  });
  final String  name, flag, code; // code = ISO 3166-1 alpha-2 (for OCM countrycode)
  final double? latMin, latMax, lngMin, lngMax;
  final bool    localCovered;

  bool get hasBox => latMin != null;
  bool contains(double lat, double lng) =>
      hasBox &&
      lat >= latMin! && lat <= latMax! &&
      lng >= lngMin! && lng <= lngMax!;
}

// Georgia is always first; every other country follows in alphabetical order.
final List<CountryDef> kCountries = _buildCountries();

List<CountryDef> _buildCountries() {
  const georgia = CountryDef('Georgia', '🇬🇪', 'GE',
      latMin: 41.0, latMax: 43.6, lngMin: 40.0, lngMax: 46.7, localCovered: true);

  final others = <CountryDef>[
    const CountryDef('Albania', '🇦🇱', 'AL'),
    const CountryDef('Andorra', '🇦🇩', 'AD'),
    // Armenia & Turkey have local provider data (boxes); Armenia is localCovered.
    const CountryDef('Armenia', '🇦🇲', 'AM',
        latMin: 38.8, latMax: 41.3, lngMin: 43.4, lngMax: 46.6, localCovered: true),
    const CountryDef('Austria', '🇦🇹', 'AT'),
    const CountryDef('Azerbaijan', '🇦🇿', 'AZ'),
    const CountryDef('Belarus', '🇧🇾', 'BY'),
    const CountryDef('Belgium', '🇧🇪', 'BE'),
    const CountryDef('Bosnia and Herzegovina', '🇧🇦', 'BA'),
    const CountryDef('Bulgaria', '🇧🇬', 'BG'),
    const CountryDef('Croatia', '🇭🇷', 'HR'),
    const CountryDef('Cyprus', '🇨🇾', 'CY'),
    const CountryDef('Czechia', '🇨🇿', 'CZ'),
    const CountryDef('Denmark', '🇩🇰', 'DK'),
    const CountryDef('Estonia', '🇪🇪', 'EE'),
    const CountryDef('Finland', '🇫🇮', 'FI'),
    const CountryDef('France', '🇫🇷', 'FR'),
    const CountryDef('Germany', '🇩🇪', 'DE'),
    const CountryDef('Greece', '🇬🇷', 'GR'),
    const CountryDef('Hungary', '🇭🇺', 'HU'),
    const CountryDef('Iceland', '🇮🇸', 'IS'),
    const CountryDef('Ireland', '🇮🇪', 'IE'),
    const CountryDef('Italy', '🇮🇹', 'IT'),
    const CountryDef('Kosovo', '🇽🇰', 'XK'),
    const CountryDef('Latvia', '🇱🇻', 'LV'),
    const CountryDef('Liechtenstein', '🇱🇮', 'LI'),
    const CountryDef('Lithuania', '🇱🇹', 'LT'),
    const CountryDef('Luxembourg', '🇱🇺', 'LU'),
    const CountryDef('Malta', '🇲🇹', 'MT'),
    const CountryDef('Moldova', '🇲🇩', 'MD'),
    const CountryDef('Monaco', '🇲🇨', 'MC'),
    const CountryDef('Montenegro', '🇲🇪', 'ME'),
    const CountryDef('Netherlands', '🇳🇱', 'NL'),
    const CountryDef('North Macedonia', '🇲🇰', 'MK'),
    const CountryDef('Norway', '🇳🇴', 'NO'),
    const CountryDef('Poland', '🇵🇱', 'PL'),
    const CountryDef('Portugal', '🇵🇹', 'PT'),
    const CountryDef('Romania', '🇷🇴', 'RO'),
    const CountryDef('Russia', '🇷🇺', 'RU'),
    const CountryDef('San Marino', '🇸🇲', 'SM'),
    const CountryDef('Serbia', '🇷🇸', 'RS'),
    const CountryDef('Slovakia', '🇸🇰', 'SK'),
    const CountryDef('Slovenia', '🇸🇮', 'SI'),
    const CountryDef('Spain', '🇪🇸', 'ES'),
    const CountryDef('Sweden', '🇸🇪', 'SE'),
    const CountryDef('Switzerland', '🇨🇭', 'CH'),
    const CountryDef('Turkey', '🇹🇷', 'TR',
        latMin: 35.8, latMax: 42.1, lngMin: 26.0, lngMax: 44.8),
    const CountryDef('Ukraine', '🇺🇦', 'UA'),
    const CountryDef('United Kingdom', '🇬🇧', 'GB'),
  ]..sort((a, b) => a.name.compareTo(b.name));

  return [georgia, ...others];
}

// ISO code -> our country name (so OCM stations match our selection names).
final Map<String, String> _kCodeToName = {
  for (final c in kCountries) c.code: c.name,
};
String? countryNameForCode(String? code) =>
    code == null ? null : _kCodeToName[code.toUpperCase()];

/// The country a coordinate falls in (first matching box; Georgia checked
/// first), or null if it sits outside every boxed country.
String? countryOf(double lat, double lng) {
  for (final c in kCountries) {
    if (c.contains(lat, lng)) { return c.name; }
  }
  return null;
}
