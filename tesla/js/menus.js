// The topbar's anchored dropdowns: countries, favourites, car.
//
// Its own module, and one that imports nothing, because every one of those
// three lives in a different file: hanging this off ui.js made car.js import
// ui.js, and ui.js already reaches car.js through map.js.

/**
 * Close every topbar dropdown except the one being opened. Each opener stops
 * the click from reaching the document — that is what keeps a menu open while
 * the driver picks two things out of it — which also means opening one cannot
 * close the others on its own. With three of them side by side, two open at
 * once overlap.
 */
export function closeTopbarMenus(exceptId) {
  for (const [menuId, btnId] of [
    ['country-menu', 'btn-countries'],
    ['fav-menu', 'btn-favs'],
    ['car-menu', 'btn-car'],
  ]) {
    if (menuId === exceptId) continue;
    document.getElementById(menuId)?.classList.add('is-hidden');
    document.getElementById(btnId)?.setAttribute('aria-expanded', 'false');
  }
}

// ── Menu building blocks ─────────────────────────────────────────────────────
// The star menu is drawn by two modules (places in favorites.js, routes in
// routes.js) and they have to look like one list. These live here rather than
// in either of them so neither has to import the other.

/** A section heading inside a topbar dropdown. */
export function heading(label) {
  const h = document.createElement('div');
  h.className = 'car-menu__label';
  h.textContent = label;
  return h;
}

/** The greyed line a section shows instead of rows when it has none. */
export function emptyNote(text) {
  const p = document.createElement('p');
  p.className = 'fav-menu__empty';
  p.textContent = text;
  return p;
}
