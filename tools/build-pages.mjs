#!/usr/bin/env node
// Generates the static SEO catalogue pages under site/ from the live chargers gist.
//
//   node tools/build-pages.mjs            # fetch gist, write pages + sitemap
//   node tools/build-pages.mjs --ping     # …and notify IndexNow
//   node tools/build-pages.mjs --offline  # reuse tools/.cache/chargers.json
//
// Deliberately NOT published: lat/lng and live port status. The website answers
// "which chargers exist and where"; the app answers "which one is free right now".
// buildStationRows() is the only place station fields are emitted — keep it that way.

import { mkdir, writeFile, readFile } from 'node:fs/promises';
import { existsSync, readdirSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { loadTurkey, turkeyStats, provinceStats, corridor, trSlug, trKw,
  provName, provIn, big } from './turkey.mjs';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const SITE = path.join(ROOT, 'site');
const CACHE = path.join(ROOT, 'tools', '.cache', 'chargers.json');
const GIST = 'https://gist.githubusercontent.com/experto44/36f39392ce7a4abe14ab065aa8e846bd/raw/chargers.json';
const ORIGIN = 'https://geocharge.ge';
const INDEXNOW_KEY = '6d092fc8f368db37e8960cf3843bde7e';

const SHOW_PRICE = true;   // tariffs are catalogue data, not live status — flip to false to drop them
const MIN_CITY_STATIONS = 3; // below this a city page would be thin content

const PLAY = 'https://play.google.com/store/apps/details?id=ge.geocharge.app';
const APPSTORE = 'https://apps.apple.com/ge/app/geocharge/id6785467389';

/* ── Georgian cities ─────────────────────────────────────────────────────────
   Coordinates are used ONLY to bucket stations at build time. They are never
   written into the generated HTML. `ka` is the locative form ("in Tbilisi"). */
const CITIES = [
  ['Tbilisi',         'თბილისი',        'თბილისში',        41.7151, 44.8271, 28],
  ['Rustavi',         'რუსთავი',        'რუსთავში',        41.5495, 44.9930, 12],
  ['Mtskheta',        'მცხეთა',         'მცხეთაში',        41.8450, 44.7200, 9],
  ['Gardabani',       'გარდაბანი',      'გარდაბანში',      41.4600, 45.0900, 12],
  ['Marneuli',        'მარნეული',       'მარნეულში',       41.4750, 44.8090, 12],
  ['Bolnisi',         'ბოლნისი',        'ბოლნისში',        41.4470, 44.5390, 12],
  ['Tetritskaro',     'თეთრიწყარო',     'თეთრიწყაროში',    41.5450, 44.4650, 10],
  ['Tsalka',          'წალკა',          'წალკაში',         41.5950, 44.0930, 12],
  ['Dmanisi',         'დმანისი',        'დმანისში',        41.3270, 44.2070, 12],
  ['Batumi',          'ბათუმი',         'ბათუმში',         41.6460, 41.6400, 11],
  ['Kobuleti',        'ქობულეთი',       'ქობულეთში',       41.8210, 41.7756, 10],
  ['Chakvi',          'ჩაქვი',          'ჩაქვში',          41.7360, 41.7220, 6],
  ['Gonio',           'გონიო',          'გონიოში',         41.5720, 41.5680, 6],
  ['Kvariati',        'კვარიათი',       'კვარიათში',       41.5480, 41.5560, 5],
  ['Sarpi',           'სარფი',          'სარფში',          41.5220, 41.5450, 5],
  ['Khelvachauri',    'ხელვაჩაური',     'ხელვაჩაურში',     41.6000, 41.6400, 7],
  ['Kutaisi',         'ქუთაისი',        'ქუთაისში',        42.2679, 42.6946, 14],
  ['Tskaltubo',       'წყალტუბო',       'წყალტუბოში',      42.3400, 42.6000, 10],
  ['Zestaponi',       'ზესტაფონი',      'ზესტაფონში',      42.1119, 43.0500, 11],
  ['Samtredia',       'სამტრედია',      'სამტრედიაში',     42.1550, 42.3350, 11],
  ['Terjola',         'თერჯოლა',        'თერჯოლაში',       42.1780, 42.9660, 9],
  ['Chiatura',        'ჭიათურა',        'ჭიათურაში',       42.2900, 43.2830, 11],
  ['Sachkhere',       'საჩხერე',        'საჩხერეში',       42.3400, 43.4030, 11],
  ['Tkibuli',         'ტყიბული',        'ტყიბულში',        42.3480, 42.9930, 10],
  ['Vani',            'ვანი',           'ვანში',           42.0830, 42.5170, 9],
  ['Khoni',           'ხონი',           'ხონში',           42.3200, 42.4200, 9],
  ['Baghdati',        'ბაღდათი',        'ბაღდათში',        41.9900, 42.8250, 10],
  ['Gori',            'გორი',           'გორში',           41.9847, 44.1086, 13],
  ['Khashuri',        'ხაშური',         'ხაშურში',         41.9950, 43.6010, 11],
  ['Kareli',          'ქარელი',         'ქარელში',         41.9990, 43.8930, 10],
  ['Kaspi',           'კასპი',          'კასპში',          41.9250, 44.4250, 10],
  ['Surami',          'სურამი',         'სურამში',         41.9990, 43.5540, 7],
  ['Borjomi',         'ბორჯომი',        'ბორჯომში',        41.8397, 43.3808, 11],
  ['Bakuriani',       'ბაკურიანი',      'ბაკურიანში',      41.7480, 43.5320, 8],
  ['Akhaltsikhe',     'ახალციხე',       'ახალციხეში',      41.6390, 42.9860, 12],
  ['Akhalkalaki',     'ახალქალაქი',     'ახალქალაქში',     41.4050, 43.4870, 12],
  ['Ninotsminda',     'ნინოწმინდა',     'ნინოწმინდაში',    41.2650, 43.5880, 11],
  ['Adigeni',         'ადიგენი',        'ადიგენში',        41.6930, 42.7000, 9],
  ['Aspindza',        'ასპინძა',        'ასპინძაში',       41.5720, 43.2500, 9],
  ['Telavi',          'თელავი',         'თელავში',         41.9192, 45.4731, 12],
  ['Gurjaani',        'გურჯაანი',       'გურჯაანში',       41.7430, 45.8000, 11],
  ['Sagarejo',        'საგარეჯო',       'საგარეჯოში',      41.7340, 45.3300, 11],
  ['Kvareli',         'ყვარელი',        'ყვარელში',        41.9500, 45.8170, 11],
  ['Signagi',         'სიღნაღი',        'სიღნაღში',        41.6180, 45.9210, 9],
  ['Tsnori',          'წნორი',          'წნორში',          41.6250, 45.9670, 7],
  ['Lagodekhi',       'ლაგოდეხი',       'ლაგოდეხში',       41.8250, 46.2780, 11],
  ['Akhmeta',         'ახმეტა',         'ახმეტაში',        42.0330, 45.2080, 11],
  ['Dedoplistskaro',  'დედოფლისწყარო',  'დედოფლისწყაროში', 41.4650, 46.1030, 12],
  ['Zugdidi',         'ზუგდიდი',        'ზუგდიდში',        42.5088, 41.8709, 12],
  ['Poti',            'ფოთი',           'ფოთში',           42.1462, 41.6725, 11],
  ['Senaki',          'სენაკი',         'სენაკში',         42.2700, 42.0670, 10],
  ['Khobi',           'ხობი',           'ხობში',           42.3170, 41.9000, 10],
  ['Abasha',          'აბაშა',          'აბაშაში',         42.2000, 42.2000, 9],
  ['Martvili',        'მარტვილი',       'მარტვილში',       42.4150, 42.3780, 10],
  ['Chkhorotsku',     'ჩხოროწყუ',       'ჩხოროწყუში',      42.5170, 42.1170, 10],
  ['Tsalenjikha',     'წალენჯიხა',      'წალენჯიხაში',     42.6000, 42.0670, 10],
  ['Anaklia',         'ანაკლია',        'ანაკლიაში',       42.3880, 41.5720, 8],
  ['Mestia',          'მესტია',         'მესტიაში',        43.0430, 42.7280, 14],
  ['Ozurgeti',        'ოზურგეთი',       'ოზურგეთში',       41.9250, 42.0080, 11],
  ['Lanchkhuti',      'ლანჩხუთი',       'ლანჩხუთში',       42.0900, 42.0330, 10],
  ['Chokhatauri',     'ჩოხატაური',      'ჩოხატაურში',      42.0170, 42.2500, 9],
  ['Ureki',           'ურეკი',          'ურეკში',          41.9930, 41.7750, 7],
  ['Shekvetili',      'შეკვეთილი',      'შეკვეთილში',      41.9600, 41.7700, 6],
  ['Gudauri',         'გუდაური',        'გუდაურში',        42.4780, 44.4780, 11],
  ['Stepantsminda',   'სტეფანწმინდა',   'სტეფანწმინდაში',  42.6560, 44.6430, 12],
  ['Dusheti',         'დუშეთი',         'დუშეთში',         42.0850, 44.6960, 11],
  ['Tianeti',         'თიანეთი',        'თიანეთში',        42.1100, 44.9650, 10],
  ['Ambrolauri',      'ამბროლაური',     'ამბროლაურში',     42.5200, 43.1500, 12],
  ['Oni',             'ონი',            'ონში',            42.5800, 43.4400, 10],
];

/* ── Routes ──────────────────────────────────────────────────────────────────
   `km` is road distance from the start, not great-circle. Stops naming a city
   from CITIES reuse that city's bucket, so a route page and the city page always
   agree. Stops outside Georgia carry their own coords and are counted by radius
   from the unfiltered dataset, because the catalogue itself is Georgia only. */
const ROUTES = [
  {
    slug: 'tbilisi-batumi', km: 370,
    stops: [['Tbilisi', 0], ['Gori', 86], ['Khashuri', 125], ['Terjola', 180],
      ['Kutaisi', 225], ['Samtredia', 255], ['Kobuleti', 340], ['Batumi', 370]],
    ka: {
      from: 'თბილისი', to: 'ბათუმი', fromAbl: 'თბილისიდან', toLoc: 'ბათუმში',
      note: 'ეს საქართველოს ყველაზე კარგად დაფარული მარშრუტია. რიკოთის მონაკვეთი თერჯოლასთან ცალკე კვანძია, სადაც ყველაზე მძლავრი დამტენები დგას, ამიტომ ერთი გაჩერება აქ თითქმის ყოველთვის საკმარისია.',
      advice: 'ხაშური და ქობულეთი შედარებით სუსტი წერტილებია, ამიტომ მათზე დაყრდნობა არ ღირს. ქუთაისი და თერჯოლა უფრო საიმედოა.',
    },
    en: {
      from: 'Tbilisi', to: 'Batumi',
      note: 'This is the best covered route in Georgia. The Rikoti stretch around Terjola is a hub in its own right and holds the most powerful chargers on the way, so one stop there is almost always enough.',
      advice: 'Khashuri and Kobuleti are the weaker points, so it is better not to depend on them. Kutaisi and Terjola are the safer bets.',
    },
  },
  {
    slug: 'tbilisi-kazbegi', km: 155,
    stops: [['Tbilisi', 0], ['Mtskheta', 20], ['Gudauri', 120], ['Stepantsminda', 155]],
    ka: {
      from: 'თბილისი', to: 'ყაზბეგი', fromAbl: 'თბილისიდან', toLoc: 'ყაზბეგში',
      note: 'ჯვრის უღელტეხილი 2379 მეტრზეა და აღმართი ბატარეას შესამჩნევად ხარჯავს. ზამთარში დანახარჯი კიდევ იზრდება, რადგან სალონისა და ბატარეის გათბობა ენერგიას იღებს.',
      advice: 'სტეფანწმინდაში სწრაფი დამტენი არ არის, მხოლოდ ნელი AC. ეს ნიშნავს, რომ თბილისში დაბრუნების მარაგი წინასწარ უნდა გქონდეთ, ან ღამის განმავლობაში დატენოთ. გუდაური ბოლო წერტილია, სადაც სწრაფად დატენვა შეგიძლიათ.',
    },
    en: {
      from: 'Tbilisi', to: 'Kazbegi',
      note: 'The Jvari Pass sits at 2379 metres and the climb costs noticeably more battery. In winter it costs more still, since heating the cabin and the battery draws power too.',
      advice: 'Stepantsminda has no fast charger, only slow AC. That means you need the range to get back to Gudauri or Tbilisi already in the battery, or an overnight charge. Gudauri is the last point where you can charge quickly.',
    },
  },
  {
    slug: 'tbilisi-bakuriani', km: 185,
    stops: [['Tbilisi', 0], ['Gori', 86], ['Khashuri', 125], ['Borjomi', 155], ['Bakuriani', 185]],
    ka: {
      from: 'თბილისი', to: 'ბაკურიანი', fromAbl: 'თბილისიდან', toLoc: 'ბაკურიანში',
      note: 'ბორჯომიდან ბაკურიანამდე 30 კილომეტრი სულ აღმართია, დაახლოებით 1700 მეტრამდე. ეს მოკლე მონაკვეთი ბატარეას იმაზე მეტს ხარჯავს, ვიდრე კილომეტრაჟით ჩანს.',
      advice: 'ბაკურიანში სწრაფი დამტენი არ არის, მხოლოდ ნელი AC 22 კილოვატამდე. სასრიალო სეზონზე ეს დამტენები დაკავებულია, ამიტომ ჯობია ბორჯომში ან გორში დატენოთ და ბაკურიანში მარაგით ახვიდეთ.',
    },
    en: {
      from: 'Tbilisi', to: 'Bakuriani',
      note: 'The 30 km from Borjomi up to Bakuriani is a continuous climb to about 1700 metres. That short stretch costs more battery than the distance suggests.',
      advice: 'Bakuriani has no fast charger, only slow AC up to 22 kW, and in ski season those are busy. Better to charge in Borjomi or Gori and arrive with margin.',
    },
  },
  {
    slug: 'tbilisi-mestia', km: 465,
    stops: [['Tbilisi', 0], ['Gori', 86], ['Kutaisi', 225], ['Samtredia', 255],
      ['Zugdidi', 335], ['Mestia', 465]],
    ka: {
      from: 'თბილისი', to: 'მესტია', fromAbl: 'თბილისიდან', toLoc: 'მესტიაში',
      note: 'ეს საქართველოს ყველაზე რთული მარშრუტია ელექტრომობილისთვის. ზუგდიდიდან მესტიამდე 130 კილომეტრია და ამ მონაკვეთზე დამტენი პრაქტიკულად არ არსებობს, გზა კი მუდმივ აღმართზე მიდის 1500 მეტრამდე.',
      advice: 'ზუგდიდი ბოლო სერიოზული წერტილია. იქიდან სავსე ბატარეით უნდა გახვიდეთ და გაითვალისწინოთ, რომ აღმართზე რეალური გარბენი დეკლარირებულის ნახევრამდე ეცემა. მესტიაში დაბრუნების ენერგია ან ღამის დატენვით უნდა მოაგროვოთ.',
    },
    en: {
      from: 'Tbilisi', to: 'Mestia',
      note: 'This is the hardest route in Georgia for an EV. From Zugdidi to Mestia is 130 km with essentially no chargers on the way, and the road climbs continuously to about 1500 metres.',
      advice: 'Zugdidi is the last serious point. Leave it full and expect real range on the climb to fall to about half the rated figure. The energy to come back has to come from an overnight charge in Mestia.',
    },
  },
  {
    slug: 'tbilisi-erevani', km: 275,
    stops: [['Tbilisi', 0], ['Marneuli', 45],
      [{ ka: 'სადახლო, საზღვარი', en: 'Sadakhlo, border', lat: 41.2150, lng: 44.8100, r: 12 }, 75],
      [{ ka: 'ვანაძორი', en: 'Vanadzor', lat: 40.8128, lng: 44.4883, r: 14 }, 165],
      [{ ka: 'დილიჟანი', en: 'Dilijan', lat: 40.7400, lng: 44.8600, r: 12 }, 190],
      [{ ka: 'ერევანი', en: 'Yerevan', lat: 40.1792, lng: 44.4991, r: 25 }, 275]],
    ka: {
      from: 'თბილისი', to: 'ერევანი', fromAbl: 'თბილისიდან', toLoc: 'ერევანში',
      note: 'ერევანში დატენვის ინფრასტრუქტურა მკვრივია, გზაში კი თითქმის არაფერია. საზღვრიდან ვანაძორამდე 90 კილომეტრი პრაქტიკულად ცარიელია.',
      advice: 'თბილისიდან სავსე ბატარეით გადით. საზღვართან, სადახლოს მხარეს, სწრაფი დამტენებია, ანუ ეს ბოლო საიმედო წერტილია საქართველოში. GeoCharge სომხეთის სადგურებსაც აჩვენებს, ამიტომ იმავე აპლიკაციით დაგეგმავთ მთელ გზას.',
    },
    en: {
      from: 'Tbilisi', to: 'Yerevan',
      note: 'Yerevan itself is densely covered, but there is almost nothing on the way. The 90 km from the border to Vanadzor is essentially empty.',
      advice: 'Leave Tbilisi full. There are fast chargers on the Georgian side near Sadakhlo, and that is the last reliable point before the border. GeoCharge shows Armenian stations too, so the whole trip plans in one app.',
    },
  },
];

const GE_BBOX = { minLat: 41.0, maxLat: 43.65, minLng: 39.9, maxLng: 46.8 };
const AM_BBOX = { minLat: 38.8, maxLat: 41.30, minLng: 43.4, maxLng: 46.7 };

const inBox = (s, b) => s.lat >= b.minLat && s.lat <= b.maxLat && s.lng >= b.minLng && s.lng <= b.maxLng;
export const inGeorgia = (s) => inBox(s, GE_BBOX) && !inBox(s, AM_BBOX);

function haversineKm(aLat, aLng, bLat, bLng) {
  const R = 6371, r = Math.PI / 180;
  const dLat = (bLat - aLat) * r, dLng = (bLng - aLng) * r;
  const h = Math.sin(dLat / 2) ** 2 +
    Math.cos(aLat * r) * Math.cos(bLat * r) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(h));
}

export function assignCity(s) {
  let best = null, bestD = Infinity;
  for (const c of CITIES) {
    const d = haversineKm(s.lat, s.lng, c[3], c[4]);
    if (d <= c[5] && d < bestD) { best = c; bestD = d; }
  }
  return best;
}

const slug = (s) => s.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
const esc = (s) => String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;')
  .replace(/>/g, '&gt;').replace(/"/g, '&quot;');
const kw = (s) => { const m = /(\d+(?:\.\d+)?)\s*kW/i.exec(s?.power || ''); return m ? parseFloat(m[1]) : 0; };

/* ── provider display names ──────────────────────────────────────────────── */
const PROVIDER_KA = {
  'mart EV': 'mart EV', 'E-Space': 'E-Space (ი-სფეის)', 'EcoCars': 'EcoCars (ეკოკარსი)',
  'Da-Tene': 'Da-Tene (დატენე)', 'Charger Plus': 'Charger Plus (ჩარჯერ პლუს)',
  'EV Power GE': 'EV Power (ივი პაუერ)', 'Tegeta': 'Tegeta (თეგეტა)',
  'Electrify Georgia': 'Electrify Georgia (ელექტრიფაი)', 'Solar Station': 'Solar Station (სოლარ სტეიშენ)',
  'MOVEO': 'MOVEO (მოვეო)', 'Gadatene': 'Gadatene (გადატენე)',
};
const PROVIDER_LOGO = {
  'mart EV': 'martev.svg', 'E-Space': 'espace.svg', 'EcoCars': 'ecocars.png',
  'Da-Tene': 'datene.png', 'Charger Plus': 'chargerplus.png', 'EV Power GE': 'evpower.png',
  'Tegeta': 'tegeta.png', 'Electrify Georgia': 'electrify.png', 'Solar Station': 'solarstation.png',
  'MOVEO': 'moveo.png', 'Gadatene': 'gadatene-dark.svg',
};

/* ── i18n ────────────────────────────────────────────────────────────────── */
const L = {
  ka: {
    code: 'ka', base: '', chargersDir: 'damtenebi', networksDir: 'qselebi',
    home: 'მთავარი', catalog: 'დამტენები', networks: 'ქსელები',
    catalogTitle: 'ელექტრო მანქანის დამტენები საქართველოში',
    stations: 'სადგური', station: 'სადგური', networksWord: 'ქსელი',
    fast: 'სწრაფი (DC)', slow: 'ჩვეულებრივი (AC)', maxPower: 'მაქს. სიმძლავრე',
    thName: 'სადგური', thProvider: 'ქსელი', thType: 'ტიპი', thPower: 'სიმძლავრე',
    thConnectors: 'კონექტორები', thPrice: 'ტარიფი', thCity: 'ქალაქი', thCount: 'დამტენი',
    byCity: 'დამტენები ქალაქების მიხედვით', byNetwork: 'დამტენები ქსელების მიხედვით',
    connectorMix: 'კონექტორების ტიპები', allStations: 'ყველა სადგური',
    updated: 'მონაცემები ავტომატურად ახლდება პროვაიდერებისგან. ბოლო განახლება:',
    ctaTitle: 'რუკა და ცოცხალი სტატუსი აპლიკაციაშია',
    ctaBody: 'ამ გვერდზე ხედავთ, რომელი დამტენები არსებობს და სად. რუკა, ზუსტი მდებარეობა, ცოცხალი სტატუსი (თავისუფალია თუ დაკავებული) და მარშრუტის დაგეგმვა უფასო აპლიკაციაშია.',
    ctaPlay: 'ჩამოტვირთვა Google Play-დან', ctaStore: 'ჩამოტვირთვა App Store-დან',
    otherCities: 'სხვა ქალაქები', otherNetworks: 'სხვა ქსელები', backToAll: 'ყველა დამტენი საქართველოში',
    noPrice: '—', faq: 'ხშირად დასმული კითხვები',
    priceNote: 'ტარიფები ინფორმაციული ხასიათისაა და პროვაიდერის მიერაა გამოქვეყნებული.',
    tariffsDir: 'tarifebi', routesDir: 'marshruti', calcDir: 'kalkulatori', calc: 'კალკულატორი',
    timeDir: 'datenvis-dro', timeCalc: 'დატენვის დრო',
    tariffs: 'ტარიფები', routes: 'მარშრუტები',
    customsDir: 'ganbajeba', customs: 'განბაჟება',
    turkeyDir: 'turketi', turkey: 'თურქეთი', thDcTr: 'DC ₺/kWh',
    thDc: 'DC ₾/kWh', thAc: 'AC ₾/kWh', thNoPrice: 'ფასის გარეშე', thCities: 'ქალაქი',
    thKm: 'კმ თბილისიდან', thStop: 'გაჩერება', median: 'მედიანა',
    cheapestDc: 'ყველაზე იაფი DC', cheapestAc: 'ყველაზე იაფი AC', dearestDc: 'ყველაზე ძვირი DC',
    routeTable: 'დამტენები მარშრუტზე', routeNotes: 'რაზე მიაქციოთ ყურადღება',
    generalRules: 'შორი მგზავრობის ზოგადი წესები ცალკე გვაქვს აღწერილი',
    howToCalc: 'როგორ ითვლება დატენვის ღირებულება, ცალკე სტატიაშია ახსნილი',
    allRoutes: 'ყველა მარშრუტი', noFast: 'სწრაფი დამტენი არ არის',
    routePlan: 'რამდენი გაჩერება დასჭირდება',
    routeTime: 'რამდენი ხანი გავჩერდებით',
    routeCars: 'რომელი მანქანა დაიტენება ამ გზაზე',
    routeCost: 'რა დაჯდება ეს გზა',
    routeNets: 'ქსელები ამ მარშრუტზე',
    routeWinter: 'რა იცვლება ზამთარში',
    longestGap: 'ყველაზე გრძელი მონაკვეთი სწრაფის გარეშე',
    winterCopy: 'ცივ ამინდში ორი რამ ერთდროულად ხდება: ბატარეა ნაკლებ ენერგიას გასცემს და სალონის გათბობა თავისას იღებს. რეალური გარბენი ზამთარში მეოთხედამდე ეცემა, ცივი ბატარეა კი სწრაფ დამტენზეც ნელა იტენება, სანამ არ გაცხელდება. პრაქტიკული დასკვნა მარტივია: იმავე მარშრუტზე ზამთარში ერთი დამატებითი გაჩერება ჩადეთ გეგმაში და დანიშნულების ადგილს 20 პროცენტზე მეტი მარაგით მიაღწიეთ.',
    winterMore: 'ზამთრის გარბენზე ცალკე სტატია გვაქვს',
    calcMore: 'თქვენი მანქანის ციფრებით გადათვლა კალკულატორში შეგიძლიათ',
  },
  en: {
    code: 'en', base: '/en', chargersDir: 'chargers', networksDir: 'networks',
    home: 'Home', catalog: 'Chargers', networks: 'Networks',
    catalogTitle: 'EV charging stations in Georgia',
    stations: 'stations', station: 'station', networksWord: 'networks',
    fast: 'Fast (DC)', slow: 'Standard (AC)', maxPower: 'Max power',
    thName: 'Station', thProvider: 'Network', thType: 'Type', thPower: 'Power',
    thConnectors: 'Connectors', thPrice: 'Tariff', thCity: 'City', thCount: 'chargers',
    byCity: 'Chargers by city', byNetwork: 'Chargers by network',
    connectorMix: 'Connector types', allStations: 'All stations',
    updated: 'Data refreshes automatically from the providers. Last update:',
    ctaTitle: 'Map and live status are in the app',
    ctaBody: 'This page shows which chargers exist and where. The map, exact locations, real-time availability and route planning live in the free app.',
    ctaPlay: 'Get it on Google Play', ctaStore: 'Download on the App Store',
    otherCities: 'Other cities', otherNetworks: 'Other networks', backToAll: 'All chargers in Georgia',
    noPrice: '—', faq: 'Frequently asked questions',
    priceNote: 'Tariffs are indicative and published by the provider.',
    tariffsDir: 'tariffs', routesDir: 'routes', calcDir: 'calculator', calc: 'Calculator',
    timeDir: 'charging-time', timeCalc: 'Charging time',
    tariffs: 'Tariffs', routes: 'Routes',
    customsDir: 'customs', customs: 'Import duty',
    turkeyDir: 'turkey', turkey: 'Turkey', thDcTr: 'DC TRY/kWh',
    thDc: 'DC GEL/kWh', thAc: 'AC GEL/kWh', thNoPrice: 'No price', thCities: 'Cities',
    thKm: 'km from Tbilisi', thStop: 'Stop', median: 'median',
    cheapestDc: 'Cheapest DC', cheapestAc: 'Cheapest AC', dearestDc: 'Most expensive DC',
    routeTable: 'Chargers along the route', routeNotes: 'What to watch for',
    generalRules: 'The general rules for long trips are covered separately',
    howToCalc: 'How a charge is priced is explained in its own guide',
    allRoutes: 'All routes', noFast: 'no fast charger',
    routePlan: 'How many stops it takes',
    routeTime: 'How long the stop takes',
    routeCars: 'Which cars this road serves',
    routeCost: 'What the drive costs',
    routeNets: 'Networks on this route',
    routeWinter: 'What changes in winter',
    longestGap: 'longest stretch without fast charging',
    winterCopy: 'Two things happen at once in cold weather: the battery gives up less energy, and cabin heating takes its own share. Real range drops by up to a quarter, and a cold battery also charges slowly on a fast charger until it warms up. The practical conclusion is simple: plan one extra stop on the same route in winter, and arrive with more than 20 percent left.',
    winterMore: 'Winter range has its own guide',
    calcMore: 'You can redo the numbers for your own car in the calculator',
  },
};

/* ── shared chrome ───────────────────────────────────────────────────────── */
export const CSS = `
:root{--ink:#11161A;--ink-2:#5A6671;--dark:#11161A;--dark-2:#0D1115;
--accent:#2BD594;--accent-d:#17995F;--on-accent:#0D1A13;--mint:#ECFAF3;--mint-b:#C8EFDD;
--soft:#F6FAF8;--line:#E3EEE8;--on-dark:#A7B4BD;--on-dark-2:#B9C4CB}
*{box-sizing:border-box}
body{margin:0;background:#fff;color:var(--ink);font-family:'Poppins','Noto Sans Georgian',system-ui,sans-serif;-webkit-font-smoothing:antialiased}
::selection{background:var(--accent);color:var(--ink)}
a{color:inherit}
.hdr{position:sticky;top:0;z-index:60;background:rgba(17,22,26,.94);backdrop-filter:blur(14px);-webkit-backdrop-filter:blur(14px);border-bottom:1px solid rgba(255,255,255,.07)}
.hdr-in{max-width:1100px;margin:0 auto;padding:0 clamp(16px,4vw,40px);height:64px;display:flex;align-items:center;justify-content:space-between;gap:16px}
.lang{display:flex;border:1px solid #39434C;border-radius:999px;overflow:hidden}
.lang a{padding:7px 13px;font-weight:600;font-size:12.5px;text-decoration:none;color:#B9C4CB}
.lang a[aria-current="true"]{background:var(--accent);color:var(--on-accent)}
.hnav{display:flex;align-items:center;gap:clamp(12px,1.6vw,24px);flex-shrink:0}
.hnav a{color:var(--on-dark-2);text-decoration:none;font-size:clamp(13px,1.05vw,14px);font-weight:500;white-space:nowrap}
.hnav a:hover{color:#fff}
@media (max-width:899px){.hnav{display:none}}
main{max-width:1100px;margin:0 auto;padding:clamp(28px,5vw,48px) clamp(20px,5vw,40px) clamp(56px,8vw,90px)}
.crumbs{font-size:13.5px;color:#8B98A1;margin:0 0 18px;display:flex;flex-wrap:wrap;gap:8px;align-items:center}
.crumbs a{color:var(--accent-d);text-decoration:none}
.crumbs a:hover{text-decoration:underline}
h1{font-size:clamp(28px,4.4vw,42px);font-weight:700;letter-spacing:-.02em;margin:0 0 14px;text-wrap:balance}
h2{font-size:clamp(21px,2.6vw,26px);font-weight:700;letter-spacing:-.02em;margin:44px 0 16px}
.intro{color:var(--ink-2);font-size:17px;line-height:1.7;margin:0;max-width:760px;text-wrap:pretty}
.upd{color:#8B98A1;font-size:13px;margin:16px 0 0}
.stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:14px;margin:28px 0 0}
.stat{background:var(--mint);border:1px solid var(--mint-b);border-radius:16px;padding:20px 18px;text-align:center}
.stat b{display:block;font-size:clamp(26px,3.6vw,34px);font-weight:800;color:var(--accent-d);letter-spacing:-.02em}
.stat span{display:block;font-size:13.5px;font-weight:500;color:#3D4A52;margin-top:6px;line-height:1.35}
.tw{overflow-x:auto;border:1px solid var(--line);border-radius:16px}
table{border-collapse:collapse;width:100%;min-width:560px;font-size:14.5px}
th,td{text-align:left;padding:12px 16px;border-bottom:1px solid var(--line);vertical-align:top}
th{background:var(--soft);font-weight:600;font-size:13px;color:#3D4A52;white-space:nowrap}
tr:last-child td{border-bottom:none}
td a{color:var(--accent-d);text-decoration:none;font-weight:500}
td a:hover{text-decoration:underline}
.tag{display:inline-block;border-radius:999px;padding:3px 9px;font-size:12px;font-weight:600;white-space:nowrap}
.dc{background:var(--mint);color:var(--mint-ink,#137A4C);border:1px solid var(--mint-b)}
.ac{background:#F1F4F6;color:#5A6671;border:1px solid #E1E7EB}
.chips{display:flex;flex-wrap:wrap;gap:10px;margin:0}
.chip{background:var(--soft);border:1px solid var(--line);border-radius:999px;padding:8px 15px;font-size:14px;font-weight:500}
.chip b{color:var(--accent-d);font-weight:700}
.links{display:flex;flex-wrap:wrap;gap:10px;margin:0}
.links a{background:var(--soft);border:1px solid var(--line);border-radius:10px;padding:9px 14px;
font-size:14px;font-weight:500;text-decoration:none;color:var(--ink)}
.links a:hover{border-color:var(--accent);color:var(--accent-d)}
.cta{background-color:var(--dark);background-image:radial-gradient(600px 400px at 50% 0%,rgba(43,213,148,.16),transparent 65%);
border-radius:20px;padding:clamp(28px,5vw,44px);margin:48px 0 0;text-align:center;color:#fff}
.cta h2{color:#fff;margin:0 0 12px}
.cta p{color:var(--on-dark);font-size:16px;line-height:1.65;margin:0 auto 24px;max-width:560px;text-wrap:pretty}
.cta .row{display:flex;flex-wrap:wrap;gap:12px;justify-content:center}
.cta a{background:var(--accent);color:var(--on-accent);text-decoration:none;border-radius:11px;
padding:13px 22px;font-size:15px;font-weight:600}
.cta a:hover{background:#25C486}
.faq details{border:1px solid var(--line);border-radius:14px;padding:0 20px;margin-bottom:10px;background:#fff}
.faq summary{display:flex;justify-content:space-between;gap:16px;align-items:center;padding:16px 0;
cursor:pointer;font-size:15.5px;font-weight:600;list-style:none}
.faq summary::-webkit-details-marker{display:none}
.faq summary::after{content:"+";color:var(--accent-d);font-size:20px;flex-shrink:0}
.faq details[open] summary::after{content:"–"}
.faq details p{color:var(--ink-2);font-size:15px;line-height:1.68;margin:0;padding:0 0 16px;text-wrap:pretty}
footer{background:var(--dark-2);color:#8B98A1}
.f-in{max-width:1100px;margin:0 auto;padding:26px clamp(20px,5vw,40px);display:flex;flex-wrap:wrap;
gap:12px 26px;justify-content:space-between;align-items:center;font-size:13px}
.f-in a{color:#B9C4CB;text-decoration:none;font-weight:500}
.f-in a:hover{color:var(--accent)}
/* The footer carries the full map of the site, including the sections that are
   deliberately not in the header nav (Turkey). One link from every page is what
   makes a section reachable at all, for a reader and for a crawler. */
.fnav{max-width:1100px;margin:0 auto;padding:30px clamp(20px,5vw,40px) 4px;
display:flex;flex-wrap:wrap;gap:10px 22px;border-bottom:1px solid rgba(255,255,255,.07)}
.fnav a{color:#B9C4CB;text-decoration:none;font-size:13.5px;font-weight:500}
.fnav a:hover{color:var(--accent)}
.fnav a.hi{color:#fff}
.fnav a.hi::before{content:"🇹🇷";margin-right:6px;font-size:12px}
.note{color:#8B98A1;font-size:13px;margin:12px 0 0}
.calc{display:grid;grid-template-columns:minmax(260px,1fr) minmax(240px,320px);gap:24px;
background:var(--soft);border:1px solid var(--line);border-radius:20px;padding:clamp(20px,3vw,30px);margin:28px 0 0}
.calc-in{display:grid;gap:14px;align-content:start}
.calc-in label{display:grid;gap:6px;font-size:14px;font-weight:600;color:var(--ink)}
.calc-in input,.calc-in select{width:100%;padding:11px 14px;border:1px solid #D7E0DB;border-radius:11px;
font-size:16px;font-family:inherit;font-weight:500;color:var(--ink);background:#fff;outline:none}
.calc-in input:focus,.calc-in select:focus{border-color:var(--accent);box-shadow:0 0 0 3px rgba(43,213,148,.18)}
.calc-out{background:#fff;border:1px solid var(--line);border-radius:16px;padding:22px;align-self:start}
.calc-big b{display:block;font-size:clamp(30px,4.5vw,40px);font-weight:800;color:var(--accent-d);letter-spacing:-.02em;line-height:1.1}
.calc-big span{display:block;font-size:13.5px;color:#5A6671;margin-top:4px}
.calc-small{display:grid;grid-template-columns:1fr 1fr;gap:14px;margin-top:18px;padding-top:16px;border-top:1px solid var(--line)}
.calc-small b{display:block;font-size:19px;font-weight:700;color:var(--ink)}
.calc-small span{display:block;font-size:12.5px;color:#77848C;margin-top:3px;line-height:1.35}
.calc-time{margin:16px 0 0;padding-top:14px;border-top:1px solid var(--line);font-size:13px;color:#77848C}
.calc-time b{display:block;color:var(--ink);font-weight:600;margin-top:4px;line-height:1.6}
/* Power presets for the time calculator. The ratings are the ones that really
   exist in Georgia, so the chips are a shortcut rather than a guess, and the
   number field stays editable for everything else. */
.pw{display:flex;flex-wrap:wrap;gap:7px;margin-top:2px}
.pw button{font:inherit;font-size:13px;font-weight:600;color:#5A6671;background:#fff;
border:1px solid #D7E0DB;border-radius:9px;padding:7px 11px;cursor:pointer;white-space:nowrap}
.pw button:hover{border-color:var(--accent)}
.pw button[aria-pressed="true"]{background:var(--mint);border-color:var(--mint-b);color:#137A4C}
.calc-band{margin:16px 0 0;padding-top:14px;border-top:1px solid var(--line);display:grid;gap:9px}
.calc-band div{display:flex;justify-content:space-between;gap:12px;font-size:13.5px;color:#5A6671}
.calc-band b{color:var(--ink);font-weight:700;white-space:nowrap}
.calc-hint{font-size:12.5px;color:#8B98A1;font-weight:500;margin:2px 0 0}
@media (max-width:700px){.calc{grid-template-columns:1fr}}
`.trim();

// `image` is the share card. Everything that does not pass one keeps the site
// cover, which is right for a catalogue page and wrong for an article: a feed
// full of identical thumbnails is a feed nobody clicks.
export function shell({ lang, title, desc, canonical, altHref, jsonld, body, image }) {
  const t = L[lang];
  const other = lang === 'ka' ? 'en' : 'ka';
  const kaHref = lang === 'ka' ? canonical : altHref;
  const enHref = lang === 'en' ? canonical : altHref;
  const og = image || `${ORIGIN}/assets/og-image.png`;
  return `<!DOCTYPE html>
<html lang="${t.code}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(title)}</title>
<meta name="description" content="${esc(desc)}">
<meta name="theme-color" content="#11161A">
<link rel="canonical" href="${canonical}">
<link rel="alternate" hreflang="ka" href="${kaHref}">
<link rel="alternate" hreflang="en" href="${enHref}">
<link rel="alternate" hreflang="x-default" href="${kaHref}">
<meta property="og:type" content="website">
<meta property="og:site_name" content="GeoCharge">
<meta property="og:locale" content="${lang === 'ka' ? 'ka_GE' : 'en_US'}">
<meta property="og:url" content="${canonical}">
<meta property="og:title" content="${esc(title)}">
<meta property="og:description" content="${esc(desc)}">
<meta property="og:image" content="${og}">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="${esc(title)}">
<meta name="twitter:description" content="${esc(desc)}">
<meta name="twitter:image" content="${og}">
<link rel="icon" href="/favicon.ico" sizes="any">
<link rel="icon" type="image/svg+xml" href="/assets/mark.svg">
<link rel="apple-touch-icon" href="/assets/icon-1024.png">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Poppins:wght@500;600;700;800&amp;family=Noto+Sans+Georgian:wght@400;500;600;700;800&amp;display=swap" rel="stylesheet">
<script type="application/ld+json">
${JSON.stringify(jsonld, null, 1)}
</script>
<style>
${CSS}
</style>
</head>
<body>
<header class="hdr">
  <div class="hdr-in">
    <a href="${t.base}/" aria-label="GeoCharge"><img src="/assets/logo-dark.svg" alt="GeoCharge" height="28" style="height:28px;display:block"></a>
    <nav class="hnav" aria-label="${lang === 'ka' ? 'ნავიგაცია' : 'Navigation'}">
      <a href="${t.base}/${t.chargersDir}/">${esc(t.catalog)}</a>
      <a href="${t.base}/${t.tariffsDir}/">${esc(t.tariffs)}</a>
      <a href="${t.base}/${t.calcDir}/">${esc(t.calc)}</a>
      <a href="${t.base}/${t.customsDir}/">${esc(t.customs)}</a>
      <a href="${t.base}/${t.routesDir}/">${esc(t.routes)}</a>
      <a href="${t.base}/blog/">${lang === 'ka' ? 'სტატიები' : 'Guides'}</a>
    </nav>
    <div class="lang" role="group" aria-label="${lang === 'ka' ? 'ენა' : 'Language'}">
      <a href="${kaHref.replace(ORIGIN, '')}"${lang === 'ka' ? ' aria-current="true"' : ''} hreflang="ka">ქარ</a>
      <a href="${enHref.replace(ORIGIN, '')}"${lang === 'en' ? ' aria-current="true"' : ''} hreflang="en">ENG</a>
    </div>
  </div>
</header>
<main>
${body}
<section class="cta">
  <h2>${esc(t.ctaTitle)}</h2>
  <p>${esc(t.ctaBody)}</p>
  <div class="row">
    <a href="${PLAY}" target="_blank" rel="noopener">${esc(t.ctaPlay)}</a>
    <a href="${APPSTORE}" target="_blank" rel="noopener">${esc(t.ctaStore)}</a>
  </div>
</section>
</main>
<footer>
  <nav class="fnav" aria-label="${lang === 'ka' ? 'საიტის რუკა' : 'Site map'}">
    <a href="${t.base}/${t.chargersDir}/">${esc(t.catalog)}</a>
    <a href="${t.base}/${t.tariffsDir}/">${esc(t.tariffs)}</a>
    <a href="${t.base}/${t.calcDir}/">${esc(t.calc)}</a>
    <a href="${t.base}/${t.timeDir}/">${esc(t.timeCalc)}</a>
    <a href="${t.base}/${t.networksDir}/">${esc(t.networks)}</a>
    <a href="${t.base}/${t.routesDir}/">${esc(t.routes)}</a>
    <a href="${t.base}/${t.customsDir}/">${esc(t.customs)}</a>
    <a href="${t.base}/blog/">${lang === 'ka' ? 'სტატიები' : 'Guides'}</a>
    <a class="hi" href="${t.base}/${t.turkeyDir}/">${lang === 'ka' ? 'დამტენები თურქეთში' : 'Chargers in Turkey'}</a>
  </nav>
  <div class="f-in">
    <p style="margin:0">© 2026 GeoCharge</p>
    <a href="${t.base}/">← geocharge.ge</a>
  </div>
</footer>
</body>
</html>
`;
}

const crumbs = (items) => `<nav class="crumbs" aria-label="breadcrumb">${
  items.map((i, n) => (i.href ? `<a href="${i.href}">${esc(i.name)}</a>` : `<span>${esc(i.name)}</span>`) +
    (n < items.length - 1 ? '<span aria-hidden="true">›</span>' : '')).join('')}</nav>`;

const breadcrumbLd = (items) => ({
  '@type': 'BreadcrumbList',
  itemListElement: items.map((i, n) => ({
    '@type': 'ListItem', position: n + 1, name: i.name,
    ...(i.href ? { item: ORIGIN + i.href } : {}),
  })),
});

/* ── the ONLY place that decides whether a city is linkable ──────────────────
   A network reaches towns that hold one or two chargers between them, and those
   towns are deliberately given no page of their own (see MIN_CITY_STATIONS).
   Linking them anyway is how this file used to emit 44 dead links, so every
   city link in the build goes through here. Filled by main() before any page
   is rendered; a city missing from it is printed as plain text. */
const CITY_PAGES = new Set();
const cityCell = (lang, key, label) => (CITY_PAGES.has(key)
  ? `<a href="${L[lang].base}/${L[lang].chargersDir}/${slug(key)}/">${esc(label)}</a>`
  : esc(label));

/* ── the ONLY place station fields reach the page ────────────────────────── */
function buildStationRows(list, lang, { showCity = false, showProvider = true } = {}) {
  const t = L[lang];
  const head = [t.thName, showProvider ? t.thProvider : null, showCity ? t.thCity : null,
    t.thType, t.thPower, t.thConnectors, SHOW_PRICE ? t.thPrice : null].filter(Boolean);
  const rows = list.map((s) => {
    const cells = [`<td>${esc(s.name || '—')}</td>`];
    if (showProvider) {
      const pslug = slug(s.provider);
      cells.push(`<td><a href="${t.base}/${t.networksDir}/${pslug}/">${esc(lang === 'ka' ? (PROVIDER_KA[s.provider] || s.provider) : s.provider)}</a></td>`);
    }
    if (showCity) {
      cells.push(s._city
        ? `<td>${cityCell(lang, s._city[0], lang === 'ka' ? s._city[1] : s._city[0])}</td>`
        : '<td>—</td>');
    }
    const dc = s.type === 'Fast DC';
    cells.push(`<td><span class="tag ${dc ? 'dc' : 'ac'}">${dc ? 'DC' : 'AC'}</span></td>`);
    cells.push(`<td>${esc(s.power && s.power !== '—' ? s.power : '—')}</td>`);
    cells.push(`<td>${esc((s.connectors || []).join(', ') || '—')}</td>`);
    if (SHOW_PRICE) cells.push(`<td>${esc(s.price || t.noPrice)}</td>`);
    return `<tr>${cells.join('')}</tr>`;
  });
  return `<div class="tw"><table>
<thead><tr>${head.map((h) => `<th>${esc(h)}</th>`).join('')}</tr></thead>
<tbody>
${rows.join('\n')}
</tbody></table></div>${SHOW_PRICE ? `\n<p class="note">${esc(L[lang].priceNote)}</p>` : ''}`;
}

function summarise(list) {
  const dc = list.filter((s) => s.type === 'Fast DC').length;
  const providers = [...new Set(list.map((s) => s.provider))];
  const powers = list.map(kw).filter(Boolean);
  const conn = {};
  for (const s of list) for (const c of (s.connectors || [])) conn[c] = (conn[c] || 0) + 1;
  return {
    total: list.length, dc, ac: list.length - dc, providers,
    maxKw: powers.length ? Math.max(...powers) : 0,
    connectors: Object.entries(conn).sort((a, b) => b[1] - a[1]),
  };
}

const statBlock = (sum, lang, n = (x) => x) => {
  const t = L[lang];
  return `<div class="stats">
  <div class="stat"><b>${n(sum.total)}</b><span>${esc(t.stations)}</span></div>
  <div class="stat"><b>${n(sum.dc)}</b><span>${esc(t.fast)}</span></div>
  <div class="stat"><b>${n(sum.ac)}</b><span>${esc(t.slow)}</span></div>
  <div class="stat"><b>${sum.providers.length}</b><span>${esc(t.networksWord)}</span></div>
  ${sum.maxKw ? `<div class="stat"><b>${sum.maxKw} kW</b><span>${esc(t.maxPower)}</span></div>` : ''}
</div>`;
};

const connectorChips = (sum, lang, fmt = (x) => x) => `<h2>${esc(L[lang].connectorMix)}</h2>
<div class="chips">${sum.connectors.map(([c, n]) => `<span class="chip"><b>${fmt(n)}</b> ${esc(c)}</span>`).join('')}</div>`;

/* ── page builders ───────────────────────────────────────────────────────── */
function catalogPage(lang, all, byCity, byProvider, updated) {
  const t = L[lang], sum = summarise(all);
  const url = `${ORIGIN}${t.base}/${t.chargersDir}/`;
  const alt = `${ORIGIN}${L[lang === 'ka' ? 'en' : 'ka'].base}/${L[lang === 'ka' ? 'en' : 'ka'].chargersDir}/`;
  const cities = [...byCity.entries()].sort((a, b) => b[1].length - a[1].length);
  const provs = [...byProvider.entries()].sort((a, b) => b[1].length - a[1].length);

  const title = lang === 'ka'
    ? `ელექტრო მანქანის დამტენები საქართველოში, ${sum.total} სადგური | GeoCharge`
    : `EV charging stations in Georgia — ${sum.total} stations | GeoCharge`;
  const desc = lang === 'ka'
    ? `საქართველოს ${sum.total} საჯარო დამტენი სადგური ერთ სიაში: ${sum.dc} სწრაფი DC, ${sum.providers.length} ქსელი, ქალაქებისა და კონექტორის ტიპის მიხედვით.`
    : `All ${sum.total} public EV chargers in Georgia in one list: ${sum.dc} fast DC, ${sum.providers.length} networks, broken down by city and connector type.`;

  const intro = lang === 'ka'
    ? `საქართველოში ამჟამად <strong>${sum.total} საჯარო დამტენი სადგურია</strong> ${sum.providers.length} ქსელში. მათგან ${sum.dc} სწრაფი DC დამტენია, ${sum.ac} კი ჩვეულებრივი AC. ყველაზე მძლავრი სადგური ${sum.maxKw} kW-ია. სია ავტომატურად ახლდება უშუალოდ პროვაიდერებისგან.`
    : `Georgia currently has <strong>${sum.total} public EV charging stations</strong> across ${sum.providers.length} networks. ${sum.dc} of them are fast DC chargers and ${sum.ac} are standard AC. The most powerful station delivers ${sum.maxKw} kW. This list updates automatically, straight from the providers.`;

  const bc = [{ name: t.home, href: `${t.base}/` }, { name: t.catalog }];

  const faq = lang === 'ka' ? [
    [`რამდენი ელექტრო მანქანის დამტენია საქართველოში?`,
      `ამჟამად ${sum.total} საჯარო დამტენი სადგური, ${sum.providers.length} სხვადასხვა ქსელში. აქედან ${sum.dc} სწრაფი DC დამტენია.`],
    [`სად არის ყველაზე მეტი დამტენი?`,
      `${cities[0] ? cities[0][1][0]._city[2] : ''}, სულ ${cities[0] ? cities[0][1].length : 0} სადგური. შემდეგ მოდის ${cities[1] ? cities[1][1][0]._city[1] : ''} (${cities[1] ? cities[1][1].length : 0}).`],
    [`რომელი კონექტორები გვხვდება საქართველოში?`,
      `ყველაზე გავრცელებულია ${sum.connectors.slice(0, 3).map(([c, n]) => `${c} (${n})`).join(', ')}. სრული განაწილება ამ გვერდზეა.`],
    [`სად ვნახო, დამტენი თავისუფალია თუ არა?`,
      `ცოცხალი სტატუსი და რუკა GeoCharge-ის უფასო აპლიკაციაშია. ამ გვერდზე მხოლოდ სადგურების კატალოგია.`],
  ] : [
    [`How many EV chargers are there in Georgia?`,
      `${sum.total} public charging stations right now, across ${sum.providers.length} different networks. ${sum.dc} of them are fast DC chargers.`],
    [`Which city has the most chargers?`,
      `${cities[0] ? cities[0][0] : ''} with ${cities[0] ? cities[0][1].length : 0} stations, followed by ${cities[1] ? cities[1][0] : ''} (${cities[1] ? cities[1][1].length : 0}).`],
    [`Which connectors are used in Georgia?`,
      `The most common are ${sum.connectors.slice(0, 3).map(([c, n]) => `${c} (${n})`).join(', ')}. The full breakdown is on this page.`],
    [`Where can I see whether a charger is free?`,
      `Live availability and the map are in the free GeoCharge app — this page is the station catalogue only.`],
  ];

  const body = `${crumbs(bc)}
<h1>${esc(t.catalogTitle)}</h1>
<p class="intro">${intro}</p>
${statBlock(sum, lang)}
<p class="upd">${esc(t.updated)} ${esc(updated)}</p>

<div class="links" style="margin-top:22px">
  <a href="${t.base}/${t.tariffsDir}/">${esc(t.tariffs)}</a>
  <a href="${t.base}/${t.calcDir}/">${esc(t.calc)}</a>
  <a href="${t.base}/${t.timeDir}/">${esc(t.timeCalc)}</a>
  <a href="${t.base}/${t.routesDir}/">${esc(t.routes)}</a>
  <a href="${t.base}/${t.networksDir}/">${esc(t.networks)}</a>
  <a href="${t.base}/${t.turkeyDir}/">${lang === 'ka' ? 'დამტენები თურქეთში' : 'Chargers in Turkey'}</a>
</div>

<h2>${esc(t.byCity)}</h2>
<div class="tw"><table>
<thead><tr><th>${esc(t.thCity)}</th><th>${esc(t.thCount)}</th><th>${esc(t.fast)}</th><th>${esc(t.thProvider)}</th></tr></thead>
<tbody>
${cities.map(([cityEn, list]) => {
    const c = list[0]._city, s = summarise(list);
    const name = lang === 'ka' ? c[1] : c[0];
    return `<tr><td><a href="${t.base}/${t.chargersDir}/${slug(cityEn)}/">${esc(name)}</a></td><td>${s.total}</td><td>${s.dc}</td><td>${s.providers.length}</td></tr>`;
  }).join('\n')}
</tbody></table></div>

<h2>${esc(t.byNetwork)}</h2>
<div class="tw"><table>
<thead><tr><th>${esc(t.thProvider)}</th><th>${esc(t.thCount)}</th><th>${esc(t.fast)}</th><th>${esc(t.slow)}</th><th>${esc(t.maxPower)}</th></tr></thead>
<tbody>
${provs.map(([p, list]) => {
    const s = summarise(list);
    return `<tr><td><a href="${t.base}/${t.networksDir}/${slug(p)}/">${esc(lang === 'ka' ? (PROVIDER_KA[p] || p) : p)}</a></td><td>${s.total}</td><td>${s.dc}</td><td>${s.ac}</td><td>${s.maxKw ? s.maxKw + ' kW' : '—'}</td></tr>`;
  }).join('\n')}
</tbody></table></div>

${connectorChips(sum, lang)}

<h2>${esc(t.faq)}</h2>
<div class="faq">
${faq.map(([q, a]) => `<details><summary>${esc(q)}</summary><p>${esc(a)}</p></details>`).join('\n')}
</div>`;

  return {
    file: path.join(SITE, t.base.replace('/', ''), t.chargersDir, 'index.html'),
    url,
    html: shell({
      lang, title, desc, canonical: url, altHref: alt, body,
      jsonld: {
        '@context': 'https://schema.org',
        '@graph': [
          breadcrumbLd(bc),
          {
            '@type': 'CollectionPage', '@id': url + '#page', name: title, url,
            inLanguage: t.code, description: desc,
            isPartOf: { '@type': 'WebSite', '@id': `${ORIGIN}/#website` },
          },
          {
            '@type': 'FAQPage', inLanguage: t.code,
            mainEntity: faq.map(([q, a]) => ({
              '@type': 'Question', name: q,
              acceptedAnswer: { '@type': 'Answer', text: a },
            })),
          },
        ],
      },
    }),
  };
}

function cityPage(lang, city, list, allCities, updated) {
  const t = L[lang], sum = summarise(list);
  const s = slug(city[0]);
  const url = `${ORIGIN}${t.base}/${t.chargersDir}/${s}/`;
  const o = L[lang === 'ka' ? 'en' : 'ka'];
  const alt = `${ORIGIN}${o.base}/${o.chargersDir}/${s}/`;
  const name = lang === 'ka' ? city[1] : city[0];
  const loc = lang === 'ka' ? city[2] : `in ${city[0]}`;
  const top = [...new Set(list.map((x) => x.provider))]
    .map((p) => [p, list.filter((x) => x.provider === p).length])
    .sort((a, b) => b[1] - a[1]);

  const title = lang === 'ka'
    ? `ელექტრო მანქანის დამტენები ${loc}, ${sum.total} სადგური | GeoCharge`
    : `EV charging stations ${loc} — ${sum.total} stations | GeoCharge`;
  const desc = lang === 'ka'
    ? `${name}: ${sum.total} საჯარო დამტენი სადგური, ${sum.dc} სწრაფი DC. ქსელები: ${top.slice(0, 3).map((x) => x[0]).join(', ')}. სიმძლავრე, კონექტორები და ტარიფები.`
    : `${name}: ${sum.total} public EV chargers, ${sum.dc} fast DC. Networks: ${top.slice(0, 3).map((x) => x[0]).join(', ')}. Power, connectors and tariffs.`;

  const intro = lang === 'ka'
    ? `${loc} ${sum.total} საჯარო დამტენი სადგურია: ${sum.dc} სწრაფი DC და ${sum.ac} ჩვეულებრივი AC. ისინი ${sum.providers.length} ქსელს ეკუთვნის, ყველაზე დიდი წილი ${PROVIDER_KA[top[0][0]] || top[0][0]}-ს აქვს (${top[0][1]} სადგური).${sum.maxKw ? ` ყველაზე მძლავრი დამტენი ${sum.maxKw} kW-ია.` : ''}`
    : `${name} has ${sum.total} public charging stations — ${sum.dc} fast DC and ${sum.ac} standard AC. They belong to ${sum.providers.length} networks, with ${top[0][0]} operating the most (${top[0][1]} stations).${sum.maxKw ? ` The most powerful charger here delivers ${sum.maxKw} kW.` : ''}`;

  const bc = [{ name: t.home, href: `${t.base}/` },
    { name: t.catalog, href: `${t.base}/${t.chargersDir}/` }, { name }];

  const others = allCities.filter(([c]) => c !== city[0]).slice(0, 18);

  const faq = lang === 'ka' ? [
    [`რამდენი ელექტრო დამტენია ${loc}?`, `${sum.total} საჯარო დამტენი სადგური, აქედან ${sum.dc} სწრაფი DC.`],
    [`რომელი ქსელების დამტენებია ${loc}?`, `${top.map((x) => `${PROVIDER_KA[x[0]] || x[0]} (${x[1]})`).join(', ')}.`],
    [`რომელი კონექტორები გვხვდება ${loc}?`, `${sum.connectors.map(([c, n]) => `${c} (${n})`).join(', ')}.`],
  ] : [
    [`How many EV chargers are there ${loc}?`, `${sum.total} public charging stations, ${sum.dc} of them fast DC.`],
    [`Which networks operate ${loc}?`, `${top.map((x) => `${x[0]} (${x[1]})`).join(', ')}.`],
    [`Which connectors are available ${loc}?`, `${sum.connectors.map(([c, n]) => `${c} (${n})`).join(', ')}.`],
  ];

  const body = `${crumbs(bc)}
<h1>${lang === 'ka' ? `ელექტრო მანქანის დამტენები ${esc(loc)}` : `EV charging stations ${esc(loc)}`}</h1>
<p class="intro">${intro}</p>
${statBlock(sum, lang)}
<p class="upd">${esc(t.updated)} ${esc(updated)}</p>

<h2>${esc(t.byNetwork)}</h2>
<div class="tw"><table>
<thead><tr><th>${esc(t.thProvider)}</th><th>${esc(t.thCount)}</th></tr></thead>
<tbody>
${top.map(([p, n]) => `<tr><td><a href="${t.base}/${t.networksDir}/${slug(p)}/">${esc(lang === 'ka' ? (PROVIDER_KA[p] || p) : p)}</a></td><td>${n}</td></tr>`).join('\n')}
</tbody></table></div>

<h2>${esc(t.allStations)}</h2>
${buildStationRows(list.slice().sort((a, b) => kw(b) - kw(a)), lang)}

${connectorChips(sum, lang)}

<h2>${esc(t.faq)}</h2>
<div class="faq">
${faq.map(([q, a]) => `<details><summary>${esc(q)}</summary><p>${esc(a)}</p></details>`).join('\n')}
</div>

<h2>${esc(t.otherCities)}</h2>
<div class="links">
<a href="${t.base}/${t.chargersDir}/">${esc(t.backToAll)}</a>
${others.map(([c, l]) => `<a href="${t.base}/${t.chargersDir}/${slug(c)}/">${esc(lang === 'ka' ? l[0]._city[1] : c)} (${l.length})</a>`).join('\n')}
</div>`;

  return {
    file: path.join(SITE, t.base.replace('/', ''), t.chargersDir, s, 'index.html'),
    url,
    html: shell({
      lang, title, desc, canonical: url, altHref: alt, body,
      jsonld: {
        '@context': 'https://schema.org',
        '@graph': [
          breadcrumbLd(bc),
          {
            '@type': 'CollectionPage', '@id': url + '#page', name: title, url,
            inLanguage: t.code, description: desc,
            about: { '@type': 'City', name: city[0] },
            isPartOf: { '@type': 'WebSite', '@id': `${ORIGIN}/#website` },
          },
          {
            '@type': 'FAQPage', inLanguage: t.code,
            mainEntity: faq.map(([q, a]) => ({
              '@type': 'Question', name: q,
              acceptedAnswer: { '@type': 'Answer', text: a },
            })),
          },
        ],
      },
    }),
  };
}

function providerPage(lang, provider, list, allProviders, updated) {
  const t = L[lang], sum = summarise(list);
  const s = slug(provider);
  const url = `${ORIGIN}${t.base}/${t.networksDir}/${s}/`;
  const o = L[lang === 'ka' ? 'en' : 'ka'];
  const alt = `${ORIGIN}${o.base}/${o.networksDir}/${s}/`;
  const name = lang === 'ka' ? (PROVIDER_KA[provider] || provider) : provider;
  const cities = [...new Set(list.filter((x) => x._city).map((x) => x._city[0]))]
    .map((c) => [c, list.filter((x) => x._city && x._city[0] === c)])
    .sort((a, b) => b[1].length - a[1].length);

  const title = lang === 'ka'
    ? `${provider} დამტენები საქართველოში, ${sum.total} სადგური | GeoCharge`
    : `${provider} chargers in Georgia — ${sum.total} stations | GeoCharge`;
  const desc = lang === 'ka'
    ? `${name}: ${sum.total} დამტენი სადგური საქართველოში, ${sum.dc} სწრაფი DC. მდებარეობები, სიმძლავრე, კონექტორები და ტარიფები.`
    : `${provider}: ${sum.total} charging stations in Georgia, ${sum.dc} fast DC. Locations, power, connectors and tariffs.`;

  const intro = lang === 'ka'
    ? `${name} საქართველოში ${sum.total} საჯარო დამტენ სადგურს ოპერირებს: ${sum.dc} სწრაფი DC და ${sum.ac} AC.${sum.maxKw ? ` ქსელის ყველაზე მძლავრი დამტენი ${sum.maxKw} kW-ია.` : ''} სადგურები ${cities.length} ქალაქშია განთავსებული.`
    : `${provider} operates ${sum.total} public charging stations in Georgia — ${sum.dc} fast DC and ${sum.ac} AC.${sum.maxKw ? ` Its most powerful charger delivers ${sum.maxKw} kW.` : ''} The stations are spread across ${cities.length} cities.`;

  const bc = [{ name: t.home, href: `${t.base}/` },
    { name: t.catalog, href: `${t.base}/${t.chargersDir}/` }, { name: provider }];

  const logo = PROVIDER_LOGO[provider];

  const faq = lang === 'ka' ? [
    [`რამდენი ${provider} დამტენია საქართველოში?`, `${sum.total} საჯარო დამტენი სადგური, აქედან ${sum.dc} სწრაფი DC.`],
    [`რომელ ქალაქებშია ${provider}-ის დამტენები?`, `${cities.slice(0, 8).map((c) => `${lang === 'ka' ? c[1][0]._city[1] : c[0]} (${c[1].length})`).join(', ')}${cities.length > 8 ? ' და სხვა.' : '.'}`],
    [`რომელი კონექტორები აქვს ${provider}-ს?`, `${sum.connectors.map(([c, n]) => `${c} (${n})`).join(', ')}.`],
  ] : [
    [`How many ${provider} chargers are there in Georgia?`, `${sum.total} public charging stations, ${sum.dc} of them fast DC.`],
    [`Which cities have ${provider} chargers?`, `${cities.slice(0, 8).map((c) => `${c[0]} (${c[1].length})`).join(', ')}${cities.length > 8 ? ' and more.' : '.'}`],
    [`Which connectors does ${provider} use?`, `${sum.connectors.map(([c, n]) => `${c} (${n})`).join(', ')}.`],
  ];

  const body = `${crumbs(bc)}
${logo ? `<img src="/assets/providers/${logo}" alt="${esc(provider)}" style="max-height:44px;margin:0 0 14px;display:block">` : ''}
<h1>${lang === 'ka' ? `${esc(provider)} დამტენები საქართველოში` : `${esc(provider)} chargers in Georgia`}</h1>
<p class="intro">${intro}</p>
${statBlock(sum, lang)}
<p class="upd">${esc(t.updated)} ${esc(updated)}</p>

<h2>${esc(t.byCity)}</h2>
<div class="tw"><table>
<thead><tr><th>${esc(t.thCity)}</th><th>${esc(t.thCount)}</th></tr></thead>
<tbody>
${cities.map(([c, l]) => `<tr><td>${cityCell(lang, c, lang === 'ka' ? l[0]._city[1] : c)}</td><td>${l.length}</td></tr>`).join('\n')}
</tbody></table></div>

<h2>${esc(t.allStations)}</h2>
${buildStationRows(list.slice().sort((a, b) => kw(b) - kw(a)), lang, { showCity: true, showProvider: false })}

${connectorChips(sum, lang)}

<h2>${esc(t.faq)}</h2>
<div class="faq">
${faq.map(([q, a]) => `<details><summary>${esc(q)}</summary><p>${esc(a)}</p></details>`).join('\n')}
</div>

<h2>${esc(t.otherNetworks)}</h2>
<div class="links">
<a href="${t.base}/${t.chargersDir}/">${esc(t.backToAll)}</a>
${allProviders.filter(([p]) => p !== provider).map(([p, l]) => `<a href="${t.base}/${t.networksDir}/${slug(p)}/">${esc(lang === 'ka' ? (PROVIDER_KA[p] || p) : p)} (${l.length})</a>`).join('\n')}
</div>`;

  return {
    file: path.join(SITE, t.base.replace('/', ''), t.networksDir, s, 'index.html'),
    url,
    html: shell({
      lang, title, desc, canonical: url, altHref: alt, body,
      jsonld: {
        '@context': 'https://schema.org',
        '@graph': [
          breadcrumbLd(bc),
          {
            '@type': 'CollectionPage', '@id': url + '#page', name: title, url,
            inLanguage: t.code, description: desc,
            about: { '@type': 'Organization', name: provider },
            isPartOf: { '@type': 'WebSite', '@id': `${ORIGIN}/#website` },
          },
          {
            '@type': 'FAQPage', inLanguage: t.code,
            mainEntity: faq.map(([q, a]) => ({
              '@type': 'Question', name: q,
              acceptedAnswer: { '@type': 'Answer', text: a },
            })),
          },
        ],
      },
    }),
  };
}

/* ── tariffs ─────────────────────────────────────────────────────────────── */
// Prices above 2 GEL/kWh are provider data errors (one EcoCars row reads 50.02),
// not premium tariffs. Excluded so the medians stay honest.
function priceOf(s) {
  const m = /^([\d.]+)\s*₾/.exec(String(s.price || ''));
  if (!m) return null;
  const v = parseFloat(m[1]);
  return v > 0 && v <= 2 ? v : null;
}
export const median = (v) => {
  const a = v.slice().sort((x, y) => x - y);
  return a.length % 2 ? a[(a.length - 1) / 2] : (a[a.length / 2 - 1] + a[a.length / 2]) / 2;
};
const fmt = (n) => n.toFixed(2);
const range = (v, t) => (v.length
  ? `${fmt(Math.min(...v))} .. ${fmt(Math.max(...v))} <span style="color:#8A97A0">(${t.median} ${fmt(median(v))})</span>`
  : '—');

export function tariffStats(list) {
  const dc = [], ac = [];
  let noPrice = 0;
  for (const s of list) {
    const p = priceOf(s);
    if (p === null) { noPrice++; continue; }
    (s.type === 'Fast DC' ? dc : ac).push(p);
  }
  return { dc, ac, noPrice, total: list.length };
}

function tariffPage(lang, ge, byProvider, updated) {
  const t = L[lang];
  const o = L[lang === 'ka' ? 'en' : 'ka'];
  const url = `${ORIGIN}${t.base}/${t.tariffsDir}/`;
  const alt = `${ORIGIN}${o.base}/${o.tariffsDir}/`;
  const rows = [...byProvider.entries()]
    .map(([p, list]) => [p, tariffStats(list)])
    .sort((a, b) => b[1].total - a[1].total);
  const all = tariffStats(ge);
  const withDc = rows.filter((r) => r[1].dc.length);
  const withAc = rows.filter((r) => r[1].ac.length);
  const cheapDc = withDc.slice().sort((a, b) => median(a[1].dc) - median(b[1].dc))[0];
  const dearDc = withDc.slice().sort((a, b) => median(b[1].dc) - median(a[1].dc))[0];
  const cheapAc = withAc.slice().sort((a, b) => median(a[1].ac) - median(b[1].ac))[0];
  const nm = (p) => (lang === 'ka' ? (PROVIDER_KA[p] || p) : p);

  const title = lang === 'ka'
    ? 'დატენვის ტარიფები საქართველოში, ქსელების შედარება | GeoCharge'
    : 'EV charging tariffs in Georgia, network by network | GeoCharge';
  const desc = lang === 'ka'
    ? `რომელი ქსელი რა ტარიფს იღებს საქართველოში. DC ${fmt(Math.min(...all.dc))} ლარიდან, AC ${fmt(Math.min(...all.ac))} ლარიდან. ცხრილი ავტომატურად ახლდება.`
    : `What each charging network in Georgia charges. DC from ${fmt(Math.min(...all.dc))} GEL, AC from ${fmt(Math.min(...all.ac))} GEL. The table updates automatically.`;

  const bc = [{ name: t.home, href: `${t.base}/` },
    { name: t.catalog, href: `${t.base}/${t.chargersDir}/` }, { name: t.tariffs }];

  const faq = lang === 'ka' ? [
    ['რომელი ქსელია ყველაზე იაფი საქართველოში?',
      `სწრაფ DC დატენვაზე ${nm(cheapDc[0])}, მედიანური ტარიფით ${fmt(median(cheapDc[1].dc))} ლარი. ნელ AC დატენვაზე ${nm(cheapAc[0])}, ${fmt(median(cheapAc[1].ac))} ლარი.`],
    ['რატომ არ აქვს ზოგიერთ დამტენს მითითებული ფასი?',
      `საქართველოს ${all.total} სადგურიდან ${all.noPrice} ტარიფს არ აქვეყნებს საჯარო API-ში. ეს ჩვეულებრივ სასტუმროების, სავაჭრო ცენტრებისა და რესტორნების დამტენებია, სადაც დატენვა კლიენტისთვის უფასოა, ან ფასი ადგილზე ჩანს.`],
    ['რამდენად ხშირად იცვლება ეს ციფრები?',
      'ცხრილი უშუალოდ პროვაიდერების მონაცემებიდან ახლდება, ყოველდღიურად. ტარიფებს ოპერატორები რამდენიმე თვეში ერთხელ ცვლიან.'],
    ['DC თუ AC, რომელი ჯობია ფასის მიხედვით?',
      `AC საშუალოდ იაფია: მედიანა ${fmt(median(all.ac))} ლარი, DC-ზე კი ${fmt(median(all.dc))}. სამაგიეროდ AC-ზე დატენვას საათები სჭირდება.`],
  ] : [
    ['Which network is cheapest in Georgia?',
      `For fast DC it is ${cheapDc[0]}, with a median tariff of ${fmt(median(cheapDc[1].dc))} GEL. For slow AC it is ${cheapAc[0]} at ${fmt(median(cheapAc[1].ac))} GEL.`],
    ['Why do some chargers show no price?',
      `Of Georgia's ${all.total} stations, ${all.noPrice} publish no tariff in their public API. These are typically at hotels, shopping centres and restaurants, where charging is free for customers or the price is shown on site.`],
    ['How often do these figures change?',
      'The table refreshes daily, straight from the providers. Operators themselves change tariffs every few months.'],
    ['DC or AC, which is better value?',
      `AC is cheaper on average: a median of ${fmt(median(all.ac))} GEL against ${fmt(median(all.dc))} for DC. AC charging takes hours, though.`],
  ];

  const body = `${crumbs(bc)}
<h1>${lang === 'ka' ? 'ელექტრომობილის დატენვის ტარიფები საქართველოში' : 'EV charging tariffs in Georgia'}</h1>
<p class="intro">${lang === 'ka'
    ? `ქვემოთ მოცემულია, რა ტარიფს იღებს საქართველოს თითოეული დამტენი ქსელი. ციფრები უშუალოდ პროვაიდერების საჯარო მონაცემებიდან მოდის და ყოველდღიურად ახლდება. ამჟამად ტარიფი გამოქვეყნებული აქვს ${all.total - all.noPrice} სადგურს ${all.total}-დან.`
    : `Below is what each charging network in Georgia charges. The figures come straight from the providers' public data and refresh daily. Right now ${all.total - all.noPrice} of ${all.total} stations publish a tariff.`}</p>
<div class="stats">
  <div class="stat"><b>${fmt(median(all.dc))} ₾</b><span>${lang === 'ka' ? 'DC მედიანა' : 'DC median'}</span></div>
  <div class="stat"><b>${fmt(median(all.ac))} ₾</b><span>${lang === 'ka' ? 'AC მედიანა' : 'AC median'}</span></div>
  <div class="stat"><b>${esc(nm(cheapDc[0]))}</b><span>${esc(t.cheapestDc)}</span></div>
  <div class="stat"><b>${esc(nm(dearDc[0]))}</b><span>${esc(t.dearestDc)}</span></div>
</div>
<p class="upd">${esc(t.updated)} ${esc(updated)}</p>
<div class="links" style="margin-top:22px">
  <a href="${t.base}/${t.calcDir}/" style="background:var(--mint);border-color:var(--mint-b);color:var(--mint-ink,#137A4C);font-weight:600">${lang === 'ka' ? 'გამოთვალეთ თქვენი დატენვის ღირებულება' : 'Work out what your charge will cost'}</a>
  <a href="${t.base}/${t.chargersDir}/">${esc(t.backToAll)}</a>
  <a href="${t.base}/${t.networksDir}/">${esc(t.networks)}</a>
</div>

<h2>${lang === 'ka' ? 'ტარიფები ქსელების მიხედვით' : 'Tariffs by network'}</h2>
<div class="tw"><table>
<thead><tr><th>${esc(t.thProvider)}</th><th>${esc(t.thCount)}</th><th>${esc(t.thDc)}</th><th>${esc(t.thAc)}</th><th>${esc(t.thNoPrice)}</th></tr></thead>
<tbody>
${rows.map(([p, s]) => `<tr><td><a href="${t.base}/${t.networksDir}/${slug(p)}/">${esc(nm(p))}</a></td><td>${s.total}</td><td>${range(s.dc, t)}</td><td>${range(s.ac, t)}</td><td>${s.noPrice || '—'}</td></tr>`).join('\n')}
</tbody></table></div>
<p class="note">${esc(t.priceNote)} ${lang === 'ka'
    ? '2 ლარზე მაღალი ერთეული მნიშვნელობები მონაცემთა შეცდომაა და გამოთვლაში არ მონაწილეობს.'
    : 'Isolated values above 2 GEL are data errors and are excluded from the figures.'}</p>

<h2>${lang === 'ka' ? 'როგორ წავიკითხოთ ეს ცხრილი' : 'How to read this table'}</h2>
<p class="intro" style="margin-bottom:14px">${lang === 'ka'
    ? 'დიაპაზონი აჩვენებს ყველაზე დაბალ და ყველაზე მაღალ ტარიფს ქსელის შიგნით, მედიანა კი იმას, რასაც ყველაზე ხშირად შეხვდებით. ერთ ქსელს სხვადასხვა სადგურზე სხვადასხვა ფასი შეიძლება ჰქონდეს, რადგან ტარიფი დამოკიდებულია იმაზეც, თუ ვის ეკუთვნის ადგილი, სადაც დამტენი დგას.'
    : 'The range shows the lowest and highest tariff inside a network, and the median shows what you will most often meet. One network can price differently across its stations, because the tariff also depends on who owns the site the charger sits on.'}</p>
<p class="intro">${esc(t.howToCalc)}: <a href="${t.base}/blog/datenvis-fasi/" style="color:var(--accent-d);font-weight:500;text-decoration:none">${lang === 'ka' ? 'რამდენი ღირს ელექტრომობილის დატენვა' : 'how much does it cost to charge an EV'}</a>.</p>

<h2>${esc(t.faq)}</h2>
<div class="faq">
${faq.map(([q, a]) => `<details><summary>${esc(q)}</summary><p>${esc(a)}</p></details>`).join('\n')}
</div>`;

  return {
    file: path.join(SITE, t.base.replace('/', ''), t.tariffsDir, 'index.html'),
    url,
    html: shell({
      lang, title, desc, canonical: url, altHref: alt, body,
      jsonld: {
        '@context': 'https://schema.org',
        '@graph': [
          breadcrumbLd(bc),
          { '@type': 'CollectionPage', '@id': url + '#page', name: title, url, inLanguage: t.code, description: desc,
            isPartOf: { '@type': 'WebSite', '@id': `${ORIGIN}/#website` } },
          { '@type': 'FAQPage', inLanguage: t.code,
            mainEntity: faq.map(([q, a]) => ({ '@type': 'Question', name: q, acceptedAnswer: { '@type': 'Answer', text: a } })) },
        ],
      },
    }),
  };
}

/* ── charging cost calculator ────────────────────────────────────────────────
   The widget is progressive enhancement. Crawlers and language models cannot
   run it, so the same answers are also published as a static table below it,
   which is what actually gets indexed and quoted. */
function calculatorPage(lang, ge, byProvider, updated) {
  const t = L[lang];
  const o = L[lang === 'ka' ? 'en' : 'ka'];
  const url = `${ORIGIN}${t.base}/${t.calcDir}/`;
  const alt = `${ORIGIN}${o.base}/${o.calcDir}/`;
  const nm = (p) => (lang === 'ka' ? (PROVIDER_KA[p] || p) : p);
  const all = tariffStats(ge);
  const dcMed = median(all.dc), acMed = median(all.ac);

  const presets = [...byProvider.entries()]
    .map(([p, list]) => [p, tariffStats(list)])
    .sort((a, b) => b[1].total - a[1].total);

  const SIZES = [40, 60, 75, 100];
  const exampleRow = (kwh) => {
    const added = kwh * 0.6;            // the usual 20 to 80 percent window
    return `<tr><td>${kwh} kWh</td><td>${added.toFixed(0)} kWh</td><td>${(added * dcMed).toFixed(2)} ₾</td><td>${(added * acMed).toFixed(2)} ₾</td></tr>`;
  };

  const title = lang === 'ka'
    ? 'დატენვის ხარჯის კალკულატორი | GeoCharge'
    : 'EV charging cost calculator for Georgia | GeoCharge';
  const desc = lang === 'ka'
    ? `გამოთვალეთ, რამდენი დაგიჯდებათ ერთი დატენვა საქართველოში. ტარიფები 11 ქსელიდან, ავტომატურად განახლებადი. 60 kWh ბატარეა 20-დან 80%-მდე დაახლოებით ${(36 * dcMed).toFixed(0)} ლარია.`
    : `Work out what one charge costs in Georgia. Tariffs from all 11 networks, updated automatically. A 60 kWh battery from 20 to 80 percent is about ${(36 * dcMed).toFixed(0)} GEL.`;

  const bc = [{ name: t.home, href: `${t.base}/` },
    { name: t.catalog, href: `${t.base}/${t.chargersDir}/` }, { name: t.calc }];

  const faq = lang === 'ka' ? [
    ['როგორ გამოვთვალო დატენვის ღირებულება?',
      `ბატარეის ტევადობა გაამრავლეთ შესავსებ პროცენტზე და მიღებული კილოვატსაათები ტარიფზე. მაგალითად 60 kWh ბატარეა 20-დან 80 პროცენტამდე არის 36 kWh, რაც ${dcMed.toFixed(2)} ლარიან DC ტარიფზე ${(36 * dcMed).toFixed(2)} ლარია.`],
    ['რა ტარიფია საქართველოში ახლა?',
      `სწრაფ DC დამტენზე მედიანური ტარიფი ${dcMed.toFixed(2)} ლარია კილოვატსაათზე, ნელ AC დამტენზე ${acMed.toFixed(2)}. ქსელების მიხედვით სრული სურათი ტარიფების გვერდზეა.`],
    ['რატომ არ ემთხვევა რეალური ჩეკი გამოთვლას?',
      'ორი მიზეზით. ბატარეაში შესული ენერგია ყოველთვის ოდნავ ნაკლებია იმაზე, რასაც დამტენი ხარჯავს, რადგან ნაწილი სითბოდ იკარგება. ასევე ზოგი ოპერატორი დატენვის შემდეგ დგომას ცალკე ურიცხავს.'],
  ] : [
    ['How do I calculate charging cost?',
      `Multiply battery capacity by the share you are adding, then multiply the kilowatt hours by the tariff. A 60 kWh battery from 20 to 80 percent is 36 kWh, which at a ${dcMed.toFixed(2)} GEL DC tariff comes to ${(36 * dcMed).toFixed(2)} GEL.`],
    ['What is the current tariff in Georgia?',
      `The median fast DC tariff is ${dcMed.toFixed(2)} GEL per kWh and the median slow AC tariff is ${acMed.toFixed(2)}. The full picture by network is on the tariffs page.`],
    ['Why does the real receipt differ from the calculation?',
      'Two reasons. The energy that reaches the battery is always slightly less than the charger draws, since some is lost as heat. And some operators bill separately for occupying the bay after charging ends.'],
  ];

  const S = lang === 'ka' ? {
    h1: 'ელექტრომობილის დატენვის ხარჯის კალკულატორი',
    intro: `შეიყვანეთ ბატარეის ტევადობა და მუხტის დონე, კალკულატორი გამოთვლის, რამდენი კილოვატსაათი შედის და რა დაგიჯდებათ. ტარიფები საქართველოს ${presets.length} ქსელის ცოცხალი მონაცემებიდან მოდის.`,
    battery: 'ბატარეის ტევადობა (kWh)', from: 'მიმდინარე მუხტი (%)', to: 'სასურველი მუხტი (%)',
    tariff: 'ტარიფი (₾ / kWh)', preset: 'აირჩიეთ ქსელი', custom: 'სხვა, ხელით',
    added: 'ბატარეაში შედის', cost: 'ღირებულება', per100: '100 კილომეტრზე',
    cons: 'ხარჯი (kWh / 100 კმ)', timeH: 'რამდენი ხანი დასჭირდება',
    exampleH: 'ტიპური დატენვის ღირებულება', exampleP: `ქვემოთ ერთი დატენვის ღირებულებაა 20-დან 80 პროცენტამდე, ${dcMed.toFixed(2)} ლარიან DC და ${acMed.toFixed(2)} ლარიან AC მედიანურ ტარიფზე.`,
    thBattery: 'ბატარეა', thAdded: 'შედის', thDc: 'DC ღირებულება', thAc: 'AC ღირებულება',
    howH: 'როგორ ითვლება', dcOpt: 'სწრაფი DC', acOpt: 'ნელი AC',
    note: 'შედეგი სავარაუდოა. რეალური თანხა ოდნავ განსხვავდება, რადგან ენერგიის ნაწილი სითბოდ იკარგება.',
    more: 'დეტალურად, რატომ განსხვავდება ტარიფები და რა ჯდება სახლში დატენვა',
  } : {
    h1: 'EV charging cost calculator',
    intro: `Enter your battery size and charge levels and the calculator works out how many kilowatt hours go in and what it costs. Tariffs come from live data across Georgia's ${presets.length} networks.`,
    battery: 'Battery capacity (kWh)', from: 'Current charge (%)', to: 'Target charge (%)',
    tariff: 'Tariff (GEL / kWh)', preset: 'Pick a network', custom: 'Other, enter manually',
    added: 'Energy added', cost: 'Cost', per100: 'Per 100 km',
    cons: 'Consumption (kWh / 100 km)', timeH: 'How long it takes',
    exampleH: 'What a typical charge costs', exampleP: `Below is the cost of one charge from 20 to 80 percent at the median tariffs of ${dcMed.toFixed(2)} GEL on DC and ${acMed.toFixed(2)} GEL on AC.`,
    thBattery: 'Battery', thAdded: 'Added', thDc: 'DC cost', thAc: 'AC cost',
    howH: 'How it is calculated', dcOpt: 'Fast DC', acOpt: 'Slow AC',
    note: 'The result is an estimate. The real amount differs slightly because some energy is lost as heat.',
    more: 'More on why tariffs differ and what home charging costs',
  };

  const body = `${crumbs(bc)}
<h1>${esc(S.h1)}</h1>
<p class="intro">${esc(S.intro)}</p>

<div class="calc">
  <div class="calc-in">
    <label>${esc(S.battery)}<input type="number" id="c-batt" value="60" min="5" max="250" step="1"></label>
    <label>${esc(S.from)}<input type="number" id="c-from" value="20" min="0" max="100" step="1"></label>
    <label>${esc(S.to)}<input type="number" id="c-to" value="80" min="0" max="100" step="1"></label>
    <label>${esc(S.preset)}<select id="c-preset">
      <optgroup label="${esc(S.dcOpt)}">
${presets.filter((p) => p[1].dc.length).map(([p, s]) => `        <option value="${median(s.dc).toFixed(2)}">${esc(nm(p))} ${median(s.dc).toFixed(2)} ₾</option>`).join('\n')}
      </optgroup>
      <optgroup label="${esc(S.acOpt)}">
${presets.filter((p) => p[1].ac.length).map(([p, s]) => `        <option value="${median(s.ac).toFixed(2)}">${esc(nm(p))} ${median(s.ac).toFixed(2)} ₾</option>`).join('\n')}
      </optgroup>
      <option value="">${esc(S.custom)}</option>
    </select></label>
    <label>${esc(S.tariff)}<input type="number" id="c-price" value="${dcMed.toFixed(2)}" min="0" max="5" step="0.01"></label>
    <label>${esc(S.cons)}<input type="number" id="c-cons" value="18" min="5" max="40" step="0.5"></label>
  </div>
  <div class="calc-out">
    <div class="calc-big"><b id="c-cost">—</b><span>${esc(S.cost)}</span></div>
    <div class="calc-small">
      <div><b id="c-kwh">—</b><span>${esc(S.added)}</span></div>
      <div><b id="c-100">—</b><span>${esc(S.per100)}</span></div>
    </div>
    <p class="calc-time"><span>${esc(S.timeH)}:</span> <b id="c-time">—</b></p>
  </div>
</div>
<p class="note">${esc(S.note)}</p>

<h2>${esc(S.exampleH)}</h2>
<p class="intro" style="margin-bottom:16px">${esc(S.exampleP)}</p>
<div class="tw"><table>
<thead><tr><th>${esc(S.thBattery)}</th><th>${esc(S.thAdded)}</th><th>${esc(S.thDc)}</th><th>${esc(S.thAc)}</th></tr></thead>
<tbody>
${SIZES.map(exampleRow).join('\n')}
</tbody></table></div>
<p class="upd">${esc(t.updated)} ${esc(updated)}</p>

<h2>${esc(S.howH)}</h2>
<p class="intro">${lang === 'ka'
    ? 'ფორმულა ერთი ნაბიჯია. ბატარეის ტევადობა გაამრავლეთ იმ პროცენტზე, რასაც ავსებთ, და მიღებული კილოვატსაათები ტარიფზე. ერთადერთი, რაც ამას ართულებს, არის ის, რომ სწრაფი დამტენი 80 პროცენტის შემდეგ მკვეთრად ანელებს, ამიტომ დროის შეფასება ამ ზღვარს ზემოთ ოპტიმისტურია.'
    : 'The formula is one step: battery capacity times the share you are adding, then the kilowatt hours times the tariff. The only complication is that fast chargers slow down sharply above 80 percent, so the time estimate is optimistic beyond that point.'}</p>
<p class="intro">${esc(S.more)}: <a href="${t.base}/blog/datenvis-fasi/" style="color:var(--accent-d);font-weight:500;text-decoration:none">${lang === 'ka' ? 'რამდენი ღირს დატენვა' : 'how much charging costs'}</a>. ${lang === 'ka' ? 'ქსელების ტარიფები' : 'Tariffs by network'}: <a href="${t.base}/${t.tariffsDir}/" style="color:var(--accent-d);font-weight:500;text-decoration:none">${esc(t.tariffs)}</a>. ${lang === 'ka' ? 'რამდენ ხანში დაიტენება' : 'How long the charge takes'}: <a href="${t.base}/${t.timeDir}/" style="color:var(--accent-d);font-weight:500;text-decoration:none">${esc(t.timeCalc)}</a>.</p>

<h2>${esc(t.faq)}</h2>
<div class="faq">
${faq.map(([q, a]) => `<details><summary>${esc(q)}</summary><p>${esc(a)}</p></details>`).join('\n')}
</div>

<script>
${chargeProfile.toString()}
(function(){
  var $=function(i){return document.getElementById(i);};
  var batt=$('c-batt'),from=$('c-from'),to=$('c-to'),price=$('c-price'),cons=$('c-cons'),preset=$('c-preset');
  var POWERS=[7,22,60,120];
  function calc(){
    var b=parseFloat(batt.value)||0,f=parseFloat(from.value)||0,tt=parseFloat(to.value)||0;
    var p=parseFloat(price.value)||0,c=parseFloat(cons.value)||0;
    var share=Math.max(0,Math.min(100,tt)-Math.max(0,f))/100;
    var kwh=b*share, cost=kwh*p;
    $('c-kwh').textContent=kwh?kwh.toFixed(1)+' kWh':'—';
    $('c-cost').textContent=kwh?cost.toFixed(2)+' ₾':'—';
    $('c-100').textContent=(c&&p)?(c*p).toFixed(2)+' ₾':'—';
    // Same model as the charging time page, so the two never disagree.
    $('c-time').textContent=kwh?POWERS.map(function(w){
      var r=chargeProfile(b,w,f,tt);
      var m=r?Math.round(r.minutes):0;
      var H='${lang === 'ka' ? 'სთ' : 'h'}',M='${lang === 'ka' ? 'წთ' : 'm'}';
      if(m<60) return w+' kW: '+m+M;
      var hh=Math.floor(m/60),mm=m%60;
      return w+' kW: '+hh+H+(mm?' '+mm+M:'');
    }).join('  ·  '):'—';
  }
  preset.addEventListener('change',function(){ if(preset.value) price.value=preset.value; calc(); });
  [batt,from,to,price,cons].forEach(function(el){ el.addEventListener('input',calc); });
  calc();
})();
</script>`;

  return {
    file: path.join(SITE, t.base.replace('/', ''), t.calcDir, 'index.html'),
    url,
    html: shell({
      lang, title, desc, canonical: url, altHref: alt, body,
      jsonld: {
        '@context': 'https://schema.org',
        '@graph': [
          breadcrumbLd(bc),
          { '@type': 'WebApplication', '@id': url + '#app', name: title, url,
            applicationCategory: 'UtilitiesApplication', operatingSystem: 'Any',
            browserRequirements: 'Requires JavaScript', inLanguage: t.code, description: desc,
            offers: { '@type': 'Offer', price: '0', priceCurrency: 'GEL' },
            isPartOf: { '@type': 'WebSite', '@id': `${ORIGIN}/#website` } },
          { '@type': 'FAQPage', inLanguage: t.code,
            mainEntity: faq.map(([q, a]) => ({ '@type': 'Question', name: q, acceptedAnswer: { '@type': 'Answer', text: a } })) },
        ],
      },
    }),
  };
}

/* ── charging time calculator ────────────────────────────────────────────────
   The cost calculator answers what a charge costs. This one answers how long
   it takes, which is the question that gets asked before a long drive.
   A flat "kWh divided by kW" is wrong by a wide margin near a full battery, so
   the model integrates over the pack's acceptance curve instead. */

// Share of its peak DC rate a pack accepts, per 10 percent band of charge.
// Flat while the pack is empty, then the taper that every fast charge ends in.
// Deliberately ES5 and free of outer references: this same function is
// serialised into the page, so the widget and the published tables cannot
// drift apart.
function chargeProfile(batteryKwh, chargerKw, fromPct, toPct, peakKw) {
  var ACCEPT = [0.85, 1, 1, 0.95, 0.85, 0.72, 0.6, 0.48, 0.32, 0.18];
  var peak = peakKw > 0 ? peakKw : batteryKwh * 2;
  var eff = chargerKw > 22 ? 0.94 : 0.89;   // DC loses less than an onboard charger
  var lo = Math.max(0, Math.min(100, fromPct));
  var hi = Math.max(0, Math.min(100, toPct));
  if (!(batteryKwh > 0) || !(chargerKw > 0) || !(hi > lo)) return null;
  var minutes = 0, kwh = 0;
  for (var i = 0; i < 10; i++) {
    var a = Math.max(lo, i * 10), b = Math.min(hi, i * 10 + 10);
    if (b <= a) continue;
    var e = batteryKwh * (b - a) / 100;
    kwh += e;
    minutes += (e / eff) / Math.min(chargerKw, peak * ACCEPT[i]) * 60;
  }
  return { minutes: minutes, kwh: kwh, avgKw: (kwh / eff) / (minutes / 60) };
}

// The power ratings a driver in Georgia actually meets, most common first, plus
// 7 kW because charging at home is the other half of the question.
function powerPresets(ge) {
  const n = new Map();
  for (const s of ge) { const k = kw(s); if (k) n.set(k, (n.get(k) || 0) + 1); }
  const top = [...n.entries()].sort((a, b) => b[1] - a[1]).slice(0, 6).map(([k]) => k);
  return [...new Set([7, ...top])].sort((a, b) => a - b);
}

function fmtMinutes(m, lang) {
  if (m == null) return '—';
  const t = Math.round(m), h = Math.floor(t / 60), mm = t % 60;
  const H = lang === 'ka' ? 'სთ' : 'h', M = lang === 'ka' ? 'წთ' : 'min';
  return t < 60 ? `${t} ${M}` : `${h} ${H}${mm ? ` ${mm} ${M}` : ''}`;
}

function timeCalculatorPage(lang, ge, updated) {
  const t = L[lang];
  const o = L[lang === 'ka' ? 'en' : 'ka'];
  const url = `${ORIGIN}${t.base}/${t.timeDir}/`;
  const alt = `${ORIGIN}${o.base}/${o.timeDir}/`;
  const ka = lang === 'ka';

  const presets = powerPresets(ge);
  const dcPresets = presets.filter((p) => p >= 22);
  const SIZES = [40, 60, 75, 100];
  const mn = (m) => fmtMinutes(m, lang);
  const at = (b, w, from, to) => chargeProfile(b, w, from, to)?.minutes ?? null;

  // The headline example the description and the FAQ both quote.
  const ex = Math.round(at(60, 60, 20, 80));
  const exFast = Math.round(at(60, 120, 20, 80));
  const exTail = Math.round(at(60, 120, 80, 100));

  const title = ka
    ? 'დატენვის დროის კალკულატორი | GeoCharge'
    : 'EV charging time calculator for Georgia | GeoCharge';
  const desc = ka
    ? `გამოთვალეთ, რამდენ ხანში დაიტენება თქვენი ელექტრომობილი. მიუთითეთ ბატარეა, დამტენის სიმძლავრე და მუხტის დონე. 60 kWh ბატარეა 60 kW დამტენზე 20 პროცენტიდან 80 პროცენტამდე დაახლოებით ${ex} წუთში ივსება.`
    : `Work out how long your EV takes to charge. Enter the battery, the charger's power and the charge levels. A 60 kWh battery on a 60 kW charger goes from 20 to 80 percent in about ${ex} minutes.`;

  const bc = [{ name: t.home, href: `${t.base}/` },
    { name: t.catalog, href: `${t.base}/${t.chargersDir}/` }, { name: t.timeCalc }];

  const faq = ka ? [
    ['რამდენ ხანში იტენება ელექტრომობილი?',
      `დამოკიდებულია ბატარეაზე და დამტენის სიმძლავრეზე. 60 kWh ბატარეა 20 პროცენტიდან 80 პროცენტამდე 60 kW დამტენზე დაახლოებით ${ex} წუთს ითხოვს, 120 kW დამტენზე კი ${exFast} წუთს. სახლის 7 kW დამტენზე იგივე მუხტი ${mn(at(60, 7, 20, 80))} სჭირდება.`],
    ['რატომ ნელდება დატენვა 80 პროცენტის შემდეგ?',
      `ბატარეა რაც უფრო ივსება, მით ნაკლებ დენს იღებს, რადგან მართვის სისტემა უჯრედებს იცავს. სწორედ ამიტომ 60 kWh ბატარეას 120 kW დამტენზე 20 პროცენტიდან 80 პროცენტამდე ${exFast} წუთი სჭირდება, ბოლო 20 პროცენტს კი დამატებით ${exTail} წუთი. გრძელ გზაზე ორი მოკლე გაჩერება 80 პროცენტამდე უფრო სწრაფია, ვიდრე ერთი გრძელი 100 პროცენტამდე.`],
    ['რატომ არ ვიღებ დამტენზე მითითებულ სიმძლავრეს?',
      'რიცხვი დამტენზე მისი ზღვარია, არა თქვენი მანქანის. რეალური სიმძლავრე არის ამ ორიდან უმცირესი და მასზე მოქმედებს მუხტის დონეც, ბატარეის ტემპერატურაც და ის, დგას თუ არა მეორე მანქანა იმავე კაბინეტზე. ცივ ბატარეას გახურება სჭირდება, ამიტომ ზამთარში პირველი წუთები ყოველთვის ნელია.'],
    ['რა განსხვავებაა AC და DC დატენვას შორის?',
      'AC დამტენი დენს მანქანის ბორტულ გარდამქმნელში ატარებს, რომელსაც ჩვეულებრივ 7-დან 22 kW-მდე ზღვარი აქვს, სამაგიეროდ სიმძლავრე თითქმის 100 პროცენტამდე უცვლელი რჩება. DC დამტენი ბორტულ გარდამქმნელს გვერდს უვლის და პირდაპირ ბატარეას კვებავს, ამიტომ ბევრად სწრაფია, მაგრამ სწორედ მას აქვს გამოხატული შენელება მაღალ მუხტზე.'],
  ] : [
    ['How long does it take to charge an EV?',
      `It depends on the battery and the charger. A 60 kWh battery from 20 to 80 percent takes about ${ex} minutes on a 60 kW charger and ${exFast} minutes on a 120 kW one. On a 7 kW home charger the same top up takes ${mn(at(60, 7, 20, 80))}.`],
    ['Why does charging slow down after 80 percent?',
      `The fuller the pack, the less current it accepts, because the battery management system protects the cells. That is why a 60 kWh battery on a 120 kW charger needs ${exFast} minutes from 20 to 80 percent and another ${exTail} minutes for the last 20. On a long drive two short stops to 80 percent beat one long stop to 100.`],
    ['Why am I not getting the power written on the charger?',
      "That number is the charger's limit, not your car's. The real rate is the lower of the two, and it also depends on the state of charge, the battery temperature and whether another car is sharing the same cabinet. A cold pack has to warm up first, so the opening minutes in winter are always slow."],
    ['What is the difference between AC and DC charging?',
      'An AC charger feeds the car through its onboard converter, usually capped between 7 and 22 kW, but it holds that power almost all the way to 100 percent. A DC charger bypasses the onboard converter and feeds the pack directly, which is far quicker, and it is the one with the pronounced taper at high states of charge.'],
  ];

  const S = ka ? {
    h1: 'ელექტრომობილის დატენვის დროის კალკულატორი',
    intro: `მიუთითეთ ბატარეის ტევადობა, დამტენის სიმძლავრე და მუხტის დონე. კალკულატორი ითვლის დატენვის რეალური მრუდით, ამიტომ ბოლო პროცენტები იმაზე ნელა ივსება, ვიდრე უბრალო გაყოფა აჩვენებდა. სიმძლავრის ღილაკები საქართველოში არსებული დამტენების ნამდვილი მაჩვენებლებია.`,
    battery: 'ბატარეის ტევადობა (kWh)', power: 'დამტენის სიმძლავრე (kW)',
    peak: 'მანქანის მაქსიმალური სიმძლავრე (kW)',
    peakHint: 'ავტომატურად ივსება ბატარეის ტევადობის მიხედვით. თუ იცით თქვენი მანქანის ზღვარი, შეცვალეთ.',
    from: 'მიმდინარე მუხტი (%)', to: 'სასურველი მუხტი (%)',
    result: 'დატენვის დრო', added: 'ბატარეაში შედის', avg: 'საშუალო სიმძლავრე',
    bandH: 'იმავე დამტენზე', band8: '20 პროცენტიდან 80-მდე', band10: 'ბოლო 20 პროცენტი',
    note: 'შედეგი შეფასებაა. ზუსტი დრო მანქანის მოდელზე, ბატარეის ტემპერატურაზე და დამტენის დატვირთვაზეა დამოკიდებული. ზამთარში ცივი ბატარეა პირველ წუთებში უფრო ნელა იტენება.',
    tableH: 'რამდენ ხანში ივსება 20 პროცენტიდან 80-მდე',
    tableP: 'სვეტებში საქართველოში ყველაზე გავრცელებული სიმძლავრეებია, სტრიქონებში ტიპური ბატარეები.',
    thBattery: 'ბატარეა',
    tailH: 'რას ცვლის ბოლო 20 პროცენტი',
    tailP: '60 kWh ბატარეა. ბოლო მეხუთედი დამტენის სიმძლავრეს თითქმის აღარ უყურებს. 47 kW-იან და 160 kW-იან დამტენზე მას ერთი და იგივე დრო სჭირდება, რადგან ამ ეტაპზე ზღვარს ბატარეა აწესებს, არა დამტენი. სწრაფ დამტენზე ბოლო 20 პროცენტი მთელ 20-დან 80 პროცენტამდე მონაკვეთზე მეტ დროს ითხოვს.',
    thPower: 'დამტენი', thFull: '20 პროცენტიდან 100-მდე',
    howH: 'როგორ ითვლება',
    how: 'დროს ორი რამ განსაზღვრავს. პირველი, რამდენი კილოვატსაათი შედის ბატარეაში, ეს ტევადობა გამრავლებული შესავსებ პროცენტზე. მეორე, რა სიმძლავრით შედის, და აი ეს მუდმივი არაა. კალკულატორი მუხტის დიაპაზონს ათ მონაკვეთად ყოფს და თითოეულში ირჩევს უმცირესს ორ რიცხვს შორის: დამტენის სიმძლავრესა და იმას, რისი მიღებაც მანქანას ამ მუხტზე შეუძლია. ენერგიის დაახლოებით 6 პროცენტი სითბოდ იკარგება DC დატენვისას და 11 პროცენტი AC დატენვისას, ესეც გათვლილია.',
    more: 'რა დაჯდება ეს დატენვა',
  } : {
    h1: 'EV charging time calculator',
    intro: `Enter your battery size, the charger's power and the charge levels. The calculator follows the real charging curve, so the last percentages fill more slowly than plain division would suggest. The power buttons are the ratings that actually exist on chargers in Georgia.`,
    battery: 'Battery capacity (kWh)', power: 'Charger power (kW)',
    peak: "Car's maximum power (kW)",
    peakHint: 'Filled automatically from the battery size. Change it if you know your car’s limit.',
    from: 'Current charge (%)', to: 'Target charge (%)',
    result: 'Charging time', added: 'Energy added', avg: 'Average power',
    bandH: 'On the same charger', band8: '20 to 80 percent', band10: 'The last 20 percent',
    note: 'The result is an estimate. The exact time depends on the car, the battery temperature and how busy the charger is. A cold pack in winter charges slowly for the first few minutes.',
    tableH: 'How long 20 to 80 percent takes',
    tableP: 'The columns are the most common power ratings in Georgia, the rows are typical battery sizes.',
    thBattery: 'Battery',
    tailH: 'What the last 20 percent costs you',
    tailP: 'A 60 kWh battery. The last fifth barely notices how strong the charger is. It takes the same time on a 47 kW unit as on a 160 kW one, because at that point the pack sets the limit, not the charger. On a fast charger the last 20 percent takes longer than the whole 20 to 80 percent stretch.',
    thPower: 'Charger', thFull: '20 to 100 percent',
    howH: 'How it is calculated',
    how: 'Two things set the time. First, how many kilowatt hours go into the pack, which is capacity times the share you are adding. Second, how fast they go in, and that part is not constant. The calculator splits the range into ten bands and in each one takes the lower of the charger’s power and what the car will accept at that state of charge. About 6 percent of the energy is lost as heat on DC and 11 percent on AC, and that is accounted for too.',
    more: 'What this charge will cost',
  };

  const chips = presets.map((p) => `<button type="button" data-kw="${p}">${p} kW</button>`).join('');

  const body = `${crumbs(bc)}
<h1>${esc(S.h1)}</h1>
<p class="intro">${esc(S.intro)}</p>

<div class="calc">
  <div class="calc-in">
    <label>${esc(S.battery)}<input type="number" id="t-batt" value="60" min="5" max="250" step="1"></label>
    <label>${esc(S.power)}<input type="number" id="t-pw" value="60" min="1" max="400" step="1"></label>
    <div class="pw" id="t-chips">${chips}</div>
    <label>${esc(S.from)}<input type="number" id="t-from" value="20" min="0" max="100" step="1"></label>
    <label>${esc(S.to)}<input type="number" id="t-to" value="80" min="0" max="100" step="1"></label>
    <label>${esc(S.peak)}<input type="number" id="t-peak" value="120" min="3" max="400" step="1"></label>
    <p class="calc-hint">${esc(S.peakHint)}</p>
  </div>
  <div class="calc-out">
    <div class="calc-big"><b id="t-time">—</b><span>${esc(S.result)}</span></div>
    <div class="calc-small">
      <div><b id="t-kwh">—</b><span>${esc(S.added)}</span></div>
      <div><b id="t-avg">—</b><span>${esc(S.avg)}</span></div>
    </div>
    <div class="calc-band">
      <div><span>${esc(S.band8)}</span><b id="t-b8">—</b></div>
      <div><span>${esc(S.band10)}</span><b id="t-b10">—</b></div>
    </div>
  </div>
</div>
<p class="note">${esc(S.note)}</p>

<h2>${esc(S.tableH)}</h2>
<p class="intro" style="margin-bottom:16px">${esc(S.tableP)}</p>
<div class="tw"><table>
<thead><tr><th>${esc(S.thBattery)}</th>${dcPresets.map((p) => `<th>${p} kW</th>`).join('')}</tr></thead>
<tbody>
${SIZES.map((b) => `<tr><td>${b} kWh</td>${dcPresets.map((p) => `<td>${mn(at(b, p, 20, 80))}</td>`).join('')}</tr>`).join('\n')}
</tbody></table></div>

<h2>${esc(S.tailH)}</h2>
<p class="intro" style="margin-bottom:16px">${esc(S.tailP)}</p>
<div class="tw"><table>
<thead><tr><th>${esc(S.thPower)}</th><th>${esc(S.band8)}</th><th>${esc(S.band10)}</th><th>${esc(S.thFull)}</th></tr></thead>
<tbody>
${dcPresets.map((p) => `<tr><td>${p} kW</td><td>${mn(at(60, p, 20, 80))}</td><td>${mn(at(60, p, 80, 100))}</td><td>${mn(at(60, p, 20, 100))}</td></tr>`).join('\n')}
</tbody></table></div>
<p class="upd">${esc(t.updated)} ${esc(updated)}</p>

<div class="links" style="margin-top:22px">
  <a href="${t.base}/${t.calcDir}/" style="background:var(--mint);border-color:var(--mint-b);color:var(--mint-ink,#137A4C);font-weight:600">${esc(S.more)}</a>
  <a href="${t.base}/${t.tariffsDir}/">${esc(t.tariffs)}</a>
  <a href="${t.base}/${t.chargersDir}/">${esc(t.backToAll)}</a>
  <a href="${t.base}/${t.routesDir}/">${esc(t.routes)}</a>
</div>

<h2>${esc(S.howH)}</h2>
<p class="intro">${esc(S.how)}</p>

<h2>${esc(t.faq)}</h2>
<div class="faq">
${faq.map(([q, a]) => `<details><summary>${esc(q)}</summary><p>${esc(a)}</p></details>`).join('\n')}
</div>

<script>
${chargeProfile.toString()}
(function(){
  var $=function(i){return document.getElementById(i);};
  var batt=$('t-batt'),pw=$('t-pw'),peak=$('t-peak'),from=$('t-from'),to=$('t-to');
  var H='${ka ? 'სთ' : 'h'}',M='${ka ? 'წთ' : 'min'}',touched=false;
  function fmt(m){
    if(m==null) return '—';
    var t=Math.round(m),h=Math.floor(t/60),mm=t%60;
    return t<60 ? t+' '+M : h+' '+H+(mm?' '+mm+' '+M:'');
  }
  function calc(){
    var b=parseFloat(batt.value)||0,w=parseFloat(pw.value)||0;
    if(!touched){ peak.value=Math.round(b*2)||''; }
    var pk=parseFloat(peak.value)||0;
    var r=chargeProfile(b,w,parseFloat(from.value)||0,parseFloat(to.value)||0,pk);
    $('t-time').textContent=r?fmt(r.minutes):'—';
    $('t-kwh').textContent=r?r.kwh.toFixed(1)+' kWh':'—';
    $('t-avg').textContent=r?Math.round(r.avgKw)+' kW':'—';
    var a=chargeProfile(b,w,20,80,pk),c=chargeProfile(b,w,80,100,pk);
    $('t-b8').textContent=a?fmt(a.minutes):'—';
    $('t-b10').textContent=c?'+ '+fmt(c.minutes):'—';
    var kws=$('t-chips').getElementsByTagName('button');
    for(var i=0;i<kws.length;i++){ kws[i].setAttribute('aria-pressed', parseFloat(kws[i].getAttribute('data-kw'))===w?'true':'false'); }
  }
  $('t-chips').addEventListener('click',function(e){
    var el=e.target.closest('button[data-kw]');
    if(!el) return;
    pw.value=el.getAttribute('data-kw');
    calc();
  });
  peak.addEventListener('input',function(){ touched=true; });
  [batt,pw,peak,from,to].forEach(function(el){ el.addEventListener('input',calc); });
  calc();
})();
</script>`;

  return {
    file: path.join(SITE, t.base.replace('/', ''), t.timeDir, 'index.html'),
    url,
    html: shell({
      lang, title, desc, canonical: url, altHref: alt, body,
      jsonld: {
        '@context': 'https://schema.org',
        '@graph': [
          breadcrumbLd(bc),
          { '@type': 'WebApplication', '@id': url + '#app', name: title, url,
            applicationCategory: 'UtilitiesApplication', operatingSystem: 'Any',
            browserRequirements: 'Requires JavaScript', inLanguage: t.code, description: desc,
            offers: { '@type': 'Offer', price: '0', priceCurrency: 'GEL' },
            isPartOf: { '@type': 'WebSite', '@id': `${ORIGIN}/#website` } },
          { '@type': 'FAQPage', inLanguage: t.code,
            mainEntity: faq.map(([q, a]) => ({ '@type': 'Question', name: q, acceptedAnswer: { '@type': 'Answer', text: a } })) },
        ],
      },
    }),
  };
}

/* ── customs clearance, straight from the Revenue Service ────────────────────
   Tax rules change and a wrong number here costs more trust than the page can
   ever earn back, so nothing on the customs page is written by hand. Every
   figure is what rs.ge's own calculator answers at build time, and the fee list
   is parsed out of the script rs.ge serves to its own visitors. Rebuild and the
   page is current; if rs.ge is unreachable the cache from the last successful
   build is used and the page says when that was. */
const RSGE = 'https://rs.ge';
const RSGE_PAGE = `${RSGE}/CarClearance?cat=2&tab=1`;
const RSGE_CACHE = path.join(ROOT, 'tools', '.cache', 'rsge-clearance.json');
const EXTRA_DAY = 5;   // GEL per day, rs.ge charges this past the declaration deadline

// Years are relative to the build, never hard coded, so "a ten year old car"
// stays a ten year old car in 2030.
function clearanceCases() {
  const y = new Date().getFullYear();
  return {
    evNew:    { Celi: y,      Zravismoculoba: 0.1, elektroCar: true },
    evUsed:   { Celi: y - 10, Zravismoculoba: 0.1, elektroCar: true },
    evRhd:    { Celi: y,      Zravismoculoba: 2.0, elektroCar: true, sWheel: true },
    ice16New: { Celi: y,      Zravismoculoba: 1.6 },
    ice16Old: { Celi: y - 10, Zravismoculoba: 1.6 },
    ice20New: { Celi: y,      Zravismoculoba: 2.0 },
    ice20Old: { Celi: y - 10, Zravismoculoba: 2.0 },
    hyb20New: { Celi: y,      Zravismoculoba: 2.0, hybridCar: true },
  };
}

async function fetchClearance() {
  const page = await fetch(RSGE_PAGE);
  if (!page.ok) throw new Error(`rs.ge page: HTTP ${page.status}`);
  const cookie = page.headers.getSetCookie().map((c) => c.split(';')[0]).join('; ');
  const html = await page.text();
  const token = (/name="__RequestVerificationToken" type="hidden" value="([^"]+)"/.exec(html) || [])[1];
  if (!token) throw new Error('rs.ge: no request verification token in the page');

  // The service fees live in a plain object literal in their own script. Read
  // them from there rather than retyping them, so a fee change lands on the
  // next build instead of being noticed months later.
  const js = await (await fetch(`${RSGE}/Modules/RsGe.Module/scripts/CarClearance.js`)).text();
  const block = (/pricesForCar\s*=\s*\{([^}]*)\}/.exec(js) || [])[1];
  if (!block) throw new Error('rs.ge: could not read the service fee list');
  const fees = {};
  for (const m of block.matchAll(/(\w+)\s*:\s*([\d.]+)/g)) fees[m[1]] = parseFloat(m[2]);

  const ask = async (params) => {
    const body = new URLSearchParams({
      hybridCar: false, elektroCar: false, sWheel: false, SportCar: false, ClassicCar: false,
      ...params, __RequestVerificationToken: token,
    });
    const r = await fetch(`${RSGE}/RsGe.Module/CarClearance/Calculate`, {
      method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded', cookie }, body,
    });
    if (!r.ok) throw new Error(`rs.ge calculate: HTTP ${r.status}`);
    const j = await r.json();
    return { excise: parseFloat(j.Aqcizi), duty: parseFloat(j.Sabgad) };
  };

  const cases = clearanceCases();
  const results = {};
  for (const [k, v] of Object.entries(cases)) results[k] = { ...await ask(v), ...v };
  return { checked: new Date().toISOString().slice(0, 10), fees, cases: results };
}

async function clearanceData(offline) {
  const cached = existsSync(RSGE_CACHE) ? JSON.parse(await readFile(RSGE_CACHE, 'utf8')) : null;
  if (offline && cached) {
    console.log(`· rs.ge: using cached clearance figures from ${cached.checked}`);
    return cached;
  }
  try {
    const fresh = await fetchClearance();
    await mkdir(path.dirname(RSGE_CACHE), { recursive: true });
    await writeFile(RSGE_CACHE, JSON.stringify(fresh, null, 1), 'utf8');
    const ev = fresh.cases.evNew;
    console.log(`· rs.ge: checked ${fresh.checked}, electric excise ${ev.excise}, import duty ${ev.duty}`);
    return fresh;
  } catch (e) {
    if (!cached) throw new Error(`rs.ge unreachable and no cache to fall back on: ${e.message}`);
    console.warn(`  !! rs.ge unreachable (${e.message}), falling back to ${cached.checked}`);
    return cached;
  }
}

const CUSTOMS_CSS = `
.answer{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(240px,100%),1fr));gap:16px;margin:28px 0 0}
.answer div{background:linear-gradient(180deg,var(--mint),#fff);border:1px solid var(--mint-b);border-radius:20px;padding:26px 24px}
.answer b{display:block;font-size:clamp(40px,6vw,56px);font-weight:800;color:var(--accent-d);letter-spacing:-.03em;line-height:1}
.answer span{display:block;font-size:15px;font-weight:600;color:#1B5E42;margin-top:10px}
.answer i{display:block;font-style:normal;font-size:13.5px;color:#4C6B5C;margin-top:6px;line-height:1.5}
.ledger{background:#fff;border:1px solid var(--line);border-radius:20px;padding:8px 24px;margin:24px 0 0;max-width:620px}
.ledger label{display:flex;align-items:center;gap:14px;padding:14px 0;border-bottom:1px solid var(--line);cursor:pointer}
.ledger label:last-of-type{border-bottom:none}
.ledger input{width:18px;height:18px;accent-color:var(--accent-d);flex-shrink:0;margin:0}
.ledger label span{flex:1;font-size:15px;color:var(--ink-2);line-height:1.45}
.ledger label b{font-size:15px;font-weight:600;color:var(--ink);white-space:nowrap}
.ledger .days{display:flex;align-items:center;gap:14px;padding:14px 0;border-top:1px solid var(--line)}
.ledger .days span{flex:1;font-size:15px;color:var(--ink-2);line-height:1.45}
.ledger .days input[type=number]{width:76px;height:auto;padding:9px 11px;border:1px solid #D7E0DB;border-radius:10px;
font-size:15px;font-family:inherit;font-weight:600;color:var(--ink);background:#fff;outline:none;accent-color:auto}
.ledger .days input[type=number]:focus{border-color:var(--accent);box-shadow:0 0 0 3px rgba(43,213,148,.18)}
.total{display:flex;flex-wrap:wrap;gap:12px;align-items:baseline;justify-content:space-between;
background:var(--dark);color:#fff;border-radius:16px;padding:20px 24px;margin:16px 0 0;max-width:620px}
.total span{font-size:15px;font-weight:500;color:var(--on-dark-2)}
.total b{font-size:clamp(28px,4vw,36px);font-weight:800;color:var(--accent);letter-spacing:-.02em}
.warn{background:#FFF7EC;border:1px solid #F2DFC0;border-radius:16px;padding:22px 24px;margin:24px 0 0;max-width:760px}
.warn b{display:block;font-size:16px;color:#7A4E10;margin-bottom:8px}
.warn p{margin:0;color:#6B5533;font-size:15.5px;line-height:1.65}
.src{display:flex;flex-wrap:wrap;gap:8px 14px;align-items:center;background:var(--soft);border:1px solid var(--line);
border-radius:14px;padding:14px 18px;margin:28px 0 0;font-size:13.5px;color:#5A6671;max-width:760px;line-height:1.55}
.src a{color:var(--accent-d);font-weight:600;text-decoration:none}
.src a:hover{text-decoration:underline}
.zero{color:var(--accent-d);font-weight:700}
`.trim();

function customsPage(lang, C) {
  const t = L[lang];
  const o = L[lang === 'ka' ? 'en' : 'ka'];
  const url = `${ORIGIN}${t.base}/${t.customsDir}/`;
  const alt = `${ORIGIN}${o.base}/${o.customsDir}/`;
  const bc = [{ name: t.home, href: `${t.base}/` }, { name: t.customs }];
  const c = C.cases;
  const cur = lang === 'ka' ? '₾' : 'GEL';
  const n = (v) => (Number.isInteger(v) ? String(v) : v.toFixed(2));
  const money = (v) => (lang === 'ka' ? `${n(v)} ₾` : `${n(v)} GEL`);
  const evAge = new Date().getFullYear() - c.evUsed.Celi;

  // The order the fees are listed in on rs.ge, with their labels. Amounts come
  // from rs.ge; only the wording is ours.
  const FEE_ORDER = ['purchaseValue', 'customsDeclaration', 'exportInspectionAct',
    'issuanceOfTransitNumber', 'registrationCertificate', 'stateNumber', 'actOfBrowsing'];
  const FEE_LABEL = {
    ka: {
      purchaseValue: 'სატრანსპორტო საშუალების გაფორმება',
      customsDeclaration: 'საბაჟო დეკლარაციის შევსება',
      exportInspectionAct: 'საექსპერტო შემოწმების აქტი',
      issuanceOfTransitNumber: 'შიდა ტრანზიტული ნომრის გაცემა',
      registrationCertificate: 'სარეგისტრაციო მოწმობა',
      stateNumber: 'სახელმწიფო ნომერი',
      actOfBrowsing: 'დათვალიერების აქტი',
    },
    en: {
      purchaseValue: 'Vehicle clearance',
      customsDeclaration: 'Filing the customs declaration',
      exportInspectionAct: 'Expert inspection certificate',
      issuanceOfTransitNumber: 'Internal transit plate',
      registrationCertificate: 'Registration certificate',
      stateNumber: 'Number plate',
      actOfBrowsing: 'Inspection certificate',
    },
  }[lang];
  const feeList = FEE_ORDER.filter((k) => C.fees[k] != null);
  const feeTotal = feeList.reduce((s, k) => s + C.fees[k], 0);

  const S = lang === 'ka' ? {
    h1: 'ელექტრომობილის განბაჟება საქართველოში',
    intro: `ელექტრომობილს საქართველოში არც აქციზი ერიცხება და არც იმპორტის გადასახადი. რჩება მხოლოდ გაფორმების ფიქსირებული საფასურები, სულ ${money(feeTotal)}. ყველა ციფრი შემოსავლების სამსახურის ოფიციალური კალკულატორიდანაა აღებული და ყოველ განახლებაზე თავიდან მოწმდება.`,
    exciseL: 'აქციზი', dutyL: 'იმპორტის გადასახადი',
    exciseNote: `ნებისმიერ გამოშვების წელზე. ${evAge} წლის ელექტრომობილზეც ${money(c.evUsed.excise)}.`,
    dutyNote: 'ბენზინის მანქანაზე ეს ძრავის ყოველ კუბურ სანტიმეტრზე ითვლება. ელექტროძრავას მოცულობა არ აქვს.',
    feesH: 'რას იხდით სინამდვილეში',
    feesP: 'გადასახადი ნული რომ იყოს, ეს არ ნიშნავს, რომ განბაჟება უფასოა. საბაჟოსა და შსს მომსახურების სააგენტოში ფიქსირებული საფასურები მაინც წარმოიშობა. მონიშნეთ, რომელი გჭირდებათ.',
    daysL: 'დეკლარირების ვადის გადაცილება, დღე',
    daysNote: `თითო დღე ${money(EXTRA_DAY)}`,
    totalL: 'სულ გადასახდელი',
    cmpH: 'რამდენს ზოგავს ელექტრომობილი',
    cmpP: `ერთი და იმავე ასაკის მანქანები, სხვაობა მხოლოდ ძრავაშია. ციფრები rs.ge-ის კალკულატორის პასუხია ${C.checked}-ის მდგომარეობით.`,
    thCar: 'მანქანა', thExcise: 'აქციზი', thDuty: 'იმპორტის გადასახადი', thSum: 'სულ გადასახადი',
    rhdH: 'ერთი გამონაკლისი, რომელიც ძვირი ჯდება',
    rhdP: `მარჯვენასაჭიან ან გადატანილსაჭიან ელექტრომობილს აქციზი უკვე ერიცხება და ის ${money(c.evRhd.excise)}-ია, ასაკის მიუხედავად. იმპორტის გადასახადი ასეთ შემთხვევაშიც ${money(c.evRhd.duty)} რჩება. თუ იაპონიიდან ან დიდი ბრიტანეთიდან ჩამოტანას გეგმავთ, ეს თანხა წინასწარ ჩადეთ ანგარიშში.`,
    notH: 'რა არ შედის ამ ციფრებში',
    srcPre: 'წყარო:', srcCalc: 'შემოსავლების სამსახურის განბაჟების კალკულატორი',
    srcPost: `ბოლოს შემოწმდა ${C.checked}. ციფრები ავტომატურად ახლდება საიტის ყოველ აწყობაზე, ხელით არაფერია ჩაწერილი.`,
  } : {
    h1: 'Importing an electric car into Georgia',
    intro: `An electric car in Georgia pays no excise and no import duty. What remains is the fixed clearance fees, ${money(feeTotal)} in total. Every figure here comes from the Revenue Service's own calculator and is re-checked on every rebuild.`,
    exciseL: 'Excise', dutyL: 'Import duty',
    exciseNote: `Whatever the year of manufacture. A ${evAge} year old electric car is also ${money(c.evUsed.excise)}.`,
    dutyNote: 'On a petrol car this is charged per cubic centimetre of engine. An electric motor has no displacement.',
    feesH: 'What you actually pay',
    feesP: 'Zero tax does not mean clearance is free. Fixed fees still arise at customs and at the Public Service Hall. Tick the ones that apply to you.',
    daysL: 'Days past the declaration deadline',
    daysNote: `${money(EXTRA_DAY)} per day`,
    totalL: 'Total payable',
    cmpH: 'What the exemption is worth',
    cmpP: `Cars of the same age, differing only in what drives them. The figures are what the rs.ge calculator answered on ${C.checked}.`,
    thCar: 'Car', thExcise: 'Excise', thDuty: 'Import duty', thSum: 'Total tax',
    rhdH: 'The one exception, and it is expensive',
    rhdP: `A right hand drive or converted electric car does pay excise, and it is ${money(c.evRhd.excise)} regardless of age. Import duty stays at ${money(c.evRhd.duty)} even then. If you are planning to bring one in from Japan or the UK, budget for it up front.`,
    notH: 'What these figures do not include',
    srcPre: 'Source:', srcCalc: "the Revenue Service's clearance calculator",
    srcPost: `Last checked ${C.checked}. The figures refresh on every site build; none of them are typed in by hand.`,
  };

  const cmpRows = lang === 'ka' ? [
    ['ელექტრომობილი, ახალი', c.evNew],
    [`ელექტრომობილი, ${evAge} წლის`, c.evUsed],
    ['ჰიბრიდი 2.0, ახალი', c.hyb20New],
    ['ბენზინი 1.6, ახალი', c.ice16New],
    [`ბენზინი 1.6, ${evAge} წლის`, c.ice16Old],
    ['ბენზინი 2.0, ახალი', c.ice20New],
    [`ბენზინი 2.0, ${evAge} წლის`, c.ice20Old],
  ] : [
    ['Electric, new', c.evNew],
    [`Electric, ${evAge} years old`, c.evUsed],
    ['Hybrid 2.0, new', c.hyb20New],
    ['Petrol 1.6, new', c.ice16New],
    [`Petrol 1.6, ${evAge} years old`, c.ice16Old],
    ['Petrol 2.0, new', c.ice20New],
    [`Petrol 2.0, ${evAge} years old`, c.ice20Old],
  ];

  const notIncluded = lang === 'ka' ? [
    'თავად მანქანის ფასი და ტრანსპორტირება საქართველოში.',
    'ავტოსატრანსპორტო საშუალების ტექნიკური ინსპექტირება, თუ ის ცალკე გჭირდებათ.',
    'დაზღვევა და საბროკერო მომსახურება, თუ განბაჟებას შუამავლით აკეთებთ.',
    'იურიდიული პირის სახელით იმპორტი. rs.ge-ის ეს კალკულატორი ფიზიკური პირის მსუბუქ ავტომობილზეა გათვლილი, კომპანიის შემთხვევაში პირობები განსხვავდება და ცალკე უნდა დააზუსტოთ.',
  ] : [
    'The price of the car itself and shipping it to Georgia.',
    'Roadworthiness inspection, if you need it separately.',
    'Insurance and broker fees, if you clear the car through an agent.',
    'Importing in a company name. This rs.ge calculator covers a passenger car imported by an individual; for a legal entity the terms differ and need checking separately.',
  ];

  const faq = lang === 'ka' ? [
    ['რამდენი ღირს ელექტრომობილის განბაჟება საქართველოში?',
      `აქციზი და იმპორტის გადასახადი ელექტრომობილზე ნულია. გადასახდელი რჩება მხოლოდ გაფორმების ფიქსირებული საფასურები, სულ ${money(feeTotal)}. ეს თანხა არ არის დამოკიდებული არც მანქანის ფასზე და არც გამოშვების წელზე.`],
    ['ერიცხება თუ არა ელექტრომობილს აქციზი?',
      `არა. შემოსავლების სამსახურის კალკულატორი ელექტროძრავიან მსუბუქ ავტომობილზე აქციზს ${money(c.evNew.excise)}-ს აჩვენებს ნებისმიერ გამოშვების წელზე. გამონაკლისია მარჯვენასაჭიანი და გადატანილსაჭიანი მანქანა, სადაც აქციზი ${money(c.evRhd.excise)}-ია.`],
    ['ძველ ელექტრომობილზე მეტი ხომ არ გადამახდევინებენ?',
      `არა. ბენზინის მანქანაზე ასაკს დიდი მნიშვნელობა აქვს, ელექტრომობილზე კი არა. ${evAge} წლის ელექტრომობილზეც გადასახადი იგივე ${money(c.evUsed.excise + c.evUsed.duty)}-ია, რაც ახალზე.`],
    ['რამდენს იხდის ბენზინის მანქანა იმავე პირობებში?',
      `ახალ 2.0 ლიტრიან ბენზინის მანქანაზე აქციზი და იმპორტის გადასახადი ერთად ${money(c.ice20New.excise + c.ice20New.duty)}-ია, ${evAge} წლისაზე კი ${money(c.ice20Old.excise + c.ice20Old.duty)}. ელექტრომობილზე ორივე ნულია.`],
    ['ეს ციფრები რამდენად ახალია?',
      `ბოლოს ${C.checked}-ს გადამოწმდა უშუალოდ rs.ge-ის კალკულატორზე. საიტის ყოველი განახლებისას ისინი თავიდან მოითხოვება, ამიტომ აქ ხელით ჩაწერილი ციფრი არ არის. მიუხედავად ამისა, გადახდამდე გირჩევთ rs.ge-ზე თავად შეამოწმოთ.`],
  ] : [
    ['How much does it cost to import an electric car into Georgia?',
      `Excise and import duty on an electric car are both zero. What remains is the fixed clearance fees, ${money(feeTotal)} in total. That amount depends neither on the price of the car nor on its year.`],
    ['Do electric cars pay excise in Georgia?',
      `No. The Revenue Service calculator returns ${money(c.evNew.excise)} of excise on an electric passenger car for any year of manufacture. The exception is a right hand drive or converted car, where excise is ${money(c.evRhd.excise)}.`],
    ['Is an older electric car taxed more?',
      `No. Age matters a great deal for a petrol car and not at all for an electric one. A ${evAge} year old electric car is taxed the same ${money(c.evUsed.excise + c.evUsed.duty)} as a new one.`],
    ['What would a petrol car pay instead?',
      `A new 2.0 litre petrol car pays ${money(c.ice20New.excise + c.ice20New.duty)} in excise and import duty combined, and a ${evAge} year old one pays ${money(c.ice20Old.excise + c.ice20Old.duty)}. On an electric car both are zero.`],
    ['How current are these figures?',
      `They were last verified against the rs.ge calculator on ${C.checked}. They are requested again on every site build, so nothing here is typed in by hand. Even so, check rs.ge yourself before you pay.`],
  ];

  const title = lang === 'ka'
    ? 'ელექტრომობილის განბაჟება საქართველოში 2026 | GeoCharge'
    : 'Importing an electric car into Georgia: duty and fees | GeoCharge';
  const desc = lang === 'ka'
    ? `ელექტრომობილზე აქციზი ${money(c.evNew.excise)} და იმპორტის გადასახადი ${money(c.evNew.duty)}. რჩება მხოლოდ გაფორმების საფასურები, სულ ${money(feeTotal)}. ციფრები rs.ge-ის ოფიციალური კალკულატორიდან.`
    : `Excise ${money(c.evNew.excise)} and import duty ${money(c.evNew.duty)} on an electric car. Only the clearance fees remain, ${money(feeTotal)} in total. Figures from the official rs.ge calculator.`;

  const body = `${crumbs(bc)}
<style>${CUSTOMS_CSS}</style>
<h1>${esc(S.h1)}</h1>
<p class="intro">${esc(S.intro)}</p>

<div class="answer">
  <div><b>${esc(money(c.evNew.excise))}</b><span>${esc(S.exciseL)}</span><i>${esc(S.exciseNote)}</i></div>
  <div><b>${esc(money(c.evNew.duty))}</b><span>${esc(S.dutyL)}</span><i>${esc(S.dutyNote)}</i></div>
</div>

<h2>${esc(S.feesH)}</h2>
<p class="intro">${esc(S.feesP)}</p>
<div class="ledger">
${feeList.map((k) => `  <label><input type="checkbox" class="f" data-v="${C.fees[k]}" checked><span>${esc(FEE_LABEL[k])}</span><b>${esc(money(C.fees[k]))}</b></label>`).join('\n')}
  <div class="days"><span>${esc(S.daysL)}<br><small style="color:#8B98A1">${esc(S.daysNote)}</small></span><input type="number" id="f-days" value="0" min="0" max="30" step="1"></div>
</div>
<div class="total"><span>${esc(S.totalL)}</span><b id="f-total">${esc(money(feeTotal))}</b></div>

<div class="warn">
  <b>${esc(S.rhdH)}</b>
  <p>${esc(S.rhdP)}</p>
</div>

<h2>${esc(S.cmpH)}</h2>
<p class="intro" style="margin-bottom:16px">${esc(S.cmpP)}</p>
<div class="tw"><table>
<thead><tr><th>${esc(S.thCar)}</th><th>${esc(S.thExcise)}</th><th>${esc(S.thDuty)}</th><th>${esc(S.thSum)}</th></tr></thead>
<tbody>
${cmpRows.map(([label, r]) => {
    const z = r.excise + r.duty === 0 ? ' class="zero"' : '';
    return `<tr><td>${esc(label)}</td><td>${esc(money(r.excise))}</td><td>${esc(money(r.duty))}</td><td${z}>${esc(money(r.excise + r.duty))}</td></tr>`;
  }).join('\n')}
</tbody></table></div>

<h2>${esc(S.notH)}</h2>
<ul class="intro" style="padding-left:20px">
${notIncluded.map((x) => `<li style="margin-bottom:8px">${esc(x)}</li>`).join('\n')}
</ul>

<div class="src"><span>${esc(S.srcPre)} <a href="${RSGE_PAGE}" target="_blank" rel="nofollow noopener">${esc(S.srcCalc)}</a>. ${esc(S.srcPost)}</span></div>

<h2>${esc(t.faq)}</h2>
<div class="faq">
${faq.map(([q, a]) => `<details><summary>${esc(q)}</summary><p>${esc(a)}</p></details>`).join('\n')}
</div>

<h2>${lang === 'ka' ? 'შემდეგი ნაბიჯი' : 'Next step'}</h2>
<p class="intro">${lang === 'ka'
    ? 'მანქანა რომ ჩამოიყვანთ, დატენვა მოგიწევთ.'
    : 'Once the car is here, you will need to charge it.'} <a href="${t.base}/${t.chargersDir}/" style="color:var(--accent-d);font-weight:500;text-decoration:none">${lang === 'ka' ? 'საქართველოს დამტენების სია' : "Georgia's charger list"}</a>, <a href="${t.base}/${t.calcDir}/" style="color:var(--accent-d);font-weight:500;text-decoration:none">${lang === 'ka' ? 'დატენვის ხარჯის კალკულატორი' : 'the charging cost calculator'}</a>${lang === 'ka' ? ' და ' : ' and '}<a href="${t.base}/blog/100-km-fasi/" style="color:var(--accent-d);font-weight:500;text-decoration:none">${lang === 'ka' ? '100 კილომეტრის რეალური ღირებულება' : 'what 100 km really costs'}</a>.</p>

<script>
(function(){
  var boxes=[].slice.call(document.querySelectorAll('.ledger .f'));
  var days=document.getElementById('f-days'), out=document.getElementById('f-total');
  function upd(){
    var sum=0;
    boxes.forEach(function(b){ if(b.checked) sum+=parseFloat(b.getAttribute('data-v'))||0; });
    sum+=(parseFloat(days.value)||0)*${EXTRA_DAY};
    out.textContent=(sum%1?sum.toFixed(2):sum)+' ${cur}';
  }
  boxes.forEach(function(b){ b.addEventListener('change',upd); });
  days.addEventListener('input',upd);
  upd();
})();
</script>`;

  return {
    file: path.join(SITE, t.base.replace('/', ''), t.customsDir, 'index.html'),
    url,
    html: shell({
      lang, title, desc, canonical: url, altHref: alt, body,
      jsonld: {
        '@context': 'https://schema.org',
        '@graph': [
          breadcrumbLd(bc),
          { '@type': 'WebPage', '@id': url + '#page', name: title, url, inLanguage: t.code,
            description: desc, dateModified: C.checked,
            isPartOf: { '@type': 'WebSite', '@id': `${ORIGIN}/#website` },
            citation: { '@type': 'WebPage', name: 'Revenue Service of Georgia', url: RSGE_PAGE } },
          { '@type': 'FAQPage', inLanguage: t.code,
            mainEntity: faq.map(([q, a]) => ({ '@type': 'Question', name: q, acceptedAnswer: { '@type': 'Answer', text: a } })) },
        ],
      },
    }),
  };
}

/* ── networks index ──────────────────────────────────────────────────────── */
function networksIndexPage(lang, byProvider, updated) {
  const t = L[lang];
  const o = L[lang === 'ka' ? 'en' : 'ka'];
  const url = `${ORIGIN}${t.base}/${t.networksDir}/`;
  const alt = `${ORIGIN}${o.base}/${o.networksDir}/`;
  const nm = (p) => (lang === 'ka' ? (PROVIDER_KA[p] || p) : p);
  const rows = [...byProvider.entries()].map(([p, list]) => {
    const s = summarise(list);
    const cities = new Set(list.filter((x) => x._city).map((x) => x._city[0]));
    return { p, s, cities: cities.size, price: tariffStats(list) };
  }).sort((a, b) => b.s.total - a.s.total);

  const widest = rows[0];
  const fastest = rows.slice().sort((a, b) => b.s.maxKw - a.s.maxKw)[0];
  const mostCities = rows.slice().sort((a, b) => b.cities - a.cities)[0];

  const title = lang === 'ka'
    ? 'ელექტრომობილის დამტენი ქსელები საქართველოში | GeoCharge'
    : 'EV charging networks in Georgia | GeoCharge';
  const desc = lang === 'ka'
    ? `საქართველოს ${rows.length} დამტენი ქსელი ერთ ცხრილში: დაფარვა, სიმძლავრე, კონექტორები და ტარიფები.`
    : `All ${rows.length} EV charging networks in Georgia in one table: coverage, power, connectors and tariffs.`;

  const bc = [{ name: t.home, href: `${t.base}/` },
    { name: t.catalog, href: `${t.base}/${t.chargersDir}/` }, { name: t.networks }];

  const faq = lang === 'ka' ? [
    ['რომელ ქსელს აქვს ყველაზე ბევრი დამტენი საქართველოში?',
      `${nm(widest.p)}, ${widest.s.total} სადგურით. ქალაქების მიხედვით ყველაზე ფართოდ ${nm(mostCities.p)} არის გაშლილი, ${mostCities.cities} ქალაქში.`],
    ['რომელ ქსელს აქვს ყველაზე მძლავრი დამტენები?',
      `${nm(fastest.p)}, ${fastest.s.maxKw} კილოვატამდე.`],
    ['მჭირდება თითოეული ქსელის ცალკე აპლიკაცია?',
      'დამტენის გასაშვებად ჩვეულებრივ პროვაიდერის აპლიკაცია ან ბარათი გჭირდებათ. GeoCharge გიჩვენებთ, სად რომელი ქსელია და რა პირობებით, რომ წინასწარ იცოდეთ, რომელი დაგჭირდებათ.'],
  ] : [
    ['Which network has the most chargers in Georgia?',
      `${widest.p}, with ${widest.s.total} stations. The widest spread across cities is ${mostCities.p}, present in ${mostCities.cities} cities.`],
    ['Which network has the most powerful chargers?',
      `${fastest.p}, up to ${fastest.s.maxKw} kW.`],
    ['Do I need a separate app for every network?',
      'To start a charge you normally need the provider’s own app or card. GeoCharge shows you which network is where and on what terms, so you know in advance which one you will need.'],
  ];

  const body = `${crumbs(bc)}
<h1>${lang === 'ka' ? 'ელექტრომობილის დამტენი ქსელები საქართველოში' : 'EV charging networks in Georgia'}</h1>
<p class="intro">${lang === 'ka'
    ? `საქართველოში ${rows.length} საჯარო დამტენი ქსელი მუშაობს. ქვემოთ თითოეულის დაფარვა, სიმძლავრე, კონექტორები და ტარიფია, ერთ ცხრილში, რომ ერთმანეთს შეადაროთ.`
    : `${rows.length} public charging networks operate in Georgia. Below is each one’s coverage, power, connectors and tariff, in a single table so you can compare them.`}</p>
<p class="upd">${esc(t.updated)} ${esc(updated)}</p>

<div class="tw"><table>
<thead><tr><th>${esc(t.thProvider)}</th><th>${esc(t.thCount)}</th><th>${esc(t.thCities)}</th><th>${esc(t.fast)}</th><th>${esc(t.maxPower)}</th><th>${esc(t.thConnectors)}</th><th>${esc(t.thDc)}</th></tr></thead>
<tbody>
${rows.map((r) => `<tr><td><a href="${t.base}/${t.networksDir}/${slug(r.p)}/">${esc(nm(r.p))}</a></td><td>${r.s.total}</td><td>${r.cities}</td><td>${r.s.dc}</td><td>${r.s.maxKw ? r.s.maxKw + ' kW' : '—'}</td><td>${esc(r.s.connectors.slice(0, 4).map(([c]) => c).join(', '))}</td><td>${r.price.dc.length ? `${fmt(median(r.price.dc))}` : '—'}</td></tr>`).join('\n')}
</tbody></table></div>
<p class="note">${lang === 'ka'
    ? 'ტარიფის სვეტში მედიანური DC ფასია. სრული დიაპაზონები'
    : 'The tariff column shows the median DC price. Full ranges are on the'} <a href="${t.base}/${t.tariffsDir}/" style="color:var(--accent-d);font-weight:500;text-decoration:none">${lang === 'ka' ? 'ტარიფების გვერდზეა' : 'tariffs page'}</a>.</p>

<h2>${esc(t.faq)}</h2>
<div class="faq">
${faq.map(([q, a]) => `<details><summary>${esc(q)}</summary><p>${esc(a)}</p></details>`).join('\n')}
</div>`;

  return {
    file: path.join(SITE, t.base.replace('/', ''), t.networksDir, 'index.html'),
    url,
    html: shell({
      lang, title, desc, canonical: url, altHref: alt, body,
      jsonld: {
        '@context': 'https://schema.org',
        '@graph': [
          breadcrumbLd(bc),
          { '@type': 'CollectionPage', '@id': url + '#page', name: title, url, inLanguage: t.code, description: desc,
            isPartOf: { '@type': 'WebSite', '@id': `${ORIGIN}/#website` } },
          { '@type': 'FAQPage', inLanguage: t.code,
            mainEntity: faq.map(([q, a]) => ({ '@type': 'Question', name: q, acceptedAnswer: { '@type': 'Answer', text: a } })) },
        ],
      },
    }),
  };
}

/* ── routes ──────────────────────────────────────────────────────────────── */
function routeStops(route, byCity, byCityAll, raw) {
  return route.stops.map(([ref, km]) => {
    if (typeof ref === 'string') {
      const city = CITIES.find((c) => c[0] === ref);
      const list = byCityAll.get(ref) || [];
      return { city, list, km, linked: byCity.has(ref), name: (l) => (l === 'ka' ? city[1] : city[0]) };
    }
    // stop outside Georgia: count by radius from the unfiltered dataset
    const list = raw.filter((s) => haversineKm(ref.lat, ref.lng, s.lat, s.lng) <= ref.r);
    return { city: null, list, km, linked: false, name: (l) => ref[l] };
  });
}

/* Planning model. Deliberately one stated set of assumptions rather than a
   per-car guess: 18 kWh/100 km is the calculator's default, 60 kWh is a typical
   pack, and 20 % to 80 % is the window a DC charger actually covers quickly.
   Every page prints the assumptions next to the result. */
const CONS_KWH_100 = 18;
const TYPICAL_PACK = 60;
const FAST_WINDOW = 0.6;

const KA_NUM = ['ნული', 'ერთი', 'ორი', 'სამი', 'ოთხი', 'ხუთი', 'ექვსი'];
const EN_NUM = ['no', 'one', 'two', 'three', 'four', 'five', 'six'];

function routePage(lang, route, byCity, byCityAll, raw, updated, byProvider) {
  const t = L[lang], a = route[lang];
  const o = L[lang === 'ka' ? 'en' : 'ka'];
  const url = `${ORIGIN}${t.base}/${t.routesDir}/${route.slug}/`;
  const alt = `${ORIGIN}${o.base}/${o.routesDir}/${route.slug}/`;
  const stops = routeStops(route, byCity, byCityAll, raw);
  const onWay = stops.slice(1);   // leaving the origin, its own chargers do not count
  const enRoute = onWay.reduce((n, s) => n + s.list.length, 0);
  const dcOnRoute = onWay.reduce((n, s) => n + s.list.filter((x) => x.type === 'Fast DC').length, 0);
  const dest = stops[stops.length - 1];
  const destDc = dest.list.filter((x) => x.type === 'Fast DC').length;

  /* ── planning figures ─────────────────────────────────────────────────── */
  const kwh = Math.round(route.km * CONS_KWH_100 / 100);
  const legKm = Math.round(TYPICAL_PACK * FAST_WINDOW / CONS_KWH_100 * 100 / 10) * 10;
  const legs = Math.max(0, Math.ceil(route.km / legKm) - 1);
  const legWord = (lang === 'ka' ? KA_NUM : EN_NUM)[Math.min(legs, 6)];

  // Gaps are measured between the route's named stops, so this is the longest
  // stretch where the itinerary itself offers no fast charging. A charger may
  // still sit at a village in between; the wording says "between stops".
  const dcPts = stops.filter((s) => s.list.some((x) => x.type === 'Fast DC'));
  let gapKm = 0, gapFrom = null, gapTo = null;
  for (let i = 1; i < dcPts.length; i++) {
    const d = dcPts[i].km - dcPts[i - 1].km;
    if (d > gapKm) { gapKm = d; gapFrom = dcPts[i - 1]; gapTo = dcPts[i]; }
  }
  const tailKm = dcPts.length ? route.km - dcPts[dcPts.length - 1].km : route.km;

  const routeStations = stops.flatMap((s) => s.list);
  const routePrice = tariffStats(routeStations);
  const dcMed = routePrice.dc.length ? median(routePrice.dc) : null;
  const cost = dcMed ? kwh * dcMed : null;

  // Charging time. Real average power over a 20 % to 80 % session sits well
  // below the rated figure, because the curve tapers; 75 % is the derate used.
  const legKwh = Math.round(TYPICAL_PACK * FAST_WINDOW);
  const mins = (kwRated) => Math.round(legKwh / (kwRated * 0.75) * 60);

  // Which cars this road actually serves. The connector mix is the one thing a
  // driver with a US or Chinese spec car cannot get anywhere else.
  const connOnRoute = Object.fromEntries(summarise(onWay.flatMap((s) => s.list)).connectors);
  const nConn = (...names) => names.reduce((n, c) => n + (connOnRoute[c] || 0), 0);
  const euConn = nConn('CCS2'), cnConn = nConn('GB/T'), usConn = nConn('CCS1', 'NACS', 'Type 1');
  const acConn = nConn('Type 2');

  const netCount = {};
  for (const s of onWay) for (const x of s.list) netCount[x.provider] = (netCount[x.provider] || 0) + 1;
  const nets = Object.entries(netCount).sort((x, y) => y[1] - x[1]);
  const netName = (p) => (lang === 'ka' ? (PROVIDER_KA[p] || p) : p);
  const hasNetPage = (p) => !byProvider || byProvider.has(p);
  const onWaySum = summarise(onWay.flatMap((s) => s.list));

  const title = lang === 'ka'
    ? `${a.fromAbl} ${a.toLoc} ელექტრო მანქანით, სად დავტენოთ | GeoCharge`
    : `${a.from} to ${a.to} by electric car, where to charge | GeoCharge`;
  const desc = lang === 'ka'
    ? `${a.fromAbl} ${a.toLoc} ${route.km} კილომეტრია. მარშრუტზე ${enRoute} დამტენი სადგურია, აქედან ${dcOnRoute} სწრაფი. რამდენი გაჩერება დასჭირდება, რა დაჯდება გზა და რაზე მივაქციოთ ყურადღება.`
    : `${a.from} to ${a.to} is ${route.km} km with ${enRoute} charging stations on the way, ${dcOnRoute} of them fast. How many stops it takes, what the drive costs and what to watch for.`;

  const bc = [{ name: t.home, href: `${t.base}/` },
    { name: t.routes, href: `${t.base}/${t.routesDir}/` }, { name: `${a.from} ${a.to}` }];

  const faq = lang === 'ka' ? [
    [`შემიძლია ${a.fromAbl} ${a.toLoc} წასვლა ელექტრო მანქანით?`,
      `დიახ. ${route.km} კილომეტრია და მარშრუტზე ${enRoute} დამტენი სადგურია, აქედან ${dcOnRoute} სწრაფი DC. ${a.advice}`],
    [`რამდენი გაჩერება დამჭირდება ${a.fromAbl} ${a.toLoc}?`,
      legs
        ? `დაახლოებით ${legWord}. გაანგარიშება ეყრდნობა 18 კილოვატსაათს 100 კილომეტრზე და 60 კილოვატსაათიან ბატარეას, რომელიც 20-დან 80 პროცენტამდე დატენვისას დაახლოებით ${legKm} კილომეტრს ფარავს. ზამთარში ერთი დამატებითი გაჩერება ჩადეთ.`
        : `სავსე ბატარეით გასვლის შემთხვევაში გზაში გაჩერება არ არის საჭირო. ${route.km} კილომეტრი 60 კილოვატსაათიანი ბატარეის ერთ დატენვაში ეტევა, თუ ხარჯი 18 კილოვატსაათია 100 კილომეტრზე. ზამთარში და აღმართზე მარაგი შეამცირეთ.`],
    [`სად არის დამტენები ${a.from} ${a.to} მარშრუტზე?`,
      onWay.filter((s) => s.list.length).map((s) => `${s.name('ka')} ${s.list.length}`).join(', ') + '.'],
    [`რა დაჯდება ${a.fromAbl} ${a.toLoc} ელექტრო ავტომობილით?`,
      cost
        ? `მთელ გზაზე დაახლოებით ${kwh} კილოვატსაათი იხარჯება. მარშრუტის სწრაფი დამტენების მედიანური ტარიფით, ${fmt(dcMed)} ლარი კილოვატსაათზე, ეს დაახლოებით ${fmt(cost)} ლარია. სახლში დატენვა მნიშვნელოვნად იაფია.`
        : `მთელ გზაზე დაახლოებით ${kwh} კილოვატსაათი იხარჯება. ღირებულება იმაზეა დამოკიდებული, რომელ ქსელში დატენავთ.`],
    [`არის თუ არა სწრაფი დამტენი ${a.toLoc}?`,
      destDc ? `დიახ, ${destDc} სწრაფი DC სადგური.` : `არა. ${a.toLoc} მხოლოდ ნელი AC დამტენებია, ამიტომ დაბრუნების ენერგია წინასწარ უნდა დაგეგმოთ.`],
    [`რომელი ქსელები მუშაობს ამ მარშრუტზე?`,
      nets.length ? nets.map(([p, n]) => `${netName(p)} ${n}`).join(', ') + '.' : 'მონაცემები ჯერ არ არის.'],
    ['რა იცვლება ზამთარში?', t.winterCopy],
  ] : [
    [`Can I drive from ${a.from} to ${a.to} in an electric car?`,
      `Yes. It is ${route.km} km with ${enRoute} charging stations along the way, ${dcOnRoute} of them fast DC. ${a.advice}`],
    [`How many stops does ${a.from} to ${a.to} take?`,
      legs
        ? `About ${legWord}. That assumes 18 kWh per 100 km and a 60 kWh battery, which covers roughly ${legKm} km between 20 and 80 percent. Add one more stop in winter.`
        : `None, if you leave with a full battery. ${route.km} km fits in a single charge of a 60 kWh battery at 18 kWh per 100 km. Leave more margin in winter and on climbs.`],
    [`Where are the chargers between ${a.from} and ${a.to}?`,
      onWay.filter((s) => s.list.length).map((s) => `${s.name('en')} ${s.list.length}`).join(', ') + '.'],
    [`What does ${a.from} to ${a.to} cost in an EV?`,
      cost
        ? `The drive uses about ${kwh} kWh. At the median fast-charging tariff on this route, ${fmt(dcMed)} GEL per kWh, that is roughly ${fmt(cost)} GEL. Charging at home costs considerably less.`
        : `The drive uses about ${kwh} kWh. What it costs depends on which network you charge with.`],
    [`Is there a fast charger in ${a.to}?`,
      destDc ? `Yes, ${destDc} fast DC stations.` : `No. ${a.to} has only slow AC chargers, so the energy to get back has to be planned in advance.`],
    ['Which networks operate on this route?',
      nets.length ? nets.map(([p, n]) => `${netName(p)} ${n}`).join(', ') + '.' : 'No data yet.'],
    ['What changes in winter?', t.winterCopy],
  ];

  const lk = 'style="color:var(--accent-d);font-weight:500;text-decoration:none"';

  const body = `${crumbs(bc)}
<h1>${lang === 'ka' ? `${esc(a.fromAbl)} ${esc(a.toLoc)} ელექტრო მანქანით` : `${esc(a.from)} to ${esc(a.to)} by electric car`}</h1>
<p class="intro">${lang === 'ka'
    ? `${esc(a.fromAbl)} ${esc(a.toLoc)} ${route.km} კილომეტრია. ეს გვერდი აჩვენებს, სად დგას დამტენები ამ გზაზე, რამდენი გაჩერება დასჭირდება ელექტრომობილს და რა დაჯდება მთელი მარშრუტი. ციფრები ცოცხალი მონაცემებიდან მოდის და ავტომატურად ახლდება.`
    : `${esc(a.from)} to ${esc(a.to)} is ${route.km} km. This page shows where the chargers stand on that road, how many stops an EV needs and what the whole drive costs. The figures come from live data and refresh automatically.`}</p>
<p class="intro">${esc(a.note)}</p>
<div class="stats">
  <div class="stat"><b>${route.km} km</b><span>${lang === 'ka' ? 'მანძილი' : 'distance'}</span></div>
  <div class="stat"><b>${enRoute}</b><span>${lang === 'ka' ? 'დამტენი გზაში' : 'chargers on the way'}</span></div>
  <div class="stat"><b>${dcOnRoute}</b><span>${esc(t.fast)}</span></div>
  <div class="stat"><b>${kwh} kWh</b><span>${lang === 'ka' ? 'ენერგია მთელ გზაზე' : 'energy for the drive'}</span></div>
  ${cost ? `<div class="stat"><b>${fmt(cost)} ₾</b><span>${lang === 'ka' ? 'სავარაუდო ღირებულება' : 'estimated cost'}</span></div>` : ''}
  ${gapKm ? `<div class="stat"><b>${gapKm} km</b><span>${esc(t.longestGap)}</span></div>` : ''}
  <div class="stat"><b>${destDc || esc(t.noFast)}</b><span>${lang === 'ka' ? `სწრაფი ${esc(a.toLoc)}` : `fast in ${esc(a.to)}`}</span></div>
</div>
<p class="upd">${esc(t.updated)} ${esc(updated)}</p>

<h2>${esc(t.routePlan)}</h2>
<p class="intro">${lang === 'ka'
    ? `${route.km} კილომეტრზე დაახლოებით ${kwh} კილოვატსაათი ენერგია იხარჯება. გაანგარიშება 18 კილოვატსაათს იღებს 100 კილომეტრზე, რაც ზომიერ ამინდში საშუალო მაჩვენებელია. 60 კილოვატსაათიანი ბატარეა 20-დან 80 პროცენტამდე დატენვისას დაახლოებით ${legKm} კილომეტრს ფარავს, ამიტომ ${legs ? `ამ მარშრუტზე ${legWord} გაჩერება დაგჭირდებათ` : 'სავსე ბატარეით გასვლის შემთხვევაში გზაში გაჩერება საერთოდ არ დაგჭირდებათ'}. თუ თქვენი მანქანის ბატარეა ამაზე პატარაა ან ხარჯი მეტია, ერთი გაჩერება დაამატეთ.`
    : `The drive uses about ${kwh} kWh. That takes 18 kWh per 100 km, an average figure in mild weather. A 60 kWh battery covers roughly ${legKm} km between 20 and 80 percent, so ${legs ? `this route takes ${legWord} stop${legs > 1 ? 's' : ''}` : 'you need no stop at all if you leave with a full battery'}. If your battery is smaller or your consumption higher, add one stop.`}</p>
${gapKm ? `<p class="intro" style="margin-top:14px">${lang === 'ka'
    ? `სწრაფი დამტენი მარშრუტის ${dcPts.length} გაჩერებაზეა. ყველაზე გრძელი მონაკვეთი ორ ასეთ წერტილს შორის ${gapKm} კილომეტრია (${esc(gapFrom.name('ka'))} და ${esc(gapTo.name('ka'))}). ${tailKm
      ? `ბოლო სწრაფი წერტილიდან ${esc(a.toLoc)} კიდევ ${tailKm} კილომეტრი რჩება, ამიტომ ბოლო გაჩერებას ეს მანძილიც უნდა დაემატოს.`
      : `${esc(a.to)} თავად სწრაფი დამტენებით არის დაფარული, ანუ ბოლო მონაკვეთზე დამატებითი მარაგის დაგროვება საჭირო არ არის.`} სწორედ ეს ციფრები განსაზღვრავს, რამდენი მარაგით უნდა გახვიდეთ დამტენიდან.`
    : `${dcPts.length} of the stops on this route have fast charging. The longest stretch between two of them is ${gapKm} km (${esc(gapFrom.name('en'))} to ${esc(gapTo.name('en'))}). ${tailKm
      ? `Another ${tailKm} km remain from the last fast point to ${esc(a.to)}, so the final stop has to cover that too.`
      : `${esc(a.to)} has fast charging of its own, so the last leg needs no extra reserve.`} Those figures decide how much margin you need when you leave a charger.`}</p>` : ''}

<h2>${esc(t.routeTable)}</h2>
<div class="tw"><table>
<thead><tr><th>${esc(t.thStop)}</th><th>${esc(t.thKm)}</th><th>${esc(t.thCount)}</th><th>${esc(t.fast)}</th><th>${esc(t.maxPower)}</th></tr></thead>
<tbody>
${stops.map((s) => {
    const sum = summarise(s.list);
    const label = esc(s.name(lang));
    const cell = s.linked
      ? `<a href="${t.base}/${t.chargersDir}/${slug(s.city[0])}/">${label}</a>` : label;
    return `<tr><td>${cell}</td><td>${s.km}</td><td>${sum.total || '—'}</td><td>${sum.dc || '—'}</td><td>${sum.maxKw ? sum.maxKw + ' kW' : '—'}</td></tr>`;
  }).join('\n')}
</tbody></table></div>

<h2>${esc(t.routeTime)}</h2>
<p class="intro">${lang === 'ka'
    ? `ერთი გაჩერება 20-დან 80 პროცენტამდე დაახლოებით ${legKwh} კილოვატსაათს ნიშნავს. 50 კილოვატიან დამტენზე ეს დაახლოებით ${mins(50)} წუთია, 100 კილოვატიანზე ${mins(100)} წუთი, 150 კილოვატიანზე კი ${mins(150)} წუთი.${onWaySum.maxKw >= 120 ? ` ამ მარშრუტის ყველაზე მძლავრი სადგური ${onWaySum.maxKw} კილოვატია, თუმცა რეალურ დროს ჩვეულებრივ სადგური კი არა, მანქანა განსაზღვრავს: ბევრი ელექტრომობილი 150 კილოვატზე მეტს ვერ იღებს.` : ''} გაანგარიშება რეალურ საშუალო სიმძლავრეს იღებს დეკლარირებულის სამ მეოთხედად, რადგან 80 პროცენტთან მიახლოებისას დატენვა ბუნებრივად ნელდება.`
    : `One stop from 20 to 80 percent means about ${legKwh} kWh. On a 50 kW charger that is roughly ${mins(50)} minutes, on a 100 kW one ${mins(100)} minutes, and on a 150 kW one ${mins(150)}.${onWaySum.maxKw >= 120 ? ` The most powerful station on this route is ${onWaySum.maxKw} kW, but the real limit is usually the car rather than the charger: many EVs cannot take more than 150 kW.` : ''} The figures take real average power as three quarters of the rated one, because charging naturally slows as it approaches 80 percent.`}</p>

${(euConn || cnConn || usConn) ? `<h2>${esc(t.routeCars)}</h2>
<p class="intro">${lang === 'ka'
    ? `კონექტორი განსაზღვრავს, რომელ სადგურზე გაჩერდებით. ამ მარშრუტზე ევროპული სპეციფიკაციის მანქანას (CCS2) ${euConn} სწრაფი პორტი ხვდება, ჩინურს (GB/T) ${cnConn}, ამერიკულს კი (CCS1, NACS ან Type 1) სულ ${usConn}. ${usConn < 5 ? 'ამერიკიდან ჩამოყვანილი მანქანით ამ გზაზე ადაპტერის გარეშე გასვლა რისკია.' : 'ამერიკული სპეციფიკაციისთვისაც არის რამდენიმე ვარიანტი, თუმცა ადაპტერი მაინც აუცილებელია.'} ნელი AC დატენვისთვის Type 2 პორტი ${acConn} ადგილზეა.`
    : `The connector decides which stations you can use. On this route a European spec car (CCS2) meets ${euConn} fast ports, a Chinese one (GB/T) ${cnConn}, and a US spec car (CCS1, NACS or Type 1) ${usConn} in total. ${usConn < 5 ? 'Driving this road in a US import without an adapter is a risk.' : 'There are a few options for US spec cars too, though an adapter is still needed.'} For slow AC charging there are ${acConn} Type 2 ports.`}</p>
<p class="intro" style="margin-top:14px">${lang === 'ka' ? 'კონექტორების ტიპები ცალკე სტატიაშია ახსნილი' : 'Connector types are explained in their own guide'}: <a href="${t.base}/blog/konektorebi/" ${lk}>${lang === 'ka' ? 'რომელი კონექტორი რომელ მანქანას' : 'which connector fits which car'}</a>.</p>` : ''}

<h2>${esc(t.routeCost)}</h2>
<p class="intro">${lang === 'ka'
    ? (cost
      ? `${kwh} კილოვატსაათი სწრაფ დამტენზე დაახლოებით ${fmt(cost)} ლარი დაჯდება. ტარიფად აღებულია ამ მარშრუტის სწრაფი დამტენების მედიანური ფასი, ${fmt(dcMed)} ლარი კილოვატსაათზე. რეალური თანხა იმაზეა დამოკიდებული, რომელ ქსელში გაჩერდებით, რადგან ტარიფები ქსელებს შორის შესამჩნევად განსხვავდება. სახლში დატენვისას იგივე ენერგია რამდენჯერმე იაფი გამოდის.`
      : `${kwh} კილოვატსაათი დასჭირდება მთელ გზას. ამ მარშრუტზე გამოქვეყნებული ტარიფები საკმარისი არ არის მედიანის დასათვლელად, ამიტომ ღირებულება ქსელის მიხედვით უნდა შეამოწმოთ.`)
    : (cost
      ? `${kwh} kWh on fast chargers costs about ${fmt(cost)} GEL. The tariff used is the median fast-charging price on this route, ${fmt(dcMed)} GEL per kWh. What you actually pay depends on which network you stop at, since tariffs differ noticeably between them. The same energy at home costs several times less.`
      : `The whole drive needs ${kwh} kWh. There are not enough published tariffs on this route to take a median, so check the cost per network.`)}</p>
<p class="intro" style="margin-top:14px">${esc(t.calcMore)}: <a href="${t.base}/${t.calcDir}/" ${lk}>${lang === 'ka' ? 'დატენვის კალკულატორი' : 'the charging calculator'}</a>. ${esc(t.howToCalc)}: <a href="${t.base}/blog/100-km-fasi/" ${lk}>${lang === 'ka' ? '100 კილომეტრის რეალური ღირებულება' : 'what 100 km really costs'}</a>.</p>

${nets.length ? `<h2>${esc(t.routeNets)}</h2>
<p class="intro">${lang === 'ka'
    ? `გზაში ${nets.length} სხვადასხვა ქსელის დამტენს გადააწყდებით. თითოეულს თავისი ტარიფი და თავისი აპლიკაცია აქვს, ამიტომ გრძელ მარშრუტზე ერთ ქსელზე დაყრდნობა არ ღირს.`
    : `You will meet chargers from ${nets.length} different networks on the way. Each has its own tariff and its own app, so it is not worth depending on a single network for a long drive.`}</p>
<div class="chips">${nets.map(([p, n]) => (hasNetPage(p)
    ? `<a class="chip" href="${t.base}/${t.networksDir}/${slug(p)}/" style="text-decoration:none;color:inherit"><b>${n}</b> ${esc(netName(p))}</a>`
    : `<span class="chip"><b>${n}</b> ${esc(netName(p))}</span>`)).join('')}</div>` : ''}

${onWaySum.connectors.length ? connectorChips(onWaySum, lang) : ''}

<h2>${esc(t.routeNotes)}</h2>
<p class="intro">${esc(a.advice)}</p>
<p class="intro" style="margin-top:14px">${esc(t.generalRules)}: <a href="${t.base}/blog/shori-mgzavroba/" ${lk}>${lang === 'ka' ? 'შორ გზაზე ელექტრო მანქანით' : 'driving long distance by EV'}</a>.</p>

<h2>${esc(t.routeWinter)}</h2>
<p class="intro">${esc(t.winterCopy)}</p>
<p class="intro" style="margin-top:14px">${esc(t.winterMore)}: <a href="${t.base}/blog/zamtari/" ${lk}>${lang === 'ka' ? 'ელექტრომობილი ზამთარში' : 'EVs in winter'}</a>.</p>

<h2>${esc(t.faq)}</h2>
<div class="faq">
${faq.map(([q, ans]) => `<details><summary>${esc(q)}</summary><p>${esc(ans)}</p></details>`).join('\n')}
</div>

<h2>${esc(t.allRoutes)}</h2>
<div class="links">
<a href="${t.base}/${t.routesDir}/">${esc(t.allRoutes)}</a>
${ROUTES.filter((r) => r.slug !== route.slug).map((r) => `<a href="${t.base}/${t.routesDir}/${r.slug}/">${esc(r[lang].from)} ${esc(r[lang].to)}</a>`).join('\n')}
</div>`;

  return {
    file: path.join(SITE, t.base.replace('/', ''), t.routesDir, route.slug, 'index.html'),
    url,
    html: shell({
      lang, title, desc, canonical: url, altHref: alt, body,
      jsonld: {
        '@context': 'https://schema.org',
        '@graph': [
          breadcrumbLd(bc),
          { '@type': 'CollectionPage', '@id': url + '#page', name: title, url, inLanguage: t.code, description: desc,
            isPartOf: { '@type': 'WebSite', '@id': `${ORIGIN}/#website` } },
          { '@type': 'FAQPage', inLanguage: t.code,
            mainEntity: faq.map(([q, ans]) => ({ '@type': 'Question', name: q, acceptedAnswer: { '@type': 'Answer', text: ans } })) },
        ],
      },
    }),
  };
}

function routesIndexPage(lang, byCity, byCityAll, raw, updated) {
  const t = L[lang];
  const o = L[lang === 'ka' ? 'en' : 'ka'];
  const url = `${ORIGIN}${t.base}/${t.routesDir}/`;
  const alt = `${ORIGIN}${o.base}/${o.routesDir}/`;
  const title = lang === 'ka'
    ? 'შორ გზაზე ელექტრო მანქანით: მარშრუტები საქართველოში | GeoCharge'
    : 'Long drives by electric car: EV routes in Georgia | GeoCharge';
  const desc = lang === 'ka'
    ? 'სად დავტენოთ ელექტრო მანქანა საქართველოს მთავარ მარშრუტებზე: ბათუმი, ყაზბეგი, ბაკურიანი, მესტია და ერევანი. რამდენი გაჩერება სჭირდება თითოეულს.'
    : 'Where to charge an electric car on Georgia’s main routes: Batumi, Kazbegi, Bakuriani, Mestia and Yerevan, and how many stops each one takes.';
  const bc = [{ name: t.home, href: `${t.base}/` }, { name: t.routes }];

  const body = `${crumbs(bc)}
<h1>${lang === 'ka' ? 'შორ გზაზე ელექტრო მანქანით საქართველოში' : 'Long drives by electric car in Georgia'}</h1>
<p class="intro" style="margin-bottom:32px">${lang === 'ka'
    ? 'თითოეულ მარშრუტზე ნაჩვენებია, სად არის დამტენები, რამდენია სწრაფი, რამდენი გაჩერება სჭირდება ელექტრომობილს და სად შეიძლება პრობლემა შეგხვდეთ. ციფრები ცოცხალი მონაცემებიდან მოდის.'
    : 'Each route shows where the chargers are, how many are fast, how many stops an EV needs, and where you may run into trouble. The figures come from live data.'}</p>
<div class="tw"><table>
<thead><tr><th>${esc(t.routes)}</th><th>km</th><th>${esc(t.thCount)}</th><th>${esc(t.fast)}</th></tr></thead>
<tbody>
${ROUTES.map((r) => {
    const stops = routeStops(r, byCity, byCityAll, raw);
    const n = stops.slice(1).reduce((x, s) => x + s.list.length, 0);
    const dc = stops.slice(1).reduce((x, s) => x + s.list.filter((y) => y.type === 'Fast DC').length, 0);
    return `<tr><td><a href="${t.base}/${t.routesDir}/${r.slug}/">${esc(r[lang].from)} ${esc(r[lang].to)}</a></td><td>${r.km}</td><td>${n}</td><td>${dc}</td></tr>`;
  }).join('\n')}
</tbody></table></div>
<p class="upd">${esc(t.updated)} ${esc(updated)}</p>

<h2>${lang === 'ka' ? 'საზღვარს გარეთ' : 'Beyond the border'}</h2>
<p>${lang === 'ka'
    ? 'ერთადერთი საზღვარი, რომელსაც ქართველი მძღოლი ელექტრო მანქანით რეალურად კვეთს, თურქეთისაა. თურქეთის საჯარო დამტენების სრული სია, ტარიფებით და პროვინციების მიხედვით, ცალკე გვერდზეა.'
    : 'The one border Georgian EV drivers actually cross is the Turkish one. The full list of public chargers in Turkey, with tariffs and a breakdown by province, has its own page.'}</p>
<div class="links">
  <a href="${t.base}/${t.turkeyDir}/">${lang === 'ka' ? 'დამტენები თურქეთში' : 'Chargers in Turkey'}</a>
  <a href="${t.base}/blog/tbilisi-stambuli/">${lang === 'ka' ? 'თბილისი სტამბოლი' : 'Tbilisi to Istanbul'}</a>
  <a href="${t.base}/blog/turketshi-mgzavroba/">${lang === 'ka' ? 'თურქეთში ელექტრო მანქანით' : 'Driving into Turkey'}</a>
</div>`;

  return {
    file: path.join(SITE, t.base.replace('/', ''), t.routesDir, 'index.html'),
    url,
    html: shell({
      lang, title, desc, canonical: url, altHref: alt, body,
      jsonld: {
        '@context': 'https://schema.org',
        '@graph': [breadcrumbLd(bc),
          { '@type': 'CollectionPage', '@id': url + '#page', name: title, url, inLanguage: t.code, description: desc,
            isPartOf: { '@type': 'WebSite', '@id': `${ORIGIN}/#website` } }],
      },
    }),
  };
}

/* ── sitemap ─────────────────────────────────────────────────────────────── */
// Hand-written guides live in tools/build-articles.mjs and are written by that
// script, not this one. This file still has to know their URLs, because the
// sitemap and the IndexNow submission are both built here. Keep in sync.
/* ── Turkey ──────────────────────────────────────────────────────────────────
   The app ships the whole Turkish registry (13k+ stations, see tools/turkey.mjs
   and docs/turkey_epdk_api.md), and driving into Turkey is the one international
   trip Georgian EV owners actually make. These pages publish that dataset on the
   same terms as the Georgian catalogue: what exists and where, never coordinates
   and never live status. Deliberately absent from the header nav, because the
   site's subject stays Georgia; readers reach this section from search, from the
   guides and from the catalogue. */
const TR_MIN_PAGE = 80;   // below this a province page would be thin content
const TR_FORCE = ['Rize', 'Artvin', 'Giresun', 'Erzurum', 'Kars']; // the roads out of Georgia
const TR_ROWS = 150;      // rows per province page: İstanbul alone holds 2,800

const TR_PAGES = new Set(); // filled in main(), read by every Turkish province link
const trHref = (lang, prov) => `${L[lang].base}/${L[lang].turkeyDir}/${trSlug(prov)}/`;
const trCell = (lang, prov) => (TR_PAGES.has(prov)
  ? `<a href="${trHref(lang, prov)}">${esc(provName(prov, lang))}</a>`
  : esc(provName(prov, lang)));

const lira = (n) => `${n.toFixed(2)} ₺`;

function trStationRows(list, lang) {
  const t = L[lang];
  const head = [t.thName, t.thProvider, t.thType, t.thPower, t.thConnectors, t.thPrice];
  const rows = list.map((s) => `<tr>`
    + `<td>${esc(s.name || '—')}</td>`
    + `<td>${esc(s.provider || '—')}</td>`
    + `<td><span class="tag ${s.type === 'Fast DC' ? 'dc' : 'ac'}">${s.type === 'Fast DC' ? 'DC' : 'AC'}</span></td>`
    + `<td>${esc(s.power && s.power !== '—' ? s.power : '—')}</td>`
    + `<td>${esc((s.connectors || []).join(', ') || '—')}</td>`
    + `<td>${esc(s.price || t.noPrice)}</td>`
    + `</tr>`);
  return `<div class="tw"><table>
<thead><tr>${head.map((h) => `<th>${esc(h)}</th>`).join('')}</tr></thead>
<tbody>
${rows.join('\n')}
</tbody></table></div>`;
}

// Sorted the way a driver reads the list: fast chargers first, strongest first,
// so the top of a capped table is the part that matters on a trip.
const trRank = (a, b) => (b.type === 'Fast DC') - (a.type === 'Fast DC')
  || trKw(b) - trKw(a) || String(a.name).localeCompare(String(b.name));

function turkeyHubPage(lang, list, st, provPages) {
  const t = L[lang];
  const o = L[lang === 'ka' ? 'en' : 'ka'];
  const url = `${ORIGIN}${t.base}/${t.turkeyDir}/`;
  const alt = `${ORIGIN}${o.base}/${o.turkeyDir}/`;
  const bc = [{ name: t.home, href: `${t.base}/` }, { name: t.turkey }];

  const chademo = (st.connectors.find(([c]) => c === 'CHAdeMO') || ['', 0])[1];
  const ccs2 = (st.connectors.find(([c]) => c === 'CCS2') || ['', 0])[1];
  const type2 = (st.connectors.find(([c]) => c === 'Type 2') || ['', 0])[1];
  const border = corridor(list, 'sarp-trabzon', { maxKm: 5, minKw: 50 });
  const toIst = corridor(list, 'sarp-istanbul', { maxKm: 5, minKw: 50 });
  const top = st.provinces[0], second = st.provinces[1];
  const topBrand = st.brands[0], brand2 = st.brands[1];
  const pricedPct = Math.round((st.withPrice / st.total) * 100);

  const title = lang === 'ka'
    ? `ელექტრო მანქანის დამტენები თურქეთში: ${big(st.total, 'ka')} სადგური | GeoCharge`
    : `EV charging stations in Turkey — ${big(st.total, 'en')} stations | GeoCharge`;
  const desc = lang === 'ka'
    ? `თურქეთის ${big(st.total, 'ka')} საჯარო დამტენი ერთ სიაში: ${big(st.dc, 'ka')} სწრაფი DC, ${st.brands.length} ოპერატორი, ტარიფები ლირაში და დაყოფა 81 პროვინციაზე. მონაცემები EPDK-ის ოფიციალური რეესტრიდან.`
    : `All ${big(st.total, 'en')} public EV chargers in Turkey in one list: ${big(st.dc, 'en')} fast DC, ${st.brands.length} operators, tariffs in lira and a breakdown across all 81 provinces, from the official EPDK registry.`;

  const faq = lang === 'ka' ? [
    ['რამდენი ელექტრო მანქანის დამტენია თურქეთში?',
      `${big(st.total, 'ka')} საჯარო სადგური, ${st.brands.length} ოპერატორთან. აქედან ${big(st.dc, 'ka')} სწრაფი DC დამტენია და ${big(st.ultra, 'ka')} სადგური 150 კილოვატს ან მეტს იძლევა. ციფრები EPDK-ის ოფიციალური რეესტრიდანაა.`],
    ['რომელი კონექტორი მჭირდება თურქეთში?',
      `სწრაფი დატენვისთვის CCS2, ნელისთვის Type 2. CCS2 ${big(ccs2, 'ka')} სადგურზეა, Type 2 ${big(type2, 'ka')}-ზე. CHAdeMO მხოლოდ ${big(chademo, 'ka')} სადგურზე გვხვდება, GB/T კი საერთოდ არ არსებობს, ამიტომ ჩინური მანქანა მხოლოდ GB/T კონექტორით თურქეთში სწრაფად ვერ დაიტენება.`],
    ['რა ღირს დატენვა თურქეთში?',
      `სწრაფ DC დამტენზე კილოვატსაათის მედიანური ტარიფი ${lira(st.dcMed)}, ნელ AC დამტენზე ${lira(st.acMed)}. ფასს სადგურების ${pricedPct} პროცენტი აქვეყნებს, ტარიფები კი თითქმის ყველა ოპერატორთან ერთიანია მთელი ქვეყნისთვის.`],
    ['სად არის ყველაზე მეტი დამტენი თურქეთში?',
      `${provIn(top[0], 'ka')}, სულ ${big(top[1].length, 'ka')} სადგური. მეორეა ${provName(second[0], 'ka')} ${big(second[1].length, 'ka')} სადგურით.`],
    ['ჩანს თუ არა თურქეთში, დამტენი თავისუფალია თუ დაკავებული?',
      'არა. თურქეთის რეესტრი ცოცხალ სტატუსს არ აქვეყნებს, ამიტომ თურქულ სადგურებზე GeoCharge აჩვენებს კონექტორების რაოდენობას და ტარიფს, თავისუფალი ადგილების ნაცვლად. საქართველოში ცოცხალი სტატუსი მუშაობს.'],
    ['საზღვრიდან პირველი სწრაფი დამტენი რამდენ კილომეტრშია?',
      `სარფის საზღვრიდან ტრაბზონამდე მონაკვეთზე ${border.count} სწრაფი დამტენია გზიდან 5 კილომეტრში, ყველაზე გრძელი მონაკვეთი მათ შორის კი დაახლოებით ${Math.round(border.gap / 5) * 5} კილომეტრია. ანუ სავსე ბატარეით საზღვარს რომ გადახვიდეთ, პირველ დატენვამდე მისვლა პრობლემა არ არის.`],
  ] : [
    ['How many EV chargers are there in Turkey?',
      `${big(st.total, 'en')} public stations run by ${st.brands.length} operators. ${big(st.dc, 'en')} of them are fast DC and ${big(st.ultra, 'en')} deliver 150 kW or more. The figures come from the official EPDK registry.`],
    ['Which connector do I need in Turkey?',
      `CCS2 for fast charging, Type 2 for slow. CCS2 is on ${big(ccs2, 'en')} stations and Type 2 on ${big(type2, 'en')}. CHAdeMO appears on only ${big(chademo, 'en')}, and GB/T does not exist in Turkey at all, so a Chinese car with a GB/T-only inlet cannot fast charge there.`],
    ['What does charging cost in Turkey?',
      `The median fast DC tariff is ${lira(st.dcMed)} per kWh and the median AC tariff ${lira(st.acMed)}. ${pricedPct} percent of stations publish a price, and most operators run one national tariff.`],
    ['Which province has the most chargers?',
      `${top[0]} with ${big(top[1].length, 'en')} stations, followed by ${second[0]} with ${big(second[1].length, 'en')}.`],
    ['Does Turkey show live charger availability?',
      'No. The Turkish registry publishes no real-time status, so GeoCharge shows the connector count and the tariff for Turkish stations instead of free bays. Live status works in Georgia.'],
    ['How far is the first fast charger from the Georgian border?',
      `On the stretch from the Sarp border gate to Trabzon there are ${border.count} fast chargers within 5 km of the road, and the longest stretch between any two of them is about ${Math.round(border.gap / 5) * 5} km.`],
  ];

  const intro = lang === 'ka'
    ? `თურქეთში <strong>${big(st.total, 'ka')} საჯარო დამტენი სადგურია</strong>, ${st.brands.length} ოპერატორთან და ქვეყნის ყველა 81 პროვინციაში. აქედან ${big(st.dc, 'ka')} სწრაფი DC დამტენია, ${big(st.ac, 'ka')} ჩვეულებრივი AC, ${big(st.ultra, 'ka')} სადგური კი 150 კილოვატს ან მეტს იძლევა. ეს იმას ნიშნავს, რომ ელექტრო მანქანით საქართველოდან თურქეთში გამგზავრება დღეს დაგეგმვის საკითხია და არა რისკის.`
    : `Turkey has <strong>${big(st.total, 'en')} public charging stations</strong>, run by ${st.brands.length} operators and spread across all 81 provinces. ${big(st.dc, 'en')} of them are fast DC, ${big(st.ac, 'en')} are standard AC, and ${big(st.ultra, 'en')} deliver 150 kW or more. Driving an EV from Georgia into Turkey is now a question of planning, not of risk.`;

  const body = `${crumbs(bc)}
<h1>${lang === 'ka' ? 'ელექტრო მანქანის დამტენები თურქეთში' : 'EV charging stations in Turkey'}</h1>
<p class="intro">${intro}</p>
${statBlock({ total: st.total, dc: st.dc, ac: st.ac, providers: st.brands, maxKw: st.maxKw }, lang, (x) => big(x, lang))}
<p class="upd">${lang === 'ka'
    ? `მონაცემები EPDK-ის, თურქეთის ენერგეტიკის მარეგულირებლის, ოფიციალური რეესტრიდან. ბოლო განახლება: ${esc(st.updated)}`
    : `Data from the official registry of EPDK, the Turkish energy regulator. Last update: ${esc(st.updated)}`}</p>

<h2>${lang === 'ka' ? 'რა იცვლება საზღვრის გადაკვეთისთანავე' : 'What changes the moment you cross the border'}</h2>
<p>${lang === 'ka'
    ? `თურქეთში დატენვის სტანდარტი ევროპულია. სწრაფი დატენვა CCS2-ზე მიდის, ნელი Type 2-ზე, და პრაქტიკულად სხვა ვარიანტი არ არსებობს: CHAdeMO მხოლოდ ${big(chademo, 'ka')} სადგურზეა, GB/T კი მთელ ქვეყანაში არც ერთზე.`
    : `Turkey charges to the European standard. Fast charging runs on CCS2, slow charging on Type 2, and there is effectively nothing else: CHAdeMO is on just ${big(chademo, 'en')} stations, and GB/T on none at all.`}</p>
<p>${lang === 'ka'
    ? `ეს ერთი წინადადება ქართველი მძღოლისთვის ყველაზე მნიშვნელოვანია. საქართველოში GB/T კონექტორი ჩვეულებრივი ამბავია, რადგან ჩინური მანქანების დიდი ნაწილი სწორედ ამ კონექტორით შემოდის. თურქეთში ასეთი მანქანა სწრაფად ვერ დაიტენება. თუ თქვენს მანქანას CCS2-იც აქვს, პრობლემა არ გაქვთ, თუ მხოლოდ GB/T აქვს, თურქეთში მხოლოდ Type 2-ზე ნელი დატენვა დაგრჩებათ და ისიც მხოლოდ იმ შემთხვევაში, თუ მანქანას Type 2 შესასვლელი აქვს. სანამ გზას დაგეგმავთ, გადაამოწმეთ, რომელი კონექტორი გაქვთ.`
    : `That single sentence matters most to drivers coming from Georgia. GB/T is ordinary in Georgia because a large share of imported cars are Chinese and arrive with that inlet. In Turkey such a car cannot fast charge at all. If your car also has CCS2 you are fine; if it only has GB/T, all that is left is slow Type 2 charging, and only where the car has a Type 2 inlet. Check which inlet you actually have before planning the drive.`}</p>
<div class="links" style="margin-top:6px">
  <a href="${t.base}/blog/${lang === 'ka' ? 'konektorebi' : 'konektorebi'}/">${lang === 'ka' ? 'კონექტორების გზამკვლევი' : 'Connector guide'}</a>
  <a href="${t.base}/blog/turketshi-mgzavroba/">${lang === 'ka' ? 'თურქეთში ელექტრო მანქანით' : 'Driving into Turkey'}</a>
  <a href="${t.base}/blog/tbilisi-stambuli/">${lang === 'ka' ? 'თბილისი სტამბოლი' : 'Tbilisi to Istanbul'}</a>
</div>

${connectorChips({ connectors: st.connectors }, lang, (x) => big(x, lang))}

<h2>${lang === 'ka' ? 'რა ღირს დატენვა თურქეთში' : 'What charging costs in Turkey'}</h2>
<p>${lang === 'ka'
    ? `თურქული ოპერატორები ტარიფს ეროვნულ დონეზე აქვეყნებენ, ანუ ერთი და იმავე ქსელის ფასი სტამბოლშიც და ტრაბზონშიც ერთია. სწრაფ DC დამტენზე კილოვატსაათის მედიანური ფასი ${lira(st.dcMed)}, დიაპაზონი ${lira(st.dcMin)}-დან ${lira(st.dcMax)}-მდე. ნელ AC დამტენზე მედიანა ${lira(st.acMed)}, დიაპაზონი ${lira(st.acMin)}-დან ${lira(st.acMax)}-მდე. ტარიფი გამოქვეყნებული აქვს სადგურების ${pricedPct} პროცენტს.`
    : `Turkish operators publish national tariffs, so the same network costs the same in İstanbul and in Trabzon. The median fast DC price is ${lira(st.dcMed)} per kWh, ranging from ${lira(st.dcMin)} to ${lira(st.dcMax)}. On AC the median is ${lira(st.acMed)}, ranging from ${lira(st.acMin)} to ${lira(st.acMax)}. ${pricedPct} percent of stations publish a tariff.`}</p>
<p>${lang === 'ka'
    ? `პრაქტიკული ორიენტირი: 60 კილოვატსაათიანი ბატარეის 20-დან 80 პროცენტამდე დატენვა 36 კილოვატსაათს ნიშნავს, ანუ მედიანურ ტარიფზე დაახლოებით ${(36 * st.dcMed).toFixed(0)} ლირას. ფასები ლირაშია და კურსი ხშირად იცვლება, ამიტომ ლარში გადათვლა მგზავრობის დღის კურსით ჯობია.`
    : `A practical yardstick: charging a 60 kWh battery from 20 to 80 percent means 36 kWh, which at the median tariff is about ${(36 * st.dcMed).toFixed(0)} lira. Prices are in lira and the exchange rate moves, so convert on the day you travel.`}</p>

<h2>${lang === 'ka' ? 'დამტენები პროვინციების მიხედვით' : 'Chargers by province'}</h2>
<p>${lang === 'ka'
    ? `თურქეთის 81-ვე პროვინციაში არის საჯარო დამტენი. ცხრილში ისინი რაოდენობის მიხედვითაა დალაგებული, ${provPages.length} ყველაზე დიდსა და საქართველოსთან ყველაზე ახლოს მდებარეს კი ცალკე გვერდი აქვს.`
    : `Every one of Turkey's 81 provinces has public chargers. The table is ordered by station count, and the ${provPages.length} largest provinces plus the ones nearest Georgia have a page of their own.`}</p>
<div class="tw"><table>
<thead><tr><th>${lang === 'ka' ? 'პროვინცია' : 'Province'}</th><th>${esc(t.thCount)}</th><th>${esc(t.fast)}</th><th>${lang === 'ka' ? '150 kW და მეტი' : '150 kW and up'}</th><th>${esc(t.thProvider)}</th></tr></thead>
<tbody>
${st.provinces.map(([p, l]) => {
    const ps = provinceStats(l);
    return `<tr><td>${trCell(lang, p)}</td><td>${big(ps.total, lang)}</td><td>${big(ps.dc, lang)}</td><td>${big(ps.ultra, lang)}</td><td>${ps.brands.length}</td></tr>`;
  }).join('\n')}
</tbody></table></div>

<h2>${lang === 'ka' ? 'ოპერატორები' : 'Operators'}</h2>
<p>${lang === 'ka'
    ? `თურქეთში ${st.brands.length} ლიცენზირებული ოპერატორია, მაგრამ ბაზარს რამდენიმე დიდი ქსელი განსაზღვრავს. ყველაზე დიდია ${topBrand[0]} ${big(topBrand[1].length, 'ka')} სადგურით, შემდეგ ${brand2[0]} ${big(brand2[1].length, 'ka')}-ით. ქვემოთ ოცდაათი უმსხვილესია.`
    : `Turkey has ${st.brands.length} licensed operators, but a handful of large networks define the market. The biggest is ${topBrand[0]} with ${big(topBrand[1].length, 'en')} stations, then ${brand2[0]} with ${big(brand2[1].length, 'en')}. The thirty largest are below.`}</p>
<div class="tw"><table>
<thead><tr><th>${esc(t.thProvider)}</th><th>${esc(t.thCount)}</th><th>${esc(t.fast)}</th><th>${esc(t.maxPower)}</th><th>${esc(t.thDcTr)}</th></tr></thead>
<tbody>
${st.brands.slice(0, 30).map(([b, l]) => {
    const ps = provinceStats(l);
    return `<tr><td>${esc(b)}</td><td>${big(ps.total, lang)}</td><td>${big(ps.dc, lang)}</td><td>${ps.maxKw ? ps.maxKw + ' kW' : '—'}</td><td>${ps.dcMed ? lira(ps.dcMed) : '—'}</td></tr>`;
  }).join('\n')}
</tbody></table></div>
<p class="note">${lang === 'ka'
    ? 'ტარიფის სვეტში ოპერატორის მედიანური DC ფასია ლირაში. ფასები ინფორმაციული ხასიათისაა და ოპერატორის მიერაა გამოქვეყნებული.'
    : 'The tariff column is the operator’s median DC price in lira. Tariffs are indicative and published by the operator.'}</p>

<h2>${lang === 'ka' ? 'გზა საქართველოს საზღვრიდან' : 'The road from the Georgian border'}</h2>
<p>${lang === 'ka'
    ? `სარფის საზღვრიდან ტრაბზონამდე შავი ზღვის გზაზე ${border.count} სწრაფი დამტენია გზიდან 5 კილომეტრში, აქედან ${border.ultra} სადგური 150 კილოვატს ან მეტს იძლევა. ორ მეზობელ დამტენს შორის ყველაზე გრძელი მონაკვეთი დაახლოებით ${Math.round(border.gap / 5) * 5} კილომეტრია.`
    : `Between the Sarp border gate and Trabzon there are ${border.count} fast chargers within 5 km of the coastal road, ${border.ultra} of them rated 150 kW or more. The longest stretch between two neighbouring chargers is about ${Math.round(border.gap / 5) * 5} km.`}</p>
<p>${lang === 'ka'
    ? `მთელ გზაზე სარფიდან სტამბოლამდე, შავი ზღვის სანაპიროთი, ${big(toIst.count, 'ka')} სწრაფი დამტენია გზის 5 კილომეტრში, ${big(toIst.ultra, 'ka')} მათგანი 150 კილოვატიდან. ეს მარშრუტი, გაჩერებებით და ხარჯით, ცალკე სტატიაშია გარჩეული.`
    : `Along the whole road from Sarp to İstanbul, following the Black Sea coast, there are ${big(toIst.count, 'en')} fast chargers within 5 km of the route, ${big(toIst.ultra, 'en')} of them at 150 kW or more. That drive, with its stops and its cost, has its own guide.`}</p>
<div class="links" style="margin-top:6px">
  <a href="${t.base}/blog/tbilisi-stambuli/">${lang === 'ka' ? 'თბილისიდან სტამბოლამდე ელექტრო მანქანით' : 'Tbilisi to Istanbul by EV'}</a>
  <a href="${t.base}/blog/turketshi-mgzavroba/">${lang === 'ka' ? 'საქართველოდან თურქეთში ელექტრო მანქანით' : 'From Georgia into Turkey by EV'}</a>
  <a href="${t.base}/${t.routesDir}/">${esc(t.routes)}</a>
</div>

<h2>${lang === 'ka' ? 'ცოცხალი სტატუსი და აპლიკაცია' : 'Live status and the app'}</h2>
<p>${lang === 'ka'
    ? 'თურქეთის რეესტრი იმას არ აქვეყნებს, დამტენი ახლა თავისუფალია თუ დაკავებული, ამიტომ თურქულ სადგურებზე აპლიკაცია კონექტორების რაოდენობასა და ტარიფს აჩვენებს და არა თავისუფალ ადგილებს. საქართველოში ცოცხალი სტატუსი მუშაობს და რეალურ დროში ახლდება.'
    : 'The Turkish registry does not publish whether a charger is busy right now, so for Turkish stations the app shows the connector count and the tariff rather than free bays. In Georgia live status works and refreshes in real time.'}</p>
<p>${lang === 'ka'
    ? 'აპლიკაციაში თურქეთი პარამეტრებში, ქვეყნების სიაში ირთვება. მარშრუტის დაგეგმვისას კი ცალკე ჩართვა საჭირო არ არის: თუ გზა თურქეთს კვეთს, თურქული დამტენები ავტომატურად ჩამოიტვირთება და გაჩერებებში ჩაითვლება.'
    : 'In the app, Turkey is switched on in Settings, in the country list. Route planning needs no switch at all: if the route crosses Turkey, the Turkish chargers are downloaded automatically and counted into the stops.'}</p>

<h2>${esc(t.faq)}</h2>
<div class="faq">
${faq.map(([q, a]) => `<details><summary>${esc(q)}</summary><p>${esc(a)}</p></details>`).join('\n')}
</div>`;

  return {
    file: path.join(SITE, t.base.replace('/', ''), t.turkeyDir, 'index.html'),
    url,
    html: shell({
      lang, title, desc, canonical: url, altHref: alt, body,
      jsonld: {
        '@context': 'https://schema.org',
        '@graph': [
          breadcrumbLd(bc),
          { '@type': 'CollectionPage', '@id': url + '#page', name: title, url, inLanguage: t.code, description: desc,
            isPartOf: { '@type': 'WebSite', '@id': `${ORIGIN}/#website` } },
          { '@type': 'FAQPage', inLanguage: t.code,
            mainEntity: faq.map(([q, a]) => ({ '@type': 'Question', name: q, acceptedAnswer: { '@type': 'Answer', text: a } })) },
        ],
      },
    }),
  };
}

function turkeyProvincePage(lang, prov, list, st) {
  const t = L[lang];
  const o = L[lang === 'ka' ? 'en' : 'ka'];
  const s = trSlug(prov);
  const url = `${ORIGIN}${t.base}/${t.turkeyDir}/${s}/`;
  const alt = `${ORIGIN}${o.base}/${o.turkeyDir}/${s}/`;
  const name = provName(prov, lang);
  const where = provIn(prov, lang);
  const ps = provinceStats(list);
  const shown = [...list].sort(trRank).slice(0, TR_ROWS);
  const rank = st.provinces.findIndex(([p]) => p === prov) + 1;
  const neighbours = st.provinces.filter(([p]) => p !== prov && TR_PAGES.has(p)).slice(0, 12);
  const bc = [{ name: t.home, href: `${t.base}/` },
    { name: t.turkey, href: `${t.base}/${t.turkeyDir}/` }, { name }];

  const title = lang === 'ka'
    ? `ელექტრო მანქანის დამტენები ${where}: ${big(ps.total, 'ka')} სადგური | GeoCharge`
    : `EV chargers in ${name} — ${big(ps.total, 'en')} stations | GeoCharge`;
  const desc = lang === 'ka'
    ? `${where} ${big(ps.total, 'ka')} საჯარო დამტენია, აქედან ${big(ps.dc, 'ka')} სწრაფი DC. ქსელები, კონექტორები, ტარიფები ლირაში და სადგურების სია.`
    : `${name} has ${big(ps.total, 'en')} public chargers, ${big(ps.dc, 'en')} of them fast DC. Networks, connectors, tariffs in lira and the station list.`;

  const faq = lang === 'ka' ? [
    [`რამდენი დამტენია ${where}?`,
      `${big(ps.total, 'ka')} საჯარო სადგური, აქედან ${big(ps.dc, 'ka')} სწრაფი DC და ${big(ps.ac, 'ka')} ჩვეულებრივი AC. ${ps.brands.length} სხვადასხვა ოპერატორი მუშაობს, ყველაზე დიდი ${ps.brands[0][0]} ${ps.brands[0][1]} სადგურით.`],
    [`რომელი კონექტორები გვხვდება ${where}?`,
      `${ps.connectors.map(([c, n]) => `${c} (${n})`).join(', ')}. სწრაფი დატენვისთვის CCS2 გჭირდებათ.`],
    [`რა ღირს სწრაფი დატენვა ${where}?`,
      ps.dcMed
        ? `მედიანური DC ტარიფი ${lira(ps.dcMed)} ერთ კილოვატსაათზე. ოპერატორები ერთიან ეროვნულ ტარიფს აქვეყნებენ, ამიტომ ფასი პრაქტიკულად იგივეა, რაც ქვეყნის დანარჩენ ნაწილში.`
        : 'ამ პროვინციის სადგურების უმეტესობა ტარიფს არ აქვეყნებს. ფასს ადგილზე, ოპერატორის აპლიკაციაში ნახავთ.'],
  ] : [
    [`How many chargers are there in ${name}?`,
      `${big(ps.total, 'en')} public stations: ${big(ps.dc, 'en')} fast DC and ${big(ps.ac, 'en')} standard AC, run by ${ps.brands.length} operators. The largest is ${ps.brands[0][0]} with ${ps.brands[0][1]} stations.`],
    [`Which connectors are used in ${name}?`,
      `${ps.connectors.map(([c, n]) => `${c} (${n})`).join(', ')}. You need CCS2 for fast charging.`],
    [`What does fast charging cost in ${name}?`,
      ps.dcMed
        ? `The median DC tariff is ${lira(ps.dcMed)} per kWh. Operators publish one national tariff, so the price is effectively the same as in the rest of the country.`
        : 'Most stations here publish no tariff. You will see the price in the operator’s app on site.'],
  ];

  const body = `${crumbs(bc)}
<h1>${lang === 'ka' ? `ელექტრო მანქანის დამტენები ${where}` : `EV chargers in ${name}`}</h1>
<p class="intro">${lang === 'ka'
    ? `${where} <strong>${big(ps.total, 'ka')} საჯარო დამტენი სადგურია</strong>, აქედან ${big(ps.dc, 'ka')} სწრაფი DC და ${big(ps.ac, 'ka')} ჩვეულებრივი AC. ეს თურქეთის პროვინციებს შორის ${rank} ადგილია. ${ps.ultra ? `${ps.ultra} სადგური 150 კილოვატს ან მეტს იძლევა, ` : ''}ყველაზე მძლავრი ${ps.maxKw} კილოვატია.`
    : `${name} has <strong>${big(ps.total, 'en')} public charging stations</strong>, ${big(ps.dc, 'en')} of them fast DC and ${big(ps.ac, 'en')} standard AC. That puts it ${rank} among Turkey's provinces. ${ps.ultra ? `${ps.ultra} stations deliver 150 kW or more, ` : ''}and the strongest is rated ${ps.maxKw} kW.`}</p>
${statBlock({ total: ps.total, dc: ps.dc, ac: ps.ac, providers: ps.brands, maxKw: ps.maxKw }, lang, (x) => big(x, lang))}
<p class="upd">${lang === 'ka'
    ? `მონაცემები EPDK-ის ოფიციალური რეესტრიდან. ბოლო განახლება: ${esc(st.updated)}`
    : `Data from the official EPDK registry. Last update: ${esc(st.updated)}`}</p>

<h2>${lang === 'ka' ? 'ქსელები' : 'Networks'}</h2>
<div class="tw"><table>
<thead><tr><th>${esc(t.thProvider)}</th><th>${esc(t.thCount)}</th></tr></thead>
<tbody>
${ps.brands.slice(0, 20).map(([b, n]) => `<tr><td>${esc(b)}</td><td>${n}</td></tr>`).join('\n')}
</tbody></table></div>

${connectorChips({ connectors: ps.connectors }, lang, (x) => big(x, lang))}

<h2>${lang === 'ka' ? 'სადგურების სია' : 'Station list'}</h2>
<p>${lang === 'ka'
    ? (list.length > TR_ROWS
      ? `ქვემოთ ${TR_ROWS} სადგურია, სწრაფი და ყველაზე მძლავრი პირველ რიგში. დანარჩენი ${big(ps.total - TR_ROWS, 'ka')} სადგური რუკაზე, აპლიკაციაშია.`
      : 'ქვემოთ ამ პროვინციის ყველა საჯარო სადგურია, სწრაფი და ყველაზე მძლავრი პირველ რიგში.')
    : (list.length > TR_ROWS
      ? `The ${TR_ROWS} stations below are ordered fast and strongest first. The remaining ${big(ps.total - TR_ROWS, 'en')} are on the map in the app.`
      : 'Below is every public station in this province, ordered fast and strongest first.')}</p>
${trStationRows(shown, lang)}
<p class="note">${lang === 'ka'
    ? 'ტარიფები ლირაშია, ინფორმაციული ხასიათისაა და ოპერატორის მიერაა გამოქვეყნებული. თურქეთში ცოცხალი სტატუსი არ ქვეყნდება.'
    : 'Tariffs are in lira, indicative and published by the operator. Turkey publishes no live availability.'}</p>

<h2>${lang === 'ka' ? 'სხვა პროვინციები' : 'Other provinces'}</h2>
<div class="links">
${neighbours.map(([p]) => `<a href="${trHref(lang, p)}">${esc(provName(p, lang))}</a>`).join('')}
<a href="${t.base}/${t.turkeyDir}/">${lang === 'ka' ? 'თურქეთის ყველა დამტენი' : 'All chargers in Turkey'}</a>
</div>

<h2>${esc(t.faq)}</h2>
<div class="faq">
${faq.map(([q, a]) => `<details><summary>${esc(q)}</summary><p>${esc(a)}</p></details>`).join('\n')}
</div>`;

  return {
    file: path.join(SITE, t.base.replace('/', ''), t.turkeyDir, s, 'index.html'),
    url,
    html: shell({
      lang, title, desc, canonical: url, altHref: alt, body,
      jsonld: {
        '@context': 'https://schema.org',
        '@graph': [
          breadcrumbLd(bc),
          { '@type': 'CollectionPage', '@id': url + '#page', name: title, url, inLanguage: t.code, description: desc,
            isPartOf: { '@type': 'WebSite', '@id': `${ORIGIN}/#website` } },
          { '@type': 'FAQPage', inLanguage: t.code,
            mainEntity: faq.map(([q, a]) => ({ '@type': 'Question', name: q, acceptedAnswer: { '@type': 'Answer', text: a } })) },
        ],
      },
    }),
  };
}

const ARTICLE_SLUGS = ['datenvis-fasi', 'konektorebi', 'ac-da-dc', 'shori-mgzavroba',
  'amerikuli-importi', 'chinuri-importi', 'zamtari', 'sakhlis-damteni', '100-km-fasi', 'batarea',
  'batareis-cveta', 'tbilisi-stambuli', 'turketshi-mgzavroba', 'meoradi-shemowmeba',
  'tesla-model-3-y', 'datenvis-kharjebi'];

// Every indexable URL on geocharge.ge that this script does not itself render:
// the two hand-written home pages and everything under /blog/.
const unrenderedUrls = () => [
  `${ORIGIN}/`, `${ORIGIN}/en/`,
  `${ORIGIN}/blog/`, `${ORIGIN}/en/blog/`,
  ...ARTICLE_SLUGS.flatMap((s) => [`${ORIGIN}/blog/${s}/`, `${ORIGIN}/en/blog/${s}/`]),
];

function sitemap(pairs, today) {
  const fixed = [
    ['https://geocharge.ge/', 'https://geocharge.ge/en/', '1.0', 'weekly'],
    ['https://geocharge.ge/blog/', 'https://geocharge.ge/en/blog/', '0.8', 'monthly'],
    ...ARTICLE_SLUGS.map((s) => [
      `https://geocharge.ge/blog/${s}/`, `https://geocharge.ge/en/blog/${s}/`, '0.8', 'monthly']),
    ['https://geocharge.ge/privacy-policy.html', 'https://geocharge.ge/en/privacy-policy.html', '0.3', 'yearly'],
  ];
  const entry = (ka, en, pri, freq) => [ka, en].map((loc) => `  <url>
    <loc>${loc}</loc>
    <xhtml:link rel="alternate" hreflang="ka" href="${ka}"/>
    <xhtml:link rel="alternate" hreflang="en" href="${en}"/>
    <xhtml:link rel="alternate" hreflang="x-default" href="${ka}"/>
    <lastmod>${today}</lastmod>
    <changefreq>${freq}</changefreq>
    <priority>${loc === en ? (parseFloat(pri) - 0.1).toFixed(1) : pri}</priority>
  </url>`).join('\n');

  return `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"
        xmlns:xhtml="http://www.w3.org/1999/xhtml">
${fixed.map((f) => entry(...f)).join('\n')}
${pairs.map(({ ka, en, priority }) => entry(ka, en, priority, 'weekly')).join('\n')}
  <url>
    <loc>https://tesla.geocharge.ge/</loc>
    <lastmod>${today}</lastmod>
    <changefreq>monthly</changefreq>
    <priority>0.6</priority>
  </url>
</urlset>
`;
}

/* ── main ────────────────────────────────────────────────────────────────── */
async function main() {
  const argv = process.argv.slice(2);
  const offline = argv.includes('--offline');
  const ping = argv.includes('--ping');

  let raw;
  if (offline && existsSync(CACHE)) {
    raw = JSON.parse(await readFile(CACHE, 'utf8'));
    console.log(`· using cached gist (${raw.length} records)`);
  } else {
    const res = await fetch(GIST);
    if (!res.ok) throw new Error(`gist fetch failed: ${res.status}`);
    raw = await res.json();
    await mkdir(path.dirname(CACHE), { recursive: true });
    await writeFile(CACHE, JSON.stringify(raw), 'utf8');
    console.log(`· fetched gist (${raw.length} records)`);
  }

  const clearance = await clearanceData(offline);

  // Turkey is a second dataset, not a second country inside the same file: it
  // comes from its own gist and its own regulator. See tools/turkey.mjs.
  const tr = await loadTurkey({ offline });
  const trStats = turkeyStats(tr);
  const trProvPages = trStats.provinces
    .filter(([prov, l]) => l.length >= TR_MIN_PAGE || TR_FORCE.includes(prov));
  for (const [prov] of trProvPages) TR_PAGES.add(prov);
  console.log(`· Turkey: ${trStats.total} stations, ${trStats.brands.length} operators,`
    + ` ${trProvPages.length} province pages of ${trStats.provinces.length} provinces`);

  const ge = raw.filter(inGeorgia);
  console.log(`· ${ge.length} in Georgia, ${raw.length - ge.length} outside (not published)`);

  for (const s of ge) s._city = assignCity(s);
  const unassigned = ge.filter((s) => !s._city).length;
  console.log(`· ${ge.length - unassigned} matched to a city, ${unassigned} on highways / outside city radii`);

  // byCityAll keeps every city, however small, because a route still passes
  // through a town with two chargers even when that town gets no page.
  const byCityAll = new Map();
  for (const s of ge) {
    if (!s._city) continue;
    const k = s._city[0];
    if (!byCityAll.has(k)) byCityAll.set(k, []);
    byCityAll.get(k).push(s);
  }
  const byCity = new Map(byCityAll);
  for (const [k, v] of byCity) if (v.length < MIN_CITY_STATIONS) byCity.delete(k);

  const byProvider = new Map();
  for (const s of ge) {
    if (!byProvider.has(s.provider)) byProvider.set(s.provider, []);
    byProvider.get(s.provider).push(s);
  }

  const updated = (ge.map((s) => s.last_updated).filter(Boolean).sort().pop() || '').slice(0, 16);
  const today = new Date().toISOString().slice(0, 10);

  const cityList = [...byCity.entries()].sort((a, b) => b[1].length - a[1].length);
  // Everything that renders a city link reads CITY_PAGES, so it has to be
  // filled before any page is built.
  for (const c of byCity.keys()) CITY_PAGES.add(c);
  const provList = [...byProvider.entries()].sort((a, b) => b[1].length - a[1].length);

  const pages = [];
  for (const lang of ['ka', 'en']) {
    pages.push(catalogPage(lang, ge, byCity, byProvider, updated));
    pages.push(tariffPage(lang, ge, byProvider, updated));
    pages.push(networksIndexPage(lang, byProvider, updated));
    pages.push(calculatorPage(lang, ge, byProvider, updated));
    pages.push(timeCalculatorPage(lang, ge, updated));
    pages.push(customsPage(lang, clearance));
    pages.push(routesIndexPage(lang, byCity, byCityAll, raw, updated));
    for (const [c, list] of cityList) pages.push(cityPage(lang, list[0]._city, list, cityList, updated));
    for (const [p, list] of provList) pages.push(providerPage(lang, p, list, provList, updated));
    for (const r of ROUTES) pages.push(routePage(lang, r, byCity, byCityAll, raw, updated, byProvider));
    pages.push(turkeyHubPage(lang, tr, trStats, trProvPages));
    for (const [prov, list] of trProvPages) pages.push(turkeyProvincePage(lang, prov, list, trStats));
  }

  // Daily snapshot. Growth over time is the one thing the catalogue cannot show
  // today, so start recording now; a history page becomes possible once there
  // are enough rows to plot. Append-only, one row per date.
  const histFile = path.join(ROOT, 'tools', 'history', 'stations.jsonl');
  await mkdir(path.dirname(histFile), { recursive: true });
  const prev = existsSync(histFile) ? await readFile(histFile, 'utf8') : '';
  if (!prev.includes(`"date":"${today}"`)) {
    const row = {
      date: today,
      total: ge.length,
      dc: ge.filter((s) => s.type === 'Fast DC').length,
      ac: ge.filter((s) => s.type !== 'Fast DC').length,
      byProvider: Object.fromEntries(provList.map(([p, l]) => [p, l.length])),
      byCity: Object.fromEntries(cityList.map(([c, l]) => [c, l.length])),
    };
    await writeFile(histFile, prev + JSON.stringify(row) + '\n', 'utf8');
    console.log(`· history: appended ${today} (${ge.length} stations)`);
  } else {
    console.log(`· history: ${today} already recorded`);
  }

  for (const p of pages) {
    await mkdir(path.dirname(p.file), { recursive: true });
    await writeFile(p.file, p.html, 'utf8');
  }
  console.log(`· wrote ${pages.length} pages`);

  // Safety net: coordinates and live status must never reach the output.
  const coords = new Set();
  for (const s of ge) {
    coords.add(String(s.lat).slice(0, 8));
    coords.add(String(s.lng).slice(0, 8));
  }
  // Match the data itself, not prose: field names plus every distinct
  // availability/port-status value the gist actually contains.
  const banned = new Set(['available_spots', 'total_spots', '"ports"', '"status"']);
  for (const s of ge) {
    if (s.available_spots) banned.add(String(s.available_spots));
    for (const port of (s.ports || [])) if (port.status) banned.add(`>${port.status}<`);
  }
  let leaks = 0;
  for (const p of pages) {
    for (const c of coords) if (p.html.includes(c)) { console.error(`  !! coordinate ${c} leaked into ${p.file}`); leaks++; }
    for (const w of banned) if (p.html.includes(w)) { console.error(`  !! live-status token ${JSON.stringify(w)} leaked into ${p.file}`); leaks++; }
  }
  if (leaks) throw new Error(`${leaks} leak(s) detected, aborting before deploy`);
  console.log('· leak check passed: no coordinates, no live status in output');

  // Every internal link must land on a file that exists. Pages here are
  // generated from the station data while some of their link targets are
  // suppressed by thresholds like MIN_CITY_STATIONS, so a link can rot without
  // anyone touching it. Checked across the whole of site/, because the guides
  // written by build-articles.mjs and these pages link to each other.
  const htmlFiles = [];
  (function walk(dir) {
    for (const e of readdirSync(dir, { withFileTypes: true })) {
      const p = path.join(dir, e.name);
      if (e.isDirectory()) walk(p);
      else if (e.name.endsWith('.html')) htmlFiles.push(p);
    }
  })(SITE);
  const dead = new Map();
  for (const f of htmlFiles) {
    const html = await readFile(f, 'utf8');
    for (const m of html.matchAll(/href="(\/[^"#?]*)"/g)) {
      const href = m[1];
      const target = href.endsWith('/')
        ? path.join(SITE, href, 'index.html')
        : path.join(SITE, href);
      if (existsSync(target)) continue;
      if (!dead.has(href)) dead.set(href, []);
      dead.get(href).push(path.relative(ROOT, f));
    }
  }
  if (dead.size) {
    console.error(`  !! ${dead.size} internal link(s) point at pages that do not exist:`);
    for (const [href, from] of [...dead].slice(0, 12)) {
      console.error(`     ${href}  <- ${from.slice(0, 2).join(', ')}${from.length > 2 ? ` (+${from.length - 2})` : ''}`);
    }
    throw new Error('link check failed');
  }
  console.log(`· link check passed: ${htmlFiles.length} files, every internal link resolves`);

  // House style: no dashes as punctuation in Georgian copy. Checked on prose
  // elements only, so the "—" placeholder in a table cell (meaning "no data")
  // and hyphens inside names like E-Space are left alone.
  const dashes = [];
  for (const p of pages.filter((x) => !x.url.includes('/en/'))) {
    const prose = [...p.html.matchAll(/<(title|h1|h2|p|summary|li)[^>]*>([\s\S]*?)<\/\1>/g)]
      .map((m) => m[2]).join('\n')
      + '\n' + (p.html.match(/name="description" content="([^"]*)"/) || [])[1];
    for (const m of prose.matchAll(/\S{0,20}\s[—–]\s\S{0,20}/g)) dashes.push(`${p.file}: …${m[0]}…`);
  }
  if (dashes.length) {
    console.error(`  !! ${dashes.length} dash(es) used as punctuation in Georgian copy:`);
    for (const d of dashes.slice(0, 10)) console.error('     ' + d);
    throw new Error('dash check failed');
  }
  console.log('· dash check passed: no dashes as punctuation in Georgian copy');

  const pairs = [];
  const kaPrefixes = ['/damtenebi', '/qselebi', '/tarifebi', '/marshruti', '/kalkulatori', '/datenvis-dro',
    '/ganbajeba', '/turketi'];
  const kaPages = pages.filter((p) => kaPrefixes.some((k) => p.url.startsWith(ORIGIN + k)));
  for (const p of kaPages) {
    const en = p.url
      .replace('/damtenebi/', '/en/chargers/')
      .replace('/qselebi/', '/en/networks/')
      .replace('/tarifebi/', '/en/tariffs/')
      .replace('/marshruti/', '/en/routes/')
      .replace('/kalkulatori/', '/en/calculator/')
      .replace('/datenvis-dro/', '/en/charging-time/')
      .replace('/ganbajeba/', '/en/customs/')
      .replace('/turketi/', '/en/turkey/');
    const top = ['/damtenebi/', '/tarifebi/', '/qselebi/', '/marshruti/', '/kalkulatori/', '/datenvis-dro/',
      '/ganbajeba/', '/turketi/'].some((k) => p.url === ORIGIN + k);
    pairs.push({ ka: p.url, en, priority: top ? '0.9' : '0.7' });
  }
  const xml = sitemap(pairs, today);
  await writeFile(path.join(SITE, 'sitemap.xml'), xml, 'utf8');
  console.log(`· sitemap.xml: ${(xml.match(/<loc>/g) || []).length} urls`);

  if (ping) {
    // The guides are the pages most worth announcing, and they are exactly the
    // ones `pages` does not contain, so add them explicitly.
    const urlList = [...new Set([...pages.map((p) => p.url), ...unrenderedUrls()])].slice(0, 10000);
    const res = await fetch('https://api.indexnow.org/indexnow', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json; charset=utf-8' },
      body: JSON.stringify({
        host: 'geocharge.ge', key: INDEXNOW_KEY,
        keyLocation: `${ORIGIN}/${INDEXNOW_KEY}.txt`, urlList,
      }),
    });
    console.log(`· IndexNow: HTTP ${res.status} for ${urlList.length} urls`);
  }

  console.log(`\n  per language: 1 catalogue + 1 tariffs + 1 networks index + 1 routes index`
    + ` + 2 calculators + 1 customs + 1 Turkey hub + ${cityList.length} cities + ${provList.length} networks`
    + ` + ${ROUTES.length} routes + ${trProvPages.length} Turkish provinces`
    + ` = ${pages.length / 2}, × 2 langs = ${pages.length} pages`);
}

// Only run the build when invoked directly; build-articles.mjs imports CSS/shell.
if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((e) => { console.error(e); process.exit(1); });
}
