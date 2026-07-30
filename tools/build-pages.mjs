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
import { existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

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

const GE_BBOX = { minLat: 41.0, maxLat: 43.65, minLng: 39.9, maxLng: 46.8 };
const AM_BBOX = { minLat: 38.8, maxLat: 41.30, minLng: 43.4, maxLng: 46.7 };

const inBox = (s, b) => s.lat >= b.minLat && s.lat <= b.maxLat && s.lng >= b.minLng && s.lng <= b.maxLng;
const inGeorgia = (s) => inBox(s, GE_BBOX) && !inBox(s, AM_BBOX);

function haversineKm(aLat, aLng, bLat, bLng) {
  const R = 6371, r = Math.PI / 180;
  const dLat = (bLat - aLat) * r, dLng = (bLng - aLng) * r;
  const h = Math.sin(dLat / 2) ** 2 +
    Math.cos(aLat * r) * Math.cos(bLat * r) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(h));
}

function assignCity(s) {
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
    ctaTitle: 'რუკა და ცოცხალი სტატუსი — აპლიკაციაში',
    ctaBody: 'ამ გვერდზე ხედავთ, რომელი დამტენები არსებობს და სად. რუკა, ზუსტი მდებარეობა, ცოცხალი სტატუსი (თავისუფალია თუ დაკავებული) და მარშრუტის დაგეგმვა უფასო აპლიკაციაშია.',
    ctaPlay: 'ჩამოტვირთვა Google Play-დან', ctaStore: 'ჩამოტვირთვა App Store-დან',
    otherCities: 'სხვა ქალაქები', otherNetworks: 'სხვა ქსელები', backToAll: 'ყველა დამტენი საქართველოში',
    noPrice: '—', faq: 'ხშირად დასმული კითხვები',
    priceNote: 'ტარიფები ინფორმაციული ხასიათისაა და პროვაიდერის მიერაა გამოქვეყნებული.',
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
    ctaTitle: 'Map and live status — in the app',
    ctaBody: 'This page shows which chargers exist and where. The map, exact locations, real-time availability and route planning live in the free app.',
    ctaPlay: 'Get it on Google Play', ctaStore: 'Download on the App Store',
    otherCities: 'Other cities', otherNetworks: 'Other networks', backToAll: 'All chargers in Georgia',
    noPrice: '—', faq: 'Frequently asked questions',
    priceNote: 'Tariffs are indicative and published by the provider.',
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
.note{color:#8B98A1;font-size:13px;margin:12px 0 0}
`.trim();

export function shell({ lang, title, desc, canonical, altHref, jsonld, body }) {
  const t = L[lang];
  const other = lang === 'ka' ? 'en' : 'ka';
  const kaHref = lang === 'ka' ? canonical : altHref;
  const enHref = lang === 'en' ? canonical : altHref;
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
<meta property="og:image" content="${ORIGIN}/assets/og-image.png">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="${esc(title)}">
<meta name="twitter:description" content="${esc(desc)}">
<meta name="twitter:image" content="${ORIGIN}/assets/og-image.png">
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
  <div class="f-in">
    <p style="margin:0">© 2026 GeoCharge</p>
    <a href="${t.base}/">${lang === 'ka' ? '← geocharge.ge' : '← geocharge.ge'}</a>
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
        ? `<td><a href="${t.base}/${t.chargersDir}/${slug(s._city[0])}/">${esc(lang === 'ka' ? s._city[1] : s._city[0])}</a></td>`
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

const statBlock = (sum, lang) => {
  const t = L[lang];
  return `<div class="stats">
  <div class="stat"><b>${sum.total}</b><span>${esc(t.stations)}</span></div>
  <div class="stat"><b>${sum.dc}</b><span>${esc(t.fast)}</span></div>
  <div class="stat"><b>${sum.ac}</b><span>${esc(t.slow)}</span></div>
  <div class="stat"><b>${sum.providers.length}</b><span>${esc(t.networksWord)}</span></div>
  ${sum.maxKw ? `<div class="stat"><b>${sum.maxKw} kW</b><span>${esc(t.maxPower)}</span></div>` : ''}
</div>`;
};

const connectorChips = (sum, lang) => `<h2>${esc(L[lang].connectorMix)}</h2>
<div class="chips">${sum.connectors.map(([c, n]) => `<span class="chip"><b>${n}</b> ${esc(c)}</span>`).join('')}</div>`;

/* ── page builders ───────────────────────────────────────────────────────── */
function catalogPage(lang, all, byCity, byProvider, updated) {
  const t = L[lang], sum = summarise(all);
  const url = `${ORIGIN}${t.base}/${t.chargersDir}/`;
  const alt = `${ORIGIN}${L[lang === 'ka' ? 'en' : 'ka'].base}/${L[lang === 'ka' ? 'en' : 'ka'].chargersDir}/`;
  const cities = [...byCity.entries()].sort((a, b) => b[1].length - a[1].length);
  const provs = [...byProvider.entries()].sort((a, b) => b[1].length - a[1].length);

  const title = lang === 'ka'
    ? `ელექტრო მანქანის დამტენები საქართველოში — ${sum.total} სადგური | GeoCharge`
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
      `${cities[0] ? (lang === 'ka' ? cities[0][1][0]._city[1] : cities[0][0]) : ''}-ში — ${cities[0] ? cities[0][1].length : 0} სადგური. შემდეგ მოდის ${cities[1] ? cities[1][1][0]._city[1] : ''} (${cities[1] ? cities[1][1].length : 0}).`],
    [`რომელი კონექტორები გვხვდება საქართველოში?`,
      `ყველაზე გავრცელებულია ${sum.connectors.slice(0, 3).map(([c, n]) => `${c} (${n})`).join(', ')}. სრული განაწილება ამ გვერდზეა.`],
    [`სად ვნახო, დამტენი თავისუფალია თუ არა?`,
      `ცოცხალი სტატუსი და რუკა GeoCharge-ის უფასო აპლიკაციაშია — ამ გვერდზე მხოლოდ სადგურების კატალოგია.`],
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
    ? `ელექტრო მანქანის დამტენები ${loc} — ${sum.total} სადგური | GeoCharge`
    : `EV charging stations ${loc} — ${sum.total} stations | GeoCharge`;
  const desc = lang === 'ka'
    ? `${name}: ${sum.total} საჯარო დამტენი სადგური, ${sum.dc} სწრაფი DC. ქსელები: ${top.slice(0, 3).map((x) => x[0]).join(', ')}. სიმძლავრე, კონექტორები და ტარიფები.`
    : `${name}: ${sum.total} public EV chargers, ${sum.dc} fast DC. Networks: ${top.slice(0, 3).map((x) => x[0]).join(', ')}. Power, connectors and tariffs.`;

  const intro = lang === 'ka'
    ? `${loc} ${sum.total} საჯარო დამტენი სადგურია — ${sum.dc} სწრაფი DC და ${sum.ac} ჩვეულებრივი AC. ისინი ${sum.providers.length} ქსელს ეკუთვნის, ყველაზე დიდი წილი ${PROVIDER_KA[top[0][0]] || top[0][0]}-ს აქვს (${top[0][1]} სადგური).${sum.maxKw ? ` ყველაზე მძლავრი დამტენი ${sum.maxKw} kW-ია.` : ''}`
    : `${name} has ${sum.total} public charging stations — ${sum.dc} fast DC and ${sum.ac} standard AC. They belong to ${sum.providers.length} networks, with ${top[0][0]} operating the most (${top[0][1]} stations).${sum.maxKw ? ` The most powerful charger here delivers ${sum.maxKw} kW.` : ''}`;

  const bc = [{ name: t.home, href: `${t.base}/` },
    { name: t.catalog, href: `${t.base}/${t.chargersDir}/` }, { name }];

  const others = allCities.filter(([c]) => c !== city[0]).slice(0, 18);

  const faq = lang === 'ka' ? [
    [`რამდენი ელექტრო დამტენია ${loc}?`, `${sum.total} საჯარო დამტენი სადგური, აქედან ${sum.dc} სწრაფი DC.`],
    [`რომელი ქსელების დამტენებია ${loc}?`, `${top.map((x) => `${PROVIDER_KA[x[0]] || x[0]} (${x[1]})`).join(', ')}.`],
    [`რომელი კონექტორები გვხვდება ${loc}?`, `${sum.connectors.map(([c, n]) => `${c} — ${n}`).join(', ')}.`],
  ] : [
    [`How many EV chargers are there ${loc}?`, `${sum.total} public charging stations, ${sum.dc} of them fast DC.`],
    [`Which networks operate ${loc}?`, `${top.map((x) => `${x[0]} (${x[1]})`).join(', ')}.`],
    [`Which connectors are available ${loc}?`, `${sum.connectors.map(([c, n]) => `${c} — ${n}`).join(', ')}.`],
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
    ? `${provider} დამტენები საქართველოში — ${sum.total} სადგური | GeoCharge`
    : `${provider} chargers in Georgia — ${sum.total} stations | GeoCharge`;
  const desc = lang === 'ka'
    ? `${name}: ${sum.total} დამტენი სადგური საქართველოში, ${sum.dc} სწრაფი DC. მდებარეობები, სიმძლავრე, კონექტორები და ტარიფები.`
    : `${provider}: ${sum.total} charging stations in Georgia, ${sum.dc} fast DC. Locations, power, connectors and tariffs.`;

  const intro = lang === 'ka'
    ? `${name} საქართველოში ${sum.total} საჯარო დამტენ სადგურს ოპერირებს — ${sum.dc} სწრაფი DC და ${sum.ac} AC.${sum.maxKw ? ` ქსელის ყველაზე მძლავრი დამტენი ${sum.maxKw} kW-ია.` : ''} სადგურები ${cities.length} ქალაქშია განთავსებული.`
    : `${provider} operates ${sum.total} public charging stations in Georgia — ${sum.dc} fast DC and ${sum.ac} AC.${sum.maxKw ? ` Its most powerful charger delivers ${sum.maxKw} kW.` : ''} The stations are spread across ${cities.length} cities.`;

  const bc = [{ name: t.home, href: `${t.base}/` },
    { name: t.catalog, href: `${t.base}/${t.chargersDir}/` }, { name: provider }];

  const logo = PROVIDER_LOGO[provider];

  const faq = lang === 'ka' ? [
    [`რამდენი ${provider} დამტენია საქართველოში?`, `${sum.total} საჯარო დამტენი სადგური, აქედან ${sum.dc} სწრაფი DC.`],
    [`რომელ ქალაქებშია ${provider}-ის დამტენები?`, `${cities.slice(0, 8).map((c) => `${lang === 'ka' ? c[1][0]._city[1] : c[0]} (${c[1].length})`).join(', ')}${cities.length > 8 ? ' და სხვა.' : '.'}`],
    [`რომელი კონექტორები აქვს ${provider}-ს?`, `${sum.connectors.map(([c, n]) => `${c} — ${n}`).join(', ')}.`],
  ] : [
    [`How many ${provider} chargers are there in Georgia?`, `${sum.total} public charging stations, ${sum.dc} of them fast DC.`],
    [`Which cities have ${provider} chargers?`, `${cities.slice(0, 8).map((c) => `${c[0]} (${c[1].length})`).join(', ')}${cities.length > 8 ? ' and more.' : '.'}`],
    [`Which connectors does ${provider} use?`, `${sum.connectors.map(([c, n]) => `${c} — ${n}`).join(', ')}.`],
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
${cities.map(([c, l]) => `<tr><td><a href="${t.base}/${t.chargersDir}/${slug(c)}/">${esc(lang === 'ka' ? l[0]._city[1] : c)}</a></td><td>${l.length}</td></tr>`).join('\n')}
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

/* ── sitemap ─────────────────────────────────────────────────────────────── */
function sitemap(pairs, today) {
  // Hand-written guides live in tools/build-articles.mjs; keep the slugs in sync.
  const ARTICLE_SLUGS = ['datenvis-fasi', 'konektorebi', 'ac-da-dc', 'shori-mgzavroba'];
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

  const ge = raw.filter(inGeorgia);
  console.log(`· ${ge.length} in Georgia, ${raw.length - ge.length} outside (not published)`);

  for (const s of ge) s._city = assignCity(s);
  const unassigned = ge.filter((s) => !s._city).length;
  console.log(`· ${ge.length - unassigned} matched to a city, ${unassigned} on highways / outside city radii`);

  const byCity = new Map();
  for (const s of ge) {
    if (!s._city) continue;
    const k = s._city[0];
    if (!byCity.has(k)) byCity.set(k, []);
    byCity.get(k).push(s);
  }
  for (const [k, v] of byCity) if (v.length < MIN_CITY_STATIONS) byCity.delete(k);

  const byProvider = new Map();
  for (const s of ge) {
    if (!byProvider.has(s.provider)) byProvider.set(s.provider, []);
    byProvider.get(s.provider).push(s);
  }

  const updated = (ge.map((s) => s.last_updated).filter(Boolean).sort().pop() || '').slice(0, 16);
  const today = new Date().toISOString().slice(0, 10);

  const cityList = [...byCity.entries()].sort((a, b) => b[1].length - a[1].length);
  const provList = [...byProvider.entries()].sort((a, b) => b[1].length - a[1].length);

  const pages = [];
  for (const lang of ['ka', 'en']) {
    pages.push(catalogPage(lang, ge, byCity, byProvider, updated));
    for (const [c, list] of cityList) pages.push(cityPage(lang, list[0]._city, list, cityList, updated));
    for (const [p, list] of provList) pages.push(providerPage(lang, p, list, provList, updated));
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
  if (leaks) throw new Error(`${leaks} leak(s) detected — aborting before deploy`);
  console.log('· leak check passed: no coordinates, no live status in output');

  const pairs = [];
  const kaPages = pages.filter((p) => p.url.startsWith(`${ORIGIN}/damtenebi`) || p.url.startsWith(`${ORIGIN}/qselebi`));
  for (const p of kaPages) {
    const en = p.url.replace('/damtenebi/', '/en/chargers/').replace('/qselebi/', '/en/networks/');
    pairs.push({ ka: p.url, en, priority: p.url.endsWith('/damtenebi/') ? '0.9' : '0.7' });
  }
  const xml = sitemap(pairs, today);
  await writeFile(path.join(SITE, 'sitemap.xml'), xml, 'utf8');
  console.log(`· sitemap.xml: ${(xml.match(/<loc>/g) || []).length} urls`);

  if (ping) {
    const urlList = [...new Set(pages.map((p) => p.url))].slice(0, 10000);
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

  console.log(`\n  ${cityList.length} cities × 2 langs + ${provList.length} networks × 2 langs + 2 catalogues = ${pages.length} pages`);
}

// Only run the build when invoked directly; build-articles.mjs imports CSS/shell.
if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((e) => { console.error(e); process.exit(1); });
}
