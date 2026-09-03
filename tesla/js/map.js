// Google Map wrapper: day/night style, status-coloured markers, clustering.

import { MAPS_API_KEY, MAP_ID, MAP_CENTER, MAP_ZOOM } from './config.js';
import { carIcon, onCarChange } from './car.js';

// Dark style tuned to the app palette (surface #151c22 family).
const NIGHT_STYLE = [
  { elementType: 'geometry', stylers: [{ color: '#151c22' }] },
  { elementType: 'labels.text.fill', stylers: [{ color: '#9fb0bb' }] },
  { elementType: 'labels.text.stroke', stylers: [{ color: '#0d1216' }] },
  { featureType: 'poi', stylers: [{ visibility: 'off' }] },
  { featureType: 'transit', stylers: [{ visibility: 'off' }] },
  { featureType: 'road', elementType: 'geometry', stylers: [{ color: '#263038' }] },
  { featureType: 'road.highway', elementType: 'geometry', stylers: [{ color: '#33414c' }] },
  { featureType: 'water', elementType: 'geometry', stylers: [{ color: '#0a2333' }] },
  { featureType: 'landscape', elementType: 'geometry', stylers: [{ color: '#11181e' }] },
  { featureType: 'administrative', elementType: 'geometry.stroke', stylers: [{ color: '#263038' }] },
];

// Daylight style. Same restraint as the night one — POIs and transit off, so
// the charger pins are the only thing competing for attention — but light
// enough to survive direct sun on the car's screen.
const DAY_STYLE = [
  { elementType: 'geometry', stylers: [{ color: '#eef2f5' }] },
  { elementType: 'labels.text.fill', stylers: [{ color: '#46545f' }] },
  { elementType: 'labels.text.stroke', stylers: [{ color: '#ffffff' }] },
  { featureType: 'poi', stylers: [{ visibility: 'off' }] },
  { featureType: 'transit', stylers: [{ visibility: 'off' }] },
  { featureType: 'road', elementType: 'geometry', stylers: [{ color: '#ffffff' }] },
  { featureType: 'road', elementType: 'geometry.stroke', stylers: [{ color: '#dfe6eb' }] },
  { featureType: 'road.highway', elementType: 'geometry', stylers: [{ color: '#ffe6b8' }] },
  { featureType: 'road.highway', elementType: 'geometry.stroke', stylers: [{ color: '#efc98c' }] },
  { featureType: 'water', elementType: 'geometry', stylers: [{ color: '#bcd8ea' }] },
  { featureType: 'landscape', elementType: 'geometry', stylers: [{ color: '#f4f6f8' }] },
  { featureType: 'administrative', elementType: 'geometry.stroke', stylers: [{ color: '#d3dbe1' }] },
];

const stylesFor = (theme) => (theme === 'light' ? DAY_STYLE : NIGHT_STYLE);

const STATUS_COLORS = {
  free: '#2bd594',
  busy: '#f5a623',
  out: '#6b7a85',
  unknown: '#4F7C9E', // no live availability published
};

// Marker pie colours — match the app's _AvailabilityPainter exactly.
const PIN_FREE = '#00C896'; // emerald  (available portion)
const PIN_BUSY = '#FFAB40'; // orangeAccent (busy portion)
const PIN_OUT  = '#6B7A85'; // grey — fully out-of-order charger
// Slate — the source publishes no real-time availability (Turkey's EPDK
// registry). Drawing those green would claim the plugs are free when we simply
// do not know. Matches _unknownSlate in lib/main.dart.
const PIN_UNKNOWN = '#4F7C9E';

// A station is fully out of order: no free plug and every published plug reads
// "out" (neither free nor busy). Such pins are drawn grey, not busy-orange.
function stationOut(s) {
  return (
    s.available === 0 &&
    // At least one plug REPORTED broken. A plug the operator publishes no
    // status for (Tegeta's Porsche destination chargers) says nothing about the
    // charger, so a site made only of those is unknown, not out of order.
    s.ports && s.ports.some((p) => p.status === 'out') &&
    !s.ports.some((p) => p.status === 'free' || p.status === 'busy')
  );
}

let map = null;
let mapContainer = null;
// Which of the two maps is on screen. The browsing map is RASTER, because that
// is the only one our own day/night styles work on; drive mode swaps to a
// VECTOR one, because a raster map physically cannot rotate and "the car
// always points up" is a rotation. See setVectorMode().
let vector = false;
let markers = new Map(); // station.id -> google.maps.Marker
let clusterer = null;
let userMarker = null;   // blue "my location" dot
let searchMarker = null; // red destination pin
let trafficLayer = null;

// Where the locate button leaves the camera. Google Maps' own "my location"
// lands at street level, and the old value here (13) showed a whole region
// with a dot somewhere in it — technically the answer, useless in a car.
const LOCATE_ZOOM = 16;

/** Load the Maps JS API once; resolves when `google.maps` is usable. */
export function loadMapsApi() {
  if (window.google?.maps) return Promise.resolve();
  return new Promise((resolve, reject) => {
    const cb = '__gcMapsReady';
    window[cb] = () => resolve();
    const s = document.createElement('script');
    s.src =
      `https://maps.googleapis.com/maps/api/js?key=${MAPS_API_KEY}` +
      `&callback=${cb}&language=ka&region=GE&loading=async&libraries=places,geometry`;
    s.onerror = () => reject(new Error('maps script failed'));
    document.head.appendChild(s);
  });
}

// Options both maps share. Everything that differs between raster and vector
// is added by mapOptions() below, so the two can never drift apart.
const BASE_OPTIONS = {
  disableDefaultUI: true,
  // No Maps API zoom control: it drew itself in the bottom-right corner, under
  // our own buttons, and at a size you cannot hit in a moving car. The column
  // in index.html carries a full-size pair instead.
  zoomControl: false,
  gestureHandling: 'greedy', // one-finger everything — it's a car screen
  clickableIcons: false,
};

function mapOptions(theme, wantVector) {
  if (wantVector) {
    return {
      ...BASE_OPTIONS,
      mapId: MAP_ID,
      renderingType: google.maps.RenderingType.VECTOR,
      // Our own styles are ignored on a vector map (Google logs exactly that),
      // so the closest we can get to the palette until the cloud style is
      // attached to MAP_ID is Google's own light/dark scheme.
      colorScheme: theme === 'light' ? 'LIGHT' : 'DARK',
    };
  }
  // The theme is already on <html> before the first paint, so the map is born
  // in the right one instead of flashing dark and then repainting.
  return { ...BASE_OPTIONS, styles: stylesFor(theme) };
}

/** Is a rotating map possible here at all? A Tesla browser without WebGL is not. */
export function canRotate() {
  if (!MAP_ID) return false;
  try {
    const c = document.createElement('canvas');
    return !!(c.getContext('webgl2') || c.getContext('webgl'));
  } catch (_) {
    return false;
  }
}

export function initMap(container) {
  mapContainer = container;
  map = new google.maps.Map(container, {
    center: MAP_CENTER,
    zoom: MAP_ZOOM,
    ...mapOptions(document.documentElement.dataset.theme, false),
  });
  // Keep the car square with the roads under it: the map eases into a new
  // heading over several frames, and the silhouette has to turn with it rather
  // than with the value we asked for.
  onMap('heading_changed', () => applyUserIcon());
  // Redraw whatever rides on our own canvas while the driver moves the map.
  onMap('bounds_changed', publishMapCamera);
  return map;
}

// ── Listeners that must survive a rebuilt map ────────────────────────────────
// A map ID cannot be changed on a live map, so switching between the raster and
// the vector one means building a new google.maps.Map — and every listener
// attached to the old one dies with it. Anything registered here is re-attached
// to the new map automatically; use it instead of getMap().addListener().
const mapListeners = [];

export function onMap(event, handler) {
  const entry = { event, handler, ref: map ? map.addListener(event, handler) : null };
  mapListeners.push(entry);
  return {
    remove() {
      entry.ref?.remove();
      const i = mapListeners.indexOf(entry);
      if (i >= 0) mapListeners.splice(i, 1);
    },
  };
}

/**
 * Swap between the browsing map (raster, our palette) and the driving map
 * (vector, rotatable). Everything map.js owns moves across by itself; anything
 * drawn by another module — the drive line, the trip route — is redrawn by that
 * module when it hears `gc:map-recreated`.
 *
 * @returns {boolean} whether the map now on screen can rotate
 */
export function setVectorMode(on) {
  const want = !!on && canRotate();
  if (!map || want === vector) return vector;

  const center = map.getCenter();
  const zoom = map.getZoom();
  const traffic = !!trafficLayer?.getMap();

  // Overlays map.js owns: unhook them, then re-hook to the new map. Markers go
  // through the clusterer, which is rebuilt from the same marker objects.
  clusterer?.clearMarkers();
  userMarker?.setMap(null);
  searchMarker?.setMap(null);
  trafficLayer?.setMap(null);
  clusterer = null;

  map = new google.maps.Map(mapContainer, {
    center,
    zoom,
    ...mapOptions(document.documentElement.dataset.theme, want),
  });
  vector = want;
  headingNow = 0; // a rebuilt map starts north-up; the nav loop turns it back

  for (const e of mapListeners) e.ref = map.addListener(e.event, e.handler);

  if (userMarker) userMarker.setMap(map);
  if (searchMarker) searchMarker.setMap(map);
  if (traffic) setTraffic(true);
  rebuildClusterer();

  document.dispatchEvent(new CustomEvent('gc:map-recreated', { detail: { vector } }));
  return vector;
}

/** True while the rotatable (vector) map is the one on screen. */
export function isVectorMap() {
  return vector;
}

// ── The navigation camera ────────────────────────────────────────────────────
// A GPS fix arrives once a second. Everything that moves has to be moved from
// it: the car, the camera under the car, and the heading the whole map is
// turned to. Doing that as three separate animations is what made the map
// stutter — panTo ran Google's own easing, setHeading snapped, and the marker
// jumped fifteen metres on the second. So there is one loop here, it eases one
// set of values, and it writes them to the map in a single call per step.
//
// The loop runs on requestAnimationFrame, with a timer behind it as a watchdog.
// rAF is the right clock here and only here: the map draws its base on the
// compositor's own frame, and a camera moved on a timer between frames left the
// route line sliding against the map underneath it — the wiggle that reads as
// two separate layers. Moved on the frame, the two move together.
//
// The watchdog is there because rAF stops in a tab that is not being painted
// (and, in the in-app preview, in one that claims to be visible). Nothing
// visual is lost while nothing is drawn; the point is that the eased position
// must not be stale when painting resumes.
const NAV_WATCHDOG_MS = 500;
// How long the camera takes to close most of the gap to the newest fix. Fixes
// arrive about once a second, so this has to be of that order: close it in a
// fifth of a second and the camera lurches and then waits, which is the jerk we
// started with, only faster.
//
// The easing is worked out from ELAPSED TIME, not from how many times the timer
// happened to fire. A background tab is throttled to one tick a second, a busy
// car screen may drop frames, and a fixed fraction per tick would then crawl
// behind and catch up in lurches — which is exactly what the measurements
// showed. With time in the exponent the path is the same however often we are
// called; a slow browser just draws fewer points along it.
const NAV_TAU_MS = 300;
// Turning is deliberately slower than moving, and capped. The camera used to
// swing the whole world round a corner in about a second, which is disorienting
// at the wheel — the map should follow the car through the bend, not whip round
// ahead of it. The car silhouette still turns at the position rate, so it leans
// into the corner a moment before the map does, the way it does in Google Maps.
const NAV_TURN_TAU_MS = 1100;
const NAV_TURN_MAX_DPS = 45;   // degrees per second, whatever the easing asks for
// A fix is a second old by the time the next one lands, so between them the car
// is carried forward along its heading at the speed it was last seen doing.
// Without it the camera can only chase a target that stands still for a second
// and then teleports, which is the pulse a driver reads as juddering. Capped,
// because if the fixes stop we must not sail off down the road alone.
const NAV_PREDICT_MAX_MS = 2500;
// Past this the car has not driven, it has teleported — a tunnel, a reroute, a
// fix that finally landed. Easing across a kilometre would fly the camera over
// the map; jump instead.
const NAV_SNAP_M = 80;
// How far ahead of the car the camera sits. Tuned with the zoom: at drive
// zoom a screen is roughly 300 m tall, so this puts the car about two thirds of
// the way down and leaves the road ahead filling the rest.
const NAV_BIAS_M = 75;
let navRaf = 0;
let navTimer = 0;
let navTarget = null;       // where the last fix says we are
let navShown = null;        // where we are currently drawn
let navLastStep = 0;        // when the easing last ran, for time-based easing
// Anything that has to be drawn in step with the camera — the route line is
// drawn on its own canvas for exactly this reason — is told here, in the same
// frame, from the same numbers.
let cameraHook = null;

/** Be told, per frame, the camera that was just written. */
export function onCameraWrite(fn) {
  cameraHook = fn;
}

/**
 * The same message, but for the camera the MAP is showing rather than the one
 * we wrote. While the driver has the map in their hand we are not moving it, so
 * without this anything drawn against our camera — the route line — would stay
 * where it was and slide off the road as they drag.
 */
function publishMapCamera() {
  if (!map || !cameraHook || !navShown || navTarget?.camera) return;
  const c = map.getCenter();
  if (!c) return;
  cameraHook({
    center: { lat: c.lat(), lng: c.lng() },
    zoom: map.getZoom(),
    heading: vector ? map.getHeading() || 0 : 0,
    car: { lat: navShown.pos.lat, lng: navShown.pos.lng, heading: navShown.heading },
  });
}
let headingNow = 0;         // what the map is turned to right now

const shortWay = (from, to) => ((((to - from) % 360) + 540) % 360) - 180;

/** Where the top of the screen points right now. */
export function getMapHeading() {
  return vector ? headingNow : 0;
}

// The camera is written here, once per animation frame, and never handed to
// the map's own panTo. Letting Google animate it does keep the route line
// glued to the ground — the map moves the base and its overlays in one pass —
// but it arrives in short glides that judder badly at driving speed, which was
// worse than the thing it fixed. Tried and rejected on the road, 2026-09-03.
function writeCamera() {
  if (!map || !navShown) return;
  // The car is drawn where we have eased it to, not where the fix was.
  userHeading = navShown.heading;
  if (userMarker) {
    userMarker.setPosition(navShown.pos);
    if (!userMarker.getMap()) userMarker.setMap(map);
  }
  applyUserIcon();

  if (!navTarget || !navTarget.camera) return;
  // Bias the camera ahead of the car so the road reads (nav convention). The
  // offset follows the heading whether or not the map itself turns.
  const center = google.maps.geometry.spherical.computeOffset(
    new google.maps.LatLng(navShown.pos.lat, navShown.pos.lng),
    NAV_BIAS_M,
    navShown.heading,
  );
  if (vector && map.moveCamera) {
    // One call for both, so the pan and the turn cannot fight each other.
    map.moveCamera({ center, heading: headingNow });
  } else {
    map.setCenter(center);
  }
  cameraHook?.({
    center: { lat: center.lat(), lng: center.lng() },
    zoom: map.getZoom(),
    heading: vector ? headingNow : 0,
    car: { lat: navShown.pos.lat, lng: navShown.pos.lng, heading: navShown.heading },
  });
}

function stepNav() {
  if (!map || !navTarget || !navShown) {
    stopNavLoop();
    return;
  }
  const now = Date.now();
  const dt = Math.min(1000, now - (navLastStep || now - 16));
  navLastStep = now;
  const ease = 1 - Math.exp(-dt / NAV_TAU_MS);
  const t = navTarget;

  if (t.locate) {
    // Everything happens on one number: how far along the route we are drawn.
    // Turn it back into a point only at the end, so the car can only ever be ON
    // the road, whatever the corner does.
    const aimAlong = t.along + carriedM();
    if (Math.abs(aimAlong - navShown.along) > NAV_SNAP_M) {
      navJump();
      return;
    }
    navShown.along += (aimAlong - navShown.along) * ease;
    const at = t.locate(navShown.along);
    if (at && at.pos) navShown.pos = at.pos;
    const headTo = Number.isFinite(at?.heading) ? at.heading : t.heading;
    navShown.heading =
      (navShown.heading + shortWay(navShown.heading, headTo) * ease + 360) % 360;
  } else {
    const aim = predicted();
    // Metres apart, near enough: a degree of latitude is ~111 km, and longitude
    // shrinks with the cosine, which at Georgian latitudes is about 0.74.
    const gapM = Math.hypot(
      (aim.lat - navShown.pos.lat) * 111320,
      (aim.lng - navShown.pos.lng) * 111320 * 0.74,
    );
    if (gapM > NAV_SNAP_M) {
      navJump();
      return;
    }
    navShown.pos = {
      lat: navShown.pos.lat + (aim.lat - navShown.pos.lat) * ease,
      lng: navShown.pos.lng + (aim.lng - navShown.pos.lng) * ease,
    };
    navShown.heading =
      (navShown.heading + shortWay(navShown.heading, t.heading) * ease + 360) % 360;
  }
  const mapTarget = vector && t.rotate
    ? (Number.isFinite(t.mapHeading) ? t.mapHeading : navShown.heading)
    : 0;
  const turnEase = 1 - Math.exp(-dt / NAV_TURN_TAU_MS);
  const turnMax = (NAV_TURN_MAX_DPS * dt) / 1000;
  let turn = shortWay(headingNow, mapTarget) * turnEase;
  turn = Math.max(-turnMax, Math.min(turnMax, turn));
  headingNow = (headingNow + turn + 360) % 360;
  writeCamera();
}

/** How far the car has carried on since the fix, at the speed it was doing. */
function carriedM() {
  const t = navTarget;
  if (!t) return 0;
  const ms = Math.min(NAV_PREDICT_MAX_MS, Date.now() - t.at);
  return (t.speed || 0) * (ms / 1000);
}

/**
 * Where the car should be by now.
 *
 * On a route this is a DISTANCE ALONG IT, which the caller turns back into a
 * point — that is what makes the car go round a corner instead of across it.
 * Easing straight from one fix to the next in latitude and longitude cuts every
 * bend, and carrying the car forward along its heading walks it off the road
 * entirely, both of which showed as the car leaving the line at junctions.
 * Off the route (or with no route at all) there is nothing to follow, and the
 * straight line between two fixes is the honest answer.
 */
function predicted() {
  const t = navTarget;
  if (!t) return null;
  if (t.locate) {
    const at = t.locate(t.along + carriedM());
    return at && at.pos ? at.pos : t.pos;
  }
  const ahead = carriedM();
  if (ahead < 1) return t.pos;
  const p = google.maps.geometry.spherical.computeOffset(
    new google.maps.LatLng(t.pos.lat, t.pos.lng),
    ahead,
    t.heading,
  );
  return { lat: p.lat(), lng: p.lng() };
}

/**
 * Feed the camera a fix. Call it once per GPS update; everything between them
 * — the prediction and the easing — is this module's job.
 *
 * @param {{pos:{lat,lng}, heading:number|null, speed:number|null,
 *          along:number|null, locate:function|null,
 *          camera:boolean, rotate:boolean}} t
 *        `speed` in m/s. `along` + `locate` say we are on a route: `along` is
 *        how far along it this fix is, and `locate(metres)` gives back
 *        `{pos, heading}` at any distance along it, which is what the easing
 *        then runs on. `camera` false leaves the map where the driver dragged
 *        it and only moves the car; `rotate` false keeps north up.
 */
export function navFollow(t) {
  const heading = Number.isFinite(t.heading) ? t.heading : navShown?.heading ?? 0;
  const onRoute = typeof t.locate === 'function' && Number.isFinite(t.along);
  navTarget = {
    pos: t.pos,
    heading,
    speed: Number.isFinite(t.speed) && t.speed > 0.5 ? t.speed : 0,
    along: onRoute ? t.along : null,
    locate: onRoute ? t.locate : null,
    mapHeading: Number.isFinite(t.mapHeading) ? t.mapHeading : null,
    at: Date.now(),
    camera: !!t.camera,
    rotate: !!t.rotate,
  };
  if (!navShown) {
    navShown = { pos: { ...t.pos }, heading, along: onRoute ? t.along : null };
    headingNow = vector && navTarget.rotate ? heading : 0;
    writeCamera();
  }
  // A route the driver has just been put on (or rerouted onto) measures its
  // distances differently from the last one, so there is nothing to ease from.
  if (onRoute && navShown.along == null) navShown.along = t.along;
  startNavLoop();
}

function pump() {
  navRaf = 0;
  stepNav();
  if (navTarget) navRaf = requestAnimationFrame(pump);
}

function startNavLoop() {
  if (!navRaf) navRaf = requestAnimationFrame(pump);
  if (!navTimer) {
    navTimer = setInterval(() => {
      // Only when the frames have stopped coming; otherwise pump() has it.
      if (Date.now() - navLastStep > NAV_WATCHDOG_MS - 100) stepNav();
    }, NAV_WATCHDOG_MS);
  }
}

function stopNavLoop() {
  if (navRaf) cancelAnimationFrame(navRaf);
  navRaf = 0;
  clearInterval(navTimer);
  navTimer = 0;
  navLastStep = 0;
}

/**
 * Hand the camera over, or take it back, THIS INSTANT.
 *
 * The loop writes the camera on every frame, so a driver dragging the map was
 * overruled sixty times a second and the map would not move at all. Waiting for
 * the next fix to carry `camera: false` is a second too late — by then the
 * gesture has been fought off. This flips it on the spot.
 */
export function navSetCamera(on) {
  if (navTarget) navTarget.camera = !!on;
}

/** Snap to the latest fix instead of easing to it (first fix, recenter). */
export function navJump() {
  if (!navTarget) return;
  navLastStep = 0;
  const t = navTarget;
  navShown = {
    pos: { ...(predicted() || t.pos) },
    heading: t.heading,
    along: t.locate ? t.along + carriedM() : null,
  };
  headingNow = vector && navTarget.rotate ? navTarget.heading : 0;
  writeCamera();
}

/** Debug handle: where the car is actually being drawn right now. */
export function navState() {
  return navShown ? { ...navShown, mapHeading: headingNow } : null;
}

/** Navigation is over: stop moving anything. */
export function navStop() {
  navTarget = null;
  stopNavLoop();
  navShown = null;
  headingNow = 0;
}

export function getMap() {
  return map;
}

/**
 * Repaint the map for 'light' / 'dark'. Silent before the map exists.
 *
 * The raster map just takes new styles. The vector one carries its scheme in an
 * option that only applies at construction, so switching theme mid-drive means
 * building it again — the same swap setVectorMode() does, and just as
 * self-repairing.
 */
export function setMapTheme(theme) {
  if (!map) return;
  if (!vector) {
    map.setOptions({ styles: stylesFor(theme) });
    return;
  }
  vector = false;      // force the rebuild past setVectorMode's early return
  setVectorMode(true);
}

/** Station-level colour: any free port → free; else any busy → busy; else out. */
export function stationStatus(s) {
  if (s.live === false) return 'unknown';
  if (s.available > 0) return 'free';
  if (s.ports.some((p) => p.status === 'busy')) return 'busy';
  return 'out';
}

/** Fraction of plugs free (available/total), like the app's freeFraction. */
function freeFraction(s) {
  if (s.total > 0) return Math.min(1, Math.max(0, s.available / s.total));
  return s.available > 0 ? 1 : 0;
}

// Point on the r=15 circle centred at (22,22) at `frac` of a full turn,
// measured clockwise from the top (12 o'clock) — for the SVG pie wedge.
function arcPoint(frac) {
  const a = -Math.PI / 2 + frac * 2 * Math.PI;
  return [22 + 15 * Math.cos(a), 22 + 15 * Math.sin(a)];
}

function markerIcon(s) {
  const f = freeFraction(s);
  let body;
  if (s.live === false) {
    body = `<circle cx="22" cy="22" r="15" fill="${PIN_UNKNOWN}"/>`;
  } else if (stationOut(s)) {
    body = `<circle cx="22" cy="22" r="15" fill="${PIN_OUT}"/>`;
  } else if (f >= 1) {
    body = `<circle cx="22" cy="22" r="15" fill="${PIN_FREE}"/>`;
  } else if (f <= 0) {
    body = `<circle cx="22" cy="22" r="15" fill="${PIN_BUSY}"/>`;
  } else {
    // Orange base, then a green pie wedge from the top clockwise by f×360°.
    const [ex, ey] = arcPoint(f);
    const large = f > 0.5 ? 1 : 0;
    body =
      `<circle cx="22" cy="22" r="15" fill="${PIN_BUSY}"/>` +
      `<path d="M22 22 L22 7 A15 15 0 ${large} 1 ${ex.toFixed(2)} ${ey.toFixed(2)} Z" fill="${PIN_FREE}"/>`;
  }
  const svg =
    `<svg xmlns="http://www.w3.org/2000/svg" width="44" height="44" viewBox="0 0 44 44">` +
    body +
    `<circle cx="22" cy="22" r="14" fill="none" stroke="rgba(255,255,255,0.25)" stroke-width="2"/>` +
    `<path d="M23.5 13l-7 10.5h5l-1 7 7-10.5h-5z" fill="#0d1216"/>` +
    `</svg>`;
  return {
    url: 'data:image/svg+xml;charset=UTF-8,' + encodeURIComponent(svg),
    scaledSize: new google.maps.Size(44, 44),
    anchor: new google.maps.Point(22, 22),
  };
}

// Cluster bubble icon: a proportional availability pie across the grouped
// stations (same green/orange split as a single pin), so a group of all-busy
// chargers reads orange from far out instead of a misleading solid green.
function clusterIcon(clustered) {
  let avail = 0, tot = 0, count = 0, outCount = 0, unknownCount = 0;
  for (const m of clustered) {
    const s = m.__station;
    if (!s) continue;
    count++;
    // Registry-only stations can't be counted free or busy — they would tint
    // the whole bubble on a guess.
    if (s.live === false) { unknownCount++; continue; }
    if (stationOut(s)) outCount++;
    avail += s.available;
    tot += s.total > 0 ? s.total : s.available > 0 ? s.available : 1;
  }
  const f = tot > 0 ? Math.min(1, Math.max(0, avail / tot)) : avail > 0 ? 1 : 0;
  const allOut = count > 0 && outCount === count; // grey only if every one is out
  const allUnknown = count > 0 && unknownCount === count;
  const cx = 26, cy = 26, r = 20;
  let body;
  if (allUnknown) {
    body = `<circle cx="${cx}" cy="${cy}" r="${r}" fill="${PIN_UNKNOWN}"/>`;
  } else if (allOut) {
    body = `<circle cx="${cx}" cy="${cy}" r="${r}" fill="${PIN_OUT}"/>`;
  } else if (f >= 1) {
    body = `<circle cx="${cx}" cy="${cy}" r="${r}" fill="${PIN_FREE}"/>`;
  } else if (f <= 0) {
    body = `<circle cx="${cx}" cy="${cy}" r="${r}" fill="${PIN_BUSY}"/>`;
  } else {
    const a = -Math.PI / 2 + f * 2 * Math.PI;
    const ex = (cx + r * Math.cos(a)).toFixed(2);
    const ey = (cy + r * Math.sin(a)).toFixed(2);
    const large = f > 0.5 ? 1 : 0;
    body =
      `<circle cx="${cx}" cy="${cy}" r="${r}" fill="${PIN_BUSY}"/>` +
      `<path d="M${cx} ${cy} L${cx} ${cy - r} A${r} ${r} 0 ${large} 1 ${ex} ${ey} Z" fill="${PIN_FREE}"/>`;
  }
  const svg =
    `<svg xmlns="http://www.w3.org/2000/svg" width="52" height="52" viewBox="0 0 52 52">` +
    body +
    `<circle cx="${cx}" cy="${cy}" r="${r - 1}" fill="none" stroke="rgba(255,255,255,0.4)" stroke-width="2"/>` +
    `</svg>`;
  return {
    url: 'data:image/svg+xml;charset=UTF-8,' + encodeURIComponent(svg),
    scaledSize: new google.maps.Size(52, 52),
  };
}

/**
 * Render (or re-render) the marker set. Reuses existing markers so a live
 * refresh only repaints icons instead of flickering the whole layer.
 */
export function renderMarkers(stations, onSelect) {
  const seen = new Set();

  for (const s of stations) {
    seen.add(s.id);
    let m = markers.get(s.id);
    if (!m) {
      m = new google.maps.Marker({ position: { lat: s.lat, lng: s.lng } });
      m.addListener('click', () => onSelect(m.__station));
      markers.set(s.id, m);
    }
    m.setIcon(markerIcon(s));
    m.__station = s;
  }

  // Drop markers for stations that vanished from the feed.
  for (const [id, m] of markers) {
    if (!seen.has(id)) {
      m.setMap(null);
      markers.delete(id);
    }
  }

  rebuildClusterer();
}

/** Put every marker we hold onto the map that is on screen right now. */
function rebuildClusterer() {
  if (!map) return;
  const list = [...markers.values()];
  if (!clusterer) {
    clusterer = new markerClusterer.MarkerClusterer({
      map,
      markers: list,
      renderer: {
        render: ({ count, position, markers: clustered }) =>
          new google.maps.Marker({
            position,
            zIndex: google.maps.Marker.MAX_ZINDEX + count,
            icon: clusterIcon(clustered),
            label: { text: String(count), color: '#0d1216', fontSize: '15px', fontWeight: '700' },
          }),
      },
    });
  } else {
    clusterer.clearMarkers();
    clusterer.addMarkers(list);
  }
}

/** Dim/undim the charger + cluster layer (used while a route is displayed). */
export function setMarkersDimmed(dim) {
  const op = dim ? 0.35 : 1;
  for (const m of markers.values()) m.setOpacity(op);
}

/** Step the zoom by ±1 (our own zoom buttons). Clamped by the API itself. */
export function zoomBy(delta) {
  if (!map) return;
  map.setZoom((map.getZoom() ?? MAP_ZOOM) + delta);
}

/**
 * Put the camera somewhere on purpose: a search result, a station, a country
 * the driver just switched on.
 *
 * The event is what tells follow.js to stop pulling the map back to the car —
 * without it, opening a charger while driving would show it for one second
 * before the next GPS fix dragged the map away. Drive mode and follow mode move
 * the camera through the map object directly, so neither raises it.
 */
export function panTo(pos, zoom) {
  map.panTo(pos);
  if (zoom != null) map.setZoom(zoom);
  document.dispatchEvent(new CustomEvent('gc:camera-moved'));
}

// ── Where the driver is ──────────────────────────────────────────────────────
// A blue dot while browsing the map, the car silhouette while navigating —
// pointing wherever the car is pointing (see js/car.js).
let userStyle = 'dot'; // 'dot' | 'car'
let userHeading = 0;
// The last position anyone has seen, and when. follow.js and drive.js both feed
// this without knowing they do, which is what lets "my location" answer
// instantly instead of asking a car's GPS to find itself all over again.
let lastFix = null;
let lastFixAt = 0;

const DOT_ICON = () => ({
  path: google.maps.SymbolPath.CIRCLE,
  scale: 8,
  fillColor: '#2196F3',
  fillOpacity: 1,
  strokeColor: '#ffffff',
  strokeWeight: 3,
});

// Marker icons are drawn on the screen, not on the ground: rotate the map and
// they stay upright. So the car is drawn at its heading MINUS the map's, which
// on a heading-up map is zero — the car points up the screen, as it should, and
// the world turns underneath it.
let drawnCarBucket = null;

function applyUserIcon() {
  if (!userMarker) return;
  if (userStyle === 'none') {
    userMarker.setMap(null);
    return;
  }
  if (userStyle !== 'car') {
    drawnCarBucket = null;
    userMarker.setIcon(DOT_ICON());
    return;
  }
  const rel = ((userHeading - getMapHeading()) % 360 + 360) % 360;
  const bucket = Math.round(rel / 3);
  if (bucket === drawnCarBucket) return; // nothing visible would change
  drawnCarBucket = bucket;
  userMarker.setIcon(carIcon(rel));
}

// Changing car in the topbar has to show on a marker that is already drawn.
onCarChange(applyUserIcon);

/** Switch the marker between the browsing dot and the driving car. */
export function setUserStyle(style) {
  if (style === userStyle) return;
  userStyle = style;
  drawnCarBucket = null;
  if (style !== 'none' && userMarker && !userMarker.getMap()) userMarker.setMap(map);
  applyUserIcon();
}

/**
 * Move the driver's marker. `heading` (degrees clockwise from north) only
 * matters for the car silhouette; passing nothing keeps the last one, so a
 * stationary fix does not spin the car back to north.
 */
export function setUserLocation(pos, heading) {
  // Drive mode moves the marker through the nav camera above, on its own
  // schedule; a second writer here would fight it once a second.
  if (navTarget) {
    lastFix = pos;
    lastFixAt = Date.now();
    return;
  }
  if (!userMarker) {
    userMarker = new google.maps.Marker({ map, zIndex: 3000 });
    applyUserIcon();
  }
  if (heading != null && Number.isFinite(heading)) {
    userHeading = heading;
    if (userStyle === 'car') applyUserIcon();
  }
  if (!userMarker.getMap()) userMarker.setMap(map);
  userMarker.setPosition(pos);
  lastFix = pos;
  lastFixAt = Date.now();
}

/** The most recent fix, if it is still worth trusting. */
export function lastKnownPosition(maxAgeMs = 120000) {
  if (!lastFix || Date.now() - lastFixAt > maxAgeMs) return null;
  return lastFix;
}

/**
 * One position, by whichever route answers first.
 *
 * getCurrentPosition alone is what the trip planner used to call, and on a real
 * Tesla it returned nothing: the car's browser can take far longer than ten
 * seconds to produce a FRESH high-accuracy fix, and `maximumAge: 0` refused
 * every fix it already had. So both doors are opened at once — the one-shot
 * call and a watch — and the first fix through either wins. Embedded browsers
 * that answer a watch but not a one-shot are common enough to be worth the
 * eight extra lines.
 */
function firstFix({ timeout = 25000, maximumAge = 30000 } = {}) {
  return new Promise((resolve, reject) => {
    if (!navigator.geolocation) return reject(new Error('no geolocation'));
    let done = false;
    let watchId = null;
    let timer = 0;

    const finish = (pos, err) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      if (watchId != null) {
        try { navigator.geolocation.clearWatch(watchId); } catch (_) {/* gone already */}
      }
      if (pos) resolve(pos);
      else reject(err || new Error('no fix'));
    };
    const ok = (p) => finish({ lat: p.coords.latitude, lng: p.coords.longitude });
    // A denied permission is the one error worth reporting straight away;
    // everything else just means "not yet", and the other door may still open.
    const bad = (e) => { if (e && e.code === 1) finish(null, e); };

    timer = setTimeout(() => finish(null, new Error('timeout')), timeout);
    const opts = { enableHighAccuracy: true, timeout, maximumAge };
    try { navigator.geolocation.getCurrentPosition(ok, bad, opts); } catch (_) {/* ignore */}
    try { watchId = navigator.geolocation.watchPosition(ok, bad, opts); } catch (_) {/* ignore */}
  });
}

/**
 * Locate the user, centre on them, and keep the dot updated. Resolves with the
 * position, or rejects (denied/unavailable/timeout) so the caller can warn.
 *
 * Keeping the dot fresh afterwards is follow.js's job — it holds the one live
 * watch this app has (outside drive mode), so granting the permission here is
 * also what lets the camera start following the car by itself.
 */
export function locateMe({ center = true, maxAgeMs = 120000 } = {}) {
  const settle = (pos) => {
    setUserLocation(pos);
    if (center) panTo(pos, LOCATE_ZOOM);
    return pos;
  };
  // If the app has been shown where the car is in the last couple of minutes,
  // that IS the answer. The car has not moved far, and asking again is how a
  // button ends up doing nothing for twenty seconds.
  const cached = lastKnownPosition(maxAgeMs);
  if (cached) return Promise.resolve(settle(cached));
  return firstFix().then(settle);
}

// ── Search destination pin (red) ─────────────────────────────────────────────
export function setSearchPin(pos) {
  if (!searchMarker) {
    searchMarker = new google.maps.Marker({
      map,
      zIndex: 2500,
      icon: {
        path: 'M12 0C7 0 3 4 3 9c0 6 9 15 9 15s9-9 9-15c0-5-4-9-9-9z',
        fillColor: '#E53935',
        fillOpacity: 1,
        strokeColor: '#ffffff',
        strokeWeight: 1.5,
        scale: 1.6,
        anchor: new google.maps.Point(12, 24),
      },
    });
  }
  searchMarker.setPosition(pos);
  searchMarker.setMap(map);
}

export function clearSearchPin() {
  searchMarker?.setMap(null);
}

// ── Traffic layer ────────────────────────────────────────────────────────────
export function setTraffic(on) {
  if (on && !trafficLayer) trafficLayer = new google.maps.TrafficLayer();
  trafficLayer?.setMap(on ? map : null);
}
