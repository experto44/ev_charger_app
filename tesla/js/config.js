// GeoCharge for Tesla — configuration.

// Browser key, referrer-restricted to tesla.geocharge.ge / geocharge-tesla.web.app
// (Maps JavaScript API + Places + Directions). Note: local dev on localhost only
// works if a localhost referrer is added to this key in the Google Cloud console.
export const MAPS_API_KEY = 'AIzaSyDYHSs4P--TUa-VVlS5DReotBtbjZK58No';

// Same live feed the mobile app uses (catalog + live status in one JSON), and
// the config file next to it that can switch off the direct-to-operator reads
// without a redeploy (see js/live.js).
export const CHARGERS_BASE =
  'https://gist.githubusercontent.com/experto44/36f39392ce7a4abe14ab065aa8e846bd/raw';
export const CHARGERS_URL = `${CHARGERS_BASE}/chargers.json`;

// Turkish chargers (EPDK registry), in their own gist and their own file: it is
// ~5 MB and ~13k stations, so it is fetched ONLY when the driver actually looks
// at Turkey or plans a route through it. No live status in it, so unlike the
// Georgian feed it is fetched once per session and never polled.
// Mirrors _url in lib/turkey_service.dart.
export const CHARGERS_TR_URL =
  'https://gist.githubusercontent.com/experto44/8cb62fc7ad6d86e3172eec6aedd4dba6/raw/chargers_tr.json';

// Bounding box used to decide when Turkey is worth loading (matches the
// CountryDef box in lib/app_constants.dart).
export const TURKEY_BOUNDS = { south: 35.8, north: 42.1, west: 26.0, east: 44.8 };

// Mobile app refreshes every 2 minutes (_kRefreshInterval) — keep in sync. The
// updater's own cycle is ~2.5 min, so polling faster than this only re-asks for
// data that cannot have changed yet.
export const REFRESH_MS = 2 * 60 * 1000;

// The feed is a ~MB JSON; allow a slow first download. Refreshes revalidate
// via ETag (cache: 'no-cache') so they are much cheaper than the first load.
export const FETCH_TIMEOUT_MS = 25000;

// Georgia map bounds / initial view.
export const MAP_CENTER = { lat: 42.0, lng: 43.5 };
export const MAP_ZOOM = 8;

// Web app config from lib/firebase_options.dart (web platform).
export const FIREBASE_CONFIG = {
  apiKey: 'AIzaSyC3gB4qBlgYW7_nLd8JZijyha0xXekGuaE',
  authDomain: 'geocharge-f6714.firebaseapp.com',
  projectId: 'geocharge-f6714',
  storageBucket: 'geocharge-f6714.firebasestorage.app',
  messagingSenderId: '518875377655',
  appId: '1:518875377655:web:460e04cac1603f2545c8f2',
  measurementId: 'G-3DK8B61WL8',
};
