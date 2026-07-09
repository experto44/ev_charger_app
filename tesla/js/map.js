// Google Map wrapper: dark style, status-coloured markers, clustering.

import { MAPS_API_KEY, MAP_CENTER, MAP_ZOOM } from './config.js';

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

const STATUS_COLORS = { free: '#2bd594', busy: '#f5a623', out: '#6b7a85' };

// Marker pie colours — match the app's _AvailabilityPainter exactly.
const PIN_FREE = '#00C896'; // emerald  (available portion)
const PIN_BUSY = '#FFAB40'; // orangeAccent (busy/out portion)

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
    styles: NIGHT_STYLE,
    disableDefaultUI: true,
    zoomControl: true,
    gestureHandling: 'greedy', // one-finger everything — it's a car screen
    clickableIcons: false,
  });
  return map;
}

export function getMap() {
  return map;
}

/** Station-level colour: any free port → free; else any busy → busy; else out. */
export function stationStatus(s) {
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
  if (f >= 1) {
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
        render: ({ count, position }) =>
          new google.maps.Marker({
            position,
            zIndex: google.maps.Marker.MAX_ZINDEX + count,
            icon: {
              url:
                'data:image/svg+xml;charset=UTF-8,' +
                encodeURIComponent(
                  `<svg xmlns="http://www.w3.org/2000/svg" width="52" height="52" viewBox="0 0 52 52">` +
                    `<circle cx="26" cy="26" r="20" fill="#1c252d" stroke="#2bd594" stroke-width="2.5"/>` +
                    `</svg>`,
                ),
              scaledSize: new google.maps.Size(52, 52),
            },
            label: { text: String(count), color: '#eef3f6', fontSize: '15px', fontWeight: '600' },
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

export function panTo(pos, zoom) {
  map.panTo(pos);
  if (zoom != null) map.setZoom(zoom);
}

// ── My-location blue dot ─────────────────────────────────────────────────────
export function setUserLocation(pos) {
  if (!userMarker) {
    userMarker = new google.maps.Marker({
      map,
      zIndex: 3000,
      icon: {
        path: google.maps.SymbolPath.CIRCLE,
        scale: 8,
        fillColor: '#2196F3',
        fillOpacity: 1,
        strokeColor: '#ffffff',
        strokeWeight: 3,
      },
    });
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
