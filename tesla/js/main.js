// App bootstrap: gate (login → trial/premium) → map + live feed + UI.

import { applyStaticStrings, setLang, t } from './i18n.js';
import { initAnalytics } from './analytics.js';
import { loginEmail, loginGoogle, logout } from './auth.js';
import { startGate } from './gate.js';
import { getTurkeyStations, loadTurkey, startFeed } from './data.js';
import { TURKEY_BOUNDS } from './config.js';
import {
  loadMapsApi,
  initMap,
  getMap,
  renderMarkers,
  locateMe,
  panTo,
  setSearchPin,
  clearSearchPin,
  setTraffic,
} from './map.js';
import { initSearch } from './search.js';
import { initDrive, startDrive } from './drive.js';
import {
  applyFilters,
  buildFilterDrawer,
  hideStation,
  setCount,
  showStation,
  showToast,
  toggleFilterDrawer,
} from './ui.js';
import { initTrip, isTripOpen, relabelTrip, setTripDestination, setTripPoints, toggleTripDrawer } from './trip.js';

let allStations = [];
let drawerBuilt = false;

// ── Turkish chargers on the map ──────────────────────────────────────────────
// The Turkish registry is ~13k stations. A Tesla's browser will not carry that
// many map markers, so Turkish pins are drawn only for the current viewport,
// only once zoomed in past the country-overview level, and capped. The trip
// planner is unaffected — it searches the whole list in memory, where the cost
// is nothing, because only MARKERS are expensive.
const TR_MIN_ZOOM = 9;
const TR_MAX_PINS = 900;
let turkeyRequested = false;

function viewportTouchesTurkey() {
  const b = getMap()?.getBounds();
  if (!b) return false;
  const sw = b.getSouthWest();
  const ne = b.getNorthEast();
  return (
    ne.lat() >= TURKEY_BOUNDS.south &&
    sw.lat() <= TURKEY_BOUNDS.north &&
    ne.lng() >= TURKEY_BOUNDS.west &&
    sw.lng() <= TURKEY_BOUNDS.east
  );
}

function turkeyPinsForViewport() {
  const map = getMap();
  if (!map || map.getZoom() < TR_MIN_ZOOM) return [];
  const b = map.getBounds();
  if (!b) return [];
  const inView = getTurkeyStations().filter((s) =>
    b.contains({ lat: s.lat, lng: s.lng }),
  );
  if (inView.length <= TR_MAX_PINS) return inView;

  // İstanbul alone holds ~3k stations in one screen. When the viewport has more
  // than the browser can carry, keep the ones a driver would actually pick —
  // fast DC first, then closest to the middle of the screen — instead of an
  // arbitrary slice of the array.
  const c = map.getCenter();
  const cLat = c.lat();
  const cLng = c.lng();
  const d2 = (s) => (s.lat - cLat) ** 2 + ((s.lng - cLng) * 0.75) ** 2;
  return inView
    .sort((a, z) => Number(z.isDC) - Number(a.isDC) || d2(a) - d2(z))
    .slice(0, TR_MAX_PINS);
}

function repaint() {
  const visible = applyFilters([...allStations, ...turkeyPinsForViewport()]);
  renderMarkers(visible, showStation);
  setCount(visible.length);
}

// Pull the Turkish file in the first time the driver looks at Turkey, then
// repaint so its pins appear. Failure is silent: the Georgian map keeps working.
function maybeLoadTurkey() {
  if (turkeyRequested || !viewportTouchesTurkey()) return;
  turkeyRequested = true;
  loadTurkey()
    .then(repaint)
    .catch(() => {
      turkeyRequested = false;
    });
}

// ── Search result handlers ───────────────────────────────────────────────────
let destPos = null;

function openStation(s) {
  panTo({ lat: s.lat, lng: s.lng }, 15);
  showStation(s);
}

function openDestination(pos, name) {
  destPos = pos;
  setSearchPin(pos);
  panTo(pos, 14);
  const card = document.getElementById('dest-card');
  card.querySelector('.dest-card__name').textContent = name;
  card.classList.remove('is-hidden');
}

function wireMapControls() {
  // Turkish pins are viewport-scoped, so they have to be re-evaluated whenever
  // the map settles. `idle` fires once after a pan/zoom finishes, not per frame.
  getMap().addListener('idle', () => {
    maybeLoadTurkey();
    if (getTurkeyStations().length) repaint();
  });

  document.getElementById('btn-locate').addEventListener('click', async () => {
    try {
      await locateMe();
    } catch (e) {
      showToast(t('locationError'));
    }
  });

  // Traffic layer toggle (persisted).
  const trafficBtn = document.getElementById('btn-traffic');
  let trafficOn = localStorage.getItem('gc_traffic') === '1';
  setTraffic(trafficOn);
  trafficBtn.classList.toggle('is-active', trafficOn);
  trafficBtn.addEventListener('click', () => {
    trafficOn = !trafficOn;
    setTraffic(trafficOn);
    trafficBtn.classList.toggle('is-active', trafficOn);
    localStorage.setItem('gc_traffic', trafficOn ? '1' : '0');
  });

  document.getElementById('dest-close').addEventListener('click', () => {
    document.getElementById('dest-card').classList.add('is-hidden');
    clearSearchPin();
  });
  document.getElementById('dest-nav').addEventListener('click', () => {
    if (!destPos) return;
    document.getElementById('dest-card').classList.add('is-hidden');
    clearSearchPin();
    startDrive({ destination: destPos });
  });
  document.getElementById('dest-route').addEventListener('click', () => {
    if (destPos) {
      setTripDestination(destPos);
      toggleFilterDrawer(false);
      toggleTripDrawer(true);
    }
    document.getElementById('dest-card').classList.add('is-hidden');
    clearSearchPin();
  });
}

/** Boots the map + live feed. Runs once, the first time access is granted. */
async function bootApp() {
  try {
    await loadMapsApi();
    initMap(document.getElementById('map'));
    initTrip();
    initDrive();
    initSearch({ getStations: () => allStations, onStation: openStation, onPlace: openDestination });
    wireMapControls();
  } catch (e) {
    document.getElementById('map').innerHTML =
      `<div class="map-error">${t('mapError')}</div>`;
    return;
  }

  try {
    await startFeed({
      onData: (stations) => {
        allStations = stations;
        if (!drawerBuilt) {
          buildFilterDrawer(stations, repaint);
          drawerBuilt = true;
        }
        repaint();
      },
      onError: () => showToast(t('fetchError')),
    });
  } catch (e) {
    showToast(t('fetchError'), 60000);
  }

  document.getElementById('loading').classList.add('is-hidden');
  document.getElementById('btn-logout').classList.remove('is-hidden');

  // One-time Tesla tips (fullscreen + bookmark).
  if (!localStorage.getItem('gc_onboarded')) {
    document.getElementById('onboard').classList.remove('is-hidden');
    document.getElementById('onboard-ok').addEventListener('click', () => {
      localStorage.setItem('gc_onboarded', '1');
      document.getElementById('onboard').classList.add('is-hidden');
    });
  }
}

function wireChrome() {
  for (const btn of document.querySelectorAll('[data-lang-btn]')) {
    btn.addEventListener('click', () => {
      setLang(btn.dataset.langBtn);
      if (drawerBuilt) buildFilterDrawer(allStations, repaint); // re-label chips
      relabelTrip();
      repaint();
    });
  }
  // The two left-side drawers are mutually exclusive.
  document.getElementById('btn-filters').addEventListener('click', () => {
    toggleTripDrawer(false);
    toggleFilterDrawer(!document.getElementById('filter-drawer').classList.contains('is-open'));
  });
  document.getElementById('btn-trip').addEventListener('click', () => {
    toggleFilterDrawer(false);
    toggleTripDrawer(!isTripOpen());
  });
  document.getElementById('filter-close').addEventListener('click', () => toggleFilterDrawer(false));
  document.getElementById('trip-close').addEventListener('click', () => toggleTripDrawer(false));
  document.getElementById('panel-close').addEventListener('click', hideStation);
}

function wireGateUi() {
  const errEl = document.getElementById('login-error');
  const showErr = (key) => {
    errEl.textContent = t(key);
    errEl.classList.remove('is-hidden');
  };

  document.getElementById('login-form').addEventListener('submit', async (e) => {
    e.preventDefault();
    errEl.classList.add('is-hidden');
    try {
      await loginEmail(
        document.getElementById('login-email').value.trim(),
        document.getElementById('login-password').value,
      );
    } catch (ex) {
      showErr(ex.code === 'auth/network-request-failed' ? 'loginNetwork' : 'loginFailed');
    }
  });

  document.getElementById('btn-google').addEventListener('click', async () => {
    errEl.classList.add('is-hidden');
    try {
      await loginGoogle();
    } catch (ex) {
      showErr(ex.code === 'auth/network-request-failed' ? 'loginNetwork' : 'loginFailed');
    }
  });

  const doLogout = () => logout();
  document.getElementById('btn-logout').addEventListener('click', doLogout);
  document.getElementById('btn-logout-paywall').addEventListener('click', doLogout);

  // QR on the paywall → app download page.
  new QRCode(document.getElementById('qr'), {
    text: 'https://geocharge.ge',
    width: 132,
    height: 132,
  });
}

applyStaticStrings();
initAnalytics();
wireChrome();
wireGateUi();
startGate(bootApp);

// Debug handle for driving the UI from the console / automated tests.
window.__gc = {
  showStation,
  stations: () => allStations,
  setTripPoints,
  map: getMap,
  openTrip: () => { toggleFilterDrawer(false); toggleTripDrawer(true); },
};
