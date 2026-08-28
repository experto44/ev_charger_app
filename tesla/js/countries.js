// Country selection for the map.
//
// GeoCharge for Tesla covers three countries a driver from Tbilisi actually
// reaches by road. Georgia and Armenia both live in the Georgian feed (they are
// told apart by coordinates, exactly like CountryDef.contains in
// lib/app_constants.dart); Turkey is its own multi-megabyte dataset, so it is
// only downloaded once the driver asks for it.

import { TURKEY_BOUNDS } from './config.js';

const STORAGE_KEY = 'gc_countries';

/**
 * Flags as inline SVG rather than emoji. The Tesla browser is Chromium on
 * Linux, where the regional-indicator pairs behind 🇬🇪 / 🇹🇷 have no glyph and
 * fall back to drawing the letters "GE" and "TR" instead of a flag. Three
 * countries is three small drawings, and they render the same everywhere.
 */
const FLAG_SVG = {
  GE:
    '<svg class="flag" viewBox="0 0 24 16" aria-hidden="true">' +
    '<rect width="24" height="16" rx="2" fill="#fff"/>' +
    '<g fill="#d0021b">' +
    '<rect x="9.6" y="0" width="4.8" height="16"/>' +
    '<rect x="0" y="5.6" width="24" height="4.8"/>' +
    '<rect x="4.2" y="2.2" width="1.2" height="3.6"/><rect x="3" y="3.4" width="3.6" height="1.2"/>' +
    '<rect x="18.6" y="2.2" width="1.2" height="3.6"/><rect x="17.4" y="3.4" width="3.6" height="1.2"/>' +
    '<rect x="4.2" y="10.2" width="1.2" height="3.6"/><rect x="3" y="11.4" width="3.6" height="1.2"/>' +
    '<rect x="18.6" y="10.2" width="1.2" height="3.6"/><rect x="17.4" y="11.4" width="3.6" height="1.2"/>' +
    '</g></svg>',
  TR:
    '<svg class="flag" viewBox="0 0 24 16" aria-hidden="true">' +
    '<rect width="24" height="16" rx="2" fill="#e30a17"/>' +
    '<circle cx="9.6" cy="8" r="4.2" fill="#fff"/>' +
    '<circle cx="11.1" cy="8" r="3.4" fill="#e30a17"/>' +
    '<polygon fill="#fff" points="15.3,5.6 15.84,7.26 17.58,7.26 16.17,8.28 16.71,9.94 ' +
    '15.3,8.92 13.89,9.94 14.43,8.28 13.02,7.26 14.76,7.26"/>' +
    '</svg>',
  AM:
    '<svg class="flag" viewBox="0 0 24 16" aria-hidden="true">' +
    '<rect width="24" height="16" rx="2" fill="#f2a800"/>' +
    '<path d="M2 0h20a2 2 0 012 2v3.33H0V2a2 2 0 012-2z" fill="#d90012"/>' +
    '<rect y="5.33" width="24" height="5.34" fill="#0033a0"/>' +
    '</svg>',
};

/** The country's flag as inline SVG markup. Empty string for an unknown code. */
export function flagSvg(code) {
  return FLAG_SVG[code] ?? '';
}

/**
 * Boxes mirror the CountryDef entries in lib/app_constants.dart.
 *
 * Listed in the order the driver sees them, which matches the app's Settings:
 * home country first, then the neighbours. See CLASSIFY_ORDER below — that
 * order is deliberately different and must stay that way.
 */
export const COUNTRIES = [
  {
    code: 'GE',
    key: 'countryGeorgia',
    bounds: { south: 41.0, north: 43.6, west: 40.0, east: 46.7 },
    centre: { lat: 42.0, lng: 43.5 },
  },
  {
    code: 'TR',
    key: 'countryTurkey',
    bounds: TURKEY_BOUNDS,
    centre: { lat: 39.5, lng: 33.5 },
  },
  {
    code: 'AM',
    key: 'countryArmenia',
    bounds: { south: 38.8, north: 41.3, west: 43.4, east: 46.6 },
    centre: { lat: 40.2, lng: 44.9 },
  },
];

/**
 * The order a coordinate is tested against the boxes, which is a different
 * problem from the order they are listed in. The boxes overlap and first match
 * wins: Armenia's (38.8–41.3 N, 43.4–46.6 E) sits partly inside Turkey's
 * (35.8–42.1 N, 26.0–44.8 E), so Gyumri (40.79 N, 43.84 E) is in both and reads
 * as Turkish unless Armenia is tested first. Georgia leads against both.
 * Mirrors _kClassifyOrder in lib/app_constants.dart.
 */
const CLASSIFY_ORDER = ['GE', 'AM', 'TR'];

const byCode = new Map(COUNTRIES.map((c) => [c.code, c]));

function inBox(b, lat, lng) {
  return lat >= b.south && lat <= b.north && lng >= b.west && lng <= b.east;
}

/**
 * Which country a station belongs to. The Turkish dataset says so outright;
 * everything else is placed by coordinates, in CLASSIFY_ORDER rather than list
 * order — Georgia first because its box and Armenia's overlap around the
 * border and the Georgian feed's own stations should read as Georgian there,
 * then Armenia before Turkey for the western-Armenia overlap.
 */
export function stationCountry(s) {
  if (s.country === 'Turkey') return 'TR';
  for (const code of CLASSIFY_ORDER) {
    const c = byCode.get(code);
    if (c && inBox(c.bounds, s.lat, s.lng)) return c.code;
  }
  return '';
}

let selected = load();

function load() {
  try {
    const raw = JSON.parse(localStorage.getItem(STORAGE_KEY));
    if (Array.isArray(raw) && raw.length) {
      const valid = raw.filter((c) => byCode.has(c));
      if (valid.length) return new Set(valid);
    }
  } catch {
    /* corrupt value — fall through to the default */
  }
  return new Set(['GE']); // home country, on by default
}

export function selectedCountries() {
  return selected;
}

export function isSelected(code) {
  return selected.has(code);
}

/**
 * Toggle a country. Georgia can be switched off like any other, but the last
 * remaining country cannot — an empty map with no explanation reads as a bug.
 * Returns true when the selection actually changed.
 */
export function toggleCountry(code) {
  if (!byCode.has(code)) return false;
  if (selected.has(code)) {
    if (selected.size === 1) return false;
    selected.delete(code);
  } else {
    selected.add(code);
  }
  localStorage.setItem(STORAGE_KEY, JSON.stringify([...selected]));
  return true;
}

/** True when [bounds] of a selected country overlap the given map viewport. */
export function boundsVisible(code, mapBounds) {
  const c = byCode.get(code);
  if (!c || !mapBounds) return false;
  const sw = mapBounds.getSouthWest();
  const ne = mapBounds.getNorthEast();
  return (
    ne.lat() >= c.bounds.south &&
    sw.lat() <= c.bounds.north &&
    ne.lng() >= c.bounds.west &&
    sw.lng() <= c.bounds.east
  );
}

export function countryCentre(code) {
  return byCode.get(code)?.centre ?? null;
}
