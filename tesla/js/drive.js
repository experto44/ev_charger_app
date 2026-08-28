// In-browser turn-by-turn navigation ("drive mode").
//
// Tesla's own nav doesn't work in Georgia and Google Maps isn't installed, so
// we drive right here in the browser. This reuses the SAME data the trip
// planner already fetches — google.maps.DirectionsService — but at step level:
// each DirectionsStep carries a `maneuver` (turn-left/right…), an already-decoded
// `path`, a `distance`, and a Georgian instruction (the Maps API is loaded with
// language=ka). We track the driver's live GPS along that path, show the next
// maneuver + distance, follow the camera, speak guidance, and reroute if they
// leave the line. No second map vendor, no new tab.

import { getMap, setUserLocation, setMarkersDimmed, setUserStyle } from './map.js';
import { showToast, hideToast } from './ui.js';
import { t, getLang } from './i18n.js';
import { track } from './analytics.js';

// ── Geometry helpers ─────────────────────────────────────────────────────────
const rad = (d) => (d * Math.PI) / 180;

function haversineM(a, b) {
  const R = 6371000;
  const dLat = rad(b.lat - a.lat);
  const dLng = rad(b.lng - a.lng);
  const s =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(rad(a.lat)) * Math.cos(rad(b.lat)) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(s));
}

/** [offMeters, tFraction] of p projected onto segment a→b (local planar approx). */
function projSeg(p, a, b) {
  const latRef = rad(a.lat);
  const M = 111320; // metres per degree of latitude
  const px = (q) => (q.lng - a.lng) * Math.cos(latRef) * M;
  const py = (q) => (q.lat - a.lat) * M;
  const bx = px(b), by = py(b);
  const qx = px(p), qy = py(p);
  const len2 = bx * bx + by * by;
  let tt = len2 === 0 ? 0 : (qx * bx + qy * by) / len2;
  tt = Math.min(1, Math.max(0, tt));
  return [Math.hypot(qx - tt * bx, qy - tt * by), tt];
}

function stripHtml(html) {
  const d = document.createElement('div');
  d.innerHTML = html || '';
  return (d.textContent || '').replace(/\s+/g, ' ').trim();
}

// ── Maneuver icons (line arrows, coloured via currentColor) ──────────────────
const SVG = (body) =>
  `<svg viewBox="0 0 32 32" fill="none" stroke="currentColor" stroke-width="3" ` +
  `stroke-linecap="round" stroke-linejoin="round">${body}</svg>`;

const ARROW = {
  up: SVG('<path d="M16 27 V7"/><path d="M8 15 L16 7 L24 15"/>'),
  right: SVG('<path d="M9 27 V15 Q9 11 13 11 H23"/><path d="M19 6 L25 11 L19 16"/>'),
  left: SVG('<path d="M23 27 V15 Q23 11 19 11 H9"/><path d="M13 6 L7 11 L13 16"/>'),
  uturn: SVG('<path d="M21 27 V13 Q21 7 15 7 Q9 7 9 13 V17"/><path d="M5 13 L9 17 L13 13"/>'),
  flag: SVG('<path d="M10 28 V5"/><path d="M10 6 H24 L20.5 10.5 L24 15 H10"/>'),
};

/** Map a Google maneuver string to one of our arrow glyphs. */
function arrowFor(maneuver) {
  const m = (maneuver || '').toLowerCase();
  if (!m) return ARROW.up;
  if (m.includes('uturn')) return ARROW.uturn;
  if (m.includes('left')) return ARROW.left;
  if (m.includes('right')) return ARROW.right;
  return ARROW.up; // straight / merge / ferry / unknown
}

// ── Distance / time formatting ───────────────────────────────────────────────
function fmtDist(m) {
  const ka = getLang() === 'ka';
  if (m < 1000) return `${Math.max(0, Math.round(m / 10) * 10)} ${ka ? 'მ' : 'm'}`;
  return `${(m / 1000).toFixed(1)} ${ka ? 'კმ' : 'km'}`;
}

function fmtClock(date) {
  return date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', hour12: false });
}

/**
 * A duration a driver can read at a glance. Tbilisi to Istanbul came out as
 * "1211 წთ", which is a number nobody converts in their head at the wheel.
 */
function fmtDuration(seconds) {
  const ka = getLang() === 'ka';
  const total = Math.max(0, Math.round(seconds / 60));
  const h = Math.floor(total / 60);
  const m = total % 60;
  if (h === 0) return `${m} ${ka ? 'წთ' : 'min'}`;
  if (m === 0) return `${h} ${ka ? 'სთ' : 'h'}`; // "1 h", not "1 h 0 min"
  return `${h} ${ka ? 'სთ' : 'h'} ${m} ${ka ? 'წთ' : 'min'}`;
}

// ── Voice (best-effort; stays silent if no matching TTS voice) ───────────────
function pickVoice() {
  if (!('speechSynthesis' in window)) return null;
  const vs = speechSynthesis.getVoices();
  const want = getLang() === 'ka' ? 'ka' : 'en';
  return (
    vs.find((v) => v.lang?.toLowerCase().startsWith(want)) ||
    vs.find((v) => v.lang?.toLowerCase().startsWith('en')) ||
    vs[0] ||
    null
  );
}

function speak(text) {
  if (!state.voiceOn || !text || !('speechSynthesis' in window)) return;
  const v = pickVoice();
  // Instructions are Georgian (Maps loaded language=ka). An English voice
  // reading Georgian is worse than silence, so skip unless a ka voice exists.
  const isGeo = /[Ⴀ-ჿ]/.test(text);
  if (isGeo && !(v && v.lang?.toLowerCase().startsWith('ka'))) return;
  try {
    const u = new SpeechSynthesisUtterance(text);
    if (v) u.voice = v;
    u.lang = v?.lang || 'ka-GE';
    u.rate = 1;
    speechSynthesis.cancel();
    speechSynthesis.speak(u);
  } catch (_) {/* TTS unavailable — text banner still guides */}
}

// ── Route building (step-level Directions) ───────────────────────────────────
async function computeRoute(origin, destination, waypoints) {
  const svc = new google.maps.DirectionsService();
  const res = await svc.route({
    origin,
    destination,
    waypoints: waypoints.map((w) => ({ location: w, stopover: true })),
    travelMode: google.maps.TravelMode.DRIVING,
  });
  const route = res.routes[0];
  if (!route) throw new Error('no route');

  const path = [];  // detailed {lat,lng} polyline across every step
  const steps = []; // flattened maneuvers with along-route end distance
  for (const leg of route.legs) {
    for (const step of leg.steps) {
      const sp = step.path.map((p) => ({ lat: p.lat(), lng: p.lng() }));
      sp.forEach((pt, i) => {
        if (path.length && i === 0) return; // drop the vertex shared with prev step
        path.push(pt);
      });
      steps.push({
        maneuver: step.maneuver || '',
        text: stripHtml(step.instructions),
        endIdx: path.length - 1,
      });
    }
  }

  const cum = new Array(path.length).fill(0);
  for (let i = 1; i < path.length; i++) cum[i] = cum[i - 1] + haversineM(path[i - 1], path[i]);
  for (const st of steps) st.endAlong = cum[st.endIdx] || 0;

  const totalM = cum.length ? cum[cum.length - 1] : 0;
  const totalDurS = route.legs.reduce((a, l) => a + l.duration.value, 0);
  return { path, cum, steps, totalM, totalDurS };
}

/** Nearest-point projection of a coordinate → {offM, alongM}. */
function project(pos) {
  const { path, cum } = state.route;
  let offM = Infinity, alongM = 0;
  for (let i = 0; i < path.length - 1; i++) {
    const [d, tt] = projSeg(pos, path[i], path[i + 1]);
    if (d < offM) {
      offM = d;
      alongM = cum[i] + tt * (cum[i + 1] - cum[i]);
    }
  }
  return { offM, alongM };
}

// ── Progress reporting ───────────────────────────────────────────────────────
/**
 * Mark every stop we have now passed. Two tests, because either alone misses a
 * real case: a charger 200 m off the road is never driven "close" to, and a
 * stop we sail past at speed can be behind us before any fix lands near it.
 */
function markPassedWaypoints(pos, alongM) {
  for (let i = 0; i < state.waypoints.length; i++) {
    if (state.done.includes(i)) continue;
    const behind = state.waypointAlong[i] < alongM - WAYPOINT_BEHIND_M;
    if (behind || haversineM(pos, state.waypoints[i]) < WAYPOINT_DONE_M) state.done.push(i);
  }
}

/**
 * Where each remaining stop sits along the current route, worked out once when
 * the route is built. project() walks the whole polyline — several thousand
 * points on a Tbilisi → Batumi run — and doing that per stop per GPS fix is
 * work for nothing when the answer cannot change until the route does.
 */
function indexWaypoints() {
  state.waypointAlong = state.waypoints.map((w, i) =>
    state.done.includes(i) ? -1 : project(w).alongM,
  );
}

/**
 * Publish where we are on the route. routes.js listens and writes it to the
 * account; nothing here knows or cares whether anyone is listening, which is
 * what keeps drive mode usable when signed out.
 */
function report(pos, remainM, force = false) {
  const now = Date.now();
  const movedEnough =
    state.lastReportPos && haversineM(state.lastReportPos, pos) >= REPORT_M;
  if (!force && now - state.lastReport < REPORT_MS && !movedEnough) return;
  state.lastReport = now;
  state.lastReportPos = pos;
  document.dispatchEvent(
    new CustomEvent('gc:drive-progress', {
      detail: {
        route: state.routeRef,
        destination: state.destination,
        waypoints: state.waypoints,
        done: [...state.done],
        pos,
        remainM,
      },
    }),
  );
}

// ── State ────────────────────────────────────────────────────────────────────
const VOICE_KEY = 'gc_drive_voice';
const DRIVE_ZOOM = 17; // street level — also what the recenter button restores
const state = {
  active: false,
  route: null,
  destination: null,
  waypoints: [],         // original stop coords (for rerouting through those still ahead)
  watchId: null,
  casing: null,
  line: null,
  destMarker: null,
  firstFix: true,
  // The camera follows the car until the driver drags the map — looking ahead
  // at the route while every GPS fix pulls the map back is unusable. `lastPos`
  // is what the recenter button flies back to.
  following: true,
  lastPos: null,
  dragListener: null,
  prevPos: null,
  heading: null,
  announced: new Set(),  // "<stepIdx>:far" / ":near" voice guards
  offCount: 0,
  lastReroute: 0,
  arrived: false,
  voiceOn: localStorage.getItem(VOICE_KEY) !== '0',
  // Which saved route this is, and how far through it we are. Reported out as
  // `gc:drive-progress` events; routes.js is what writes them to the account,
  // so drive mode itself knows nothing about Firestore.
  routeRef: null,        // { id, name } | null for an ad-hoc drive
  done: [],              // indices into state.waypoints already passed
  waypointAlong: [],     // each stop's distance along the current route
  lastReport: 0,
  lastReportPos: null,
};

// A stop counts as passed when the car comes within this of it, or when it
// falls behind us along the route. The first catches a charger set back from
// the road; the second catches a stop we drove straight past.
const WAYPOINT_DONE_M = 150;
const WAYPOINT_BEHIND_M = 200;

// How often progress is written out. A four-hour Tbilisi → Batumi run costs
// about forty writes at these numbers, which is nothing, and either trigger on
// its own would be wrong: time alone keeps writing while the car is parked,
// distance alone writes nothing while it crawls through traffic.
const REPORT_MS = 60000;
const REPORT_M = 2000;

const $ = (id) => document.getElementById(id);

// ── Public entry ─────────────────────────────────────────────────────────────
/**
 * Enter turn-by-turn drive mode. Origin is always the driver's live GPS — the
 * planned start/stops only supply the destination and intermediate waypoints.
 * That is also what makes resuming work: a trip picked up again in Gori is
 * simply the same destination and the stops that are still ahead.
 *
 * @param {{destination:{lat,lng}, waypoints?:{lat,lng}[],
 *          route?:{id:string,name:string}|null}} opts
 */
export async function startDrive({ destination, waypoints = [], route: routeRef = null }) {
  if (state.active) endDrive();
  if (!navigator.geolocation) {
    showToast(t('driveNoLocation'));
    return;
  }

  // Tell the trip planner to take its own route drawing off the map — drive
  // mode draws its own line, and two overlapping routes read as a glitch. The
  // detail is also what history.js records: every drive is a trip the driver
  // may want to repeat, whoever started it.
  document.dispatchEvent(new CustomEvent('gc:drive-start', {
    detail: { destination, waypoints, route: routeRef },
  }));

  showToast(t('driveLocating'), 60000);
  let origin;
  try {
    origin = await new Promise((resolve, reject) =>
      navigator.geolocation.getCurrentPosition(
        (p) => resolve({ lat: p.coords.latitude, lng: p.coords.longitude }),
        reject,
        { enableHighAccuracy: true, timeout: 12000, maximumAge: 0 },
      ),
    );
  } catch (_) {
    showToast(t('driveNoLocation'));
    return;
  }
  hideToast(); // clear the "locating…" notice now that we have a fix

  let route;
  try {
    route = await computeRoute(origin, destination, waypoints);
  } catch (_) {
    showToast(t('tripNoRoute'));
    return;
  }

  state.active = true;
  state.route = route;
  state.destination = destination;
  state.waypoints = waypoints.slice();
  state.firstFix = true;
  state.lastPos = origin;
  state.prevPos = null;
  state.heading = null;
  state.announced = new Set();
  state.offCount = 0;
  state.lastReroute = Date.now();
  state.arrived = false;
  state.routeRef = routeRef;
  state.done = [];
  indexWaypoints();
  state.lastReport = 0;
  state.lastReportPos = null;

  enterUi();
  setUserStyle('car'); // the driver is a Tesla now, not a blue dot
  setUserLocation(origin);
  drawRoute();
  track('drive_start', { stops: waypoints.length });

  // `dragstart` fires for the driver's finger only — our own panTo/setZoom do
  // not raise it — so it is exactly the signal that they took the map over.
  state.dragListener = getMap().addListener('dragstart', () => setFollowing(false));

  // First report goes out straight away: a trip that is interrupted two minutes
  // in should still be resumable.
  report(origin, route.totalM);

  // Follow the live position.
  state.watchId = navigator.geolocation.watchPosition(
    (p) =>
      onPosition(
        { lat: p.coords.latitude, lng: p.coords.longitude },
        Number.isFinite(p.coords.heading) ? p.coords.heading : null,
      ),
    () => {/* transient GPS error — keep last banner */},
    { enableHighAccuracy: true, maximumAge: 1000, timeout: 15000 },
  );
}

export function isDriving() {
  return state.active;
}

export function endDrive() {
  // A last position before everything is torn down. Ending on purpose is not
  // the same as arriving: the driver may be stopping for the night halfway,
  // and that is exactly the trip they will want to pick up again.
  if (state.active && !state.arrived && state.lastPos && state.route) {
    report(state.lastPos, Math.max(0, state.route.totalM - project(state.lastPos).alongM), true);
  }
  if (state.watchId != null) {
    navigator.geolocation.clearWatch(state.watchId);
    state.watchId = null;
  }
  state.dragListener?.remove();
  state.dragListener = null;
  state.following = true;
  state.lastPos = null;
  $('drive-recenter').classList.add('is-hidden');
  if ('speechSynthesis' in window) speechSynthesis.cancel();
  setUserStyle('dot');
  state.line?.setMap(null);
  state.casing?.setMap(null);
  state.destMarker?.setMap(null);
  state.line = state.casing = state.destMarker = null;
  setMarkersDimmed(false);
  document.body.classList.remove('is-driving');
  $('drive').classList.add('is-hidden');
  state.active = false;
  state.route = null;
  state.routeRef = null;
  document.dispatchEvent(new CustomEvent('gc:drive-end'));
}

// ── Map drawing ──────────────────────────────────────────────────────────────
function drawRoute() {
  const path = state.route.path;
  setMarkersDimmed(true);
  state.casing = new google.maps.Polyline({
    map: getMap(),
    path,
    strokeColor: '#0a3b2b',
    strokeOpacity: 0.9,
    strokeWeight: 11,
    zIndex: 1900,
  });
  state.line = new google.maps.Polyline({
    map: getMap(),
    path,
    strokeColor: '#2bd594',
    strokeOpacity: 0.95,
    strokeWeight: 6,
    zIndex: 1901,
  });
  state.destMarker = new google.maps.Marker({
    map: getMap(),
    position: state.destination,
    zIndex: 2200,
    icon: {
      path: 'M12 0C7 0 3 4 3 9c0 6 9 15 9 15s9-9 9-15c0-5-4-9-9-9z',
      fillColor: '#FF6B6B',
      fillOpacity: 1,
      strokeColor: '#ffffff',
      strokeWeight: 1.5,
      scale: 1.6,
      anchor: new google.maps.Point(12, 24),
    },
  });
}

// ── Per-fix update ───────────────────────────────────────────────────────────
function onPosition(pos, geoHeading) {
  if (!state.active) return;
  state.lastPos = pos; // where the recenter button goes back to

  // Heading: prefer the GPS value, else derive from movement. Worked out BEFORE
  // the marker is moved, because the car silhouette is drawn pointing along it.
  let moving = false;
  if (state.prevPos) {
    const moved = haversineM(state.prevPos, pos);
    moving = moved > 3;
    if (geoHeading == null && moving) {
      state.heading = google.maps.geometry.spherical.computeHeading(
        new google.maps.LatLng(state.prevPos.lat, state.prevPos.lng),
        new google.maps.LatLng(pos.lat, pos.lng),
      );
    }
  }
  if (geoHeading != null) state.heading = geoHeading;
  state.prevPos = pos;

  setUserLocation(pos, state.heading);
  followCamera(pos, moving);

  const { offM, alongM } = project(pos);

  // Off-route → reroute (debounced, needs a few consecutive off-fixes).
  if (offM > 60) state.offCount++;
  else state.offCount = 0;
  if (state.offCount >= 3 && Date.now() - state.lastReroute > 6000) {
    reroute(pos, alongM);
    return;
  }

  markPassedWaypoints(pos, alongM);
  report(pos, Math.max(0, state.route.totalM - alongM));
  updateBanner(alongM);
}

function followCamera(pos, moving) {
  if (!state.following) return; // driver is looking somewhere else on the map
  const map = getMap();
  if (state.firstFix) {
    map.setZoom(DRIVE_ZOOM);
    state.firstFix = false;
  }
  // Bias the camera ahead of the car so the road reads (nav convention).
  let center = pos;
  if (state.heading != null && moving) {
    center = google.maps.geometry.spherical.computeOffset(
      new google.maps.LatLng(pos.lat, pos.lng),
      120,
      state.heading,
    );
  }
  map.panTo(center);
}

/**
 * Turn camera-follow on or off and show/hide the recenter button with it.
 * Turning it back on flies to the last known fix at the driving zoom, however
 * far the driver had panned or zoomed away.
 */
function setFollowing(on) {
  state.following = on;
  $('drive-recenter').classList.toggle('is-hidden', on);
  if (!on || !state.lastPos) return;
  getMap().setZoom(DRIVE_ZOOM);
  followCamera(state.lastPos, state.heading != null);
}

function updateBanner(alongM) {
  const { steps, totalM, totalDurS } = state.route;

  // Current step = first whose end is still ahead; the maneuver we announce is
  // the START of the following step (that's where the driver turns).
  let k = steps.findIndex((st) => st.endAlong > alongM + 1);
  if (k === -1) k = steps.length - 1;

  const remainM = Math.max(0, totalM - alongM);
  if (remainM < 30 && !state.arrived) {
    onArrived();
    return;
  }

  const next = steps[k + 1];
  const distToTurn = Math.max(0, steps[k].endAlong - alongM);
  const icon = next ? arrowFor(next.maneuver) : ARROW.flag;
  const road = next ? next.text : t('driveArrive');
  const stepIdx = next ? k + 1 : steps.length;

  $('drive-icon').innerHTML = icon;
  $('drive-dist').textContent = fmtDist(distToTurn);
  $('drive-road').textContent = road;

  // Voice: announce once entering the far zone, once at the near zone.
  const far = `${stepIdx}:far`;
  const near = `${stepIdx}:near`;
  if (distToTurn <= 300 && distToTurn > 70 && !state.announced.has(far)) {
    state.announced.add(far);
    speak(`${fmtDist(distToTurn)} — ${road}`);
  } else if (distToTurn <= 70 && !state.announced.has(near)) {
    state.announced.add(near);
    speak(road);
  }

  // Remaining distance + ETA.
  const remainS = totalM > 0 ? totalDurS * (remainM / totalM) : 0;
  const eta = new Date(Date.now() + remainS * 1000);
  $('drive-remain').textContent = fmtDist(remainM);
  $('drive-eta').textContent =
    `${fmtDuration(remainS)} · ${t('driveArrivalAt')} ${fmtClock(eta)}`;
}

function onArrived() {
  state.arrived = true;
  document.dispatchEvent(new CustomEvent('gc:drive-arrived', { detail: { route: state.routeRef } }));
  $('drive-icon').innerHTML = ARROW.flag;
  $('drive-dist').textContent = '';
  $('drive-road').textContent = t('driveArrived');
  $('drive-remain').textContent = '';
  $('drive-eta').textContent = '';
  $('drive-banner').classList.add('is-arrived');
  speak(t('driveArrived'));
  track('drive_arrived', {});
}

// ── Reroute ──────────────────────────────────────────────────────────────────
async function reroute(pos, currentAlong) {
  state.lastReroute = Date.now();
  state.offCount = 0;
  $('drive-reroute').classList.remove('is-hidden');

  // Keep only the planned stops that are still ahead of us on the old route,
  // and remember the ones we are dropping: `state.done` is what a resumed trip
  // is rebuilt from, so a stop left behind here must be recorded as passed
  // rather than silently vanishing from this route only.
  const ahead = state.waypoints.filter((w, i) => {
    if (state.done.includes(i)) return false;
    if (project(w).alongM <= currentAlong + WAYPOINT_BEHIND_M) {
      state.done.push(i);
      return false;
    }
    return true;
  });

  try {
    const route = await computeRoute(pos, state.destination, ahead);
    state.route = route;
    indexWaypoints();
    state.announced = new Set();
    state.arrived = false;
    $('drive-banner').classList.remove('is-arrived');
    state.line?.setMap(null);
    state.casing?.setMap(null);
    drawRoute();
    speak(t('driveRerouted'));
  } catch (_) {
    showToast(t('tripNoRoute'));
  } finally {
    $('drive-reroute').classList.add('is-hidden');
  }
}

// ── UI wiring ────────────────────────────────────────────────────────────────
function enterUi() {
  document.body.classList.add('is-driving');
  const el = $('drive');
  el.classList.remove('is-hidden');
  state.following = true;
  $('drive-recenter').classList.add('is-hidden');
  $('drive-banner').classList.remove('is-arrived');
  $('drive-icon').innerHTML = ARROW.up;
  $('drive-dist').textContent = '';
  $('drive-road').textContent = '';
  $('drive-remain').textContent = '';
  $('drive-eta').textContent = '';
  syncVoiceBtn();
}

function syncVoiceBtn() {
  const btn = $('drive-voice');
  if (!btn) return;
  btn.classList.toggle('is-off', !state.voiceOn);
  btn.innerHTML = state.voiceOn
    ? '<svg viewBox="0 0 24 24" width="24" height="24" fill="currentColor"><path d="M3 9v6h4l5 5V4L7 9H3zm13.5 3a4.5 4.5 0 00-2.5-4v8a4.5 4.5 0 002.5-4zm-2.5-9v2.06a7 7 0 010 13.88V21a9 9 0 000-18z"/></svg>'
    : '<svg viewBox="0 0 24 24" width="24" height="24" fill="currentColor"><path d="M3 9v6h4l5 5V4L7 9H3zm16.6 3l2.1-2.1-1.4-1.4-2.1 2.1-2.1-2.1-1.4 1.4L16.8 12l-2.1 2.1 1.4 1.4 2.1-2.1 2.1 2.1 1.4-1.4L19.6 12z"/></svg>';
}

export function initDrive() {
  $('drive-exit').addEventListener('click', () => {
    track('drive_exit', {});
    endDrive();
  });
  $('drive-recenter').addEventListener('click', () => {
    track('drive_recenter', {});
    setFollowing(true);
  });
  $('drive-voice').addEventListener('click', () => {
    state.voiceOn = !state.voiceOn;
    localStorage.setItem(VOICE_KEY, state.voiceOn ? '1' : '0');
    if (!state.voiceOn && 'speechSynthesis' in window) speechSynthesis.cancel();
    syncVoiceBtn();
  });
  // Warm the voice list (Chromium populates asynchronously).
  if ('speechSynthesis' in window) speechSynthesis.getVoices();
}
