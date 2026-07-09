// Station detail panel + filter drawer.

import { t } from './i18n.js';
import { stationStatus } from './map.js';

const PORT_LABEL = { free: 'statusFree', busy: 'statusBusy', out: 'statusOut' };

// ── Active filters ───────────────────────────────────────────────────────────
export const filters = {
  provider: null, // null = all
  connector: null,
  fastDcOnly: false,
};

export function applyFilters(stations) {
  return stations.filter(
    (s) =>
      (!filters.provider || s.provider === filters.provider) &&
      (!filters.connector || s.connectors.includes(filters.connector)) &&
      (!filters.fastDcOnly || s.isDC),
  );
}

// ── Station panel ────────────────────────────────────────────────────────────
export function showStation(s) {
  const panel = document.getElementById('station-panel');
  const status = stationStatus(s);

  panel.querySelector('.panel__name').textContent = s.name;
  panel.querySelector('.panel__provider').textContent =
    s.provider + (s.city ? ` · ${s.city}` : '');

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
    row.innerHTML =
      `<span class="port__type">${p.type}</span>` +
      `<span class="port__status">${t(PORT_LABEL[p.status] ?? 'statusOut')}</span>`;
    portsEl.appendChild(row);
  }
  if (!s.ports.length) {
    portsEl.innerHTML = `<div class="port"><span class="port__type">${s.connectors.join(
      ', ',
    )}</span><span class="port__status">${s.available}/${s.total}</span></div>`;
  }

  panel.querySelector('.panel__updated').textContent = s.lastUpdated
    ? `${t('updated')}: ${s.lastUpdated}`
    : '';

  panel.classList.add('is-open');
}

export function hideStation() {
  document.getElementById('station-panel').classList.remove('is-open');
}

// ── Filter drawer ────────────────────────────────────────────────────────────
export function buildFilterDrawer(stations, onChange) {
  const providers = [...new Set(stations.map((s) => s.provider).filter(Boolean))].sort();
  const connectors = [...new Set(stations.flatMap((s) => s.connectors))].sort();

  const provEl = document.getElementById('filter-providers');
  const connEl = document.getElementById('filter-connectors');

  const chip = (label, group, value) => {
    const b = document.createElement('button');
    b.className = 'chip';
    b.textContent = label;
    b.dataset.group = group;
    if (value === null) b.dataset.all = '1';
    b.addEventListener('click', () => {
      filters[group] = value;
      syncChips();
      onChange();
    });
    b.__value = value;
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

  const dcToggle = document.getElementById('filter-dc');
  dcToggle.classList.toggle('is-active', filters.fastDcOnly); // survive drawer rebuilds
  dcToggle.onclick = () => {
    filters.fastDcOnly = !filters.fastDcOnly;
    dcToggle.classList.toggle('is-active', filters.fastDcOnly);
    onChange();
  };

  document.getElementById('filter-clear').onclick = () => {
    filters.provider = null;
    filters.connector = null;
    filters.fastDcOnly = false;
    dcToggle.classList.remove('is-active');
    syncChips();
    onChange();
  };

  function syncChips() {
    for (const b of document.querySelectorAll('.chip')) {
      b.classList.toggle('is-active', filters[b.dataset.group] === b.__value);
    }
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
