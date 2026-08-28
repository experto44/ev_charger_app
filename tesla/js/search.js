// Unified search: local charger stations (by name/city) + Google Places
// destinations. Mirrors the app's place autocomplete: biased to where the
// driver is looking, but not restricted to one country — GeoCharge now covers
// Turkey, and a hard country:ge filter meant "İstanbul" returned nothing.

import { getMap } from './map.js';
import { t } from './i18n.js';

let acService = null;
let placesService = null;
// One session token ties a keystroke burst to the Place Details call that ends
// it, so Google bills the whole search once instead of per prediction request.
let sessionToken = null;

function token() {
  if (!sessionToken) sessionToken = new google.maps.places.AutocompleteSessionToken();
  return sessionToken;
}

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
        sessionToken: token(),
        ...(centre
          ? { location: centre, radius: 300000 } // ~one country wide
          : {}),
      },
      (preds, status) =>
        resolve(status === google.maps.places.PlacesServiceStatus.OK ? preds.slice(0, 5) : []),
    );
  });
}

// Only `geometry` is asked for: that keeps Details on the cheap location-only
// billing tier (a Pro field such as `name` costs ~3x), and the label shown to
// the driver already comes from the prediction we clicked.
function resolvePlace(placeId) {
  const { placesService: ps } = services();
  const tok = token();
  // Details closes the session whatever it answers, so the next keystroke has
  // to open a new one.
  sessionToken = null;
  return new Promise((resolve) => {
    ps.getDetails({ placeId, fields: ['geometry'], sessionToken: tok }, (res, status) => {
      if (status === google.maps.places.PlacesServiceStatus.OK && res.geometry) {
        resolve({ lat: res.geometry.location.lat(), lng: res.geometry.location.lng() });
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
 * @param {(place:{lat,lng,name}) => void} onFavorite  the star was tapped
 */
export function initSearch({ getStations, onStation, onPlace, onFavorite }) {
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
    // A row is a container, not a button: it holds the result itself plus the
    // star that saves it. A <button> inside a <button> is invalid HTML and the
    // inner one does not reliably receive taps.
    const addRow = (icon, main, sub, onClick, onStar) => {
      const row = document.createElement('div');
      row.className = 'search-row';

      const go = document.createElement('button');
      go.className = 'search-row__go';
      go.type = 'button';
      go.innerHTML =
        `<span class="search-row__ico">${icon}</span>` +
        `<span class="search-row__txt"><span class="search-row__main">${main}</span>` +
        (sub ? `<span class="search-row__sub">${sub}</span>` : '') +
        `</span>`;
      go.addEventListener('click', () => {
        close();
        input.value = main;
        clearBtn.hidden = false;
        onClick();
      });
      row.appendChild(go);

      if (onStar) {
        const star = document.createElement('button');
        star.className = 'search-row__star';
        star.type = 'button';
        star.textContent = '☆';
        star.title = t('favAdd');
        star.setAttribute('aria-label', t('favAdd'));
        star.addEventListener('click', () => {
          close();
          onStar();
        });
        row.appendChild(star);
      }

      dropdown.appendChild(row);
    };

    if (stations.length) {
      addHeader(t('searchStations'));
      for (const s of stations) {
        addRow(
          '⚡',
          s.name,
          `${s.provider}${s.city ? ' · ' + s.city : ''}`,
          () => onStation(s),
          // A charger already carries its coordinates, so starring one costs
          // no Places lookup at all.
          onFavorite && (() => onFavorite({ lat: s.lat, lng: s.lng, name: s.name })),
        );
      }
    }
    if (places.length) {
      addHeader(t('searchPlaces'));
      for (const p of places) {
        const sf = p.structured_formatting || {};
        const label = sf.main_text || p.description;
        addRow(
          '📍',
          label,
          sf.secondary_text || '',
          async () => {
            const pos = await resolvePlace(p.place_id);
            if (pos) onPlace(pos, label);
          },
          onFavorite &&
            (async () => {
              // A prediction is a name and an id, not a place: it has to be
              // resolved before there is anything to save.
              const pos = await resolvePlace(p.place_id);
              if (pos) onFavorite({ lat: pos.lat, lng: pos.lng, name: label });
            }),
        );
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
