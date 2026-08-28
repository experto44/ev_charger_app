// Where the driver has been, and one tap to go again.
//
// Everything that becomes a real trip lands here by itself: a drive started
// from anywhere (a favourite, a search result, the planner, a saved route), a
// route sent from the phone, a route saved in the planner. Nothing has to be
// filed by hand, which is the whole point — the trip you want again is usually
// the one you did not think to save.
//
// It records from DOM events only, so it can be the module that depends on the
// others rather than one more thing they all have to know about.
//
// Two lists, on purpose. Saved routes are few, named and permanent; this is
// twenty rows that fall off the end. A row can be promoted into the other list
// with the star.

import { saveTeslaDoc, watchAuth, watchTeslaDoc } from './auth.js';
import { startDrive } from './drive.js';
import { getLang, t } from './i18n.js';
import { addSavedRoute } from './routes.js';
import { showToast } from './ui.js';
import { track } from './analytics.js';

const MAX_HISTORY = 20;

const state = {
  uid: null,
  items: [],
  stopDoc: null,
};

const $ = (id) => document.getElementById(id);
const cacheKey = (uid) => `gc_history_${uid}`;

const isPoint = (p) => p && Number.isFinite(p.lat) && Number.isFinite(p.lng);
const point = (p) => ({ lat: Number(p.lat), lng: Number(p.lng) });

function newId() {
  return (crypto.randomUUID?.() ?? String(Math.random()).slice(2) + Date.now()).replace(/-/g, '');
}

/**
 * What makes two trips "the same" for the purpose of not listing them twice.
 * Coordinates are rounded to about ten metres: the same destination picked
 * twice from search comes back with identical numbers, but a favourite and a
 * search result for the same place can differ in the last decimal.
 */
function tripKey(destination, waypoints) {
  const r = (p) => `${p.lat.toFixed(4)},${p.lng.toFixed(4)}`;
  return [r(destination), ...(waypoints ?? []).map(r)].join('|');
}

// ── Storage ──────────────────────────────────────────────────────────────────
function clean(list) {
  return (Array.isArray(list) ? list : [])
    .filter((h) => h && isPoint(h.destination))
    .slice(0, MAX_HISTORY)
    .map((h) => ({
      id: String(h.id || newId()),
      name: String(h.name ?? '').slice(0, 40),
      destination: point(h.destination),
      waypoints: (Array.isArray(h.waypoints) ? h.waypoints : []).filter(isPoint).map(point),
      source: String(h.source ?? 'drive'),
      at: Number(h.at) || Date.now(),
    }));
}

function readCache(uid) {
  try {
    return clean(JSON.parse(localStorage.getItem(cacheKey(uid))));
  } catch {
    return [];
  }
}

function writeCache(uid, items) {
  try {
    localStorage.setItem(cacheKey(uid), JSON.stringify(items));
  } catch {/* private mode / quota — Firestore holds the real copy */}
}

/** Fire and forget: a lost history write costs one row, never a trip. */
function persist(items) {
  state.items = items;
  renderList();
  if (!state.uid) return;
  writeCache(state.uid, items);
  saveTeslaDoc(state.uid, 'history', { items, updatedAt: Date.now() }).catch(() => {});
}

// ── Recording ────────────────────────────────────────────────────────────────
/**
 * File a trip. Repeating one moves it back to the top rather than adding a
 * second row — driving home every day would otherwise be the entire history.
 *
 * @param {{destination:{lat,lng}, waypoints?:{lat,lng}[], name?:string,
 *          source?:string}} trip
 */
function record(trip) {
  if (!state.uid || !isPoint(trip.destination)) return;

  const destination = point(trip.destination);
  const waypoints = (trip.waypoints ?? []).filter(isPoint).map(point);
  const key = tripKey(destination, waypoints);
  const existing = state.items.find(
    (h) => tripKey(h.destination, h.waypoints) === key,
  );

  const entry = {
    id: existing?.id ?? newId(),
    // Keep the better name. A trip first seen as coordinates and driven again
    // from a named favourite should end up reading as the favourite.
    name: (trip.name || existing?.name || '').trim().slice(0, 40),
    destination,
    waypoints,
    source: trip.source ?? existing?.source ?? 'drive',
    at: Date.now(),
  };

  persist([entry, ...state.items.filter((h) => h.id !== entry.id)].slice(0, MAX_HISTORY));
}

// ── Rendering ────────────────────────────────────────────────────────────────
// Month names by hand rather than through toLocaleDateString: the car's browser
// is Chromium on Linux and its ICU data cannot be relied on to carry Georgian,
// and a month rendered as "Aug" inside a Georgian line reads as a bug.
const MONTHS_KA = ['იან', 'თებ', 'მარ', 'აპრ', 'მაი', 'ივნ', 'ივლ', 'აგვ', 'სექ', 'ოქტ', 'ნოე', 'დეკ'];
const MONTHS_EN = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/** "28 აგვ, 14:32". The year appears only when it is not this one. */
function whenLabel(ms) {
  const d = new Date(ms);
  const months = getLang() === 'ka' ? MONTHS_KA : MONTHS_EN;
  const year = d.getFullYear() !== new Date().getFullYear() ? ` ${d.getFullYear()}` : '';
  const time = `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`;
  return `${d.getDate()} ${months[d.getMonth()]}${year}, ${time}`;
}

function stopsLabel(n) {
  if (!n) return t('routeNoStops');
  if (getLang() !== 'ka' && n === 1) return `1 ${t('routeStop')}`;
  return `${n} ${t('routeStops')}`;
}

function renderList() {
  const list = $('history-list');
  if (!list) return;
  list.innerHTML = '';

  if (!state.items.length) {
    const p = document.createElement('p');
    p.className = 'fav-menu__empty';
    p.textContent = t(state.uid ? 'histEmpty' : 'favSignedOut');
    list.appendChild(p);
    return;
  }

  for (const h of state.items) {
    const row = document.createElement('div');
    row.className = 'fav-item hist-item';

    const go = document.createElement('button');
    go.className = 'fav-item__go';
    go.type = 'button';
    go.innerHTML =
      '<span class="fav-item__ico">🕘</span>' +
      '<span class="fav-item__txt"><span class="fav-item__name"></span>' +
      '<span class="fav-item__sub"></span></span>';
    go.querySelector('.fav-item__name').textContent =
      h.name || `${h.destination.lat.toFixed(3)}, ${h.destination.lng.toFixed(3)}`;
    go.querySelector('.fav-item__sub').textContent = stopsLabel(h.waypoints.length);
    go.addEventListener('click', () => {
      close();
      track('history_start', { source: h.source });
      startDrive({
        destination: h.destination,
        waypoints: h.waypoints,
        route: { id: null, name: h.name },
      });
    });

    const when = document.createElement('span');
    when.className = 'hist-item__when';
    when.textContent = whenLabel(h.at);

    // Promote into the named, permanent list.
    const star = document.createElement('button');
    star.className = 'fav-item__act';
    star.type = 'button';
    star.title = t('favSave');
    star.setAttribute('aria-label', t('favSave'));
    star.textContent = '☆';
    star.addEventListener('click', () => {
      close();
      addSavedRoute({ name: h.name, destination: h.destination, waypoints: h.waypoints });
    });

    row.append(go, when, star);
    list.appendChild(row);
  }
}

function open() {
  renderList();
  $('history-panel').classList.remove('is-hidden');
  track('history_open', {});
}

function close() {
  $('history-panel').classList.add('is-hidden');
}

// ── Public ───────────────────────────────────────────────────────────────────
/** Re-render after a language switch (the "3 days ago" line is translated). */
export function relabelHistory() {
  if (!$('history-panel').classList.contains('is-hidden')) renderList();
}

export function initHistory() {
  $('btn-history')?.addEventListener('click', open);
  $('history-close')?.addEventListener('click', close);
  // Tapping the backdrop closes it, like the other overlays.
  $('history-panel')?.addEventListener('click', (e) => {
    if (e.target === $('history-panel')) close();
  });

  // Every drive, whoever started it.
  document.addEventListener('gc:drive-start', (e) => {
    const d = e.detail;
    if (!d?.destination) return;
    record({
      destination: d.destination,
      waypoints: d.waypoints,
      name: d.route?.name,
      source: 'drive',
    });
  });

  // A route that exists but is not being driven yet: one sent from the phone,
  // or one saved in the planner. The driver asked for these to be filed the
  // moment they appear, whether or not the trip ever starts.
  document.addEventListener('gc:route-known', (e) => {
    const d = e.detail;
    if (!d?.destination) return;
    record({
      destination: d.destination,
      waypoints: d.waypoints,
      name: d.name,
      source: d.source ?? 'route',
    });
  });

  watchAuth((user) => {
    state.stopDoc?.();
    state.stopDoc = null;
    state.uid = user?.uid ?? null;

    if (!state.uid) {
      state.items = [];
      close();
      return;
    }
    state.items = readCache(state.uid);
    renderList();
    state.stopDoc = watchTeslaDoc(state.uid, 'history', (data) => {
      state.items = clean(data?.items);
      writeCache(state.uid, state.items);
      renderList();
    });
  });
}

/** Debug handle. */
export function historyState() {
  return state;
}
