// Saved routes, and picking an interrupted one back up.
//
// A route here is a list of coordinates, never a drawn line: destination plus
// the stops in between. The road between them is worked out fresh by drive.js
// every time, from wherever the car actually is — which is what makes "carry on
// from Gori" possible at all. Storing Google's polyline would also be storing
// Directions results, which their terms do not allow beyond caching.
//
// Two documents on the account:
//   users/{uid}/tesla/routes   the saved list
//   users/{uid}/tesla/active   the trip in progress, rewritten as the car moves
//
// drive.js publishes progress as DOM events and knows nothing about any of
// this, so navigation keeps working for a driver who is signed out.

import { saveTeslaDoc, watchAuth, watchTeslaDoc } from './auth.js';
import { isDriving, startDrive } from './drive.js';
import { getLang, t } from './i18n.js';
import { emptyNote, heading } from './menus.js';
import { askName, MAX_NAME } from './name-dialog.js';
import { hideMapCard, showMapCard, showToast } from './ui.js';
import { track } from './analytics.js';

const MAX_ROUTES = 10;

// How long an unfinished trip stays on offer. Longer than a weekend away,
// short enough that a route from last month does not greet a driver who has
// long since forgotten it.
const RESUME_MAX_AGE_MS = 7 * 24 * 60 * 60 * 1000;

// Under this much left, the trip is over in every sense that matters and
// offering to resume it is noise.
const RESUME_MIN_REMAIN_M = 2000;

// A route sent from the phone is worth offering for a day. Beyond that the
// driver has almost certainly made the trip, or given up on it.
const INBOX_MAX_AGE_MS = 24 * 60 * 60 * 1000;

const state = {
  uid: null,
  items: [],
  active: null,
  inbox: null,
  stopRoutes: null,
  stopActive: null,
  stopInbox: null,
  resumeOffered: false, // once per session, so our own writes can't re-open it
};

const $ = (id) => document.getElementById(id);
const cacheKey = (uid) => `gc_routes_${uid}`;

function newId() {
  return (crypto.randomUUID?.() ?? String(Math.random()).slice(2) + Date.now()).replace(/-/g, '');
}

const isPoint = (p) => p && Number.isFinite(p.lat) && Number.isFinite(p.lng);
const point = (p) => ({ lat: Number(p.lat), lng: Number(p.lng) });

function fmtKm(m) {
  return `${Math.round(m / 1000)} ${getLang() === 'ka' ? 'კმ' : 'km'}`;
}

// ── Storage ──────────────────────────────────────────────────────────────────
function clean(list) {
  return (Array.isArray(list) ? list : [])
    .filter((r) => r && r.name && isPoint(r.destination))
    .slice(0, MAX_ROUTES)
    .map((r) => ({
      id: String(r.id || newId()),
      name: String(r.name).slice(0, MAX_NAME),
      destination: point(r.destination),
      waypoints: (Array.isArray(r.waypoints) ? r.waypoints : []).filter(isPoint).map(point),
      createdAt: Number(r.createdAt) || Date.now(),
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

async function persist(items) {
  state.items = items;
  redrawMenu();
  if (!state.uid) return;
  writeCache(state.uid, items);
  try {
    await saveTeslaDoc(state.uid, 'routes', { items, updatedAt: Date.now() });
  } catch (_) {
    showToast(t('favSaveFailed'));
  }
}

/** Fire-and-forget: a lost progress write costs at most one minute of accuracy. */
function writeActive(data) {
  state.active = data;
  if (!state.uid) return;
  saveTeslaDoc(state.uid, 'active', data ?? { cleared: Date.now() }).catch(() => {});
}

function clearActive() {
  state.active = null;
  hideResume();
  if (!state.uid) return;
  saveTeslaDoc(state.uid, 'active', { cleared: Date.now() }).catch(() => {});
}

// ── Starting and resuming ────────────────────────────────────────────────────
function startRoute(r, done = []) {
  startDrive({
    destination: r.destination,
    // A resumed trip drops the stops already behind the driver. Everything
    // else, including the destination, is unchanged; the origin is the live
    // GPS fix drive.js takes for itself.
    waypoints: (r.waypoints ?? []).filter((_, i) => !done.includes(i)),
    route: { id: r.id ?? null, name: r.name },
  });
}

/** The unfinished trip, if there is one worth offering. */
function resumable() {
  const a = state.active;
  if (!a || !isPoint(a.destination)) return null;
  if (!a.at || Date.now() - a.at > RESUME_MAX_AGE_MS) return null;
  if (Number.isFinite(a.remainM) && a.remainM < RESUME_MIN_REMAIN_M) return null;
  return a;
}

function showResume() {
  const a = resumable();
  if (!a || isDriving() || state.resumeOffered) return;
  if (state.inbox) return; // a route just arrived from the phone; that wins
  state.resumeOffered = true;

  const card = $('resume-card');
  card.querySelector('.resume-card__name').textContent = a.name || t('routeUnnamed');
  const sub = card.querySelector('.resume-card__sub');
  sub.textContent = Number.isFinite(a.remainM)
    ? `${t('routeRemaining')} ${fmtKm(a.remainM)}`
    : '';
  sub.hidden = !sub.textContent;
  showMapCard('resume-card');
  track('route_resume_offer', {});
}

function hideResume() {
  hideMapCard('resume-card');
}

// ── Routes arriving from the phone ───────────────────────────────────────────
// The app writes one document and the car watches it. A route that arrives
// while the car is asleep simply waits there until it is next opened, which is
// the normal case: the driver plans on the sofa and walks out to the car.

/** The inbox entry, if it has not been dealt with yet. */
function pending() {
  const i = state.inbox;
  if (!i || !isPoint(i.destination)) return null;
  if (i.consumedAt && i.consumedAt >= i.sentAt) return null;
  // Old enough that the driver has forgotten sending it.
  if (!i.sentAt || Date.now() - i.sentAt > INBOX_MAX_AGE_MS) return null;
  return i;
}

/**
 * A single point rather than a trip: the driver looked a hotel up on the phone
 * and sent where it is. Nothing in the document says which it is — the app
 * sends both through the same field — so the stops are what tell them apart,
 * and that is exactly the difference that matters here: with no stops there is
 * nothing to lose by planning the way there from scratch.
 */
function isPlace(i) {
  return !(i.waypoints ?? []).length;
}

function showInbox() {
  const i = pending();
  if (!i || isDriving()) return;

  const place = isPlace(i);
  const card = $('inbox-card');
  card.classList.toggle('is-place', place);
  card.querySelector('.resume-card__label').textContent =
    t(place ? 'inboxPlaceTitle' : 'inboxTitle');
  card.querySelector('.resume-card__name').textContent = i.name || t('routeUnnamed');
  const sub = card.querySelector('.resume-card__sub');
  const bits = place
    // Coordinates, because a place sent from a phone is often a name the driver
    // half-remembers and this is the one line that says WHERE it is.
    ? [`${i.destination.lat.toFixed(4)}, ${i.destination.lng.toFixed(4)}`]
    : [stopsLabel((i.waypoints ?? []).length)];
  if (i.avoidTolls) bits.push(t('routeNoTolls'));
  if ((i.dropped ?? []).length) bits.push(t('routeDropped'));
  sub.textContent = bits.join(' · ');
  $('inbox-plan')?.classList.toggle('is-hidden', !place);
  showMapCard('inbox-card');
  track('inbox_offer', { source: i.source ?? 'app', place: place ? 1 : 0 });
}

/** Mark it dealt with, so it is not offered again on the next launch. */
function consumeInbox() {
  hideMapCard('inbox-card');
  if (!state.uid || !state.inbox) return;
  saveTeslaDoc(state.uid, 'inbox', { consumedAt: Date.now() }).catch(() => {});
}

function inboxAsRoute(i) {
  return {
    id: null,
    name: i.name || t('routeUnnamed'),
    destination: i.destination,
    waypoints: i.waypoints ?? [],
  };
}

// ── Star menu section ────────────────────────────────────────────────────────
async function renameRoute(r) {
  const answer = await askName({
    title: t('favRenameTitle'),
    value: r.name,
    placeholder: t('routeNameHint'),
  });
  if (!answer) return;
  persist(state.items.map((x) => (x.id === r.id ? { ...x, name: answer.name } : x)));
  track('route_rename', {});
}

function routeRow(r, closeMenu) {
  const row = document.createElement('div');
  row.className = 'fav-item';

  const a = resumable();
  const inProgress = a && a.routeId === r.id;
  const done = inProgress ? a.done ?? [] : [];

  const go = document.createElement('button');
  go.className = 'fav-item__go';
  go.type = 'button';
  go.innerHTML =
    '<span class="fav-item__ico">🛣️</span>' +
    '<span class="fav-item__txt"><span class="fav-item__name"></span>' +
    '<span class="fav-item__sub"></span></span>';
  go.querySelector('.fav-item__name').textContent = r.name;
  const sub = go.querySelector('.fav-item__sub');
  sub.textContent = inProgress
    ? `${t('routeContinue')}${Number.isFinite(a.remainM) ? ` · ${fmtKm(a.remainM)}` : ''}`
    : stopsLabel(r.waypoints.length);
  if (inProgress) sub.classList.add('is-accent');
  go.addEventListener('click', () => {
    closeMenu();
    if (gated()) return;
    track('route_start', { resumed: inProgress ? 1 : 0 });
    startRoute(r, done);
  });

  const rename = document.createElement('button');
  rename.className = 'fav-item__act';
  rename.type = 'button';
  rename.title = t('favRename');
  rename.setAttribute('aria-label', t('favRename'));
  rename.textContent = '✏️';
  rename.addEventListener('click', () => {
    closeMenu();
    renameRoute(r);
  });

  const del = document.createElement('button');
  del.className = 'fav-item__act';
  del.type = 'button';
  del.title = t('favDelete');
  del.setAttribute('aria-label', t('favDelete'));
  del.textContent = '🗑';
  del.addEventListener('click', () => {
    persist(state.items.filter((x) => x.id !== r.id));
    if (inProgress) clearActive();
    track('route_remove', {});
  });

  row.append(go, rename, del);
  return row;
}

/** "2 stops" / "1 stop". Georgian has no plural here; English does. */
function stopsLabel(n) {
  if (!n) return t('routeNoStops');
  if (getLang() !== 'ka' && n === 1) return `1 ${t('routeStop')}`;
  return `${n} ${t('routeStops')}`;
}

/** True while the login or paywall screen covers the app (see favorites.js). */
function gated() {
  return document.querySelector('.gate.is-open') !== null;
}

/**
 * Draw the routes half of the star menu. Called by favorites.js, which owns
 * the menu itself — one dropdown for everything the driver has saved.
 */
export function renderRouteRows(menu, closeMenu) {
  menu.appendChild(heading(t('routesTitle')));

  // An unfinished trip that was never saved as a route still deserves a way
  // back: it goes at the top of the section as a row of its own.
  const a = resumable();
  if (a && !a.routeId) {
    menu.appendChild(
      routeRow(
        { id: null, name: a.name || t('routeUnnamed'), destination: a.destination, waypoints: a.waypoints ?? [] },
        closeMenu,
      ),
    );
  }

  if (!state.items.length) {
    if (!a || a.routeId) menu.appendChild(emptyNote(t(state.uid ? 'routeEmpty' : 'routeSignedOut')));
    return;
  }
  for (const r of state.items) menu.appendChild(routeRow(r, closeMenu));
}

function redrawMenu() {
  // Only worth doing while the driver is looking at it; favorites.js rebuilds
  // the whole menu from scratch each time it opens.
  if (!$('fav-menu').classList.contains('is-hidden')) {
    document.dispatchEvent(new CustomEvent('gc:menu-dirty'));
  }
}

// ── Saving from the trip planner ─────────────────────────────────────────────
/**
 * Save the planned trip under a name the driver types.
 * @param {{destination:{lat,lng}, waypoints:{lat,lng}[], suggestedName:string}} plan
 */
export async function saveRoute({ destination, waypoints, suggestedName }) {
  if (!isPoint(destination)) return;
  if (!state.uid) {
    showToast(t('routeSignedOut'));
    return;
  }
  if (state.items.length >= MAX_ROUTES) {
    showToast(t('routeFull'));
    return;
  }
  const answer = await askName({
    title: t('routeNameTitle'),
    subtitle: suggestedName,
    value: suggestedName.slice(0, MAX_NAME),
    placeholder: t('routeNameHint'),
  });
  if (!answer) return;

  persist([
    ...state.items,
    {
      id: newId(),
      name: answer.name,
      destination: point(destination),
      waypoints: (waypoints ?? []).filter(isPoint).map(point),
      createdAt: Date.now(),
    },
  ]);
  announceRoute(answer.name, destination, waypoints, 'plan');
  track('route_save', { stops: waypoints?.length ?? 0 });
  showToast(t('routeSaved'), 2500);
}

/**
 * Add a route to the saved list without asking for a name. Used by the history
 * panel's star, where the trip already has whatever name it was filed under.
 */
export function addSavedRoute({ name, destination, waypoints }) {
  if (!isPoint(destination)) return;
  if (!state.uid) {
    showToast(t('routeSignedOut'));
    return;
  }
  if (state.items.length >= MAX_ROUTES) {
    showToast(t('routeFull'));
    return;
  }
  persist([
    ...state.items,
    {
      id: newId(),
      name: (name || t('routeUnnamed')).slice(0, MAX_NAME),
      destination: point(destination),
      waypoints: (waypoints ?? []).filter(isPoint).map(point),
      createdAt: Date.now(),
    },
  ]);
  track('route_save', { from: 'history' });
  showToast(t('routeSaved'), 2500);
}

/**
 * Announce a route that exists but is not being driven. history.js files these
 * the moment they appear, which is what the driver asked for: a route sent from
 * the phone is worth keeping whether or not the trip ever starts.
 */
function announceRoute(name, destination, waypoints, source) {
  document.dispatchEvent(new CustomEvent('gc:route-known', {
    detail: { name, destination, waypoints, source },
  }));
}

/** Re-render after a language switch. */
export function relabelRoutes() {
  redrawMenu();
  const card = $('resume-card');
  if (card && !card.classList.contains('is-hidden')) {
    state.resumeOffered = false;
    showResume();
  }
  // The from-phone card writes its own label (a place and a route say different
  // things), and applyStaticStrings has just overwritten it with the route one.
  const inbox = $('inbox-card');
  if (inbox && !inbox.classList.contains('is-hidden')) showInbox();
}

export function initRoutes() {
  $('resume-go')?.addEventListener('click', () => {
    const a = resumable();
    hideResume();
    if (!a || gated()) return;
    track('route_resume', {});
    startRoute(
      { id: a.routeId, name: a.name, destination: a.destination, waypoints: a.waypoints ?? [] },
      a.done ?? [],
    );
  });
  $('resume-dismiss')?.addEventListener('click', () => {
    track('route_resume_dismiss', {});
    clearActive();
  });

  // A route that came from the phone: drive it now, keep it for later, or not.
  $('inbox-go')?.addEventListener('click', () => {
    const i = pending();
    consumeInbox();
    if (!i || gated()) return;
    track('inbox_start', {});
    startRoute(inboxAsRoute(i));
  });
  $('inbox-save')?.addEventListener('click', async () => {
    const i = pending();
    consumeInbox();
    if (!i) return;
    if (state.items.length >= MAX_ROUTES) {
      showToast(t('routeFull'));
      return;
    }
    persist([
      ...state.items,
      {
        id: newId(),
        name: (i.name || t('routeUnnamed')).slice(0, MAX_NAME),
        destination: point(i.destination),
        waypoints: (i.waypoints ?? []).filter(isPoint).map(point),
        createdAt: Date.now(),
      },
    ]);
    track('inbox_save', {});
    showToast(t('routeSaved'), 2500);
  });
  // A place from the phone, planned properly: the trip planner opens on it and
  // works out where to charge on the way. Announced rather than called, because
  // the planner already imports this module and a cycle between the two would
  // be a needless trap.
  $('inbox-plan')?.addEventListener('click', () => {
    const i = pending();
    consumeInbox();
    if (!i || gated()) return;
    track('inbox_plan', {});
    document.dispatchEvent(new CustomEvent('gc:plan-to', {
      detail: { pos: point(i.destination), name: i.name || '' },
    }));
  });
  $('inbox-dismiss')?.addEventListener('click', () => {
    track('inbox_dismiss', {});
    consumeInbox();
  });

  // drive.js reports where it is; this is the only thing that writes it down.
  document.addEventListener('gc:drive-progress', (e) => {
    const d = e.detail;
    writeActive({
      routeId: d.route?.id ?? null,
      name: d.route?.name ?? t('routeUnnamed'),
      destination: point(d.destination),
      waypoints: (d.waypoints ?? []).map(point),
      done: d.done ?? [],
      pos: isPoint(d.pos) ? point(d.pos) : null,
      remainM: Math.round(d.remainM ?? 0),
      at: Date.now(),
    });
  });
  // Arriving finishes the trip; there is nothing left to carry on with.
  document.addEventListener('gc:drive-arrived', () => clearActive());
  // A drive that starts hides the offer to resume a different one.
  document.addEventListener('gc:drive-start', () => {
    hideResume();
    hideMapCard('inbox-card');
  });

  watchAuth((user) => {
    state.stopRoutes?.();
    state.stopActive?.();
    state.stopInbox?.();
    state.stopRoutes = state.stopActive = state.stopInbox = null;
    state.uid = user?.uid ?? null;
    state.resumeOffered = false;

    if (!state.uid) {
      state.items = [];
      state.active = null;
      state.inbox = null;
      hideResume();
      hideMapCard('inbox-card');
      redrawMenu();
      return;
    }

    state.items = readCache(state.uid);
    redrawMenu();
    state.stopRoutes = watchTeslaDoc(state.uid, 'routes', (data) => {
      state.items = clean(data?.items);
      writeCache(state.uid, state.items);
      redrawMenu();
    });
    state.stopActive = watchTeslaDoc(state.uid, 'active', (data) => {
      state.active = data?.cleared ? null : data;
      showResume();
      redrawMenu();
    });
    // Realtime on purpose: a driver already sitting in the car should see the
    // route land within a second of tapping send on the phone.
    state.stopInbox = watchTeslaDoc(state.uid, 'inbox', (data) => {
      state.inbox = data;
      const p = pending();
      if (p) {
        showInbox();
        announceRoute(p.name, p.destination, p.waypoints, 'phone');
      } else {
        hideMapCard('inbox-card');
      }
    });
  });
}

/** Debug handle. */
export function routesState() {
  return state;
}
