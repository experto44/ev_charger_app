// GeoCharge for Tesla — configuration.

// Browser key, referrer-restricted to tesla.geocharge.ge / geocharge-tesla.web.app
// (Maps JavaScript API + Places + Directions). Note: local dev on localhost only
// works if a localhost referrer is added to this key in the Google Cloud console.
export const MAPS_API_KEY = 'AIzaSyDYHSs4P--TUa-VVlS5DReotBtbjZK58No';

// Same live feed the mobile app uses (catalog + live status in one JSON).
export const CHARGERS_URL =
  'https://gist.githubusercontent.com/experto44/36f39392ce7a4abe14ab065aa8e846bd/raw/chargers.json';

// Mobile app refreshes every 3 minutes (_kRefreshInterval) — keep in sync.
export const REFRESH_MS = 3 * 60 * 1000;

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
};
