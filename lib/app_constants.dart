// Shared constants & helpers used across the map, profile and settings screens.

// ── SharedPreferences keys ────────────────────────────────────────────────────
const kDefaultConnector = 'default_connector';   // JSON list of connector labels
const kActiveCountries  = 'active_countries';     // JSON list of country names
const kSelectedProviders = 'selected_providers';  // JSON list of provider names
const kKnownProviders   = 'known_providers';      // JSON list: provider rows this install was already offered
const kSupportPopupLastShown = 'support_popup_last_shown'; // int: epoch ms of last show
const kMinPowerEnabled  = 'min_power_enabled';    // bool: min-power map filter on/off
const kMinPowerKw       = 'min_power_kw';         // int: minimum charger power in kW
const kNewStationAlerts = 'new_station_alerts';   // bool: broadcast push when a provider opens a station

// ── Tbilisi City Hall's free chargers ─────────────────────────────────────────
/// Provider key for the free posts the city itself runs.
///
/// Unlike every other row on the map this is not an operator: City Hall has no
/// API, no live status and no way to tell us whether a post is working right
/// now. The list is an official spreadsheet, so the app may say where the posts
/// are and nothing more — see [kCityHallOptIn] for why they are also off until
/// asked for, and the station sheet for the wording that goes with them.
///
/// Stored in the feed, in the saved provider selection and in the logo maps, so
/// the spelling is fixed; the name the user READS is localised separately.
const kCityHallProvider = 'Tbilisi City Hall';

/// Providers that stay off until the user ticks them, and are never switched on
/// for anyone by us.
///
/// Every other provider we add is switched on for existing installs (see
/// [providersToAutoEnable]) because a new network is something the user wants to
/// see. City Hall is the opposite: the posts have no live status, so putting 33
/// pins of unknown state on everyone's map uninvited would make the map less
/// trustworthy, not more. Until the user opts in, these stations do not exist
/// as far as the map, the carousel and the route planner are concerned — which
/// is also why an empty selection ("no filter, show everything") still leaves
/// them out.
bool requiresExplicitOptIn(String provider) => provider == kCityHallProvider;

// ── New-network migration ─────────────────────────────────────────────────────
/// Local providers to switch on for an install whose saved selection predates
/// them, i.e. networks we added after the user last chose.
///
/// [saved] is the selection restored from [kSelectedProviders], [known] is what
/// that install was already offered ([kKnownProviders], or the historical list
/// for an install from before that key existed) and [local] is every local
/// provider we offer now. Without this a new network is invisible to every
/// upgrader, because restoring keeps only names that were saved and a name
/// added later never could be.
///
/// An empty [saved] set means "no filter, show everything", so nothing is added
/// to it — one name would turn that into "show only that one network".
Set<String> providersToAutoEnable({
  required Set<String> saved,
  required Set<String> known,
  required Iterable<String> local,
}) {
  if (saved.isEmpty) { return const <String>{}; }
  return {
    for (final p in local)
      if (!known.contains(p) && !saved.contains(p)) p,
  };
}

// ── Minimum-power presets (kW) ────────────────────────────────────────────────
// Shared by the profile filter and the route planner. Values mirror the real
// charger tiers found in the data (22 AC, 50/60 mid DC, 100+ fast DC).
const kMinPowerSteps = <int>[22, 50, 60, 100, 150];

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

// Display order, used everywhere countries are shown to the user: home country
// first, then the two neighbours a Georgian driver actually crosses into, then
// everything else A→Z. This is presentation only — see [countryOf] for the
// separate order a coordinate is classified in.
final List<CountryDef> kCountries = _buildCountries();

// Pulled to the top of the list, in this order, ahead of the alphabet.
const _kPinnedCountries = ['Georgia', 'Turkey', 'Armenia'];

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
    // Turkey is localCovered: TurkeyService ships the EPDK registry (≈5x the
    // stations OCM has, with real brand names and tariffs) and the builder has
    // already merged in the OCM rows that EPDK doesn't list, so fetching OCM
    // here again would only duplicate pins.
    const CountryDef('Turkey', '🇹🇷', 'TR',
        latMin: 35.8, latMax: 42.1, lngMin: 26.0, lngMax: 44.8,
        localCovered: true),
    const CountryDef('Ukraine', '🇺🇦', 'UA'),
    const CountryDef('United Kingdom', '🇬🇧', 'GB'),
  ]..sort((a, b) => a.name.compareTo(b.name));

  // Lift the pinned countries out of the alphabet, keeping their given order.
  final pinned = <CountryDef>[
    georgia,
    for (final name in _kPinnedCountries.skip(1))
      ...others.where((c) => c.name == name),
  ];
  others.removeWhere((c) => _kPinnedCountries.contains(c.name));
  return [...pinned, ...others];
}

// ISO code -> our country name (so OCM stations match our selection names).
final Map<String, String> _kCodeToName = {
  for (final c in kCountries) c.code: c.name,
};
String? countryNameForCode(String? code) =>
    code == null ? null : _kCodeToName[code.toUpperCase()];

// The order a coordinate is tested against the country boxes. This is a
// CORRECTNESS ordering and deliberately not the display one, because the boxes
// overlap and first match wins: the Armenian box (38.8–41.3 N, 43.4–46.6 E) sits
// partly inside the Turkish one (35.8–42.1 N, 26.0–44.8 E), so Gyumri
// (40.79 N, 43.84 E) is inside both and reads as Turkish unless Armenia is
// tested first. Georgia leads for the same reason against both of them.
// Keeping this list apart from [kCountries] means the Settings list can be
// reordered without silently relabelling real stations.
const _kClassifyOrder = ['Georgia', 'Armenia', 'Turkey'];

/// The country a coordinate falls in, or null if it sits outside every boxed
/// country. See [_kClassifyOrder] for why the test order is not the list order.
String? countryOf(double lat, double lng) {
  for (final name in _kClassifyOrder) {
    for (final c in kCountries) {
      if (c.name == name && c.contains(lat, lng)) { return c.name; }
    }
  }
  // Any other boxed country still gets a look, after the overlapping trio.
  for (final c in kCountries) {
    if (!_kClassifyOrder.contains(c.name) && c.contains(lat, lng)) {
      return c.name;
    }
  }
  return null;
}
