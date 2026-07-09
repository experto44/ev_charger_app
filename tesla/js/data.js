// Charger catalog + live status. Mirrors the parsing rules of
// Station.fromJson in lib/routing_service.dart so both clients read the
// gist identically (including the legacy schema fields).

import { CHARGERS_URL, FETCH_TIMEOUT_MS, REFRESH_MS } from './config.js';

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
  };
}

async function fetchStations() {
  const res = await fetch(CHARGERS_URL, {
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

export function stopFeed() {
  clearInterval(refreshTimer);
  listeners.clear();
}
