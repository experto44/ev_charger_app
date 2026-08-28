// Google Map wrapper: day/night style, status-coloured markers, clustering.

import { MAPS_API_KEY, MAP_CENTER, MAP_ZOOM } from './config.js';
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
let markers = new Map(); // station.id -> google.maps.Marker
let clusterer = null;
let userMarker = null;   // blue "my location" dot
let searchMarker = null; // red destination pin
let watchId = null;
let trafficLayer = null;

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

export function initMap(container) {
  map = new google.maps.Map(container, {
    center: MAP_CENTER,
    zoom: MAP_ZOOM,
    // The theme is already on <html> before the first paint, so the map is born
    // in the right one instead of flashing dark and then repainting.
    styles: stylesFor(document.documentElement.dataset.theme),
    disableDefaultUI: true,
    // No Maps API zoom control: it drew itself in the bottom-right corner, under
    // our own buttons, and at a size you cannot hit in a moving car. The column
    // in index.html carries a full-size pair instead.
    zoomControl: false,
    gestureHandling: 'greedy', // one-finger everything — it's a car screen
    clickableIcons: false,
  });
  return map;
}

export function getMap() {
  return map;
}

/** Repaint the map for 'light' / 'dark'. Silent before the map exists. */
export function setMapTheme(theme) {
  map?.setOptions({ styles: stylesFor(theme) });
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

export function panTo(pos, zoom) {
  map.panTo(pos);
  if (zoom != null) map.setZoom(zoom);
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

function applyUserIcon() {
  if (!userMarker) return;
  userMarker.setIcon(userStyle === 'car' ? carIcon(userHeading) : DOT_ICON());
}

// Changing car in the topbar has to show on a marker that is already drawn.
onCarChange(applyUserIcon);

/** Switch the marker between the browsing dot and the driving car. */
export function setUserStyle(style) {
  if (style === userStyle) return;
  userStyle = style;
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
  userMarker.setPosition(pos);
}

/**
 * Locate the user, centre on them, and keep the dot updated. Resolves with the
 * position, or rejects (denied/unavailable/timeout) so the caller can warn.
 */
export function locateMe({ center = true } = {}) {
  return new Promise((resolve, reject) => {
    if (!navigator.geolocation) return reject(new Error('no geolocation'));
    navigator.geolocation.getCurrentPosition(
      (p) => {
        const pos = { lat: p.coords.latitude, lng: p.coords.longitude };
        setUserLocation(pos);
        if (center) panTo(pos, 13);
        // Keep the dot fresh without moving the camera.
        if (watchId == null) {
          watchId = navigator.geolocation.watchPosition(
            (q) => setUserLocation({ lat: q.coords.latitude, lng: q.coords.longitude }),
            () => {},
            { enableHighAccuracy: true, maximumAge: 15000 },
          );
        }
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
