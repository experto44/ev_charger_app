// Unified search: local charger stations (by name/city) + Google Places
// destinations. Mirrors the app's place autocomplete: biased to where the
// driver is looking, but not restricted to one country — GeoCharge now covers
// Turkey, and a hard country:ge filter meant "İstanbul" returned nothing.

import { getMap } from './map.js';
import { t } from './i18n.js';

let acService = null;
let placesService = null;

function services() {
  if (!acService) acService = new google.maps.places.AutocompleteService();
  if (!placesService) {
    // PlacesService needs a node; a detached div is fine for details lookups.
    placesService = new google.maps.places.PlacesService(document.createElement('div'));
  }
  return { acService, placesService };
}

function placePredictions(query) {
  const { acService: ac } = services();
  // Rank around the map centre so local names still come first at home.
  const centre = getMap()?.getCenter();
  return new Promise((resolve) => {
    ac.getPlacePredictions(
      {
        input: query,
        ...(centre
          ? { location: centre, radius: 300000 } // ~one country wide
          : {}),
      },
      (preds, status) =>
        resolve(status === google.maps.places.PlacesServiceStatus.OK ? preds.slice(0, 5) : []),
    );
  });
}

function resolvePlace(placeId) {
  const { placesService: ps } = services();
  return new Promise((resolve) => {
    ps.getDetails({ placeId, fields: ['geometry', 'name'] }, (res, status) => {
      if (status === google.maps.places.PlacesServiceStatus.OK && res.geometry) {
        resolve({ lat: res.geometry.location.lat(), lng: res.geometry.location.lng(), name: res.name });
      } else {
        resolve(null);
      }
    });
  });
}

function matchStations(query, stations) {
  const q = query.trim().toLowerCase();
  if (q.length < 2) return [];
  return stations
    .filter((s) => s.name.toLowerCase().includes(q) || (s.city || '').toLowerCase().includes(q))
    .slice(0, 6);
}

/**
 * Wire the search input.
 * @param {() => Station[]} getStations
 * @param {(s: Station) => void} onStation  open a station
 * @param {(pos, name) => void} onPlace     a resolved destination was picked
 */
export function initSearch({ getStations, onStation, onPlace }) {
  const input = document.getElementById('search-input');
  const dropdown = document.getElementById('search-results');
  const clearBtn = document.getElementById('search-clear');
  let timer = null;

  const close = () => {
    dropdown.innerHTML = '';
    dropdown.classList.remove('is-open');
  };

  const render = (stations, places) => {
    dropdown.innerHTML = '';
    if (!stations.length && !places.length) {
      close();
      return;
    }
    const addHeader = (label) => {
      const h = document.createElement('div');
      h.className = 'search-group';
      h.textContent = label;
      dropdown.appendChild(h);
    };
    const addRow = (icon, main, sub, onClick) => {
      const row = document.createElement('button');
      row.className = 'search-row';
      row.innerHTML =
        `<span class="search-row__ico">${icon}</span>` +
        `<span class="search-row__txt"><span class="search-row__main">${main}</span>` +
        (sub ? `<span class="search-row__sub">${sub}</span>` : '') +
        `</span>`;
      row.addEventListener('click', () => {
        close();
        input.value = main;
        clearBtn.hidden = false;
        onClick();
      });
      dropdown.appendChild(row);
    };

    if (stations.length) {
      addHeader(t('searchStations'));
      for (const s of stations) {
        addRow('⚡', s.name, `${s.provider}${s.city ? ' · ' + s.city : ''}`, () => onStation(s));
      }
    }
    if (places.length) {
      addHeader(t('searchPlaces'));
      for (const p of places) {
        const sf = p.structured_formatting || {};
        addRow('📍', sf.main_text || p.description, sf.secondary_text || '', async () => {
          const pos = await resolvePlace(p.place_id);
          if (pos) onPlace(pos, sf.main_text || p.description);
        });
      }
    }
    dropdown.classList.add('is-open');
  };

  input.addEventListener('input', () => {
    const q = input.value;
    clearBtn.hidden = !q;
    clearTimeout(timer);
    if (q.trim().length < 2) {
      close();
      return;
    }
    timer = setTimeout(async () => {
      const stations = matchStations(q, getStations());
      const places = await placePredictions(q);
      // Only render if the query hasn't changed since we fired.
      if (input.value === q) render(stations, places);
    }, 300);
  });

  clearBtn.addEventListener('click', () => {
    input.value = '';
    clearBtn.hidden = true;
    close();
  });

  // Close on outside tap.
  document.addEventListener('click', (e) => {
    if (!e.target.closest('#search-box')) close();
  });
}
