// Station detail panel + filter drawer.

import { t } from './i18n.js';
import { stationStatus } from './map.js';
import { busyForLabel, formatVerified, providerLogo } from './format.js';
import { startDrive } from './drive.js';
import { track } from './analytics.js';

const PORT_LABEL = { free: 'statusFree', busy: 'statusBusy', out: 'statusOut' };

// Shared with the app: canonical connector order + minimum-power presets.
export const CONNECTOR_ORDER = ['CCS2', 'GB/T', 'CHAdeMO', 'Type 2', 'NACS', 'CCS1', 'Type 1'];
export const MIN_POWER_STEPS = [22, 50, 60, 100, 150];

/** Sort connector labels by CONNECTOR_ORDER; unknown types last, A→Z. */
export function sortConnectors(list) {
  const rank = (c) => {
    const i = CONNECTOR_ORDER.indexOf(c);
    return i === -1 ? CONNECTOR_ORDER.length : i;
  };
  return [...list].sort((a, b) => rank(a) - rank(b) || a.localeCompare(b));
}

// ── Active filters (persisted, unlike the app — the driver wants them to stick) ─
const FILTERS_KEY = 'gc_tesla_filters';
export const filters = {
  provider: null,      // null = all
  connector: null,     // null = all
  fastDcOnly: false,
  availableOnly: false, // free/busy status filter
  minKw: 0,            // 0 = any power
};

(function loadFilters() {
  try {
    Object.assign(filters, JSON.parse(localStorage.getItem(FILTERS_KEY) || '{}'));
  } catch (_) {/* corrupt value — keep defaults */}
})();

function saveFilters() {
  try {
    localStorage.setItem(FILTERS_KEY, JSON.stringify(filters));
  } catch (_) {/* storage unavailable — filters just won't persist */}
}

export function applyFilters(stations) {
  const ci = filters.connector?.toLowerCase();
  return stations.filter(
    (s) =>
      (!filters.provider || s.provider === filters.provider) &&
      (!ci || s.connectors.some((c) => c.toLowerCase() === ci)) &&
      (!filters.fastDcOnly || s.isDC) &&
      (!filters.availableOnly || s.available > 0) &&
      // Min power: hide only rated chargers below the threshold (kw==0 kept).
      !(filters.minKw > 0 && s.kw > 0 && s.kw < filters.minKw),
  );
}

// ── Station panel ────────────────────────────────────────────────────────────
export function showStation(s) {
  const panel = document.getElementById('station-panel');
  const status = stationStatus(s);

  panel.querySelector('.panel__name').textContent = s.name;
  panel.querySelector('.panel__provider').textContent =
    s.provider + (s.city ? ` · ${s.city}` : '');

  // Provider logo (hidden when the provider has no asset, e.g. International).
  const logo = panel.querySelector('.panel__logo');
  const logoSrc = providerLogo(s.provider);
  if (logoSrc) {
    logo.src = logoSrc;
    logo.hidden = false;
  } else {
    logo.hidden = true;
    logo.removeAttribute('src');
  }

  // Navigate → in-browser turn-by-turn drive mode.
  const navBtn = panel.querySelector('.panel__nav');
  navBtn.onclick = () => {
    track('navigate_station', { provider: s.provider });
    hideStation();
    startDrive({ destination: { lat: s.lat, lng: s.lng } });
  };

  const badge = panel.querySelector('.panel__status');
  badge.textContent = t(PORT_LABEL[status]);
  badge.className = `panel__status status--${status}`;

  panel.querySelector('.panel__power').textContent =
    s.kw ? `${s.kw} kW ${s.isDC ? 'DC' : 'AC'}` : '—';
  panel.querySelector('.panel__price').textContent = s.price || '—';

  const portsEl = panel.querySelector('.panel__ports');
  portsEl.innerHTML = '';
  for (const p of s.ports) {
    const row = document.createElement('div');
    row.className = `port port--${p.status}`;
    // Busy ports show how long the car has been charging (bucketed like the app).
    const busy = p.status === 'busy' ? busyForLabel(p.since) : null;
    const sub = busy ? `<span class="port__sub">${busy}</span>` : '';
    row.innerHTML =
      `<span class="port__type">${p.type}</span>` +
      `<span class="port__right">` +
      `<span class="port__status">${t(PORT_LABEL[p.status] ?? 'statusOut')}</span>` +
      sub +
      `</span>`;
    portsEl.appendChild(row);
  }
  if (!s.ports.length) {
    portsEl.innerHTML = `<div class="port"><span class="port__type">${s.connectors.join(
      ', ',
    )}</span><span class="port__status">${s.available}/${s.total}</span></div>`;
  }

  panel.querySelector('.panel__updated').textContent = s.lastUpdated
    ? `${t('updated')}: ${formatVerified(s.lastUpdated)}`
    : '';

  panel.classList.add('is-open');
}

export function hideStation() {
  document.getElementById('station-panel').classList.remove('is-open');
}

// ── Filter drawer ────────────────────────────────────────────────────────────
export function buildFilterDrawer(stations, onChange) {
  const providers = [...new Set(stations.map((s) => s.provider).filter(Boolean))].sort();
  const connectors = sortConnectors([...new Set(stations.flatMap((s) => s.connectors))]);

  const provEl = document.getElementById('filter-providers');
  const connEl = document.getElementById('filter-connectors');
  const powerEl = document.getElementById('filter-powers');

  const notify = () => {
    saveFilters();
    onChange();
  };

  const chip = (label, group, value) => {
    const b = document.createElement('button');
    b.className = 'chip';
    b.textContent = label;
    b.dataset.group = group;
    b.__value = value;
    b.addEventListener('click', () => {
      filters[group] = value;
      syncChips();
      notify();
    });
    return b;
  };

  provEl.replaceChildren(
    chip(t('allProviders'), 'provider', null),
    ...providers.map((p) => chip(p, 'provider', p)),
  );
  connEl.replaceChildren(
    chip(t('allConnectors'), 'connector', null),
    ...connectors.map((c) => chip(c, 'connector', c)),
  );
  powerEl.replaceChildren(
    chip(t('anyPower'), 'minKw', 0),
    ...MIN_POWER_STEPS.map((kw) => chip(`${kw} kW`, 'minKw', kw)),
  );

  const dcToggle = document.getElementById('filter-dc');
  dcToggle.onclick = () => {
    filters.fastDcOnly = !filters.fastDcOnly;
    dcToggle.classList.toggle('is-active', filters.fastDcOnly);
    notify();
  };

  const availToggle = document.getElementById('filter-avail');
  availToggle.onclick = () => {
    filters.availableOnly = !filters.availableOnly;
    availToggle.classList.toggle('is-active', filters.availableOnly);
    notify();
  };

  document.getElementById('filter-clear').onclick = () => {
    filters.provider = null;
    filters.connector = null;
    filters.fastDcOnly = false;
    filters.availableOnly = false;
    filters.minKw = 0;
    syncChips();
    notify();
  };

  function syncChips() {
    for (const b of document.querySelectorAll('.chip')) {
      b.classList.toggle('is-active', filters[b.dataset.group] === b.__value);
    }
    dcToggle.classList.toggle('is-active', filters.fastDcOnly);
    availToggle.classList.toggle('is-active', filters.availableOnly);
  }
  syncChips();
}

export function toggleFilterDrawer(open) {
  document.getElementById('filter-drawer').classList.toggle('is-open', open);
}

// ── Small helpers ────────────────────────────────────────────────────────────
export function setCount(n) {
  document.getElementById('station-count').textContent = `${n} ${t('stationsShown')}`;
}

export function showToast(msg, ms = 5000) {
  const el = document.getElementById('toast');
  el.textContent = msg;
  el.classList.add('is-visible');
  clearTimeout(el.__t);
  el.__t = setTimeout(() => el.classList.remove('is-visible'), ms);
}

export function hideToast() {
  const el = document.getElementById('toast');
  clearTimeout(el.__t);
  el.classList.remove('is-visible');
}
