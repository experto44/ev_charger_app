// Inline SVG icons.
//
// Everything in here used to be a character: ✕ on the close buttons, ✓ on a
// ticked option, ☐/☑ in the country menu, ☆ on "save this place", ＋, ↑/↓, ▸.
// On a real Tesla they all arrived as empty boxes (reported from the car,
// 2026-09-02): the browser is Chromium on Linux and its fonts have no glyph
// for those symbol blocks, exactly as with the flag emoji in countries.js.
//
// A drawing cannot be missing from a font, so every symbol the driver has to
// recognise is drawn here instead. Emoji proper (🔍, 📍) do render on the car
// and stay where they are; what is drawn below is the symbol characters, plus
// the two emoji used as BUTTONS (edit / delete), where a box would be an
// unusable control rather than a missing decoration.
//
// All paths are 24×24 and painted with currentColor, so an icon takes the
// colour and the size of whatever it sits in.

const P = {
  close: '<path d="M18.3 5.71L12 12.01l-6.29-6.3-1.42 1.42 6.3 6.29-6.3 6.29 1.42 1.42 6.29-6.3 6.29 6.3 1.42-1.42-6.3-6.29 6.3-6.29z"/>',
  check: '<path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/>',
  box: '<path d="M19 5v14H5V5h14m0-2H5a2 2 0 00-2 2v14a2 2 0 002 2h14a2 2 0 002-2V5a2 2 0 00-2-2z"/>',
  boxChecked:
    '<path d="M19 3H5a2 2 0 00-2 2v14a2 2 0 002 2h14a2 2 0 002-2V5a2 2 0 00-2-2zm-9 14l-5-5 1.41-1.41L10 14.17l7.59-7.59L19 8z"/>',
  star: '<path d="M12 15.4l-3.76 2.27 1-4.28-3.32-2.88 4.38-.38L12 6.1l1.71 4.04 4.38.38-3.32 2.88 1 4.28M22 9.24l-7.19-.62L12 2 9.19 8.63 2 9.24l5.46 4.73L5.82 21 12 17.27 18.18 21l-1.63-7.03z"/>',
  plus: '<path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6z"/>',
  arrowUp: '<path d="M13 20V7.83l5.59 5.58L20 12l-8-8-8 8 1.41 1.41L11 7.83V20z"/>',
  arrowDown: '<path d="M11 4v12.17l-5.59-5.58L4 12l8 8 8-8-1.41-1.41L13 16.17V4z"/>',
  chevronRight: '<path d="M9.29 6.71L14.58 12l-5.29 5.29 1.42 1.42L17.41 12l-6.7-6.71z"/>',
  uTurn: '<path d="M15 20V9.5A3.5 3.5 0 008 9.5V13h2V9.5a1.5 1.5 0 013 0V20zM9.5 13H4l2.75 4z"/>',
  trash: '<path d="M9 3l-1 1H4v2h16V4h-4l-1-1zM6 7v13a2 2 0 002 2h8a2 2 0 002-2V7zm3 3h2v9H9zm4 0h2v9h-2z"/>',
  pencil: '<path d="M20.71 7.04a1 1 0 000-1.41l-2.34-2.34a1 1 0 00-1.41 0l-1.83 1.83 3.75 3.75zM3 17.25V21h3.75L17.81 9.94l-3.75-3.75z"/>',
  bolt: '<path d="M11 21h-1l1-7H7.5a.5.5 0 01-.4-.8L13 3h1l-1 7h3.5a.5.5 0 01.4.8z"/>',
  clock:
    '<path d="M12 2a10 10 0 100 20 10 10 0 000-20zm0 18a8 8 0 110-16 8 8 0 010 16zm.5-13H11v6l5.2 3.2.8-1.3-4.5-2.7z"/>',
  road: '<path d="M11 3h2v4h-2zm0 6h2v6h-2zm0 8h2v4h-2zM6.5 3h2.2l-2 18H4.3zm8.8 0h2.2l2 18h-2.4z"/>',
  // Drive-mode toggle between "north is up" and "the car always points up".
  compass:
    '<path d="M12 2a10 10 0 100 20 10 10 0 000-20zm0 18a8 8 0 110-16 8 8 0 010 16zm2.5-10.5L9 11l-1.5 5.5L13 15z"/>',
  headingUp:
    '<path d="M12 2L4.5 20.29l.71.71L12 17.5l6.79 3.5.71-.71z"/>',
};

/** Icon markup, sized in pixels (24 by default). */
export function icon(name, size = 24) {
  const body = P[name];
  if (!body) return '';
  return (
    `<svg class="ico ico--${name}" viewBox="0 0 24 24" width="${size}" height="${size}" ` +
    `fill="currentColor" aria-hidden="true">${body}</svg>`
  );
}

/** The same as an <svg> element, for the places that build DOM rather than HTML. */
export function iconEl(name, size = 24) {
  const span = document.createElement('span');
  span.className = 'ico-wrap';
  span.innerHTML = icon(name, size);
  return span.firstElementChild || span;
}

// Saved places keep the emoji they were created with in Firestore ('🏠', '🏢',
// '🏡', '📍'), so the stored value stays the key and only the drawing changes.
// Anything unknown falls through and is rendered as the character it is.
const FAV = {
  '🏠': '<path d="M12 3L2 12h3v8h6v-6h2v6h6v-8h3z"/>',
  '🏢': '<path d="M5 3v18h6v-4h2v4h6V3zm3 3h2v2H8zm6 0h2v2h-2zM8 10h2v2H8zm6 0h2v2h-2zM8 14h2v2H8zm6 0h2v2h-2z"/>',
  '🏡': '<path d="M12 3L2 12h3v8h14v-8h3zm0 5.5l4 3.5v6h-2.5v-4h-3v4H8v-6z"/>',
  '📍': '<path d="M12 2a7 7 0 00-7 7c0 5.25 7 13 7 13s7-7.75 7-13a7 7 0 00-7-7zm0 9.5A2.5 2.5 0 1114.5 9 2.5 2.5 0 0112 11.5z"/>',
};

/** Markup for a saved-place icon: our drawing where we have one. */
export function favIcon(key, size = 24) {
  const body = FAV[key];
  if (!body) return key || '';
  return (
    `<svg class="ico ico--fav" viewBox="0 0 24 24" width="${size}" height="${size}" ` +
    `fill="currentColor" aria-hidden="true">${body}</svg>`
  );
}

/** The keys the favourite-icon picker offers, in order. */
export const FAV_KEYS = Object.keys(FAV);
