// Day / night theme.
//
// The car screen is used in both, and the dark map that reads perfectly at
// night washes out in direct sun. `data-theme` on <html> drives the CSS tokens
// (css/app.css) and the Google map style (js/map.js). The attribute is already
// set before first paint by the bootstrap script in index.html — this module
// only owns the switch and the persistence, so there is never a dark flash.

import { setMapTheme } from './map.js';
import { t } from './i18n.js';

const KEY = 'gc_theme';

/** 'light' | 'dark' — whatever is painted right now. */
function getTheme() {
  return document.documentElement.dataset.theme === 'light' ? 'light' : 'dark';
}

function apply(theme) {
  document.documentElement.dataset.theme = theme;
  setMapTheme(theme); // no-op until the map exists (login gate is still up)
  syncBtn();
}

function syncBtn() {
  const btn = document.getElementById('btn-theme');
  if (!btn) return;
  // The icon shows the theme the tap switches TO, so the label has to say the
  // same thing rather than name the current one. The data-* attributes keep it
  // translated when the driver switches language.
  const key = getTheme() === 'light' ? 'themeDark' : 'themeLight';
  btn.dataset.tTitle = key;
  btn.dataset.tAria = key;
  btn.title = t(key);
  btn.setAttribute('aria-label', t(key));
}

export function initTheme() {
  const btn = document.getElementById('btn-theme');
  btn?.addEventListener('click', () => {
    const next = getTheme() === 'light' ? 'dark' : 'light';
    localStorage.setItem(KEY, next);
    apply(next);
  });

  // Until the driver picks a side, follow the car/browser. Tesla flips its own
  // UI between day and night, and where the browser reports that we go with it.
  try {
    const mq = matchMedia('(prefers-color-scheme: light)');
    const onChange = (e) => {
      if (localStorage.getItem(KEY)) return; // explicit choice wins
      apply(e.matches ? 'light' : 'dark');
    };
    mq.addEventListener?.('change', onChange);
  } catch (_) {/* no matchMedia — the stored/default theme stands */}

  syncBtn();
}
