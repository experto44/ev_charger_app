// Reading one station straight from its operator, for the panel's refresh button.
//
// The feed behind this app is a Gist that a GitHub Actions loop rewrites every
// ~2.5 min, so what is on screen can be a couple of minutes behind the plug. For
// the four Georgian networks running AMPECO the browser can ask the operator
// itself instead: one request, about a second old, no login. Those hosts send
// `Access-Control-Allow-Origin: *` and answer the preflight, so this works from
// a page exactly as it does from the mobile app.
//
// Mirrors lib/services/live_status_service.dart. The counting rules in
// applyAmpeco() must stay in step with that file AND with fetch_ampeco in
// .github/workflows/update_gist.yml — three copies of one rule is the thing
// most likely to drift here, and drift shows up to a driver as the map and the
// panel disagreeing about the same charger. tools/check_ampeco_parsers.py pins
// the Python and Dart halves against a fixture; this file follows the same one.

import { CHARGERS_BASE } from './config.js';

/**
 * AMPECO networks we may read directly, keyed by the prefix their station ids
 * carry ("martev_220" → cp.martev.io, location 220).
 * Mirrors AMPECO_HOSTS in the updater workflow and _kAmpecoHosts in the app.
 */
const AMPECO_HOSTS = {
  martev: 'cp.martev.io',
  moveo: 'cp.moveo.ge',
  electrify: 'cp.electrify.ge',
  evpower: 'cp.evpower.ge',
};

/** Headers the operators' own apps send; all three pass their CORS preflight. */
const AMPECO_HEADERS = {
  Accept: 'application/json',
  'Accept-Language': 'ka',
  'App-Version': '3.130.0',
  'X-Internal-App-Version': '3.130.0',
};

/** EVSE statuses that mean a session is under way. Mirrors SESSION upstream. */
const SESSION = new Set([
  'charging', 'preparing', 'finishing', 'occupied', 'reserved',
  'suspendedev', 'suspendedevse', 'inuse', 'intransaction',
]);

/** Connector aliases → the labels the rest of the app uses. Mirrors CONN_MAP. */
const CONNECTORS = {
  ccs: 'CCS2', ccs2: 'CCS2', combo2: 'CCS2', iec62196t2combo: 'CCS2',
  ccs1: 'CCS1', combo1: 'CCS1',
  chademo: 'CHAdeMO',
  type2: 'Type 2', mennekes: 'Type 2', iec62196t2: 'Type 2',
  type1: 'Type 1', j1772: 'Type 1',
  gbt: 'GB/T', gbtdc: 'GB/T', gbtac: 'GB/T',
  gbtdccable: 'GB/T', chinese: 'GB/T', gbtgb: 'GB/T',
  nacs: 'NACS', tesla: 'NACS',
};

function normalizeConnector(raw) {
  if (!raw) return null;
  const k = String(raw).toLowerCase().replace(/[ \-_/]/g, '');
  return CONNECTORS[k] ?? null;
}

// ── Remote kill-switch ───────────────────────────────────────────────────────
// These are reverse-engineered endpoints. The day an operator gates or blocks
// them every driver's refresh button breaks at once, so the same config.json the
// mobile app reads can route everyone back through the feed. Editing that file
// by hand in the Gist takes effect here within CONFIG_TTL.
const CONFIG_TTL_MS = 5 * 60 * 1000;
const FALLBACK_CONFIG = {
  enabled: true,
  providers: ['mart EV', 'MOVEO', 'Electrify Georgia', 'EV Power GE'],
};

let config = FALLBACK_CONFIG;
let configCheckedAt = 0;

async function refreshConfig() {
  if (Date.now() - configCheckedAt < CONFIG_TTL_MS) return;
  configCheckedAt = Date.now();
  try {
    // Same per-minute cache bucket as the feed: fresh enough to matter, still
    // one shared CDN entry rather than a request per driver.
    const bucket = Math.floor(Date.now() / 60000);
    const res = await fetch(`${CHARGERS_BASE}/config.json?t=${bucket}`, {
      signal: AbortSignal.timeout(6000),
    });
    if (!res.ok) return; // 404 until the updater first writes it — keep defaults
    const j = await res.json();
    if (j && typeof j === 'object' && j.direct_fetch) {
      config = {
        enabled: j.direct_fetch.enabled !== false,
        providers: Array.isArray(j.direct_fetch.providers)
          ? j.direct_fetch.providers
          : FALLBACK_CONFIG.providers,
      };
    }
  } catch {
    /* keep whatever settings we already have */
  }
}

// ── Direct read ──────────────────────────────────────────────────────────────
/** Splits "martev_220" into its operator host and location id. */
function target(id) {
  const i = String(id ?? '').indexOf('_');
  if (i <= 0 || i === String(id).length - 1) return null;
  const host = AMPECO_HOSTS[String(id).slice(0, i)];
  return host ? { host, locId: String(id).slice(i + 1) } : null;
}

/** True when this station can be read straight from its operator right now. */
export function canRefresh(s) {
  return Boolean(
    s && target(s.id) && config.enabled && config.providers.includes(s.provider),
  );
}

/**
 * Rebuild a station's live fields from an AMPECO location response, leaving
 * every descriptive field (name, price, connector list, city) as the feed
 * published it.
 * @returns {object|null} null when the response cannot be trusted, which always
 *   means "keep what you had" — this path must never leave a driver worse off.
 */
export function applyAmpeco(station, body, locId) {
  const locations = body?.locations;
  if (!Array.isArray(locations)) return null;

  let available = 0;
  let total = 0;
  let matched = false;
  const ports = [];

  for (const loc of locations) {
    // One call can answer for several linked locations; only the one this
    // station's id points at describes THIS station.
    if (String(loc?.id) !== String(locId)) continue;
    matched = true;

    for (const zone of loc.zones ?? []) {
      for (const e of zone.evses ?? []) {
        const cs = Array.isArray(e.connectors) ? e.connectors : [];
        total += cs.length || 1; // an EVSE has at least one plug
        const st = String(e.status ?? '').trim().toLowerCase();
        // On a dual-connector DC cabinet (CCS2 + GB/T on one power module)
        // AMPECO marks the idle sibling status=unavailable while the other
        // charges. That means "sibling busy", never a broken unit — those report
        // out of order — so it counts as free, exactly as upstream counts it.
        const isFree = e.isAvailable === true || st === 'unavailable';
        if (isFree) available += cs.length || 1;

        const status = isFree ? 'free' : SESSION.has(st) ? 'busy' : 'out';
        const since = status === 'busy' ? e.startedAt : undefined;
        for (const c of cs) {
          ports.push({
            type: normalizeConnector(c.icon ?? c.name) ?? c.name ?? '?',
            status,
            since,
          });
        }
      }
    }
  }

  // No matching location, or an operator answering with an empty rig, is not
  // something to render.
  if (!matched || total === 0) return null;

  return { ...station, available, total, ports, lastUpdated: stampNow() };
}

/** "YYYY-MM-DD HH:MM UTC", the shape formatVerified() already understands. */
function stampNow() {
  const n = new Date();
  const p = (v) => String(v).padStart(2, '0');
  return (
    `${n.getUTCFullYear()}-${p(n.getUTCMonth() + 1)}-${p(n.getUTCDate())} ` +
    `${p(n.getUTCHours())}:${p(n.getUTCMinutes())} UTC`
  );
}

/** True when two readings of one station say the same thing about availability. */
export function sameLiveState(a, b) {
  if (a.available !== b.available || a.total !== b.total) return false;
  if (a.ports.length !== b.ports.length) return false;
  return a.ports.every(
    (p, i) => p.type === b.ports[i].type && p.status === b.ports[i].status,
  );
}

// Repeat taps are answered from memory rather than from the operator: a driver
// prodding the button on a bumpy road must not turn into a burst of requests.
const COOLDOWN_MS = 15000;
const cache = new Map(); // station id → { at, station }

/**
 * Re-read one station from its operator.
 * @returns {Promise<{outcome: 'updated'|'unchanged'|'failed', station?: object}>}
 *   `failed` means the caller should keep showing what it already had.
 */
export async function refreshStation(s) {
  await refreshConfig();
  const tgt = target(s.id);
  if (!tgt || !canRefresh(s)) return { outcome: 'failed' };

  const hit = cache.get(s.id);
  if (hit && Date.now() - hit.at < COOLDOWN_MS) {
    return {
      outcome: sameLiveState(s, hit.station) ? 'unchanged' : 'updated',
      station: hit.station,
    };
  }

  try {
    const res = await fetch(
      `https://${tgt.host}/api/v1/app/locations/${tgt.locId}`,
      { headers: AMPECO_HEADERS, signal: AbortSignal.timeout(8000) },
    );
    if (!res.ok) return { outcome: 'failed' };
    const fresh = applyAmpeco(s, await res.json(), tgt.locId);
    if (!fresh) return { outcome: 'failed' };
    cache.set(s.id, { at: Date.now(), station: fresh });
    return {
      outcome: sameLiveState(s, fresh) ? 'unchanged' : 'updated',
      station: fresh,
    };
  } catch {
    return { outcome: 'failed' };
  }
}
