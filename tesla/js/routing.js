// EV route planning — the transport half.
//
// This module only talks to Google: it asks DirectionsService for the road,
// flattens the result into plain {lat,lng} points, and hands everything to the
// planning core. The algorithm itself lives in route-core.js, a 1:1 port of
// lib/routing_service.dart (planRoute), so it can also run inside a Worker.
//
// The interactive "options blocks" list of the mobile planner is not ported;
// this client shows the greedy recommended plan only.

import { planFromRoute } from './route-core.js';

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

async function fetchRoad(waypoints) {
  const key = roadKey(waypoints);
  if (roadCache.has(key)) return roadCache.get(key);

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

// Turns one Google route into the plain data the EV core runs on.
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
