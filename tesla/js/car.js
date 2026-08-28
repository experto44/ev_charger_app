// The driver's car: which Tesla they drive, in which colour, and the top-down
// silhouette that replaces the blue dot while navigating.
//
// The shapes are our own drawing, not Tesla artwork: one parametric outline
// (narrow at the nose, widest at the doors, slightly drawn in at the tail) with
// per-model proportions. Seen from straight above that is the only thing that
// tells the four apart — the sedans are narrower, the SUVs wider and boxier —
// so the numbers below are the whole difference and are worth keeping honest.

import { t } from './i18n.js';
import { closeTopbarMenus } from './menus.js';

const MODEL_KEY = 'gc_car_model';
const COLOR_KEY = 'gc_car_color';

// l/w are HALF length and width in the 64×64 icon box; nose/tail scale the
// width at each end; glass is the cabin panel. A POSITIVE gy pushes that cabin
// behind centre, which is what leaves a bonnet at the front — at 48px on a
// moving map that asymmetry, plus the headlights, is how the driver reads which
// way the car is pointing. The sedans get the longer bonnet, the SUVs a shorter
// one, as they have.
const MODELS = [
  { id: 'model3', name: 'Model 3', l: 23,   w: 10.5, nose: 0.72, tail: 0.80, r: 3,   gl: 8,   gw: 7.5, gy: 2 },
  { id: 'modely', name: 'Model Y', l: 23,   w: 11.8, nose: 0.80, tail: 0.88, r: 4,   gl: 8.5, gw: 8.4, gy: 1.5 },
  { id: 'models', name: 'Model S', l: 25.5, w: 10.8, nose: 0.70, tail: 0.82, r: 3,   gl: 8.5, gw: 7.6, gy: 2.5 },
  { id: 'modelx', name: 'Model X', l: 25.5, w: 12.2, nose: 0.78, tail: 0.90, r: 4.5, gl: 9,   gw: 8.6, gy: 1.5 },
];

// halo = the outer ring that keeps the car visible on both map themes: a light
// one under dark paint, a dark one under light paint.
const COLORS = [
  { id: 'white', body: '#f3f5f7', edge: '#8d99a3', glass: '#39424b', halo: 'rgba(13,18,22,0.45)' },
  { id: 'black', body: '#23282d', edge: '#6b7680', glass: '#12181e', halo: 'rgba(255,255,255,0.55)' },
  { id: 'red',   body: '#cf2b28', edge: '#7d1512', glass: '#3a1b1b', halo: 'rgba(255,255,255,0.5)' },
  { id: 'blue',  body: '#2563b8', edge: '#123566', glass: '#152a44', halo: 'rgba(255,255,255,0.5)' },
];

const COLOR_NAME = { white: 'colorWhite', black: 'colorBlack', red: 'colorRed', blue: 'colorBlue' };

let model = MODELS.find((m) => m.id === localStorage.getItem(MODEL_KEY)) || MODELS[0];
let color = COLORS.find((c) => c.id === localStorage.getItem(COLOR_KEY)) || COLORS[0];

const listeners = [];
/** Called whenever the driver picks a different car, so the map can repaint. */
export function onCarChange(fn) {
  listeners.push(fn);
}

// ── Drawing ──────────────────────────────────────────────────────────────────
const CX = 32, CY = 32;

function bodyPath(m) {
  const fw = m.w * m.nose, tw = m.w * m.tail;
  const y0 = CY - m.l, y1 = CY + m.l, r = m.r;
  return (
    `M${CX - fw} ${y0 + r}` +
    `Q${CX - fw} ${y0} ${CX - fw + r} ${y0}` +
    `L${CX + fw - r} ${y0}` +
    `Q${CX + fw} ${y0} ${CX + fw} ${y0 + r}` +
    `C${CX + m.w} ${CY - m.l * 0.45} ${CX + m.w} ${CY + m.l * 0.35} ${CX + tw} ${y1 - r}` +
    `Q${CX + tw} ${y1} ${CX + tw - r} ${y1}` +
    `L${CX - tw + r} ${y1}` +
    `Q${CX - tw} ${y1} ${CX - tw} ${y1 - r}` +
    `C${CX - m.w} ${CY + m.l * 0.35} ${CX - m.w} ${CY - m.l * 0.45} ${CX - fw} ${y0 + r}Z`
  );
}

/**
 * Top-down car, nose pointing at `heading` degrees clockwise from north.
 * @param {number} heading  0 = north / straight up
 */
/** Headlight and tail-light cluster for one model, front of the car pointing up. */
function lamps(m) {
  const fw = m.w * m.nose, tw = m.w * m.tail;
  const y0 = CY - m.l, y1 = CY + m.l;
  const lamp = (x, y, w, h, fill, rim) =>
    `<rect x="${x.toFixed(1)}" y="${y.toFixed(1)}" width="${w}" height="${h}" rx="${(h / 2).toFixed(1)}" ` +
    `fill="${fill}" stroke="${rim}" stroke-width="0.45"/>`;
  return (
    // spill in front of the bumper and behind the tail
    `<rect x="${(CX - fw + 0.6).toFixed(1)}" y="${(y0 - 1.4).toFixed(1)}" width="${(fw * 2 - 1.2).toFixed(1)}" height="4.6" rx="2.3" fill="#ffd98a" opacity="0.38"/>` +
    `<rect x="${(CX - tw + 0.6).toFixed(1)}" y="${(y1 - 3.2).toFixed(1)}" width="${(tw * 2 - 1.2).toFixed(1)}" height="4.6" rx="2.3" fill="#ff3b30" opacity="0.34"/>` +
    lamp(CX - fw + 1.1, y0 + 0.7, 3.6, 2, '#fff3c4', '#d9a63c') +
    lamp(CX + fw - 4.7, y0 + 0.7, 3.6, 2, '#fff3c4', '#d9a63c') +
    lamp(CX - tw + 1.1, y1 - 2.7, 3.2, 1.9, '#ff5a4f', '#6e0f0a') +
    lamp(CX + tw - 4.3, y1 - 2.7, 3.2, 1.9, '#ff5a4f', '#6e0f0a')
  );
}

export function carSvg(heading = 0, m = model, c = color) {
  const path = bodyPath(m);
  const wheelX = m.w - 0.6, wheelY = m.l * 0.52;
  const wheel = (x, y) =>
    `<rect x="${(CX + x - 1.5).toFixed(1)}" y="${(CY + y - 3.2).toFixed(1)}" width="3" height="6.4" rx="1.4" fill="#15191d" opacity="0.9"/>`;
  return (
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" width="64" height="64">` +
    `<g transform="rotate(${heading.toFixed(0)} ${CX} ${CY})">` +
    // halo first: it is the same outline, stroked wide, so the car never
    // disappears into a road of a similar colour
    `<path d="${path}" fill="none" stroke="${c.halo}" stroke-width="4"/>` +
    wheel(-wheelX, -wheelY) + wheel(wheelX, -wheelY) +
    wheel(-wheelX, wheelY) + wheel(wheelX, wheelY) +
    `<path d="${path}" fill="${c.body}" stroke="${c.edge}" stroke-width="1.4"/>` +
    // Lit lamps: warm white at the front, red at the back. This is what tells
    // the driver which way the car is pointing at 48px, so each lamp is a soft
    // spill (a low-opacity band that overhangs the bumper, drawn first) plus a
    // bright core with a dark rim — the rim is what keeps a white lamp legible
    // on white paint and a red one on red.
    lamps(m) +
    // glass roof
    `<rect x="${(CX - m.gw).toFixed(1)}" y="${(CY + m.gy - m.gl).toFixed(1)}" width="${(m.gw * 2).toFixed(1)}" height="${(m.gl * 2).toFixed(1)}" rx="${(m.gw * 0.6).toFixed(1)}" fill="${c.glass}" opacity="0.9"/>` +
    // mirrors
    `<rect x="${(CX - m.w - 1.8).toFixed(1)}" y="${(CY - m.l * 0.34).toFixed(1)}" width="2.6" height="3.4" rx="1.2" fill="${c.edge}"/>` +
    `<rect x="${(CX + m.w - 0.8).toFixed(1)}" y="${(CY - m.l * 0.34).toFixed(1)}" width="2.6" height="3.4" rx="1.2" fill="${c.edge}"/>` +
    `</g></svg>`
  );
}

// Heading is rounded to 3° before an icon is built: a data URI per GPS fix is
// wasteful, and nobody sees a 3° difference on a 48px car.
const iconCache = new Map();

/** google.maps Icon for the live car marker. */
export function carIcon(heading) {
  const bucket = Math.round((((heading ?? 0) % 360) + 360) % 360 / 3) * 3;
  const key = `${model.id}|${color.id}|${bucket}`;
  let icon = iconCache.get(key);
  if (!icon) {
    icon = {
      url: 'data:image/svg+xml;charset=UTF-8,' + encodeURIComponent(carSvg(bucket)),
      scaledSize: new google.maps.Size(48, 48),
      anchor: new google.maps.Point(24, 24),
    };
    iconCache.set(key, icon);
  }
  return icon;
}

// ── Topbar picker ────────────────────────────────────────────────────────────
function paintBadge() {
  const badge = document.getElementById('car-badge');
  if (badge) badge.innerHTML = carSvg(0);
}

function renderMenu() {
  const menu = document.getElementById('car-menu');
  if (!menu) return;
  menu.innerHTML =
    `<h3 class="car-menu__label">${t('carModel')}</h3>` +
    MODELS.map(
      (m) =>
        `<button type="button" class="car-item${m.id === model.id ? ' is-on' : ''}" data-model="${m.id}">` +
        `<span class="car-item__art">${carSvg(0, m)}</span>` +
        `<span class="car-item__name">${m.name}</span>` +
        `<span class="car-item__tick">${m.id === model.id ? '✓' : ''}</span>` +
        `</button>`,
    ).join('') +
    `<h3 class="car-menu__label">${t('carColor')}</h3>` +
    `<div class="car-colors">` +
    COLORS.map(
      (c) =>
        `<button type="button" class="car-swatch${c.id === color.id ? ' is-on' : ''}" data-color="${c.id}" ` +
        `style="background:${c.body};border-color:${c.edge}" title="${t(COLOR_NAME[c.id])}" ` +
        `aria-label="${t(COLOR_NAME[c.id])}"></button>`,
    ).join('') +
    `</div>`;
}

function pick(nextModel, nextColor) {
  if (nextModel) {
    model = nextModel;
    localStorage.setItem(MODEL_KEY, model.id);
  }
  if (nextColor) {
    color = nextColor;
    localStorage.setItem(COLOR_KEY, color.id);
  }
  iconCache.clear();
  renderMenu();
  paintBadge();
  for (const fn of listeners) fn();
}

/** Re-label the picker after a language switch. */
export function relabelCar() {
  renderMenu();
  const btn = document.getElementById('btn-car');
  if (btn) {
    btn.title = t('carTitle');
    btn.setAttribute('aria-label', t('carTitle'));
  }
}

export function initCarPicker() {
  const btn = document.getElementById('btn-car');
  const menu = document.getElementById('car-menu');
  if (!btn || !menu) return;

  relabelCar();
  paintBadge();

  btn.addEventListener('click', (e) => {
    e.stopPropagation();
    closeTopbarMenus('car-menu');
    const hidden = menu.classList.toggle('is-hidden');
    btn.setAttribute('aria-expanded', String(!hidden));
  });
  // Picking a model and then a colour is one errand, so the menu stays open
  // until the driver taps away from it.
  menu.addEventListener('click', (e) => {
    e.stopPropagation();
    const mBtn = e.target.closest('[data-model]');
    if (mBtn) return pick(MODELS.find((m) => m.id === mBtn.dataset.model), null);
    const cBtn = e.target.closest('[data-color]');
    if (cBtn) return pick(null, COLORS.find((c) => c.id === cBtn.dataset.color));
  });
  document.addEventListener('click', () => {
    menu.classList.add('is-hidden');
    btn.setAttribute('aria-expanded', 'false');
  });
}
