// App bootstrap: gate (login → trial/premium) → map + live feed + UI.

import { applyStaticStrings, setLang, t } from './i18n.js';
import { initAnalytics } from './analytics.js';
import { loginEmail, loginGoogle, logout } from './auth.js';
import { startGate } from './gate.js';
import { getTurkeyStations, loadTurkey, startFeed } from './data.js';
import {
  COUNTRIES,
  boundsVisible,
  countryCentre,
  isSelected,
  selectedCountries,
  stationCountry,
  toggleCountry,
} from './countries.js';
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
  setStationRefreshedHandler,
  showStation,
  showToast,
  toggleFilterDrawer,
} from './ui.js';
import { initTrip, isTripOpen, relabelTrip, setTripDestination, setTripPoints, toggleTripDrawer } from './trip.js';

let allStations = [];
let drawerBuilt = false;

// ── Turkish chargers on the map ──────────────────────────────────────────────
// The Turkish registry is ~13k stations. A Tesla's browser will not carry that
// many map markers, so the set is capped. Over the cap we keep fast DC first
// and then thin the rest out evenly, which matters at country zoom: picking the
// ones nearest the screen centre would bunch every pin in the middle and leave
// the edges looking empty. The trip planner is unaffected — it searches the
// whole list in memory, where only MARKERS are expensive.
const TR_MAX_PINS = 900;
let turkeyRequested = false;

function capForDisplay(list) {
  if (list.length <= TR_MAX_PINS) return list;
  const dc = list.filter((s) => s.isDC);
  const pool = dc.length >= TR_MAX_PINS ? dc : [...dc, ...list.filter((s) => !s.isDC)];
  if (pool.length <= TR_MAX_PINS) return pool;
  const stride = pool.length / TR_MAX_PINS;
  const out = [];
  for (let i = 0; out.length < TR_MAX_PINS && Math.floor(i) < pool.length; i += stride) {
    out.push(pool[Math.floor(i)]);
  }
  return out;
}

function turkeyPinsForViewport() {
  if (!isSelected('TR')) return [];
  const map = getMap();
  const b = map?.getBounds();
  if (!b) return [];
  return capForDisplay(
    getTurkeyStations().filter((s) => b.contains({ lat: s.lat, lng: s.lng })),
  );
}

// A refresh in the station panel patches the station in place; repainting is
// what turns that into a marker in the new colour.
setStationRefreshedHandler(() => repaint());

function repaint() {
  // The picker is live before the Maps API finishes loading, so a country can
  // be toggled while there is still nothing to draw on.
  if (!getMap()) return;
  // Georgia and Armenia share the Georgian feed and are told apart by
  // coordinates; Turkey identifies itself.
  const local = allStations.filter((s) => isSelected(stationCountry(s)));
  const visible = applyFilters([...local, ...turkeyPinsForViewport()]);
  renderMarkers(visible, showStation);
  setCount(visible.length);
}

// Pull the Turkish file in the first time it is needed, then repaint so its
// pins appear. Failure is silent: the rest of the map keeps working.
function maybeLoadTurkey() {
  if (turkeyRequested || !isSelected('TR')) return;
  turkeyRequested = true;
  loadTurkey()
    .then(repaint)
    .catch(() => {
      turkeyRequested = false;
    });
}

// ── Country picker ───────────────────────────────────────────────────────────
function renderCountryMenu() {
  const menu = document.getElementById('country-menu');
  const counts = new Map();
  for (const s of allStations) {
    const c = stationCountry(s);
    if (c) counts.set(c, (counts.get(c) ?? 0) + 1);
  }
  counts.set('TR', getTurkeyStations().length);

  menu.innerHTML = '';
  for (const c of COUNTRIES) {
    const on = isSelected(c.code);
    const btn = document.createElement('button');
    btn.className = `country-item${on ? ' is-on' : ''}`;
    btn.type = 'button';
    btn.innerHTML =
      `<span class="country-item__box">${on ? '☑' : '☐'}</span>` +
      `<span class="country-item__flag">${c.flag}</span>` +
      `<span class="country-item__name">${t(c.key)}</span>` +
      `<span class="country-item__count">${counts.get(c.code) || ''}</span>`;
    btn.addEventListener('click', () => selectCountry(c.code));
    menu.appendChild(btn);
  }

  document.getElementById('country-label').textContent =
    `${COUNTRIES.filter((c) => isSelected(c.code)).map((c) => c.flag).join(' ')} ${t('countries')}`;
}

// Built and wired before anything else in bootApp. It used to be created
// inside the feed's onData and wired inside wireMapControls, which meant the
// button sat blank and inert until the first gist response arrived — and stayed
// that way for the whole session if the feed or the Maps API failed.
export function initCountryPicker() {
  const btn = document.getElementById('btn-countries');
  const menu = document.getElementById('country-menu');
  if (!btn || !menu) return;

  renderCountryMenu();

  btn.addEventListener('click', (e) => {
    e.stopPropagation();
    const hidden = menu.classList.toggle('is-hidden');
    btn.setAttribute('aria-expanded', String(!hidden));
  });
  // Clicks inside the menu must not reach the document handler that closes it.
  menu.addEventListener('click', (e) => e.stopPropagation());
  document.addEventListener('click', () => {
    menu.classList.add('is-hidden');
    btn.setAttribute('aria-expanded', 'false');
  });
}

function selectCountry(code) {
  if (!toggleCountry(code)) return; // last country can't be switched off
  renderCountryMenu();
  if (isSelected(code)) {
    maybeLoadTurkey();
    // Switching a country on while looking somewhere else would appear to do
    // nothing, so move the map there — once there is a map to move.
    const map = getMap();
    if (map && !boundsVisible(code, map.getBounds())) {
      const c = countryCentre(code);
      if (c) panTo(c, 7);
    }
  }
  repaint();
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
  // Turkish pins are viewport-scoped, so they are re-evaluated whenever the map
  // settles. `idle` fires once after a pan/zoom finishes, not per frame.
  getMap().addListener('idle', () => {
    if (isSelected('TR') && getTurkeyStations().length) repaint();
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
  // First, and outside the try: the picker must work even if the map or the
  // feed does not.
  initCountryPicker();

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
        // The picker shows a per-country station count, so it is rebuilt with
        // every feed refresh.
        renderCountryMenu();
        repaint();
      },
      onError: () => showToast(t('fetchError')),
    });
  } catch (e) {
    showToast(t('fetchError'), 60000);
  }

  // A driver who left Turkey switched on last session gets it back without
  // having to touch the picker again.
  maybeLoadTurkey();

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
  // The logo doubles as "start over": reload, which also drops the map back to
  // MAP_CENTER / MAP_ZOOM. Cache-busted so a driver who taps it after an update
  // is guaranteed the new build rather than whatever the car cached.
  document.getElementById('btn-home')?.addEventListener('click', () => {
    location.replace(location.pathname);
  });

  for (const btn of document.querySelectorAll('[data-lang-btn]')) {
    btn.addEventListener('click', () => {
      setLang(btn.dataset.langBtn);
      if (drawerBuilt) buildFilterDrawer(allStations, repaint); // re-label chips
      renderCountryMenu(); // country names + the button label are translated too
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
