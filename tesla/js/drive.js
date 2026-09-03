// In-browser turn-by-turn navigation ("drive mode").
//
// Tesla's own nav doesn't work in Georgia and Google Maps isn't installed, so
// we drive right here in the browser. We track the driver's live GPS along a
// road, show the next maneuver + distance, follow the camera, speak guidance,
// and reroute if they leave the line. No second map vendor, no new tab.
//
// The road comes from OpenRouteService (through our own Cloud Function) and
// from Google Directions only when that fails — the same order the trip planner
// uses, for the same reason: Directions is the SKU that costs money, and every
// reroute is another call. Both are normalised into one shape below, so nothing
// past computeRoute() knows or cares which answered.
//
// The wording differs, though. Google shipped a ready Georgian sentence per
// step; ORS gives a maneuver code and a road name, and turn-phrases.js turns
// those into our own Georgian.

import {
  getMap,
  isVectorMap,
  locateMe,
  navFollow,
  navSetCamera,
  onCameraWrite,
  navJump,
  navStop,
  onMap,
  setMarkersDimmed,
  setUserLocation,
  setUserStyle,
  setVectorMode,
} from './map.js';
import { icon } from './icons.js';
import { createRouteCanvas } from './route-canvas.js';
import { carSvg, onCarChange } from './car.js';
import {
  distanceClip,
  hasVoice,
  maneuverClip,
  preload as preloadVoice,
  say,
  setVoiceSex,
  stop as stopVoice,
  unlock as unlockVoice,
  voiceSex,
} from './voice.js';
import { showToast, hideToast } from './ui.js';
import { t, getLang } from './i18n.js';
import { track } from './analytics.js';
import { callFn } from './auth.js';
import { turnPhrase } from './turn-phrases.js';

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
  // Google separates the two halves of an instruction with block elements, and
  // textContent runs them straight together — "მოუხვიეთ მარჯვნივდანიშნულების
  // ადგილი იქნება მარცხნივ". Give those boundaries a space before flattening.
  d.innerHTML = String(html || '').replace(/<(?:br|\/?div|\/?p)[^>]*>/gi, ' ');
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

// Google's path knows only which way the arrow points, so that is what its
// spoken clip is picked by.
const ARROW_KIND = { left: 'left', right: 'right', uturn: 'uturn', up: 'straight' };

/** Map a Google maneuver string to one of our arrow names. */
function googleArrowKey(maneuver) {
  const m = (maneuver || '').toLowerCase();
  if (!m) return 'up';
  if (m.includes('uturn')) return 'uturn';
  if (m.includes('left')) return 'left';
  if (m.includes('right')) return 'right';
  return 'up'; // straight / merge / ferry / unknown
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

// ── Voice ───────────────────────────────────────────────────────────────────
// Recorded clips first (js/voice.js), the browser's own synthesiser only as a
// fallback. On a Tesla that fallback produces nothing at all — no installed
// voices — which is exactly why the recordings exist.
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

/** The browser's synthesiser. Returns false when it cannot say this sentence. */
function synthesize(text) {
  if (!text || !('speechSynthesis' in window)) return false;
  const v = pickVoice();
  // Instructions are Georgian. An English voice reading Georgian is worse than
  // silence, so skip unless a Georgian voice exists.
  const isGeo = /[Ⴀ-ჿ]/.test(text);
  if (isGeo && !(v && v.lang?.toLowerCase().startsWith('ka'))) return false;
  try {
    const u = new SpeechSynthesisUtterance(text);
    if (v) u.voice = v;
    u.lang = v?.lang || 'ka-GE';
    u.rate = 1;
    speechSynthesis.cancel();
    speechSynthesis.speak(u);
    return true;
  } catch (_) {
    return false; // text banner still guides
  }
}

/**
 * Say one instruction: the recorded clips if we have them, the synthesiser
 * otherwise.
 *
 * @param {string[]} clips  clip ids, in the order they should be heard
 * @param {string} text     the same thing as a sentence, for the fallback
 */
function speak(clips, text) {
  if (!state.voiceOn) return;
  say(clips).then((played) => {
    if (!played) synthesize(text);
  });
}

// ── Route building ───────────────────────────────────────────────────────────
// Both providers hand back the same thing: a dense {lat,lng} path, the running
// distance along it, and steps that say what to do and where. `endAlong` is
// filled in once, here, so the two paths cannot disagree about it.
function finish(path, steps, totalDurS) {
  const cum = new Array(path.length).fill(0);
  for (let i = 1; i < path.length; i++) cum[i] = cum[i - 1] + haversineM(path[i - 1], path[i]);
  for (const st of steps) st.endAlong = cum[st.endIdx] || 0;
  const totalM = cum.length ? cum[cum.length - 1] : 0;
  return { path, cum, steps, totalM, totalDurS };
}

// OpenRouteService, via functions/ors-route.js. Returns null on anything we do
// not fully understand — a route with no steps could still be driven, but it
// would be driven in silence, so Google is the better answer.
async function orsRoute(points) {
  try {
    const road = await callFn('orsRoute', { waypoints: points });
    const pts = road && road.pts;
    const steps = road && road.steps;
    if (!Array.isArray(pts) || pts.length < 2) return null;
    if (!Array.isArray(steps) || !steps.length) return null;

    const lang = getLang();
    const mapped = [];
    for (const st of steps) {
      if (!Number.isInteger(st.endIdx) || st.endIdx < 0 || st.endIdx >= pts.length) return null;
      const { text, arrow, kind } = turnPhrase(st, lang);
      mapped.push({ arrowKey: arrow, text, kind, endIdx: st.endIdx });
    }
    return finish(pts, mapped, road.totalDurS || 0);
  } catch (e) {
    console.warn('[drive] ORS unavailable, using Google:', e?.code || e?.message || e);
    return null;
  }
}

async function googleRoute(origin, destination, waypoints) {
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
      const arrowKey = googleArrowKey(step.maneuver);
      steps.push({
        arrowKey,
        text: stripHtml(step.instructions),
        // Google gives a sentence, not a maneuver we recognise; the arrow is
        // the most the recorded clips can be chosen by on this path.
        kind: ARROW_KIND[arrowKey],
        endIdx: path.length - 1,
      });
    }
  }

  return finish(path, steps, route.legs.reduce((a, l) => a + l.duration.value, 0));
}

async function computeRoute(origin, destination, waypoints) {
  const points = [origin, ...waypoints, destination];
  return (await orsRoute(points)) || googleRoute(origin, destination, waypoints);
}

/**
 * Nearest-point projection of a coordinate onto the route.
 *
 * `snapped` is the point ON the line, and it is what the car is drawn at while
 * we are plausibly on the road. Two errors stack up otherwise, and on a real
 * Tesla they showed as a car driving alongside its own route: the GPS fix is a
 * few metres out, and the road itself comes from OpenStreetMap (through ORS)
 * while the tiles under it are Google's, whose geometry for the same street can
 * sit several metres away. Neither is wrong enough to fix; both are visible.
 *
 * `bearing` is the direction of the segment we are on — a steadier heading than
 * the GPS one, which wanders at low speed and lags in a bend.
 */
function project(pos) {
  const { path, cum } = state.route;
  let offM = Infinity, alongM = 0, snapped = pos, segA = null, segB = null;
  for (let i = 0; i < path.length - 1; i++) {
    const [d, tt] = projSeg(pos, path[i], path[i + 1]);
    if (d < offM) {
      offM = d;
      alongM = cum[i] + tt * (cum[i + 1] - cum[i]);
      snapped = {
        lat: path[i].lat + (path[i + 1].lat - path[i].lat) * tt,
        lng: path[i].lng + (path[i + 1].lng - path[i].lng) * tt,
      };
      segA = path[i];
      segB = path[i + 1];
    }
  }
  // The bearing is taken to a point well AHEAD on the route, not along the
  // segment we happen to be standing on. A road's geometry turns a few degrees
  // at every vertex — about every twenty metres in an ORS path — and the camera
  // sits seventy-five metres in front of the car, so each of those little kinks
  // swung the view sideways by several metres while the route line stayed put.
  // That sideways sway is what reads as the line wobbling against the map.
  // Looking further down the road averages the kinks out and, as a bonus, leans
  // the map into a bend slightly before the car reaches it.
  const bearing = bearingAhead(snapped, alongM);
  return { offM, alongM, snapped, bearing };
}

// Two different questions, two different distances. The CAMERA wants to know
// where the road is going, far enough ahead that the little kinks in it average
// out; the CAR wants to know which way it is actually travelling right now. Use
// the camera's distance for the silhouette and it points across the road
// through every bend, which is what "the car is moving sideways" looked like.
const LOOKAHEAD_CAMERA_M = 60;
const LOOKAHEAD_CAR_M = 15;

/**
 * The point on the route at `alongM`, and the way the road runs there. This is
 * what the camera eases along: give it a distance and it gives back a place on
 * the line, so a car being animated between two fixes goes round the bend
 * rather than across it.
 */
function routePointAt(alongM) {
  const { path, cum } = state.route;
  const end = cum[cum.length - 1] || 0;
  const m = Math.max(0, Math.min(end, alongM));
  let i = 1;
  while (i < cum.length && cum[i] < m) i++;
  const a = path[i - 1];
  const b = path[i] || a;
  const seg = (cum[i] ?? cum[i - 1]) - cum[i - 1];
  const tt = seg > 0 ? (m - cum[i - 1]) / seg : 0;
  const pos = { lat: a.lat + (b.lat - a.lat) * tt, lng: a.lng + (b.lng - a.lng) * tt };
  return { pos, heading: bearingAhead(pos, m, LOOKAHEAD_CAR_M) };
}

function bearingAhead(from, alongM, lookahead = LOOKAHEAD_CAMERA_M) {
  const { path, cum } = state.route;
  const want = alongM + lookahead;
  let i = 1;
  while (i < cum.length && cum[i] < want) i++;
  const to = path[Math.min(i, path.length - 1)];
  if (!to) return null;
  // Too close to tell a direction from (the end of the route).
  if (haversineM(from, to) < 5) return null;
  return (
    (google.maps.geometry.spherical.computeHeading(
      new google.maps.LatLng(from.lat, from.lng),
      new google.maps.LatLng(to.lat, to.lng),
    ) + 360) % 360
  );
}

// How far off the line we still call "on the road". Beyond this the car is
// drawn at the raw fix, because pulling it onto a road it has left would hide
// exactly the thing the driver needs to see — and past 60 m, three fixes in a
// row, we reroute anyway.
const SNAP_MAX_M = 45;

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
// "The car always points up", the way Google Maps drives. On by default because
// that is what a driver expects of a nav screen; the button in the drive footer
// turns it off for anyone who would rather keep north at the top.
const HEADING_KEY = 'gc_drive_heading_up';
// Street level, one step closer than it was: at 17 the car sat in a view wide
// enough to plan with and too wide to drive by. Also what the recenter button
// restores.
const DRIVE_ZOOM = 18;
const state = {
  active: false,
  route: null,
  destination: null,
  waypoints: [],         // original stop coords (for rerouting through those still ahead)
  watchId: null,
  destMarker: null,
  firstFix: true,
  // The camera follows the car until the driver drags the map — looking ahead
  // at the route while every GPS fix pulls the map back is unusable. `lastPos`
  // is what the recenter button flies back to.
  following: true,
  lastPos: null,
  dragListener: null,
  pointerWatch: null,
  prevPos: null,
  prevAt: 0,
  speed: 0,
  heading: null,
  announced: new Set(),  // "<stepIdx>:far" / ":near" voice guards
  offCount: 0,
  snapNext: false,
  lastReroute: 0,
  arrived: false,
  voiceOn: localStorage.getItem(VOICE_KEY) !== '0',
  headingUp: localStorage.getItem(HEADING_KEY) !== '0',
  rotatable: false,      // the vector map is up and can actually turn
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
    // Through locateMe, which accepts a fix the app already has and asks both
    // ways at once — a car's browser can take a long time over a brand new
    // one, and navigation that refuses to start is worse than starting from
    // fifteen seconds ago. `center: false` because drawRoute() frames the
    // route itself a moment later.
    origin = await locateMe({ center: false, maxAgeMs: 15000 });
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
  state.prevAt = 0;
  state.speed = 0;
  state.heading = null;
  state.announced = new Set();
  state.offCount = 0;
  state.snapNext = false;
  state.lastReroute = Date.now();
  state.arrived = false;
  state.routeRef = routeRef;
  state.done = [];
  indexWaypoints();
  state.lastReport = 0;
  state.lastReportPos = null;

  enterUi();
  // Audio may only start from something the driver did, and starting navigation
  // is exactly that — the tap is still what got us here. Warm the clips up too,
  // so the first instruction does not wait on a download.
  unlockVoice();
  preloadVoice();
  // Swap the browsing map for the vector one, which is the only kind Google
  // lets us rotate. Returns false on a browser with no WebGL, and then drive
  // mode simply runs north-up on the map we already had.
  state.rotatable = setVectorMode(true);
  syncHeadingBtn();
  // The car is drawn on the route canvas from here on: the canvas covers the
  // map, so Google's own marker would be under the line.
  setUserStyle('none');
  setUserLocation(origin);
  drawRoute();
  track('drive_start', { stops: waypoints.length });

  // Two ways of noticing that the driver has taken the map over, because one is
  // not enough any more. `dragstart` is the map's own signal and never fires for
  // our camera writes — but those writes now happen every frame, and a gesture
  // that is overruled sixty times a second may never become a drag at all. So
  // the pointer itself is watched too: once a finger has moved a few pixels
  // across the map, the camera is theirs.
  state.dragListener = onMap('dragstart', () => setFollowing(false));
  state.pointerWatch = watchMapPointer();

  // First report goes out straight away: a trip that is interrupted two minutes
  // in should still be resumable.
  report(origin, route.totalM);

  // Follow the live position.
  state.watchId = navigator.geolocation.watchPosition(
    (p) =>
      onPosition(
        { lat: p.coords.latitude, lng: p.coords.longitude },
        Number.isFinite(p.coords.heading) ? p.coords.heading : null,
        Number.isFinite(p.coords.speed) && p.coords.speed >= 0 ? p.coords.speed : null,
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
  state.pointerWatch?.();
  state.pointerWatch = null;
  state.following = true;
  state.lastPos = null;
  $('drive-recenter').classList.add('is-hidden');
  stopVoice();
  if ('speechSynthesis' in window) speechSynthesis.cancel();
  setUserStyle('dot');
  // Take the route off the map and mark the drive over BEFORE the map is
  // swapped back: the swap announces itself, and a drive that still looked
  // active would answer by drawing the line again on the new map.
  routeLine.detach();
  state.destMarker?.setMap(null);
  state.destMarker = null;
  state.active = false;
  state.route = null;
  state.routeRef = null;
  navStop();
  setVectorMode(false); // back to the browsing map, in our own palette
  state.rotatable = false;
  setMarkersDimmed(false);
  document.body.classList.remove('is-driving');
  $('drive').classList.add('is-hidden');
  document.dispatchEvent(new CustomEvent('gc:drive-end'));
}

// ── Map drawing ──────────────────────────────────────────────────────────────
// The route line. Ours, on our own canvas, drawn from the same camera values in
// the same frame — see js/route-canvas.js for why Google's own polyline could
// not stay still on the road.
const routeLine = createRouteCanvas({ color: '#2bd594', casing: '#0a3b2b', widthPx: 7, casingPx: 12 });
// A different car or colour has to reach the canvas as well.
onCarChange(() => routeLine.setCarImage(carSvg(0)));
onCameraWrite((cam) => {
  routeLine.setCar(cam.car);
  routeLine.draw(cam);
});

function drawRoute() {
  // Idempotent on purpose: the route is drawn again whenever the map object
  // underneath is rebuilt (entering drive mode, switching theme mid-drive) and
  // after every reroute.
  setMarkersDimmed(true);
  routeLine.attach(document.getElementById('map').parentElement);
  routeLine.setRoute(state.route.path);
  routeLine.setCarImage(carSvg(0));
  drawDestination();
}

function drawDestination() {
  state.destMarker?.setMap(null);
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
function onPosition(pos, geoHeading, geoSpeed) {
  if (!state.active) return;

  const { offM, alongM, snapped, bearing } = project(pos);
  // On the road as far as we can tell: draw the car on the line rather than
  // beside it. Off it, the raw fix is the honest answer.
  const onRoute = offM <= SNAP_MAX_M;
  const shown = onRoute ? snapped : pos;
  state.lastPos = shown; // where the recenter button goes back to

  // Heading, best source first: the road we are on, then the GPS bearing, then
  // the line between the last two fixes. Worked out BEFORE the marker moves,
  // because the car silhouette is drawn pointing along it.
  // Speed, for the camera to carry the car forward on between fixes. The GPS
  // value where the car publishes one, otherwise the distance since the last
  // fix over the time it took.
  const now = Date.now();
  if (geoSpeed != null) {
    state.speed = geoSpeed;
  } else if (state.prevPos && state.prevAt) {
    const dt = (now - state.prevAt) / 1000;
    if (dt > 0.2 && dt < 10) state.speed = haversineM(state.prevPos, pos) / dt;
  }

  let moving = false;
  if (state.prevPos) moving = haversineM(state.prevPos, pos) > 3;
  if (onRoute && moving && bearing != null) {
    state.heading = bearing;
  } else if (geoHeading != null) {
    state.heading = geoHeading;
  } else if (moving && state.prevPos) {
    state.heading = google.maps.geometry.spherical.computeHeading(
      new google.maps.LatLng(state.prevPos.lat, state.prevPos.lng),
      new google.maps.LatLng(pos.lat, pos.lng),
    );
  }
  state.prevPos = pos;
  state.prevAt = now;

  // One handover per fix: where we are, which way we point, whether the camera
  // is still ours, and whether the map should turn with us. Everything between
  // two fixes is eased inside map.js.
  //
  // The heading is only handed over while the car is actually moving: a
  // stationary GPS heading wanders, and a map that spins at a red light is
  // worse than one that does not turn at all.
  navFollow({
    pos: shown,
    heading: moving ? state.heading : null,
    speed: moving ? state.speed : 0,
    // On the road, the camera follows the road: it is handed the distance we
    // have reached and a way to turn any distance back into a place.
    along: onRoute ? alongM : null,
    locate: onRoute ? routePointAt : null,
    // Which way to point the MAP, as opposed to the car: further down the road,
    // so the view leans into a bend instead of following every kink.
    mapHeading: onRoute ? bearingAhead(shown, alongM) : null,
    camera: state.following,
    rotate: state.headingUp && state.rotatable,
  });
  if (state.snapNext) {
    navJump(); // a new route measures distances differently; do not ease across
    state.snapNext = false;
  }
  if (state.firstFix) {
    getMap().setZoom(DRIVE_ZOOM);
    navJump();
    state.firstFix = false;
  }

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

/**
 * Watch for a finger dragging the map. Returns a function that stops watching.
 *
 * A tap is deliberately NOT enough: a driver who prods a charger should not lose
 * the camera. Only real movement counts.
 */
function watchMapPointer() {
  const el = document.getElementById('map');
  if (!el) return () => {};
  let from = null;
  const down = (e) => { from = { x: e.clientX, y: e.clientY }; };
  const move = (e) => {
    if (!from) return;
    if (Math.hypot(e.clientX - from.x, e.clientY - from.y) < 6) return;
    from = null;
    setFollowing(false);
  };
  const up = () => { from = null; };
  el.addEventListener('pointerdown', down, { capture: true, passive: true });
  el.addEventListener('pointermove', move, { capture: true, passive: true });
  el.addEventListener('pointerup', up, { capture: true, passive: true });
  el.addEventListener('pointercancel', up, { capture: true, passive: true });
  return () => {
    el.removeEventListener('pointerdown', down, { capture: true });
    el.removeEventListener('pointermove', move, { capture: true });
    el.removeEventListener('pointerup', up, { capture: true });
    el.removeEventListener('pointercancel', up, { capture: true });
  };
}

/**
 * Re-aim the camera after something other than a fix changed: the heading-up
 * switch, or the map being rebuilt. Without this a parked car would sit facing
 * the old way until it moved again.
 */
function applyHeadingMode() {
  if (!state.active || !state.lastPos) return;
  navFollow({
    pos: state.lastPos,
    heading: state.heading,
    speed: 0, // a deliberate re-aim, not a fix: do not carry the car forward
    camera: state.following,
    rotate: state.headingUp && state.rotatable,
  });
}

/**
 * Turn camera-follow on or off and show/hide the recenter button with it.
 * Turning it back on flies to the last known fix at the driving zoom, however
 * far the driver had panned or zoomed away.
 */
function setFollowing(on) {
  state.following = on;
  navSetCamera(on); // takes effect now, not at the next fix
  $('drive-recenter').classList.toggle('is-hidden', on);
  if (!on || !state.lastPos) return;
  getMap().setZoom(DRIVE_ZOOM);
  applyHeadingMode();
  navJump(); // the driver asked to be brought back, not eased back
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
  const icon = next ? (ARROW[next.arrowKey] || ARROW.up) : ARROW.flag;
  const road = next ? next.text : t('driveArrive');
  const stepIdx = next ? k + 1 : steps.length;

  $('drive-icon').innerHTML = icon;
  $('drive-dist').textContent = fmtDist(distToTurn);
  $('drive-road').textContent = road;

  // Voice: once on the way in, once at the turn itself. The far call carries
  // the distance ("ორას მეტრში, მოუხვიე მარჯვნივ"), the near one is the
  // maneuver alone — by then the distance is the windscreen's job.
  const kind = next ? next.kind || 'straight' : 'arrive';
  const move = maneuverClip(kind);
  const far = `${stepIdx}:far`;
  const near = `${stepIdx}:near`;
  if (distToTurn <= 300 && distToTurn > 70 && !state.announced.has(far)) {
    state.announced.add(far);
    speak([distanceClip(distToTurn), move], `${fmtDist(distToTurn)} — ${road}`);
  } else if (distToTurn <= 70 && !state.announced.has(near)) {
    state.announced.add(near);
    speak([move], road);
  }

  // Remaining distance + ETA.
  const remainS = totalM > 0 ? totalDurS * (remainM / totalM) : 0;
  const eta = new Date(Date.now() + remainS * 1000);
  $('drive-remain').textContent = fmtDist(remainM);
  // Two lines, written as two: "5 სთ 14 წთ" over "ჩასვლის დრო: 04:48". As one
  // string with a middot they wrapped wherever the car's screen ran out, which
  // put the clock on a line of its own under a dangling label.
  $('drive-duration').textContent = fmtDuration(remainS);
  $('drive-eta').textContent = `${t('driveArrivalAt')} ${fmtClock(eta)}`;
}

function onArrived() {
  state.arrived = true;
  document.dispatchEvent(new CustomEvent('gc:drive-arrived', { detail: { route: state.routeRef } }));
  $('drive-icon').innerHTML = ARROW.flag;
  $('drive-dist').textContent = '';
  $('drive-road').textContent = t('driveArrived');
  $('drive-remain').textContent = '';
  $('drive-duration').textContent = '';
  $('drive-eta').textContent = '';
  $('drive-banner').classList.add('is-arrived');
  speak(['arrive'], t('driveArrived'));
  track('drive_arrived', {});
}

// ── Reroute ──────────────────────────────────────────────────────────────────
async function reroute(pos, currentAlong) {
  state.lastReroute = Date.now();
  state.offCount = 0;
  state.snapNext = true; // the new route's distances are not the old one's
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
    drawRoute();
    speak(['reroute'], t('driveRerouted'));
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
  $('drive-duration').textContent = '';
  $('drive-eta').textContent = '';
  syncVoiceBtn();
  syncHeadingBtn();
}

/**
 * The north-up / heading-up switch. Hidden outright where the map cannot turn
 * (no WebGL in the car's browser), because a button that does nothing is worse
 * than no button.
 */
function syncHeadingBtn() {
  const btn = $('drive-heading');
  if (!btn) return;
  btn.classList.toggle('is-hidden', !state.rotatable);
  btn.classList.toggle('is-off', !state.headingUp);
  btn.innerHTML = icon(state.headingUp ? 'headingUp' : 'compass', 24);
  const key = state.headingUp ? 'driveNorthUp' : 'driveHeadingUp';
  btn.title = t(key);
  btn.setAttribute('aria-label', t(key));
}

// The speaker button carries three states, not two: the woman's voice, the
// man's voice, and off. Both languages are recorded twice (js/voice.js), and a
// car has nowhere else to put a preference — a settings screen a driver has to
// go looking for would be worse than one button they can find by pressing it.
const SPEAKER_ON =
  '<svg viewBox="0 0 24 24" width="24" height="24" fill="currentColor"><path d="M3 9v6h4l5 5V4L7 9H3zm13.5 3a4.5 4.5 0 00-2.5-4v8a4.5 4.5 0 002.5-4zm-2.5-9v2.06a7 7 0 010 13.88V21a9 9 0 000-18z"/></svg>';
const SPEAKER_OFF =
  '<svg viewBox="0 0 24 24" width="24" height="24" fill="currentColor"><path d="M3 9v6h4l5 5V4L7 9H3zm16.6 3l2.1-2.1-1.4-1.4-2.1 2.1-2.1-2.1-1.4 1.4L16.8 12l-2.1 2.1 1.4 1.4 2.1-2.1 2.1 2.1 1.4-1.4L19.6 12z"/></svg>';

function syncVoiceBtn() {
  const btn = $('drive-voice');
  if (!btn) return;
  const male = voiceSex() === 'm';
  btn.classList.toggle('is-off', !state.voiceOn);
  // The letter is what says WHICH voice without a word of explanation: ქ/კ in
  // Georgian, F/M in English. Both are letters, so no font can drop them the
  // way it dropped ✕ — see js/icons.js.
  btn.innerHTML =
    (state.voiceOn ? SPEAKER_ON : SPEAKER_OFF) +
    (state.voiceOn
      ? `<span class="drive-foot__tag">${t(male ? 'voiceTagMale' : 'voiceTagFemale')}</span>`
      : '');
  const label = !state.voiceOn ? 'voiceOff' : male ? 'voiceMale' : 'voiceFemale';
  btn.title = t(label);
  btn.setAttribute('aria-label', t(label));
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
  $('drive-heading').addEventListener('click', () => {
    state.headingUp = !state.headingUp;
    localStorage.setItem(HEADING_KEY, state.headingUp ? '1' : '0');
    applyHeadingMode();
    syncHeadingBtn();
    track('drive_heading_up', { on: state.headingUp ? 1 : 0 });
  });
  // Drive mode rebuilds the map when it starts (raster → vector), and the theme
  // switch rebuilds it again mid-drive. Both leave the route line on a map that
  // no longer exists, so it is drawn afresh.
  document.addEventListener('gc:map-recreated', () => {
    if (!state.active || !state.route) return;
    state.rotatable = isVectorMap();
    drawRoute();
    applyHeadingMode();
    syncHeadingBtn();
  });
  // Woman → man → off → woman. Muting is never more than two presses away, and
  // every press says out loud in a toast which state it landed in.
  $('drive-voice').addEventListener('click', () => {
    if (state.voiceOn && voiceSex() === 'f') {
      setVoiceSex('m');
    } else if (state.voiceOn) {
      state.voiceOn = false;
    } else {
      state.voiceOn = true;
      setVoiceSex('f');
    }
    localStorage.setItem(VOICE_KEY, state.voiceOn ? '1' : '0');
    if (!state.voiceOn) {
      stopVoice();
      if ('speechSynthesis' in window) speechSynthesis.cancel();
      showToast(t('voiceOff'), 2500);
    } else {
      unlockVoice();
      preloadVoice();
      showToast(t(voiceSex() === 'm' ? 'voiceMale' : 'voiceFemale'), 2500);
      // And say so rather than leaving the driver waiting for a voice that
      // cannot come: no recordings and no usable synthesiser is a silent
      // switch, and silence is indistinguishable from a bug.
      hasVoice().then((ok) => {
        if (!ok && !pickVoice()) showToast(t('driveNoVoice'));
      });
    }
    syncVoiceBtn();
  });
  // Warm the voice list (Chromium populates asynchronously).
  if ('speechSynthesis' in window) speechSynthesis.getVoices();
}
