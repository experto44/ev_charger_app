// Country selection for the map.
//
// GeoCharge for Tesla covers three countries a driver from Tbilisi actually
// reaches by road. Georgia and Armenia both live in the Georgian feed (they are
// told apart by coordinates, exactly like CountryDef.contains in
// lib/app_constants.dart); Turkey is its own multi-megabyte dataset, so it is
// only downloaded once the driver asks for it.

import { TURKEY_BOUNDS } from './config.js';

const STORAGE_KEY = 'gc_countries';

/** Boxes mirror the CountryDef entries in lib/app_constants.dart. */
export const COUNTRIES = [
  {
    code: 'GE',
    key: 'countryGeorgia',
    flag: '🇬🇪',
    bounds: { south: 41.0, north: 43.6, west: 40.0, east: 46.7 },
    centre: { lat: 42.0, lng: 43.5 },
  },
  {
    code: 'AM',
    key: 'countryArmenia',
    flag: '🇦🇲',
    bounds: { south: 38.8, north: 41.3, west: 43.4, east: 46.6 },
    centre: { lat: 40.2, lng: 44.9 },
  },
  {
    code: 'TR',
    key: 'countryTurkey',
    flag: '🇹🇷',
    bounds: TURKEY_BOUNDS,
    centre: { lat: 39.5, lng: 33.5 },
  },
];

const byCode = new Map(COUNTRIES.map((c) => [c.code, c]));

function inBox(b, lat, lng) {
  return lat >= b.south && lat <= b.north && lng >= b.west && lng <= b.east;
}

/**
 * Which country a station belongs to. The Turkish dataset says so outright;
 * everything else is placed by coordinates, Georgia first — its box and
 * Armenia's overlap slightly around the border, and the Georgian feed's own
 * stations should read as Georgian there.
 */
export function stationCountry(s) {
  if (s.country === 'Turkey') return 'TR';
  for (const c of COUNTRIES) {
    if (inBox(c.bounds, s.lat, s.lng)) return c.code;
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
