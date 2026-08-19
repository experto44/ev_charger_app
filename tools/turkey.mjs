// Turkish charger data for the site generators.
//
// The app reads the EPDK registry from its own gist (see lib/turkey_service.dart
// and docs/turkey_epdk_api.md); this module is the read-only site-side view of
// that same file, so the pages under /turketi/ and the guides that quote Turkish
// figures can never drift away from what the app shows.
//
// Two things the raw file needs before it can be published:
//
//  • `city` is EPDK's free text. Most rows carry the province, but a tail of
//    them carries a district ("Şişli", "Torbalı"), a shouted province
//    ("KAYSERİ"), or nothing at all. Strings are unreliable, coordinates are
//    not, so every row is assigned to the nearest province centroid and the
//    centroids themselves are computed from the rows that DO name a province.
//  • prices arrive in two shapes, "12,40 ₺/kWh" and "8.99₺/kWh", and some are
//    ranges. parsePrice handles all three; anything else gets no price rather
//    than a guess.

import { mkdir, writeFile, readFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
export const TR_CACHE = path.join(ROOT, 'tools', '.cache', 'chargers_tr.json');
const TR_GIST = 'https://gist.githubusercontent.com/experto44/8cb62fc7ad6d86e3172eec6aedd4dba6'
  + '/raw/chargers_tr.json';

/* ── the 81 provinces ────────────────────────────────────────────────────── */
// Turkish spelling is what EPDK writes and what a driver sees on a road sign,
// so it stays authoritative; the Georgian column is only for display.
export const PROVINCES = ['Adana', 'Adıyaman', 'Afyonkarahisar', 'Ağrı', 'Aksaray', 'Amasya',
  'Ankara', 'Antalya', 'Ardahan', 'Artvin', 'Aydın', 'Balıkesir', 'Bartın', 'Batman', 'Bayburt',
  'Bilecik', 'Bingöl', 'Bitlis', 'Bolu', 'Burdur', 'Bursa', 'Çanakkale', 'Çankırı', 'Çorum',
  'Denizli', 'Diyarbakır', 'Düzce', 'Edirne', 'Elazığ', 'Erzincan', 'Erzurum', 'Eskişehir',
  'Gaziantep', 'Giresun', 'Gümüşhane', 'Hakkari', 'Hatay', 'Iğdır', 'Isparta', 'İstanbul', 'İzmir',
  'Kahramanmaraş', 'Karabük', 'Karaman', 'Kars', 'Kastamonu', 'Kayseri', 'Kilis', 'Kırıkkale',
  'Kırklareli', 'Kırşehir', 'Kocaeli', 'Konya', 'Kütahya', 'Malatya', 'Manisa', 'Mardin', 'Mersin',
  'Muğla', 'Muş', 'Nevşehir', 'Niğde', 'Ordu', 'Osmaniye', 'Rize', 'Sakarya', 'Samsun', 'Siirt',
  'Sinop', 'Sivas', 'Şanlıurfa', 'Şırnak', 'Tekirdağ', 'Tokat', 'Trabzon', 'Tunceli', 'Uşak', 'Van',
  'Yalova', 'Yozgat', 'Zonguldak'];

// Provinces a Georgian reader is likely to type in Georgian. Anything missing
// here is printed in Turkish in both languages, which is better than an
// invented transliteration.
export const PROVINCE_KA = {
  'İstanbul': ['სტამბოლი', 'სტამბოლში'], Ankara: ['ანკარა', 'ანკარაში'],
  Antalya: ['ანტალია', 'ანტალიაში'], Bursa: ['ბურსა', 'ბურსაში'],
  'İzmir': ['იზმირი', 'იზმირში'], 'Muğla': ['მუღლა', 'მუღლაში'],
  Kayseri: ['ქაისერი', 'ქაისერიში'], Konya: ['ქონია', 'ქონიაში'],
  'Balıkesir': ['ბალიქესირი', 'ბალიქესირში'], Kocaeli: ['ქოჯაელი', 'ქოჯაელიში'],
  'Aydın': ['აიდინი', 'აიდინში'], Denizli: ['დენიზლი', 'დენიზლიში'],
  Sakarya: ['საქარია', 'საქარიაში'], Mersin: ['მერსინი', 'მერსინში'],
  Adana: ['ადანა', 'ადანაში'], Samsun: ['სამსუნი', 'სამსუნში'],
  Manisa: ['მანისა', 'მანისაში'], 'Tekirdağ': ['თექირდაღი', 'თექირდაღში'],
  Afyonkarahisar: ['აფიონქარაჰისარი', 'აფიონქარაჰისარში'], Trabzon: ['ტრაბზონი', 'ტრაბზონში'],
  'Çanakkale': ['ჩანაქქალე', 'ჩანაქქალეში'], 'Eskişehir': ['ესქიშეჰირი', 'ესქიშეჰირში'],
  Malatya: ['მალათია', 'მალათიაში'], Gaziantep: ['გაზიანთეფი', 'გაზიანთეფში'],
  'Diyarbakır': ['დიარბაქირი', 'დიარბაქირში'], 'Nevşehir': ['ნევშეჰირი', 'ნევშეჰირში'],
  Bolu: ['ბოლუ', 'ბოლუში'], Sivas: ['სივასი', 'სივასში'], Edirne: ['ედირნე', 'ედირნეში'],
  'Düzce': ['დუზჯე', 'დუზჯეში'], 'Kütahya': ['ქუთაჰია', 'ქუთაჰიაში'],
  'Kahramanmaraş': ['ქაჰრამანმარაში', 'ქაჰრამანმარაშში'], Ordu: ['ორდუ', 'ორდუში'],
  'Şanlıurfa': ['შანლიურფა', 'შანლიურფაში'], Rize: ['რიზე', 'რიზეში'],
  Artvin: ['ართვინი', 'ართვინში'], Giresun: ['გირესუნი', 'გირესუნში'],
  Erzurum: ['ერზურუმი', 'ერზურუმში'], Kars: ['ყარსი', 'ყარსში'],
  // named in tables and in the guides, but with no page of their own
  Ardahan: ['არდაჰანი', 'არდაჰანში'], Bayburt: ['ბაიბურთი', 'ბაიბურთში'],
  'Gümüşhane': ['გუმუშჰანე', 'გუმუშჰანეში'], Sinop: ['სინოფი', 'სინოფში'],
  Amasya: ['ამასია', 'ამასიაში'], 'Çorum': ['ჩორუმი', 'ჩორუმში'],
  'Kırıkkale': ['ქირიქქალე', 'ქირიქქალეში'], Zonguldak: ['ზონგულდაქი', 'ზონგულდაქში'],
  Kastamonu: ['ქასთამონუ', 'ქასთამონუში'], Isparta: ['ისპარტა', 'ისპარტაში'],
  Yalova: ['იალოვა', 'იალოვაში'], Hatay: ['ჰათაი', 'ჰათაიში'],
  Tokat: ['თოქათი', 'თოქათში'], Van: ['ვანი', 'ვანში'], 'Iğdır': ['იღდირი', 'იღდირში'],
  Erzincan: ['ერზინჯანი', 'ერზინჯანში'], Aksaray: ['აქსარაი', 'აქსარაიში'],
  'Niğde': ['ნიღდე', 'ნიღდეში'],
  // the rest of the 81, so the Georgian table has no Turkish holes in it
  'Elazığ': ['ელაზიღი', 'ელაზიღში'], Mardin: ['მარდინი', 'მარდინში'],
  Batman: ['ბათმანი', 'ბათმანში'], 'Kırklareli': ['ქირქლარელი', 'ქირქლარელიში'],
  Burdur: ['ბურდური', 'ბურდურში'], Yozgat: ['იოზგათი', 'იოზგათში'],
  'Uşak': ['უშაქი', 'უშაქში'], 'Çankırı': ['ჩანქირი', 'ჩანქირიში'],
  Bilecik: ['ბილეჯიქი', 'ბილეჯიქში'], Karaman: ['ქარამანი', 'ქარამანში'],
  Osmaniye: ['ოსმანიე', 'ოსმანიეში'], 'Adıyaman': ['ადიამანი', 'ადიამანში'],
  'Karabük': ['ქარაბუქი', 'ქარაბუქში'], 'Kırşehir': ['ქირშეჰირი', 'ქირშეჰირში'],
  'Muş': ['მუში', 'მუშში'], Bitlis: ['ბითლისი', 'ბითლისში'],
  'Bartın': ['ბართინი', 'ბართინში'], 'Şırnak': ['შირნაქი', 'შირნაქში'],
  'Bingöl': ['ბინგოლი', 'ბინგოლში'], 'Ağrı': ['აღრი', 'აღრიში'],
  Tunceli: ['თუნჯელი', 'თუნჯელიში'], Hakkari: ['ჰაქარი', 'ჰაქარიში'],
  Siirt: ['სიირთი', 'სიირთში'], Kilis: ['ქილისი', 'ქილისში'],
};

// Big counts read badly as a run of digits in either language.
export const big = (n, lang) => (lang === 'ka'
  ? String(n).replace(/\B(?=(\d{3})+(?!\d))/g, ' ')
  : String(n).replace(/\B(?=(\d{3})+(?!\d))/g, ','));

// Nominative in the reader's language; Turkish is the fallback in both, which
// is better than inventing a transliteration for a province nobody searches for.
export const provName = (p, lang) => (lang === 'ka' && PROVINCE_KA[p] ? PROVINCE_KA[p][0] : p);
// "in <province>". Only the provinces that get a page need this.
export const provIn = (p, lang) => (lang === 'ka'
  ? (PROVINCE_KA[p] ? PROVINCE_KA[p][1] : `${p}-ში`)
  : p);

// Latin, ASCII, hyphenated. Used for both languages so one URL serves both.
const FOLD = { 'ı': 'i', 'İ': 'i', 'ş': 's', 'Ş': 's', 'ğ': 'g', 'Ğ': 'g', 'ü': 'u', 'Ü': 'u',
  'ö': 'o', 'Ö': 'o', 'ç': 'c', 'Ç': 'c', 'â': 'a', 'î': 'i', 'û': 'u' };
export const trSlug = (s) => String(s).replace(/[ıİşŞğĞüÜöÖçÇâîû]/g, (c) => FOLD[c])
  .toLowerCase().normalize('NFKD').replace(/[̀-ͯ]/g, '')
  .replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');

/* ── numbers off the rows ────────────────────────────────────────────────── */
export const trKw = (s) => { const m = /(\d+(?:\.\d+)?)\s*kW/i.exec(s?.power || ''); return m ? parseFloat(m[1]) : 0; };

// "12,40 ₺/kWh" and "8.99₺/kWh" both mean lira-and-kuruş; "9,90 - 12,40 ₺/kWh"
// is an operator that publishes a band. A band is represented by its midpoint
// for statistics and never reprinted as if it were one exact price.
export function parsePrice(raw) {
  if (!raw) return null;
  const nums = [...String(raw).matchAll(/(\d+)[.,](\d{1,2})/g)].map((m) => parseFloat(`${m[1]}.${m[2]}`));
  if (!nums.length) return null;
  return nums.reduce((a, b) => a + b, 0) / nums.length;
}

const R = 6371, rad = Math.PI / 180;
export function km(aLat, aLng, bLat, bLng) {
  const dLat = (bLat - aLat) * rad, dLng = (bLng - aLng) * rad;
  const h = Math.sin(dLat / 2) ** 2
    + Math.cos(aLat * rad) * Math.cos(bLat * rad) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(h));
}

export const median = (v) => {
  if (!v.length) return 0;
  const s = [...v].sort((a, b) => a - b);
  return s.length % 2 ? s[(s.length - 1) / 2] : (s[s.length / 2 - 1] + s[s.length / 2]) / 2;
};

/* ── loading ─────────────────────────────────────────────────────────────── */
export async function loadTurkey({ offline = false } = {}) {
  let raw;
  if (offline && existsSync(TR_CACHE)) {
    raw = JSON.parse(await readFile(TR_CACHE, 'utf8'));
  } else {
    try {
      const res = await fetch(TR_GIST);
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      raw = await res.json();
      await mkdir(path.dirname(TR_CACHE), { recursive: true });
      await writeFile(TR_CACHE, JSON.stringify(raw), 'utf8');
    } catch (e) {
      if (!existsSync(TR_CACHE)) throw new Error(`Turkish dataset unavailable and no cache: ${e.message}`);
      console.warn(`  !! Turkish gist unavailable (${e.message}), using cache`);
      raw = JSON.parse(await readFile(TR_CACHE, 'utf8'));
    }
  }
  const good = raw.filter((s) => Number.isFinite(s.lat) && Number.isFinite(s.lng));
  assignProvinces(good);
  return good;
}

// Stamps `_prov` on every station. Centroids come from the rows that already
// name a province, so the mapping never depends on a hand-maintained table of
// coordinates that would rot as the registry grows.
function assignProvinces(list) {
  const canon = new Map(PROVINCES.map((p) => [trSlug(p), p]));
  const acc = new Map();
  for (const s of list) {
    const p = canon.get(trSlug(s.city || ''));
    if (!p) continue;
    if (!acc.has(p)) acc.set(p, { lat: 0, lng: 0, n: 0 });
    const a = acc.get(p);
    a.lat += s.lat; a.lng += s.lng; a.n++;
  }
  const centroids = [...acc.entries()].map(([p, a]) => [p, a.lat / a.n, a.lng / a.n]);
  for (const s of list) {
    const named = canon.get(trSlug(s.city || ''));
    if (named) { s._prov = named; continue; }
    let best = null, bestD = Infinity;
    for (const [p, lat, lng] of centroids) {
      const d = km(s.lat, s.lng, lat, lng);
      if (d < bestD) { bestD = d; best = p; }
    }
    s._prov = best;
  }
}

/* ── country level summary ───────────────────────────────────────────────── */
export function turkeyStats(list) {
  const dc = list.filter((s) => s.type === 'Fast DC');
  const conn = {};
  for (const s of list) for (const c of (s.connectors || [])) conn[c] = (conn[c] || 0) + 1;

  const group = (key) => {
    const m = new Map();
    for (const s of list) {
      const k = s[key];
      if (!k) continue;
      if (!m.has(k)) m.set(k, []);
      m.get(k).push(s);
    }
    return [...m.entries()].sort((a, b) => b[1].length - a[1].length);
  };

  const dcPrices = dc.map((s) => parsePrice(s.price)).filter(Boolean);
  const acPrices = list.filter((s) => s.type !== 'Fast DC').map((s) => parsePrice(s.price)).filter(Boolean);
  const powers = list.map(trKw).filter(Boolean);

  return {
    total: list.length,
    dc: dc.length,
    ac: list.length - dc.length,
    withPrice: list.filter((s) => parsePrice(s.price)).length,
    brands: group('provider'),
    provinces: group('_prov'),
    connectors: Object.entries(conn).sort((a, b) => b[1] - a[1]),
    ultra: list.filter((s) => trKw(s) >= 150).length,
    hundred: list.filter((s) => trKw(s) >= 100).length,
    maxKw: powers.length ? Math.max(...powers) : 0,
    dcMed: median(dcPrices), dcMin: Math.min(...dcPrices), dcMax: Math.max(...dcPrices),
    acMed: median(acPrices), acMin: Math.min(...acPrices), acMax: Math.max(...acPrices),
    updated: (list.map((s) => s.last_updated).filter(Boolean).sort().pop() || '').slice(0, 16),
  };
}

export function provinceStats(list) {
  const dc = list.filter((s) => s.type === 'Fast DC').length;
  const conn = {};
  for (const s of list) for (const c of (s.connectors || [])) conn[c] = (conn[c] || 0) + 1;
  const brands = new Map();
  // 25 rows in the registry carry no operator name at all (they are OCM extras).
  // They still count as stations; they just cannot head a row in a brand table.
  for (const s of list) {
    if (!s.provider || !String(s.provider).trim()) continue;
    brands.set(s.provider, (brands.get(s.provider) || 0) + 1);
  }
  const dcPrices = list.filter((s) => s.type === 'Fast DC').map((s) => parsePrice(s.price)).filter(Boolean);
  const powers = list.map(trKw).filter(Boolean);
  return {
    total: list.length, dc, ac: list.length - dc,
    brands: [...brands.entries()].sort((a, b) => b[1] - a[1]),
    connectors: Object.entries(conn).sort((a, b) => b[1] - a[1]),
    maxKw: powers.length ? Math.max(...powers) : 0,
    ultra: list.filter((s) => trKw(s) >= 150).length,
    dcMed: median(dcPrices),
  };
}

/* ── corridors ───────────────────────────────────────────────────────────────
   A route here is a polyline of towns, not a routed road, so the kilometre
   figures it produces are shorter than the drive and are only ever published as
   approximations. What it produces exactly, and what the guides quote, is the
   count of chargers within a given distance of the road and the longest stretch
   between two of them. */
export const WAYPOINTS = {
  // the Black Sea road, Sarp border gate to İstanbul via Samsun and Ankara
  sarp: [41.5147, 41.5335], hopa: [41.39, 41.42], arhavi: [41.35, 41.30], pazar: [41.18, 40.88],
  rize: [41.0201, 40.5234], trabzon: [41.0027, 39.7168], akcaabat: [41.02, 39.57],
  vakfikebir: [41.05, 39.28], gorele: [41.03, 39.00], tirebolu: [41.00, 38.82],
  giresun: [40.9128, 38.3895], ordu: [40.9839, 37.8764], unye: [41.13, 37.28],
  terme: [41.20, 36.97], samsun: [41.2867, 36.33], havza: [40.97, 35.67], merzifon: [40.87, 35.46],
  corum: [40.5506, 34.9556], sungurlu: [40.16, 34.37], delice: [39.95, 34.03],
  kirikkale: [39.8468, 33.5153], ankara: [39.9334, 32.8597], gerede: [40.80, 32.20],
  bolu: [40.735, 31.6061], duzce: [40.8438, 31.1565], adapazari: [40.7889, 30.4053],
  izmit: [40.7654, 29.9408], gebze: [40.80, 29.43], istanbul: [41.0082, 28.9784],
  // Samsun onwards the fastest road stays on the coast (E70) through Sinop and
  // the Kastamonu shore, and only turns inland at Zonguldak. It does NOT go via
  // Ankara: that is a separate, longer alternative, kept below for comparison.
  bafra: [41.5678, 35.9067], alacam: [41.61, 35.60], gerze: [41.8025, 35.20],
  sinop: [42.0231, 35.1531], ayancik: [41.945, 34.58], inebolu: [41.9769, 33.7614],
  cide: [41.89, 33.00], amasra: [41.7469, 32.3872], bartin: [41.6344, 32.3375],
  zonguldak: [41.4564, 31.7987], eregli: [41.2833, 31.4167], akcakoca: [41.085, 31.12],
  // the eastern gate, Türkgözü at Posof, and the road inland
  posof: [41.51, 42.72], ardahan: [41.1105, 42.7022], kars: [40.6013, 43.0975],
  erzurum: [39.9043, 41.2679], bayburt: [40.2552, 40.2249], gumushane: [40.46, 39.48],
  sivas: [39.7477, 37.0179], kayseri: [38.7312, 35.4787], nevsehir: [38.6244, 34.7144],
  // Georgian side, for the leg before the border
  tbilisi: [41.7151, 44.8271], gori: [41.9847, 44.1086], khashuri: [41.9950, 43.6009],
  zestaponi: [42.1108, 43.0517], samtredia: [42.1580, 42.3350], kobuleti: [41.8214, 41.7791],
  batumi: [41.6459, 41.6417], sarpi: [41.5217, 41.5461],
};

export const ROUTES = {
  // The fastest road, and the one drivers from Georgia actually take: the Black
  // Sea coast the whole way, inland only for the last stretch after Zonguldak.
  'sarp-istanbul': ['sarp', 'hopa', 'arhavi', 'pazar', 'rize', 'trabzon', 'akcaabat', 'vakfikebir',
    'gorele', 'tirebolu', 'giresun', 'ordu', 'unye', 'terme', 'samsun', 'bafra', 'alacam', 'gerze',
    'sinop', 'ayancik', 'inebolu', 'cide', 'amasra', 'bartin', 'zonguldak', 'eregli', 'akcakoca',
    'duzce', 'adapazari', 'izmit', 'gebze', 'istanbul'],
  // The inland alternative through Ankara. Longer, but worth comparing because
  // the coastal road has one thin section and this one does not.
  'sarp-istanbul-inland': ['sarp', 'hopa', 'arhavi', 'pazar', 'rize', 'trabzon', 'akcaabat',
    'vakfikebir', 'gorele', 'tirebolu', 'giresun', 'ordu', 'unye', 'terme', 'samsun', 'havza',
    'merzifon', 'corum', 'sungurlu', 'delice', 'kirikkale', 'ankara', 'gerede', 'bolu', 'duzce',
    'adapazari', 'izmit', 'gebze', 'istanbul'],
  'samsun-istanbul-inland': ['samsun', 'havza', 'merzifon', 'corum', 'sungurlu', 'delice',
    'kirikkale', 'ankara', 'gerede', 'bolu', 'duzce', 'adapazari', 'izmit', 'gebze', 'istanbul'],
  'sarp-trabzon': ['sarp', 'hopa', 'arhavi', 'pazar', 'rize', 'trabzon'],
  'sarp-samsun': ['sarp', 'hopa', 'arhavi', 'pazar', 'rize', 'trabzon', 'akcaabat', 'vakfikebir',
    'gorele', 'tirebolu', 'giresun', 'ordu', 'unye', 'terme', 'samsun'],
  'samsun-sinop': ['samsun', 'bafra', 'alacam', 'gerze', 'sinop'],
  'sinop-zonguldak': ['sinop', 'ayancik', 'inebolu', 'cide', 'amasra', 'bartin', 'zonguldak'],
  'zonguldak-istanbul': ['zonguldak', 'eregli', 'akcakoca', 'duzce', 'adapazari', 'izmit',
    'gebze', 'istanbul'],
  'posof-ankara': ['posof', 'ardahan', 'kars', 'erzurum', 'bayburt', 'gumushane', 'sivas',
    'kayseri', 'nevsehir', 'ankara'],
  'posof-erzurum': ['posof', 'ardahan', 'kars', 'erzurum'],
  'tbilisi-sarpi': ['tbilisi', 'gori', 'khashuri', 'zestaponi', 'samtredia', 'kobuleti', 'batumi', 'sarpi'],
};

// Legs of the coastal road, derived from the route itself so a waypoint edit
// can never leave a leg disagreeing with the whole.
const leg = (route, from, to) => {
  const all = ROUTES[route];
  return all.slice(all.indexOf(from), all.indexOf(to) + 1);
};
ROUTES['trabzon-samsun'] = leg('sarp-istanbul', 'trabzon', 'samsun');
ROUTES['samsun-istanbul-coast'] = leg('sarp-istanbul', 'samsun', 'istanbul');
ROUTES['ankara-istanbul'] = leg('sarp-istanbul-inland', 'ankara', 'istanbul');

// Distance from a point to a segment, in kilometres, on a local flat
// approximation. Good to a few hundred metres at these latitudes, which is well
// inside the tolerance we then apply.
function toSegment(p, a, b) {
  const kx = 111.32 * Math.cos(((a[0] + b[0]) / 2) * rad), ky = 110.57;
  const A = [(p[1] - a[1]) * kx, (p[0] - a[0]) * ky];
  const B = [(b[1] - a[1]) * kx, (b[0] - a[0]) * ky];
  const len = B[0] * B[0] + B[1] * B[1];
  let t = len ? (A[0] * B[0] + A[1] * B[1]) / len : 0;
  t = Math.max(0, Math.min(1, t));
  return { dist: Math.hypot(A[0] - B[0] * t, A[1] - B[1] * t), t };
}

export function corridor(list, routeKey, { maxKm = 5, minKw = 50 } = {}) {
  const pts = ROUTES[routeKey].map((k) => WAYPOINTS[k]);
  const segLen = [];
  for (let i = 0; i < pts.length - 1; i++) segLen.push(km(pts[i][0], pts[i][1], pts[i + 1][0], pts[i + 1][1]));
  const cum = [0];
  for (const l of segLen) cum.push(cum[cum.length - 1] + l);
  const length = cum[cum.length - 1];

  const hits = [];
  for (const s of list) {
    if (minKw && trKw(s) < minKw) continue;
    let best = null;
    for (let i = 0; i < pts.length - 1; i++) {
      const { dist, t } = toSegment([s.lat, s.lng], pts[i], pts[i + 1]);
      if (dist <= maxKm && (!best || dist < best.dist)) best = { dist, pos: cum[i] + t * segLen[i] };
    }
    if (best) hits.push({ ...best, s });
  }
  hits.sort((a, b) => a.pos - b.pos);

  let gap = 0, gapFrom = null, gapTo = null, prev = 0, prevName = null;
  for (const h of hits) {
    if (h.pos - prev > gap) { gap = h.pos - prev; gapFrom = prevName; gapTo = h.s; }
    prev = h.pos; prevName = h.s;
  }
  if (length - prev > gap) { gap = length - prev; gapFrom = prevName; gapTo = null; }

  const byProv = new Map(), byBrand = new Map();
  for (const h of hits) {
    byProv.set(h.s._prov, (byProv.get(h.s._prov) || 0) + 1);
    byBrand.set(h.s.provider, (byBrand.get(h.s.provider) || 0) + 1);
  }
  return {
    length, count: hits.length, gap, gapFrom, gapTo,
    // distance along the route of every charger found, so an article can draw
    // the coverage profile instead of asserting it
    positions: hits.map((h) => h.pos),
    ultra: hits.filter((h) => trKw(h.s) >= 150).length,
    provinces: [...byProv.entries()].sort((a, b) => b[1] - a[1]),
    brands: [...byBrand.entries()].sort((a, b) => b[1] - a[1]),
  };
}
