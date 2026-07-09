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

let map = null;
let markers = new Map(); // station.id -> google.maps.Marker
let clusterer = null;

/** Load the Maps JS API once; resolves when `google.maps` is usable. */
export function loadMapsApi() {
  if (window.google?.maps) return Promise.resolve();
  return new Promise((resolve, reject) => {
    const cb = '__gcMapsReady';
    window[cb] = () => resolve();
    const s = document.createElement('script');
    s.src =
      `https://maps.googleapis.com/maps/api/js?key=${MAPS_API_KEY}` +
      `&callback=${cb}&language=ka&region=GE&loading=async&libraries=places`;
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

function markerIcon(s) {
  const color = STATUS_COLORS[stationStatus(s)];
  const ring = s.isDC ? '#eef3f6' : 'transparent'; // DC chargers get a white ring
  const svg =
    `<svg xmlns="http://www.w3.org/2000/svg" width="44" height="44" viewBox="0 0 44 44">` +
    `<circle cx="22" cy="22" r="15" fill="${color}" stroke="${ring}" stroke-width="2.5"/>` +
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
