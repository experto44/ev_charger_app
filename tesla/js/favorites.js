// Saved places ("favourites").
//
// Four of them at most, because they are drawn as one-tap navigation buttons
// over the map and a fifth would start crowding the turn banner. Tapping one
// starts driving straight away — that is the whole point of the rail, and the
// full list (rename, remove) lives behind the star in the top bar.
//
// They belong to the ACCOUNT, not to the car: users/{uid}/tesla/favourites.
// A driver who re-pairs the car, or signs in from a different Tesla, still has
// their places. localStorage keeps a per-account copy so the rail is painted
// before Firestore has answered, which on a cold car is several seconds.

import { saveTeslaDoc, watchAuth, watchTeslaDoc } from './auth.js';
import { startDrive } from './drive.js';
import { t } from './i18n.js';
import { closeTopbarMenus, emptyNote, heading } from './menus.js';
import { askName, MAX_NAME } from './name-dialog.js';
import { renderRouteRows } from './routes.js';
import { showToast } from './ui.js';
import { track } from './analytics.js';

const MAX_FAVS = 4;

// Plain emoji, not flags: the regional-indicator pairs are the ones the car's
// browser cannot draw (see countries.js), these render everywhere.
const ICONS = ['🏠', '🏢', '🏡', '📍'];

// A place named "home" wants the house without the driver having to pick it.
// Both languages, and both the words people actually type.
const ICON_GUESS = [
  [/სახლ|home|house/i, '🏠'],
  [/სამსახურ|ოფის|work|office/i, '🏢'],
  [/სოფელ|დაჩ|village|cottage|countryside/i, '🏡'],
];

const state = {
  uid: null,
  items: [],
  stopDoc: null,
};

const $ = (id) => document.getElementById(id);
const cacheKey = (uid) => `gc_favs_${uid}`;

/**
 * True while the login or paywall screen covers the app. The rail is behind
 * that overlay and cannot be tapped, but the top bar sits above it, so the menu
 * is still reachable — and with no map and no Directions service behind it,
 * "navigate" there would end in a route error instead of the paywall the driver
 * is already looking at.
 */
function gated() {
  return document.querySelector('.gate.is-open') !== null;
}

function navigateTo(f) {
  if (gated()) return;
  track('fav_navigate', {});
  startDrive({
    destination: { lat: f.lat, lng: f.lng },
    // No id: a favourite is a place, not a saved route. The name is passed so
    // the trip reads as "Home" in the history rather than as coordinates.
    route: { id: null, name: f.name },
  });
}

function guessIcon(name) {
  for (const [re, icon] of ICON_GUESS) if (re.test(name)) return icon;
  return '📍';
}

function newId() {
  return (crypto.randomUUID?.() ?? String(Math.random()).slice(2) + Date.now()).replace(/-/g, '');
}

// ── Storage ──────────────────────────────────────────────────────────────────
/** Everything the rail and the menu need, whatever the network is doing. */
function readCache(uid) {
  try {
    const raw = JSON.parse(localStorage.getItem(cacheKey(uid)));
    return Array.isArray(raw) ? raw : [];
  } catch {
    return [];
  }
}

function writeCache(uid, items) {
  try {
    localStorage.setItem(cacheKey(uid), JSON.stringify(items));
  } catch {/* private mode / full quota — Firestore is still the real copy */}
}

/**
 * Coordinates are stored as plain numbers and the id is ours, so a favourite
 * never depends on a Places result staying resolvable.
 */
function clean(list) {
  return (Array.isArray(list) ? list : [])
    .filter((f) => f && Number.isFinite(f.lat) && Number.isFinite(f.lng) && f.name)
    .slice(0, MAX_FAVS)
    .map((f) => ({
      id: String(f.id || newId()),
      name: String(f.name).slice(0, MAX_NAME),
      icon: ICONS.includes(f.icon) ? f.icon : guessIcon(String(f.name)),
      lat: Number(f.lat),
      lng: Number(f.lng),
    }));
}

/**
 * Write the list to the account. The local copy is updated FIRST and the UI
 * repainted from it, so a slow or failed write never leaves the driver looking
 * at a button that did nothing.
 */
async function persist(items) {
  state.items = items;
  render();
  if (!state.uid) return;
  writeCache(state.uid, items);
  try {
    await saveTeslaDoc(state.uid, 'favourites', { items, updatedAt: Date.now() });
  } catch (_) {
    showToast(t('favSaveFailed'));
  }
}

// ── Rail (map, top right) ────────────────────────────────────────────────────
function renderRail() {
  const rail = $('fav-rail');
  rail.innerHTML = '';
  for (const f of state.items) {
    const b = document.createElement('button');
    b.className = 'fav-chip';
    b.type = 'button';
    b.title = f.name;
    b.innerHTML =
      `<span class="fav-chip__ico">${f.icon}</span>` +
      `<span class="fav-chip__name"></span>`;
    b.querySelector('.fav-chip__name').textContent = f.name;
    b.addEventListener('click', () => navigateTo(f));
    rail.appendChild(b);
  }
}

// ── Menu (top bar) ───────────────────────────────────────────────────────────
// The star holds everything the driver has saved, in two sections: places
// here, and routes drawn by routes.js. One button rather than two, because the
// topbar has no room for a second and "my saved things" is one errand.
function renderMenu() {
  const menu = $('fav-menu');
  menu.innerHTML = '';
  renderPlaces(menu);
  renderRouteRows(menu, closeMenu);
}

function renderPlaces(menu) {
  menu.appendChild(heading(t('favPlaces')));

  if (!state.items.length) {
    menu.appendChild(emptyNote(t(state.uid ? 'favEmpty' : 'favSignedOut')));
    return;
  }

  for (const f of state.items) {
    const row = document.createElement('div');
    row.className = 'fav-item';

    const go = document.createElement('button');
    go.className = 'fav-item__go';
    go.type = 'button';
    go.innerHTML = `<span class="fav-item__ico">${f.icon}</span><span class="fav-item__name"></span>`;
    go.querySelector('.fav-item__name').textContent = f.name;
    go.addEventListener('click', () => {
      closeMenu();
      navigateTo(f);
    });

    const rename = document.createElement('button');
    rename.className = 'fav-item__act';
    rename.type = 'button';
    rename.title = t('favRename');
    rename.setAttribute('aria-label', t('favRename'));
    rename.textContent = '✏️';
    rename.addEventListener('click', () => {
      closeMenu();
      renameFavorite(f);
    });

    const del = document.createElement('button');
    del.className = 'fav-item__act';
    del.type = 'button';
    del.title = t('favDelete');
    del.setAttribute('aria-label', t('favDelete'));
    del.textContent = '🗑';
    del.addEventListener('click', () => {
      persist(state.items.filter((x) => x.id !== f.id));
      track('fav_remove', {});
      renderMenu(); // the menu stays open: removing two in a row is one visit
    });

    row.append(go, rename, del);
    menu.appendChild(row);
  }
}

function render() {
  renderRail();
  if (!$('fav-menu').classList.contains('is-hidden')) renderMenu();
}

function closeMenu() {
  $('fav-menu').classList.add('is-hidden');
  $('btn-favs').setAttribute('aria-expanded', 'false');
}

// ── Add / rename ─────────────────────────────────────────────────────────────
async function renameFavorite(f) {
  const answer = await askName({
    title: t('favRenameTitle'),
    value: f.name,
    placeholder: t('favNameHint'),
    icons: ICONS,
    icon: f.icon,
    guessIcon,
  });
  if (!answer) return;
  persist(state.items.map((x) => (x.id === f.id ? { ...x, ...answer } : x)));
  track('fav_rename', {});
}

// ── Public API ───────────────────────────────────────────────────────────────
/**
 * Offer to save a place. Called from the star on a search result, with
 * coordinates already resolved.
 * @param {{lat:number, lng:number, name:string}} place
 */
export async function addFavorite(place) {
  if (!place || !Number.isFinite(place.lat) || !Number.isFinite(place.lng)) return;
  if (!state.uid) {
    showToast(t('favSignedOut'));
    return;
  }
  if (state.items.length >= MAX_FAVS) {
    showToast(t('favFull'));
    return;
  }
  const answer = await askName({
    title: t('favNameTitle'),
    subtitle: place.name,
    value: place.name,
    placeholder: t('favNameHint'),
    icons: ICONS,
    icon: guessIcon(place.name),
    guessIcon,
  });
  if (!answer) return;
  // The list can have filled up while the dialog was open (it cannot today,
  // but a second tab on the same account is exactly what the account-level
  // store makes possible).
  if (state.items.length >= MAX_FAVS) {
    showToast(t('favFull'));
    return;
  }
  persist([...state.items, { id: newId(), ...answer, lat: place.lat, lng: place.lng }]);
  track('fav_add', {});
  showToast(t('favAdded'), 2500);
}

/** Repaint after a language switch (the menu's headings are translated). */
export function relabelFavorites() {
  render();
}

export function initFavorites() {
  const btn = $('btn-favs');
  const menu = $('fav-menu');

  btn.setAttribute('aria-label', t('favTitle'));
  btn.title = t('favTitle');
  btn.addEventListener('click', (e) => {
    e.stopPropagation();
    closeTopbarMenus('fav-menu');
    const hidden = menu.classList.toggle('is-hidden');
    btn.setAttribute('aria-expanded', String(!hidden));
    if (!hidden) renderMenu();
  });
  menu.addEventListener('click', (e) => e.stopPropagation());
  document.addEventListener('click', closeMenu);
  // routes.js draws the other half of this menu and repaints on its own
  // schedule (a Firestore change, a finished drive). It cannot rebuild the
  // menu itself without importing this module, which would be a cycle.
  document.addEventListener('gc:menu-dirty', () => {
    if (!menu.classList.contains('is-hidden')) renderMenu();
  });

  // Follow the account rather than booting once: signing out and back in as
  // someone else must swap the list, not keep the first driver's places.
  watchAuth((user) => {
    state.stopDoc?.();
    state.stopDoc = null;
    state.uid = user?.uid ?? null;

    if (!state.uid) {
      state.items = [];
      render();
      return;
    }
    state.items = clean(readCache(state.uid)); // paint before the network answers
    render();
    state.stopDoc = watchTeslaDoc(state.uid, 'favourites', (data) => {
      state.items = clean(data?.items);
      writeCache(state.uid, state.items);
      render();
    });
  });

  // The rail is meaningless while the login or paywall screen is up, and the
  // gate does not tear the app down when a trial lapses mid-session.
  render();
}

/** Debug handle. */
export function favoritesState() {
  return state;
}
