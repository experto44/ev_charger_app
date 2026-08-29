// EV route planning — the transport half.
//
// This module fetches the road and hands it to the planning core. The algorithm
// itself lives in route-core.js, a 1:1 port of lib/routing_service.dart
// (planRoute), so it can also run inside a Worker.
//
// The road comes from OpenRouteService via our own Cloud Function, and from
// Google Directions only when that fails — measured 2026-08-29, the two agree
// to within ~1 km everywhere this app operates (all of Georgia, all of Turkey,
// including Tbilisi → İstanbul at 1620 km), and Directions is the SKU that
// costs us real money. Drive mode still routes through Google: it also needs
// turn-by-turn instruction TEXT, which is a separate piece of work.
//
// The interactive "options blocks" list of the mobile planner is not ported;
// this client shows the greedy recommended plan only.

import { planFromRoute } from './route-core.js';
import { callFn } from './auth.js';
import { CHARGERS_BASE } from './config.js';

export { parseSideFromName } from './route-core.js';

// ── Worker plumbing ──────────────────────────────────────────────────────────
// The planning pass is heavy (thousands of chargers against a polyline with
// tens of thousands of points), so it runs off the UI thread. If a worker can't
// be created — an old browser, a module-worker-less engine, a file:// origin —
// we simply call the same function inline: slower to feel, identical results.
let worker = null;
let workerBroken = false;
let nextId = 1;
const pending = new Map();

function getWorker() {
  if (workerBroken) return null;
  if (worker) return worker;
  try {
    worker = new Worker(new URL('./route-worker.js', import.meta.url), {
      type: 'module',
    });
    worker.onmessage = (e) => {
      const { id, result, error } = e.data ?? {};
      const entry = pending.get(id);
      if (!entry) return;
      pending.delete(id);
      if (error) entry.reject(new Error(error));
      else entry.resolve(result);
    };
    worker.onerror = () => {
      // A worker that dies mid-flight must not hang the planner: fail every
      // in-flight request so each caller falls back to the inline path.
      workerBroken = true;
      worker = null;
      for (const [, entry] of pending) entry.reject(new Error('worker failed'));
      pending.clear();
    };
  } catch (e) {
    workerBroken = true;
    worker = null;
  }
  return worker;
}

function planOffThread(input) {
  const w = getWorker();
  if (!w) return Promise.resolve(planFromRoute(input));
  return new Promise((resolve, reject) => {
    const id = nextId++;
    pending.set(id, { resolve, reject });
    w.postMessage({ id, input });
  }).catch(() => planFromRoute(input)); // worker died → do it here instead
}

// ── Cached road geometry ─────────────────────────────────────────────────────
// The road depends ONLY on the waypoints. The battery slider and the connector
// / min-kW chips re-plan on every nudge, and each one used to be its own billed
// Directions call — by far the biggest source of our Maps traffic. So the road
// is fetched once per waypoint list and the EV math alone re-runs on top of it.
// Three entries also cover a driver toggling a stop off and back on; more than
// that would just hold onto long international polylines for nothing.
const ROAD_CACHE_MAX = 3;
const roadCache = new Map();

const roadKey = (waypoints) =>
  waypoints.map((w) => `${w.lat.toFixed(5)},${w.lng.toFixed(5)}`).join('|');

// ── Remote kill-switch ───────────────────────────────────────────────────────
// If ORS ever starts answering badly, `"routing": {"provider": "google"}` in
// the feed's config.json puts every car back on Directions within CONFIG_TTL_MS
// — no redeploy, no release. Same file and the same per-minute cache bucket
// live.js already uses.
const CONFIG_TTL_MS = 5 * 60 * 1000;
let orsEnabled = true;
let configCheckedAt = 0;

async function refreshRoutingConfig() {
  if (Date.now() - configCheckedAt < CONFIG_TTL_MS) return;
  configCheckedAt = Date.now();
  try {
    const bucket = Math.floor(Date.now() / 60000);
    const res = await fetch(`${CHARGERS_BASE}/config.json?t=${bucket}`, {
      signal: AbortSignal.timeout(6000),
    });
    if (!res.ok) return; // absent until the updater writes it — keep the default
    const j = await res.json();
    if (j && typeof j === 'object' && j.routing) {
      orsEnabled = j.routing.provider !== 'google';
    }
  } catch {
    /* keep whatever we already decided */
  }
}

// A road we would rather refuse than plan against: the EV core projects every
// charger onto these points, so a malformed one does not fail loudly, it
// quietly recommends the wrong stops.
function usableRoad(r) {
  return Boolean(
    r && Array.isArray(r.pts) && r.pts.length > 1 &&
    r.pts.every((p) => p && Number.isFinite(p.lat) && Number.isFinite(p.lng)) &&
    Number.isFinite(r.totalDistKm) && r.totalDistKm > 0 &&
    Array.isArray(r.legEndsKm) && r.legEndsKm.length > 0 &&
    r.legEndsKm.every(Number.isFinite),
  );
}

// OpenRouteService, through functions/ors-route.js so the key stays on the
// server. Every failure — key not configured yet, quota, outage, a shape we do
// not recognise — returns null and Google answers instead.
let orsConfigured = true; // until the server tells us the key is missing

async function fromOrs(waypoints) {
  if (!orsConfigured) return null;
  try {
    const road = await callFn('orsRoute', { waypoints });
    if (usableRoad(road)) return road;
    console.warn('[routing] ORS returned an unusable road; using Google');
  } catch (e) {
    const code = e?.code || '';
    // "No key deployed yet" is the one failure that will not fix itself during
    // this session, so stop asking: every later plan goes straight to Google
    // instead of paying a round trip to be told the same thing. Every other
    // failure (quota, a blip, an outage) is worth retrying on the next route.
    if (code === 'functions/failed-precondition') orsConfigured = false;
    console.warn('[routing] ORS unavailable, using Google:', code || e?.message || e);
  }
  return null;
}

async function fromGoogle(waypoints) {
  const svc = new google.maps.DirectionsService();
  let route;
  try {
    const res = await svc.route({
      origin: waypoints[0],
      destination: waypoints[waypoints.length - 1],
      waypoints: waypoints.slice(1, -1).map((w) => ({ location: w, stopover: true })),
      travelMode: google.maps.TravelMode.DRIVING,
    });
    route = res.routes[0];
  } catch (e) {
    return null;
  }
  if (!route) return null;
  const road = roadFrom(route);
  return usableRoad(road) ? road : null;
}

async function fetchRoad(waypoints) {
  const key = roadKey(waypoints);
  if (roadCache.has(key)) return roadCache.get(key);

  await refreshRoutingConfig();
  const road = (orsEnabled ? await fromOrs(waypoints) : null)
    || (await fromGoogle(waypoints));
  if (!road) return null;

  if (roadCache.size >= ROAD_CACHE_MAX) roadCache.delete(roadCache.keys().next().value);
  roadCache.set(key, road);
  return road;
}

// ── Public entry point ───────────────────────────────────────────────────────
export async function planRoute({ waypoints, currentBatteryPct, maxRangeKm, stations }) {
  if (waypoints.length < 2) return null;

  const road = await fetchRoad(waypoints);
  if (!road) return null;

  return planOffThread({
    ...road,
    currentBatteryPct,
    maxRangeKm,
    stations,
  });
}

// Turns one Google route into the same plain shape ORS gives us back.
function roadFrom(route) {
  // Detailed road-following geometry: concatenate every step's decoded path.
  // (route.overview_path is simplified and visibly cuts corners on long routes.)
  // This is also where google.maps objects stop: everything below the handoff
  // is plain data, which is what lets the core run in a worker.
  const pts = [];
  for (const leg of route.legs) {
    for (const step of leg.steps) {
      step.path.forEach((p, i) => {
        if (pts.length && i === 0) return; // skip the vertex shared with prev step
        pts.push({ lat: p.lat(), lng: p.lng() });
      });
    }
  }
  if (!pts.length) {
    for (const p of route.overview_path) pts.push({ lat: p.lat(), lng: p.lng() });
  }
  let totalDistKm = 0;
  const legEndsKm = []; // cumulative km at each waypoint boundary
  for (const leg of route.legs) {
    totalDistKm += leg.distance.value / 1000;
    legEndsKm.push(totalDistKm);
  }

  return { pts, totalDistKm, legEndsKm };
}
