// Charger catalog + live status. Mirrors the parsing rules of
// Station.fromJson in lib/routing_service.dart so both clients read the
// gist identically (including the legacy schema fields).

import { CHARGERS_TR_URL, CHARGERS_URL, FETCH_TIMEOUT_MS, REFRESH_MS } from './config.js';

/** @typedef {{type: string, status: string, since?: string}} Port */
/**
 * @typedef {Object} Station
 * @property {string} id
 * @property {string} name
 * @property {number} lat
 * @property {number} lng
 * @property {number} kw
 * @property {boolean} isDC
 * @property {string} price
 * @property {number} available
 * @property {number} total
 * @property {string} city
 * @property {string} provider
 * @property {string[]} connectors
 * @property {Port[]} ports
 * @property {string} lastUpdated
 * @property {string} country   'Turkey' for the EPDK dataset ('' = classify by coords)
 * @property {boolean} live      false = registry data, no real-time availability
 * @property {string} priceNote  where `price` came from ('' = live/per-station)
 */

let stations = /** @type {Station[]} */ ([]);
let refreshTimer = null;
const listeners = new Set();

function leadingInt(v, fallback = 0) {
  if (typeof v === 'number') return v;
  const m = String(v ?? '').match(/\d+/);
  return m ? parseInt(m[0], 10) : fallback;
}

function normalize(raw) {
  const ports = Array.isArray(raw.ports)
    ? raw.ports.map((p) => ({
        type: p.type ?? '',
        status: (p.status ?? 'out').toLowerCase(),
        since: p.since,
      }))
    : [];

  // Availability: live per-port statuses win; fall back to the spot counters
  // (legacy schema uses `available`).
  const available = ports.length
    ? ports.filter((p) => p.status === 'free').length
    : leadingInt(raw.available_spots ?? raw.available);

  const connectors =
    Array.isArray(raw.connectors) && raw.connectors.length
      ? raw.connectors
      : [...new Set(ports.map((p) => p.type).filter(Boolean))];

  const typeStr = raw.type ?? '';
  return {
    id: String(raw.id ?? ''),
    name: raw.name ?? '',
    lat: Number(raw.lat),
    lng: Number(raw.lng),
    kw: leadingInt(raw.power ?? raw.kw),
    isDC: raw.isDC === true || typeStr.includes('DC'),
    price: raw.price ?? '',
    available,
    total: raw.total_spots ?? (ports.length || leadingInt(raw.total)),
    city: raw.city ?? raw.location ?? '',
    provider: raw.provider ?? '',
    connectors,
    ports,
    lastUpdated: raw.last_updated ?? '',
    country: raw.country ?? '',
    // Turkey's EPDK rows publish how many plugs EXIST, not how many are free.
    // Feeds without the flag (the Georgian gist) really are live.
    live: raw.live !== false,
    priceNote: raw.price_note ?? '',
  };
}

async function fetchStations(url = CHARGERS_URL) {
  const res = await fetch(url, {
    signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
    cache: 'no-cache', // always revalidate (ETag) but reuse the cached body on 304
  });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  const json = await res.json();
  if (!Array.isArray(json)) throw new Error('unexpected payload');
  return json
    .map(normalize)
    .filter((s) => Number.isFinite(s.lat) && Number.isFinite(s.lng));
}

/**
 * Fetch now and every REFRESH_MS after. A failed refresh keeps the previous
 * data (mobile behaviour: never clobber live data with nothing) and reports
 * the error so the UI can show a soft warning.
 */
export function startFeed({ onData, onError }) {
  listeners.add(onData);

  const tick = async () => {
    try {
      stations = await fetchStations();
      listeners.forEach((fn) => fn(stations));
    } catch (err) {
      if (stations.length === 0) throw err; // first load failed — caller decides
      onError?.(err);
    }
  };

  const first = tick();
  refreshTimer = setInterval(() => tick().catch((e) => onError?.(e)), REFRESH_MS);
  return first;
}

export function getStations() {
  return stations;
}

// ── Turkey (EPDK registry) ───────────────────────────────────────────────────
// Loaded on demand, once per session: several megabytes on a car's connection,
// and irrelevant to a driver who never leaves Georgia. There is no live status
// in it, so there is nothing to poll for either.
let turkey = /** @type {Station[]} */ ([]);
let turkeyPromise = null;

/** Every Turkish station, fetching them the first time this is called. */
export function loadTurkey() {
  if (turkey.length) return Promise.resolve(turkey);
  turkeyPromise ??= fetchStations(CHARGERS_TR_URL)
    .then((list) => {
      turkey = list;
      return turkey;
    })
    .catch((err) => {
      turkeyPromise = null; // let a later attempt retry
      throw err;
    });
  return turkeyPromise;
}

/** Turkish stations already in memory ([] until loadTurkey resolves). */
export function getTurkeyStations() {
  return turkey;
}

export function stopFeed() {
  clearInterval(refreshTimer);
  listeners.clear();
}
