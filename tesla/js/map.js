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
  clearInterval(headingTimer);
  headingTimer = 0;
  headingNow = headingTarget = 0;

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

// ── Rotation ─────────────────────────────────────────────────────────────────
// Heading is eased rather than snapped: a GPS fix a second, dropped straight
// onto the camera, makes the whole world jerk at every bend.
//
// The easing runs on a timer, not requestAnimationFrame. rAF is the obvious
// tool and the wrong one here: it is tied to the browser actually painting, and
// a browser that reports itself visible while painting nothing (the in-app
// preview does exactly this, and an in-car browser may too) would then never
// turn the map at all. A timer is always delivered, and 20 steps a second is
// smooth enough for a map — and cheaper on a car's GPU than 60.
const HEADING_STEP_MS = 50;
const HEADING_EASE = 0.25;   // fraction of what is left, per step
let headingNow = 0;
let headingTarget = 0;
let headingTimer = 0;

const shortWay = (from, to) => ((((to - from) % 360) + 540) % 360) - 180;

function stepHeading() {
  if (!map || !vector) {
    clearInterval(headingTimer);
    headingTimer = 0;
    return;
  }
  const delta = shortWay(headingNow, headingTarget);
  if (Math.abs(delta) < 0.4) {
    headingNow = headingTarget;
    clearInterval(headingTimer);
    headingTimer = 0;
  } else {
    headingNow = (headingNow + delta * HEADING_EASE + 360) % 360;
  }
  map.setHeading(headingNow);
  applyUserIcon();
}

/**
 * Point the map so `deg` (a compass bearing) is up the screen. 0 is north-up,
 * which is also all a raster map can do — there the call does nothing.
 */
export function setMapHeading(deg) {
  if (!map || !vector) return;
  headingTarget = ((deg % 360) + 360) % 360;
  if (Math.abs(shortWay(headingNow, headingTarget)) < 0.4) return;
  // One step immediately, so the map turns even if timers are being throttled.
  stepHeading();
  if (!headingTimer) headingTimer = setInterval(stepHeading, HEADING_STEP_MS);
}

/**
 * Where the top of the screen currently points RIGHT NOW — read back from the
 * map rather than from our own target, because the two differ while a turn is
 * still easing, and the car has to be drawn against what is actually on screen.
 */
export function getMapHeading() {
  if (!vector || !map) return 0;
  const h = map.getHeading();
  return Number.isFinite(h) ? h : headingNow;
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
  applyUserIcon();
}

/**
 * Move the driver's marker. `heading` (degrees clockwise from north) only
 * matters for the car silhouette; passing nothing keeps the last one, so a
 * stationary fix does not spin the car back to north.
 */
export function setUserLocation(pos, heading) {
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
}

/**
 * Locate the user, centre on them, and keep the dot updated. Resolves with the
 * position, or rejects (denied/unavailable/timeout) so the caller can warn.
 *
 * Keeping the dot fresh afterwards is follow.js's job — it holds the one live
 * watch this app has (outside drive mode), so granting the permission here is
 * also what lets the camera start following the car by itself.
 */
export function locateMe({ center = true } = {}) {
  return new Promise((resolve, reject) => {
    if (!navigator.geolocation) return reject(new Error('no geolocation'));
    navigator.geolocation.getCurrentPosition(
      (p) => {
        const pos = { lat: p.coords.latitude, lng: p.coords.longitude };
        setUserLocation(pos);
        if (center) panTo(pos, LOCATE_ZOOM);
        resolve(pos);
      },
      (err) => reject(err),
      { enableHighAccuracy: true, timeout: 10000, maximumAge: 0 },
    );
  });
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
