// Trip planner — mirrors the mobile RoutePlannerScreen: up to 5 reorderable
// stops, per-trip connector + min-power filters, tickable charging-option
// blocks with live battery-on-arrival, and "start navigation" to Google Maps.

import { planRoute } from './routing.js';
import { getMap, panTo, setMarkersDimmed, locateMe } from './map.js';
import { getStations } from './data.js';
import { startDrive } from './drive.js';
import { track } from './analytics.js';
import { MIN_POWER_STEPS, sortConnectors } from './ui.js';
import { providerLogo } from './format.js';
import { t } from './i18n.js';

const $ = (id) => document.getElementById(id);
const RANGE_KEY = 'gc_range';

const STOP_DOT = { origin: '#2bd594', mid: '#2196F3', dest: '#FF6B6B' };

const state = {
  stops: [{ coords: null, label: '' }, { coords: null, label: '' }],
  batteryPct: 80,
  maxRangeKm: Number(localStorage.getItem(RANGE_KEY)) || 300,
  connectors: new Set(), // per-trip, reset on open
  minKw: 0,
  pickTarget: null,      // stop index awaiting a map tap
  result: null,
  selectedKeys: new Set(),
  expandedSegments: new Set(), // which 50 km segments are open in the list
  signature: null,
  debounce: null,
  // map artefacts
  routeLine: null,
  endMarkers: [],
  stopMarkers: [],
  autocompletes: [],     // google Autocomplete per input (rebuilt on render)
};

// ── Helpers ──────────────────────────────────────────────────────────────────
function stopRole(i) {
  if (i === 0) return 'origin';
  if (i === state.stops.length - 1) return 'dest';
  return 'mid';
}

function stopLabel(i) {
  if (i === 0) return t('tripFrom');
  if (i === state.stops.length - 1) return t('tripTo');
  return `${t('tripStopN')} ${i}`;
}

function resolvedStops() {
  return state.stops.map((s) => s.coords).filter(Boolean);
}

function canPlan() {
  return state.stops[0].coords && state.stops[state.stops.length - 1].coords;
}

function tripFilteredStations() {
  const conns = [...state.connectors].map((c) => c.toLowerCase());
  return getStations().filter((s) => {
    if (conns.length && !s.connectors.some((c) => conns.includes(c.toLowerCase()))) return false;
    if (state.minKw > 0 && s.kw > 0 && s.kw < state.minKw) return false;
    return true;
  });
}

// ── Stop rows ────────────────────────────────────────────────────────────────
function renderStops() {
  const wrap = $('trip-stops');
  wrap.innerHTML = '';
  state.autocompletes = [];

  state.stops.forEach((stop, i) => {
    const role = stopRole(i);
    const row = document.createElement('div');
    row.className = 'trip-stop';
    row.innerHTML =
      `<span class="trip-stop__dot" style="background:${STOP_DOT[role]}"></span>` +
      `<input class="trip-stop__input input" type="text" autocomplete="off">` +
      `<div class="trip-stop__actions"></div>`;

    const input = row.querySelector('.trip-stop__input');
    input.placeholder = stopLabel(i);
    input.value = stop.label;

    // Places autocomplete on this input.
    const ac = new google.maps.places.Autocomplete(input, {
      componentRestrictions: { country: 'ge' },
      fields: ['geometry', 'name'],
    });
    ac.addListener('place_changed', () => {
      const g = ac.getPlace()?.geometry?.location;
      if (g) {
        stop.coords = { lat: g.lat(), lng: g.lng() };
        stop.label = input.value;
        scheduleCompute();
      }
    });
    state.autocompletes.push(ac);

    const actions = row.querySelector('.trip-stop__actions');
    const iconBtn = (svg, title, onClick) => {
      const b = document.createElement('button');
      b.className = 'trip-stop__btn';
      b.title = title;
      b.innerHTML = svg;
      b.addEventListener('click', onClick);
      actions.appendChild(b);
    };

    if (i === 0) {
      iconBtn(
        '<svg viewBox="0 0 24 24" width="18" height="18"><path fill="currentColor" d="M12 8a4 4 0 100 8 4 4 0 000-8zm8.94 3A8.994 8.994 0 0013 3.06V1h-2v2.06A8.994 8.994 0 003.06 11H1v2h2.06A8.994 8.994 0 0011 20.94V23h2v-2.06A8.994 8.994 0 0020.94 13H23v-2h-2.06zM12 19a7 7 0 110-14 7 7 0 010 14z"/></svg>',
        t('tripMyLocation'),
        async () => {
          try {
            const pos = await locateMe({ center: false });
            stop.coords = pos;
            stop.label = t('tripMyLocation');
            input.value = stop.label;
            scheduleCompute();
          } catch (_) {/* ignore; user can type instead */}
        },
      );
    }
    // Pick on map.
    iconBtn(
      '<svg viewBox="0 0 24 24" width="18" height="18"><path fill="currentColor" d="M12 2C8 2 5 5 5 9c0 5 7 13 7 13s7-8 7-13c0-4-3-7-7-7zm0 9.5A2.5 2.5 0 1112 6a2.5 2.5 0 010 5.5z"/></svg>',
      t('tripPickOnMap'),
      () => armMapPick(i),
    );
    if (i > 0) {
      iconBtn('<span class="trip-stop__ar">↑</span>', 'up', () => moveStop(i, -1));
    }
    if (i < state.stops.length - 1) {
      iconBtn('<span class="trip-stop__ar">↓</span>', 'down', () => moveStop(i, 1));
    }
    if (state.stops.length > 2) {
      iconBtn('<span class="trip-stop__ar">✕</span>', 'remove', () => removeStop(i));
    }

    wrap.appendChild(row);
  });

  $('trip-add-stop').classList.toggle('is-hidden', state.stops.length >= 5);
}

function addStop() {
  if (state.stops.length >= 5) return;
  state.stops.push({ coords: null, label: '' });
  renderStops();
  scheduleCompute();
}

function removeStop(i) {
  state.stops.splice(i, 1);
  renderStops();
  scheduleCompute();
}

function moveStop(i, dir) {
  const j = i + dir;
  if (j < 0 || j >= state.stops.length) return;
  [state.stops[i], state.stops[j]] = [state.stops[j], state.stops[i]];
  renderStops();
  scheduleCompute();
}

function armMapPick(i) {
  state.pickTarget = i;
  document.body.classList.add('is-picking');
}

function handleMapClick(e) {
  if (state.pickTarget == null) return;
  const pos = { lat: e.latLng.lat(), lng: e.latLng.lng() };
  const stop = state.stops[state.pickTarget];
  stop.coords = pos;
  stop.label = `${pos.lat.toFixed(4)}, ${pos.lng.toFixed(4)}`;
  state.pickTarget = null;
  document.body.classList.remove('is-picking');
  renderStops();
  scheduleCompute();
}

// ── Per-trip filter chips ────────────────────────────────────────────────────
function renderFilters() {
  const connEl = $('trip-connectors');
  const powerEl = $('trip-powers');
  const present = sortConnectors([...new Set(getStations().flatMap((s) => s.connectors))]);

  connEl.innerHTML = '';
  for (const c of present) {
    const b = document.createElement('button');
    b.className = 'chip';
    b.textContent = c;
    b.classList.toggle('is-active', state.connectors.has(c));
    b.addEventListener('click', () => {
      if (!state.connectors.delete(c)) state.connectors.add(c);
      b.classList.toggle('is-active', state.connectors.has(c));
      scheduleCompute();
    });
    connEl.appendChild(b);
  }

  powerEl.innerHTML = '';
  const powerChip = (label, kw) => {
    const b = document.createElement('button');
    b.className = 'chip';
    b.textContent = label;
    b.classList.toggle('is-active', state.minKw === kw);
    b.addEventListener('click', () => {
      state.minKw = kw;
      for (const el of powerEl.children) el.classList.remove('is-active');
      b.classList.add('is-active');
      scheduleCompute();
    });
    powerEl.appendChild(b);
  };
  powerChip(t('anyPower'), 0);
  for (const kw of MIN_POWER_STEPS) powerChip(`${kw} kW`, kw);
}

// ── Route computation (debounced) ────────────────────────────────────────────
function scheduleCompute() {
  clearTimeout(state.debounce);
  updateNavButton();
  if (!canPlan()) {
    state.result = null;
    clearRoute();
    renderPreview();
    renderOptions();
    return;
  }
  state.debounce = setTimeout(compute, 500);
}

async function compute() {
  if (!canPlan()) return;
  const res = await planRoute({
    waypoints: resolvedStops(),
    currentBatteryPct: state.batteryPct,
    maxRangeKm: state.maxRangeKm,
    stations: tripFilteredStations(),
  });
  state.result = res;
  if (!res) {
    clearRoute();
    renderPreview();
    renderOptions();
    return;
  }

  // Reseed ticks from the recommendation when the route/filters change;
  // keep manual ticks on a battery-only nudge (same signature).
  const wpSig = state.stops
    .map((s) => (s.coords ? `${s.coords.lat},${s.coords.lng}` : '-'))
    .join('|');
  const sig = `${wpSig}#${[...state.connectors].sort().join(',')}#${state.minKw}`;
  const valid = new Set(res.options.map((o) => o.locationKey));
  if (sig !== state.signature) {
    state.signature = sig;
    state.selectedKeys = new Set(res.options.filter((o) => o.recommended).map((o) => o.locationKey));
  } else {
    state.selectedKeys = new Set([...state.selectedKeys].filter((k) => valid.has(k)));
  }

  drawRoute();
  renderPreview();
  renderOptions();
}

// Battery % at a point, resetting to full at each ticked charger passed.
function arrivalPctAt(alongKm) {
  const r = state.result;
  const eff = r.effectiveRangeKm;
  if (eff <= 0) return 0;
  let anchorAlong = 0;
  let anchorRange = (state.batteryPct / 100) * eff;
  for (const o of r.options) {
    if (o.alongKm >= alongKm) break;
    if (state.selectedKeys.has(o.locationKey)) {
      anchorAlong = o.alongKm;
      anchorRange = eff;
    }
  }
  return Math.min(100, Math.max(0, ((anchorRange - (alongKm - anchorAlong)) / eff) * 100));
}

// ── Map drawing ──────────────────────────────────────────────────────────────
function clearRoute() {
  state.routeLine?.setMap(null);
  state.routeLine = null;
  for (const m of [...state.endMarkers, ...state.stopMarkers]) m.setMap(null);
  state.endMarkers = [];
  state.stopMarkers = [];
  setMarkersDimmed(false);
}

function endpointMarker(pos, label, color) {
  return new google.maps.Marker({
    map: getMap(),
    position: pos,
    zIndex: 2200,
    icon: {
      path: google.maps.SymbolPath.CIRCLE,
      scale: 11,
      fillColor: color,
      fillOpacity: 1,
      strokeColor: '#0d1216',
      strokeWeight: 3,
    },
    label: { text: label, color: '#0d1216', fontSize: '13px', fontWeight: '700' },
  });
}

// Ticked charging stops — deliberately loud (blue, large, numbered) so they
// stand out from the dimmed charger layer.
function stopMarker(pos, n) {
  return new google.maps.Marker({
    map: getMap(),
    position: pos,
    zIndex: 2300,
    icon: {
      path: google.maps.SymbolPath.CIRCLE,
      scale: 15,
      fillColor: '#2196F3',
      fillOpacity: 1,
      strokeColor: '#ffffff',
      strokeWeight: 3,
    },
    label: { text: String(n), color: '#ffffff', fontSize: '14px', fontWeight: '700' },
  });
}

function drawRoute() {
  clearRoute();
  const r = state.result;
  if (!r) return;

  setMarkersDimmed(true); // fade the charger layer so stops read clearly

  state.routeLine = new google.maps.Polyline({
    map: getMap(),
    path: r.polyline,
    strokeColor: '#2bd594',
    strokeOpacity: 0.95,
    strokeWeight: 5,
    zIndex: 2000,
  });

  // Endpoints + manual intermediate stops.
  state.stops.forEach((s, i) => {
    if (!s.coords) return;
    const role = stopRole(i);
    const label = role === 'origin' ? 'A' : role === 'dest' ? 'B' : String(i);
    state.endMarkers.push(endpointMarker(s.coords, label, STOP_DOT[role]));
  });

  // Ticked charging stops, numbered in along-route order.
  const ticked = r.options
    .filter((o) => state.selectedKeys.has(o.locationKey))
    .sort((a, b) => a.alongKm - b.alongKm);
  ticked.forEach((o, i) => state.stopMarkers.push(stopMarker(o.location, i + 1)));

  const bounds = new google.maps.LatLngBounds();
  for (const p of r.polyline) bounds.extend(p);
  getMap().fitBounds(bounds, 80);
}

// ── Panels ───────────────────────────────────────────────────────────────────
function renderPreview() {
  const box = $('trip-preview');
  const r = state.result;
  if (!r) {
    box.innerHTML = `<span class="txt-dim">${t('tripSetStops')}</span>`;
    $('trip-warning').classList.add('is-hidden');
    return;
  }
  const arrival = arrivalPctAt(r.totalDistanceKm);
  const stopsN = state.selectedKeys.size;
  box.innerHTML =
    `<span>${Math.round(r.totalDistanceKm)} km</span>` +
    `<span>${stopsN} ${t('tripStops')}</span>` +
    `<span class="${arrival < 15 ? 'txt-danger' : 'txt-accent'}">${t('tripArrival')} ${Math.round(arrival)}%</span>`;
  $('trip-warning').classList.toggle('is-hidden', r.reachable);
}

// One detailed charger block (inside an expanded segment).
function optionBlockEl(o) {
  const sel = state.selectedKeys.has(o.locationKey);
  const arrival = Math.round(arrivalPctAt(o.alongKm));
  const el = document.createElement('div');
  el.className = 'opt-block' + (sel ? ' is-selected' : '');

  const providerLines = o.providerPowers
    .map(
      (pp) =>
        `<div class="opt-prov"><span>${pp.name}</span>${pp.power ? `<b>${pp.power}</b>` : ''}</div>`,
    )
    .join('');
  // Provider logo(s) on the right — which company operates this charger.
  const logos = o.providerPowers
    .map((pp) => providerLogo(pp.name))
    .filter(Boolean)
    .map((src) => `<img class="opt-logo__img" src="${src}" alt="">`)
    .join('');

  const badges =
    (o.recommended ? `<span class="opt-badge">${t('recommended')}</span>` : '') +
    (o.requiresUTurn ? `<span class="opt-uturn" title="${t('uTurnInfo')}">⤴</span>` : '');

  // connectors · [N stations ·] N ports · X/Y free · arrival%
  const metaParts = [];
  if (o.connectorTypes.length) metaParts.push(o.connectorTypes.join(', '));
  if (o.stationCount > 1) metaParts.push(`${o.stationCount} ${t('tripStationsUnit')}`);
  metaParts.push(`${o.chargerCount} ${t('tripPortsUnit')}`);
  const availClass = o.availableCount > 0 ? 'txt-accent' : 'txt-busy';
  const meta =
    metaParts.join(' · ') +
    ` · <span class="${availClass}">${o.availableCount}/${o.chargerCount} ${t('tripFreeUnit')}</span>` +
    ` · <span class="${arrival < 15 ? 'txt-danger' : 'txt-accent'}">${arrival}%</span>`;

  el.innerHTML =
    `<div class="opt-tick">${sel ? '✓' : ''}</div>` +
    `<div class="opt-body">` +
    `<div class="opt-title">${o.title}${badges}</div>` +
    providerLines +
    `<div class="opt-meta">${meta}</div>` +
    `</div>` +
    (logos ? `<div class="opt-logo">${logos}</div>` : '');
  el.addEventListener('click', () => toggleOption(o.locationKey));
  return el;
}

// Charger list, grouped into 50 km collapsible segments. A collapsed segment
// header shows whether a recommended / ticked stop sits inside (✓ + name), so
// the driver knows which one to open. Expanding reveals the detailed blocks.
function renderOptions() {
  const list = $('trip-options');
  const title = $('trip-options-title');
  list.innerHTML = '';
  const r = state.result;
  if (!r || !r.options.length) {
    title.classList.add('is-hidden');
    if (r && !r.options.length) {
      list.innerHTML = `<p class="txt-dim trip-none">${t('tripNoChargers')}</p>`;
    }
    return;
  }
  title.classList.remove('is-hidden');

  const hint = document.createElement('p');
  hint.className = 'txt-dim trip-seg-hint';
  hint.textContent = t('tripSegmentsHint');
  list.appendChild(hint);

  // Group options into consecutive 50 km windows.
  const segMap = new Map();
  for (const o of r.options) {
    const k = Math.floor(o.alongKm / 50);
    if (!segMap.has(k)) segMap.set(k, []);
    segMap.get(k).push(o);
  }

  for (const k of [...segMap.keys()].sort((a, b) => a - b)) {
    const items = segMap.get(k);
    const startKm = k * 50;
    const endKm = startKm + 50;
    const selectedItems = items.filter((o) => state.selectedKeys.has(o.locationKey));
    const hasSelected = selectedItems.length > 0;
    const open = state.expandedSegments.has(k);

    const seg = document.createElement('div');
    seg.className =
      'seg' + (hasSelected ? ' has-selected' : '') + (open ? ' is-open' : '');

    const sub = hasSelected
      ? `<div class="seg__sub">✓ ${selectedItems.map((o) => o.title).join(', ')}</div>`
      : `<div class="seg__sub txt-dim">${items.length} ${t('tripChargers')}</div>`;
    const badge = hasSelected
      ? `<span class="seg__badge">✓ ${selectedItems.length}</span>`
      : `<span class="seg__count txt-dim">${items.length} ${t('tripChargers')}</span>`;

    const head = document.createElement('div');
    head.className = 'seg__head';
    head.innerHTML =
      `<span class="seg__chev">▸</span>` +
      `<div class="seg__title">` +
      `<div class="seg__range">${startKm}–${endKm} ${t('tripKmUnit')}</div>` +
      sub +
      `</div>` +
      badge;
    head.addEventListener('click', () => {
      if (state.expandedSegments.has(k)) state.expandedSegments.delete(k);
      else state.expandedSegments.add(k);
      renderOptions();
    });
    seg.appendChild(head);

    if (open) {
      const body = document.createElement('div');
      body.className = 'seg__body';
      items.forEach((o, i) => {
        if (i > 0) {
          const gap = document.createElement('div');
          gap.className = 'opt-divider';
          gap.innerHTML =
            `<span>↓ ${Math.round(o.alongKm - items[i - 1].alongKm)} ${t('tripKmUnit')}</span>`;
          body.appendChild(gap);
        }
        body.appendChild(optionBlockEl(o));
      });
      seg.appendChild(body);
    }
    list.appendChild(seg);
  }
}

function toggleOption(key) {
  if (!state.selectedKeys.delete(key)) state.selectedKeys.add(key);
  drawRoute();
  renderPreview();
  renderOptions();
}

/** Full reset: stops, result, ticks, and the drawn route. */
function clearPlan() {
  clearTimeout(state.debounce);
  state.stops = [{ coords: null, label: '' }, { coords: null, label: '' }];
  state.result = null;
  state.signature = null;
  state.selectedKeys.clear();
  state.expandedSegments.clear();
  if (state.pickTarget != null) {
    state.pickTarget = null;
    document.body.classList.remove('is-picking');
  }
  clearRoute();
  renderStops();
  renderPreview();
  renderOptions();
  updateNavButton();
}

// ── Start navigation ─────────────────────────────────────────────────────────
function updateNavButton() {
  $('trip-nav').disabled = !canPlan();
}

function startNavigation() {
  const r = state.result;
  const destination = state.stops[state.stops.length - 1].coords;
  if (!canPlan()) return;

  // Interleave manual intermediate stops (by leg-end distance) and ticked
  // chargers (by along-route distance) — the app's _planRoute ordering. The
  // origin is the driver's live GPS (added inside startDrive), not stop 0.
  const entries = [];
  if (r && r.legEndsKm.length) {
    for (let i = 1; i < state.stops.length - 1; i++) {
      if (state.stops[i].coords) entries.push([r.legEndsKm[i - 1], state.stops[i].coords]);
    }
    for (const o of r.options) {
      if (state.selectedKeys.has(o.locationKey)) entries.push([o.alongKm, o.location]);
    }
  } else {
    for (let i = 1; i < state.stops.length - 1; i++) {
      if (state.stops[i].coords) entries.push([i, state.stops[i].coords]);
    }
  }
  entries.sort((a, b) => a[0] - b[0]);

  track('trip_navigate', { stops: state.selectedKeys.size });
  toggleTripDrawer(false);
  startDrive({ destination, waypoints: entries.map((e) => e[1]) });
}

// ── Public wiring ────────────────────────────────────────────────────────────
let inited = false;
export function initTrip() {
  inited = true;
  renderStops();
  renderFilters();
  getMap().addListener('click', handleMapClick);

  const battery = $('trip-battery');
  battery.addEventListener('input', () => {
    state.batteryPct = Number(battery.value);
    $('trip-battery-val').textContent = `${battery.value}%`;
    scheduleCompute();
  });

  const range = $('trip-range');
  range.value = state.maxRangeKm;
  range.addEventListener('change', () => {
    state.maxRangeKm = Number(range.value) || 300;
    localStorage.setItem(RANGE_KEY, state.maxRangeKm);
    scheduleCompute();
  });

  $('trip-add-stop').addEventListener('click', addStop);
  $('trip-nav').addEventListener('click', startNavigation);
  $('trip-clear-route').addEventListener('click', clearPlan);

  // Drive mode draws its own route line — take the planner preview off the
  // map so the two don't overlap (and don't linger after "End").
  document.addEventListener('gc:drive-start', clearRoute);

  renderPreview();
  updateNavButton();
}

export function toggleTripDrawer(open) {
  $('trip-drawer').classList.toggle('is-open', open);
  if (open) {
    // Per-trip filters reset each time the planner opens (matches the app).
    state.connectors.clear();
    state.minKw = 0;
    renderFilters();
  } else if (state.pickTarget != null) {
    state.pickTarget = null;
    document.body.classList.remove('is-picking');
  }
}

export function isTripOpen() {
  return $('trip-drawer').classList.contains('is-open');
}

/** Re-render dynamic trip content after a language switch (no-op pre-init). */
export function relabelTrip() {
  if (!inited) return;
  renderStops();
  renderFilters();
  renderPreview();
  renderOptions();
}

/** Prefill just the destination (from search "route here"). */
export function setTripDestination(pos) {
  state.stops[state.stops.length - 1].coords = pos;
  state.stops[state.stops.length - 1].label = `${pos.lat.toFixed(4)}, ${pos.lng.toFixed(4)}`;
  renderStops();
  scheduleCompute();
}

/** Debug/testing helper: set origin + destination directly. */
export function setTripPoints(origin, destination) {
  state.stops = [
    { coords: origin, label: `${origin.lat.toFixed(4)}, ${origin.lng.toFixed(4)}` },
    { coords: destination, label: `${destination.lat.toFixed(4)}, ${destination.lng.toFixed(4)}` },
  ];
  renderStops();
  scheduleCompute();
}

/** Debug/testing helper. */
export function tripState() {
  return state;
}
