// Trip planner UI: origin/destination pickers, battery/range inputs,
// planned route + charging stops rendering.

import { planRoute } from './routing.js';
import { getMap } from './map.js';
import { getStations } from './data.js';
import { t, getLang } from './i18n.js';

const state = {
  origin: null,      // {lat,lng}
  destination: null,
  pickTarget: null,  // 'origin' | 'destination' while map-pick mode is armed
  routeLine: null,
  endMarkers: [],
  stopMarkers: [],
  result: null,
};

const $ = (id) => document.getElementById(id);

function fmtPct(p) { return `${Math.round(p)}%`; }

// ── Map artefacts ────────────────────────────────────────────────────────────
function clearRoute() {
  state.routeLine?.setMap(null);
  state.routeLine = null;
  for (const m of [...state.endMarkers, ...state.stopMarkers]) m.setMap(null);
  state.endMarkers = [];
  state.stopMarkers = [];
  state.result = null;
  $('trip-results').classList.add('is-hidden');
}

function endpointMarker(pos, label) {
  return new google.maps.Marker({
    map: getMap(),
    position: pos,
    zIndex: 2000,
    icon: {
      path: google.maps.SymbolPath.CIRCLE,
      scale: 11,
      fillColor: '#eef3f6',
      fillOpacity: 1,
      strokeColor: '#0d1216',
      strokeWeight: 3,
    },
    label: { text: label, color: '#0d1216', fontSize: '13px', fontWeight: '700' },
  });
}

function stopMarker(pos, n) {
  return new google.maps.Marker({
    map: getMap(),
    position: pos,
    zIndex: 2100,
    icon: {
      path: google.maps.SymbolPath.CIRCLE,
      scale: 13,
      fillColor: '#2bd594',
      fillOpacity: 1,
      strokeColor: '#0d1216',
      strokeWeight: 3,
    },
    label: { text: String(n), color: '#0d1216', fontSize: '14px', fontWeight: '700' },
  });
}

function drawResult(res) {
  clearRoute();
  state.result = res;

  state.routeLine = new google.maps.Polyline({
    map: getMap(),
    path: res.polyline,
    strokeColor: '#2bd594',
    strokeOpacity: 0.9,
    strokeWeight: 5,
  });
  state.endMarkers = [
    endpointMarker(state.origin, 'A'),
    endpointMarker(state.destination, 'B'),
  ];
  res.stops.forEach((s, i) => {
    state.stopMarkers.push(
      stopMarker({ lat: s.station.lat, lng: s.station.lng }, i + 1),
    );
  });

  // Fit the whole route.
  const bounds = new google.maps.LatLngBounds();
  for (const p of res.polyline) bounds.extend(p);
  getMap().fitBounds(bounds, 60);

  renderResults(res);
}

// ── Results panel ────────────────────────────────────────────────────────────
function renderResults(res) {
  const box = $('trip-results');
  box.classList.remove('is-hidden');

  $('trip-summary').innerHTML =
    `<span>${Math.round(res.totalDistanceKm)} km</span>` +
    `<span>${res.stops.length} ${t('tripStops')}</span>` +
    `<span class="${res.batteryAtArrivalPct < 15 ? 'txt-danger' : 'txt-accent'}">` +
    `${t('tripArrival')} ${fmtPct(res.batteryAtArrivalPct)}</span>`;

  $('trip-warning').classList.toggle('is-hidden', res.reachable);

  const list = $('trip-stops');
  list.innerHTML = '';
  res.stops.forEach((s, i) => {
    const el = document.createElement('div');
    el.className = 'stop-card';
    const side =
      s.requiresUTurn ? `<span class="stop-card__uturn">${t('tripUTurn')}</span>` : '';
    const charge =
      s.chargeHours != null
        ? `<span>~${(s.chargeHours * 60).toFixed(0)} ${t('tripMin')} AC</span>`
        : '';
    el.innerHTML =
      `<div class="stop-card__n">${i + 1}</div>` +
      `<div class="stop-card__body">` +
      `<div class="stop-card__name">${s.station.name}</div>` +
      `<div class="stop-card__meta">${s.station.provider}` +
      ` · ${Math.round(s.distanceFromStartKm)} km` +
      ` · ${t('tripBattery')} ${fmtPct(s.batteryOnArrivalPct)}` +
      `${charge ? ' · ' + charge : ''}${side}</div>` +
      `</div>`;
    list.appendChild(el);
  });
}

// ── Inputs ───────────────────────────────────────────────────────────────────
function attachAutocomplete(inputId, assign) {
  const ac = new google.maps.places.Autocomplete($(inputId), {
    componentRestrictions: { country: 'ge' },
    fields: ['geometry', 'name'],
  });
  ac.addListener('place_changed', () => {
    const g = ac.getPlace()?.geometry?.location;
    if (g) assign({ lat: g.lat(), lng: g.lng() });
  });
}

function armMapPick(target) {
  state.pickTarget = target;
  document.body.classList.add('is-picking');
}

function handleMapClick(e) {
  if (!state.pickTarget) return;
  const pos = { lat: e.latLng.lat(), lng: e.latLng.lng() };
  const input = $(state.pickTarget === 'origin' ? 'trip-origin' : 'trip-dest');
  input.value = `${pos.lat.toFixed(4)}, ${pos.lng.toFixed(4)}`;
  if (state.pickTarget === 'origin') state.origin = pos;
  else state.destination = pos;
  state.pickTarget = null;
  document.body.classList.remove('is-picking');
}

async function plan() {
  if (!state.origin || !state.destination) return;
  const btn = $('trip-plan');
  btn.disabled = true;
  btn.textContent = t('tripPlanning');
  try {
    const res = await planRoute({
      waypoints: [state.origin, state.destination],
      currentBatteryPct: Number($('trip-battery').value),
      maxRangeKm: Number($('trip-range').value) || 300,
      stations: getStations(),
    });
    if (res) drawResult(res);
    else {
      $('trip-results').classList.remove('is-hidden');
      $('trip-summary').innerHTML = `<span class="txt-danger">${t('tripNoRoute')}</span>`;
      $('trip-stops').innerHTML = '';
      $('trip-warning').classList.add('is-hidden');
    }
  } finally {
    btn.disabled = false;
    btn.textContent = t('tripPlan');
  }
}

// ── Public wiring ────────────────────────────────────────────────────────────
/** Call once after the map exists. */
export function initTrip() {
  attachAutocomplete('trip-origin', (pos) => (state.origin = pos));
  attachAutocomplete('trip-dest', (pos) => (state.destination = pos));
  getMap().addListener('click', handleMapClick);

  $('trip-pick-origin').addEventListener('click', () => armMapPick('origin'));
  $('trip-pick-dest').addEventListener('click', () => armMapPick('destination'));

  const battery = $('trip-battery');
  battery.addEventListener('input', () => {
    $('trip-battery-val').textContent = `${battery.value}%`;
  });

  const range = $('trip-range');
  range.value = localStorage.getItem('gc_range') || 300;
  range.addEventListener('change', () => localStorage.setItem('gc_range', range.value));

  $('trip-plan').addEventListener('click', plan);
  $('trip-clear').addEventListener('click', () => {
    clearRoute();
    state.origin = null;
    state.destination = null;
    $('trip-origin').value = '';
    $('trip-dest').value = '';
  });
}

export function toggleTripDrawer(open) {
  $('trip-drawer').classList.toggle('is-open', open);
}

export function isTripOpen() {
  return $('trip-drawer').classList.contains('is-open');
}

/** Debug/testing: set endpoints directly (same effect as picking them). */
export function setTripPoints(origin, destination) {
  state.origin = origin;
  state.destination = destination;
  $('trip-origin').value = `${origin.lat.toFixed(4)}, ${origin.lng.toFixed(4)}`;
  $('trip-dest').value = `${destination.lat.toFixed(4)}, ${destination.lng.toFixed(4)}`;
}
