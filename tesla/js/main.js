// App bootstrap: gate (login → trial/premium) → map + live feed + UI.

import { applyStaticStrings, setLang, t } from './i18n.js';
import { initAnalytics } from './analytics.js';
import { loginEmail, loginGoogle, logout } from './auth.js';
import { startGate } from './gate.js';
import { startFeed } from './data.js';
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

function repaint() {
  const visible = applyFilters(allStations);
  renderMarkers(visible, showStation);
  setCount(visible.length);
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
