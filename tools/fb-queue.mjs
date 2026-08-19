#!/usr/bin/env node
// Fills the GeoCharge Facebook page's scheduled queue from the built blog.
//
//   node tools/fb-queue.mjs                 # dry run, writes marketing/fb-queue.md
//   node tools/fb-queue.mjs --publish       # actually schedules on Facebook
//   node tools/fb-queue.mjs --list          # what is already in the queue
//   node tools/fb-queue.mjs --cancel <id>   # drop one scheduled post
//
// Facebook does the waiting, not us: every post goes in with published=false
// and a scheduled_publish_time, so nothing needs to be running at post time.
// A batch is normally a month of slots queued in one go.
//
// The article metadata (title, description, canonical URL, og image) is read
// from the BUILT pages under site/blog/, so a post can never advertise a page
// that is not live. The hook lines are authored here: a machine-cut sentence
// from the article reads like a machine cut it.

import { readFile, writeFile, readdir, mkdir } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const BLOG = path.join(ROOT, 'site', 'blog');
const STATE = path.join(ROOT, 'tools', 'fb-state.json');
const PREVIEW = path.join(ROOT, 'marketing', 'fb-queue.md');
const SITE_SOCIAL = path.join(ROOT, 'site', 'assets', 'social');
const ORIGIN = 'https://geocharge.ge';
const API = process.env.FB_API_VERSION || 'v26.0';

// Asia/Tbilisi is UTC+4 all year, no DST, so a fixed offset is correct here
// and stays correct. Slot hours below are Tbilisi wall clock.
const TZ = 4;
const SLOTS = [
  { dow: 2, h: 19, m: 0 },  // Tuesday evening
  { dow: 6, h: 12, m: 0 },  // Saturday midday
];

// Two hooks per article: the page posts the back catalogue on rotation, and a
// second pass through the same 14 articles should not repeat itself word for
// word. Order inside each pair is the order they get used.
const HOOKS = {
  'datenvis-fasi': [
    'რამდენი გიჯდებათ ერთი დატენვა? სწრაფ დამტენზე კილოვატსაათი ყველაზე ხშირად 0.78 ლარია, ნელზე 0.65. 60 კილოვატსაათიანი ბატარეის სავსემდე დატენვა 30-დან 47 ლარამდე გამოდის.\n\nსტატიაში ნახავთ, როგორ დათვალოთ თქვენი მანქანის დატენვის ზუსტი ფასი.',
    'საქართველოს 600-ზე მეტი საჯარო დამტენიდან დაახლოებით 130 ტარიფს საერთოდ არ აქვეყნებს. ესენი ძირითადად სასტუმროებისა და სავაჭრო ცენტრების დამტენებია, სადაც დატენვა კლიენტისთვის უფასოა.\n\nდანარჩენების ფასები და გამოთვლის წესი აქ არის.',
  ],
  'konektorebi': [
    'CCS2 თუ GB/T? საქართველოში ორივე თითქმის თანაბრად არის გავრცელებული და სწორედ ეს ურევს ხოლმე ხალხს.\n\nრომელი კონექტორი გჭირდებათ თქვენს მანქანაზე და რამდენი ასეთი დამტენია ქვეყანაში.',
    'ევროპული მანქანა CCS2-ს ითხოვს, ჩინური GB/T-ს, ამერიკიდან ჩამოყვანილი კი შეიძლება CCS1 ან NACS აღმოჩნდეს. საქართველოში ბოლო ორი პრაქტიკულად არ არსებობს.\n\nსრული სურათი კონექტორებზე.',
  ],
  'ac-da-dc': [
    'DC დამტენი 20 წუთში აკეთებს იმას, რასაც AC რამდენიმე საათში. მაგრამ ეს არ ნიშნავს, რომ ყოველთვის სწრაფი გჭირდებათ.\n\nრით განსხვავდება ნელი და სწრაფი დატენვა და როდის რომელი აჯობებს.',
    'საქართველოში დაახლოებით 390 სწრაფი DC დამტენია და 220 ნელი AC. ორივეს თავისი ადგილი აქვს: ერთი გზისთვისაა, მეორე ღამისთვის.\n\nროგორ ავირჩიოთ სწორად.',
  ],
  'shori-mgzavroba': [
    'თბილისი ბათუმი ელექტრო მანქანით ერთი გაჩერებით გადის. მთავარი მაგისტრალი კარგად არის დაფარული, პრობლემა მაშინ იწყება, როცა მაგისტრალს ჩამოუხვევთ.\n\nპრაქტიკული გზამკვლევი შორ მგზავრობაზე.',
    'შორ გზაზე მთავარი შეცდომა 100 პროცენტამდე დატენვის ცდაა. 80-ის შემდეგ დამტენი მკვეთრად ანელებს და დრო უქმად იკარგება.\n\nრამდენიმე წესი, რომელიც მგზავრობას ამოკლებს.',
  ],
  'amerikuli-importi': [
    'ამერიკიდან ჩამოყვანილ ელექტრომობილს სხვა კონექტორი აქვს. საქართველოში CCS1 მხოლოდ 2 სადგურზეა, NACS 9-ზე.\n\nსად დატენავთ ასეთ მანქანას და რა ადაპტერი დაგჭირდებათ.',
    'ამერიკული სპეციფიკაციის მანქანა საქართველოში დასატენად ადაპტერს ითხოვს. ყიდვამდე იცოდეთ, რომელი და რა ჯდება.\n\nსრული სია აქ არის.',
  ],
  'chinuri-importi': [
    'GB/T კონექტორი საქართველოში 359 სადგურზეა და ეს ევროპულ CCS2-ს თითქმის უტოლდება. ჩინური მანქანის მფლობელისთვის ეს კარგი ამბავია.\n\nსად და როგორ დატენოთ ჩინური ელექტრომობილი.',
    'ჩინურ ელექტრომობილს ევროპაში დატენვის პრობლემა ექნება, საქართველოში კი არა. 359 GB/T სადგურიდან 332 იმავე აპარატზეა CCS2-თან ერთად.\n\nრას ნიშნავს ეს პრაქტიკულად.',
  ],
  'zamtari': [
    'ცივ ამინდში ელექტრომობილის რეალური გარბენი 20-დან 35 პროცენტამდე ეცემა. ეს ნორმალურია და წინასწარ იგეგმება.\n\nროგორ გავიაროთ ზამთარი პრობლემების გარეშე.',
    'ბაკურიანში 6 დამტენია და არცერთი სწრაფი, სტეფანწმინდაში 2, გუდაურში 7. სასრიალოდ წასვლამდე ეს ციფრები ღირს რომ იცოდეთ.\n\nზამთრის გზამკვლევი ელექტრომობილისთვის.',
  ],
  'sakhlis-damteni': [
    'თუ დღეში 50 კილომეტრამდე დადიხართ, ჩვეულებრივი როზეტიც კმარა. კედლის დამტენი მაშინ ხდება საჭირო, როცა ერთ ღამეში ბატარეის ნახევარზე მეტი უნდა შეავსოთ.\n\nრა სჭირდება სახლის დამტენს და რაზეა დამოკიდებული ფასი.',
    'სახლის დამტენის ფასს ყველაზე მეტად ის განსაზღვრავს, რა მანძილია მრიცხველიდან პარკინგამდე და გაქვთ თუ არა სამფაზიანი შეყვანა.\n\nრეალური ხარჯების დაშლა.',
  ],
  '100-km-fasi': [
    '100 კილომეტრი ელექტრომობილით საჯარო სწრაფ დამტენზე დაახლოებით 14 ლარია, ნელზე 12. იმავე გზას ბენზინის მანქანა თითქმის 30 ლარად გადის.\n\nსრული შედარება დღევანდელ ფასებზე.',
    'ელექტრო თუ ბენზინი? პასუხი იმაზეა დამოკიდებული, სად ტენით. სახლში დატენვისას სხვაობა კიდევ უფრო იზრდება.\n\nციფრები, რომლებიც რეგულარულად ახლდება.',
  ],
  'batarea': [
    'ბატარეა წელიწადში დაახლოებით 1-დან 2 პროცენტამდე კარგავს. რვა წელში ჩვეულებრივ 85-დან 90 პროცენტამდე რჩება.\n\nრა ხდება რეალურად და რას ნიშნავს ეს საქართველოში.',
    'ბატარეის დეგრადაციაზე ბევრი მითია. ყველაზე დიდი ისაა, თითქოს სწრაფი დატენვა ბატარეას კლავს.\n\nრას ამბობს რეალური მონაცემი.',
  ],
  'batareis-cveta': [
    'საშუალო ელექტრომობილი წელიწადში 2.3 პროცენტს კარგავს. ეს Geotab-ის კვლევის ციფრია, რომელიც 22 700 რეალურ მანქანას დაეყრდნო.\n\nრამდენი რჩება ბატარეას 50 000, 100 000 და 200 000 კილომეტრზე.',
    'რომელი მოდელები ინარჩუნებენ ბატარეას საუკეთესოდ და რომელია მაღალი რისკის ჯგუფი. გაზომილი ციფრები, არა ვარაუდი.\n\nმეორადის ყიდვამდე წასაკითხი.',
  ],
  'meoradi-shemowmeba': [
    'მეორადი ელექტრო მანქანის ყიდვისას ერთადერთი ციფრი, რომელიც ყველაზე მეტს ნიშნავს, ბატარეის ჯანმრთელობაა. ის იაფი OBD ადაპტერით იზომება.\n\nსრული სია, რომელიც ერთ დათვალიერებაში ეტევა.',
    'გარბენი მეორად ელექტრომობილზე თითქმის არაფერს ამბობს. ბატარეის SoH, სწრაფი დატენვის ტესტი და იმპორტის ისტორია გაცილებით მეტს გეტყვით.\n\nშემოწმების პრაქტიკული სია.',
  ],
  'turketshi-mgzavroba': [
    'თურქეთში 13 365 საჯარო დამტენია, აქედან 7 818 სწრაფი. საქართველოსთან შედარებით ეს სხვა მასშტაბია.\n\nრომელი საზღვრით წავიდეთ, რა კონექტორი გვჭირდება და რა ღირს დატენვა.',
    'თურქეთში GB/T კონექტორი არ არსებობს. ჩინური მანქანით მგზავრობამდე ეს ღირს რომ იცოდეთ.\n\nსრული გზამკვლევი თურქეთზე.',
  ],
  'tbilisi-stambuli': [
    'თბილისი სტამბოლი ელექტრო მანქანით სრულიად გასავლელია. სარფიდან სტამბოლამდე გზიდან 5 კილომეტრში 842 სწრაფი დამტენია.\n\nსად დავიტენოთ და როგორ დავგეგმოთ მარშრუტი.',
    'თბილისიდან სტამბოლამდე სანაპირო გზა უნდა აირჩიოთ და არა ანკარაზე. დამტენების სიმჭიდროვე იქ რამდენჯერმე მაღალია.\n\nმარშრუტი დამტენების მიხედვით.',
  ],
};

// Rotation is seasonal where it matters: the winter guide goes out in winter,
// the Turkey guides in travel season. Outside its months a seasonal article is
// held back entirely rather than merely deprioritised.
const SEASON = {
  'zamtari': [11, 12, 1, 2],
  'turketshi-mgzavroba': [5, 6, 7, 8, 9],
  'tbilisi-stambuli': [5, 6, 7, 8, 9],
};

// First pass through the catalogue, deliberately mixed by topic so the page
// does not run two battery pieces or two import pieces back to back. After
// everything has gone out once, "least recently posted" takes over and this
// order only breaks ties.
const ORDER = [
  'datenvis-fasi',
  'konektorebi',
  'tbilisi-stambuli',
  'batareis-cveta',
  'sakhlis-damteni',
  'turketshi-mgzavroba',
  '100-km-fasi',
  'meoradi-shemowmeba',
  'ac-da-dc',
  'shori-mgzavroba',
  'chinuri-importi',
  'zamtari',
  'amerikuli-importi',
  'batarea',
];

const flag = (name) => process.argv.includes(`--${name}`);
const arg = (name, dflt) => {
  const i = process.argv.indexOf(`--${name}`);
  if (i === -1) return dflt;
  const next = process.argv[i + 1];
  return !next || next.startsWith('--') ? dflt : next;
};

// Metadata comes out of the built page, never out of a separate list that
// could drift away from it.
async function articles() {
  const out = [];
  for (const slug of await readdir(BLOG)) {
    const file = path.join(BLOG, slug, 'index.html');
    if (!existsSync(file)) continue;
    const html = await readFile(file, 'utf8');
    const meta = (p) => (new RegExp(`<meta property="${p}" content="([^"]*)"`).exec(html) || [])[1];
    const url = meta('og:url');
    if (!url) continue;
    out.push({
      slug,
      title: (meta('og:title') || '').replace(/ \| GeoCharge$/, ''),
      desc: meta('og:description') || '',
      image: meta('og:image') || '',
      url,
    });
  }
  return out;
}

async function state() {
  if (!existsSync(STATE)) return { posted: [] };
  return JSON.parse(await readFile(STATE, 'utf8'));
}

const tbilisiUnix = (d, h, m) =>
  Math.floor(Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate(), h - TZ, m) / 1000);

// How far ahead Facebook will accept a scheduled post. The Pages API docs say
// six months; the API actually rejects anything past ~30 days with a bare
// "(#100) The specified scheduled publish time is invalid". Measured on
// 2026-08-19: 27 days ahead was accepted, 31 days ahead was refused. 29 leaves
// a day of margin, since the window is measured from the moment of the call.
const HORIZON_DAYS = 29;

// Walks forward day by day from `from` and returns up to `count` slot times,
// stopping at the horizon. Returning fewer than asked is normal, not an error:
// the rest of the catalogue gets queued on a later run.
//
// `taken` is the set of slot times already used by earlier runs. Without it a
// second run inside the same window would double book the slots the first run
// filled, because the state file tracks which articles went out, not when the
// page is already busy.
function slots(from, count, taken = new Set()) {
  const out = [];
  const day = new Date(Date.UTC(from.getUTCFullYear(), from.getUTCMonth(), from.getUTCDate()));
  const now = Math.floor(Date.now() / 1000);
  const limit = now + HORIZON_DAYS * 86400;
  while (out.length < count && tbilisiUnix(day, 0, 0) <= limit) {
    for (const s of SLOTS) {
      if (day.getUTCDay() !== s.dow) continue;
      // Facebook refuses anything less than 10 minutes out, too.
      const t = tbilisiUnix(day, s.h, s.m);
      if (t > now + 900 && t <= limit && !taken.has(t) && out.length < count) out.push(t);
    }
    day.setUTCDate(day.getUTCDate() + 1);
  }
  return out.sort((a, b) => a - b);
}

// Picks what to post. Ranked in tiers so the rules stay separable: in-season
// and unpublished beats unpublished, which beats a repeat, which beats
// anything out of season. Nothing repeats inside a single batch.
//
// `all` is for a full sweep of the catalogue, where covering everything once
// outranks seasonal placement: an out-of-season article is then pushed to the
// back of the run rather than dropped, so it lands on the slot closest to its
// season instead of not landing at all.
function plan(list, hist, times, all = false) {
  const last = {};
  const used = {};
  for (const p of hist.posted) {
    last[p.slug] = Math.max(last[p.slug] || 0, p.at);
    used[p.slug] = (used[p.slug] || 0) + 1;
  }
  const queue = [];
  for (const at of times) {
    const month = new Date(at * 1000).getUTCMonth() + 1;
    const rank = (a) => {
      if (queue.some((q) => q.slug === a.slug)) return [9, 0];
      const season = SEASON[a.slug];
      const off = season && !season.includes(month);
      if (off) {
        // 1.5 keeps it ahead of a repeat but behind everything in season.
        return all && !last[a.slug] ? [1.5, ORDER.indexOf(a.slug)] : [3, last[a.slug] || 0];
      }
      if (last[a.slug]) return [2, last[a.slug]];
      return [season ? 0 : 1, ORDER.indexOf(a.slug)];
    };
    const pick = [...list].sort((a, b) => {
      const [ta, sa] = rank(a);
      const [tb, sb] = rank(b);
      return ta - tb || sa - sb;
    })[0];
    const hooks = HOOKS[pick.slug];
    const text = hooks ? hooks[(used[pick.slug] || 0) % hooks.length] : pick.desc;
    queue.push({ ...pick, at, message: `${text}\n\n${pick.url}` });
    last[pick.slug] = at;
    used[pick.slug] = (used[pick.slug] || 0) + 1;
  }
  return queue;
}

const DAYS = ['კვი', 'ორშ', 'სამ', 'ოთხ', 'ხუთ', 'პარ', 'შაბ'];
const stamp = (t) => {
  const d = new Date((t + TZ * 3600) * 1000);
  const hh = String(d.getUTCHours()).padStart(2, '0');
  const mm = String(d.getUTCMinutes()).padStart(2, '0');
  return `${d.toISOString().slice(0, 10)} ${DAYS[d.getUTCDay()]} ${hh}:${mm}`;
};

async function creds() {
  // The token lives in .env at the repo root, which is gitignored. It never
  // goes in a source file and never in a commit.
  const env = path.join(ROOT, '.env');
  if (existsSync(env)) {
    for (const line of (await readFile(env, 'utf8')).split('\n')) {
      const m = /^\s*([A-Z_]+)\s*=\s*(.*?)\s*$/.exec(line);
      if (m && !process.env[m[1]]) process.env[m[1]] = m[2].replace(/^["']|["']$/g, '');
    }
  }
  const id = process.env.FB_PAGE_ID;
  const token = process.env.FB_PAGE_TOKEN;
  if (!id || !token) {
    throw new Error('FB_PAGE_ID და FB_PAGE_TOKEN უნდა იყოს .env-ში (იხ. docs/facebook_page.md)');
  }
  return { id, token };
}

async function graph(endpoint, params, method = 'GET') {
  const { token } = await creds();
  const body = new URLSearchParams({ ...params, access_token: token });
  const url = `https://graph.facebook.com/${API}/${endpoint}`;
  const res = method === 'GET'
    ? await fetch(`${url}?${body}`)
    : await fetch(url, { method, body });
  const json = await res.json();
  if (json.error) throw new Error(`${json.error.type} ${json.error.code}: ${json.error.message}`);
  return json;
}

// Instagram cannot be handed a future publish time the way Facebook can, so its
// publisher is a Cloud Function that wakes at post time. It has no copy of
// site/ and no way to read this file, so the content it needs is exported to
// functions/social-content.json and deployed with it. This keeps the hooks
// authored in exactly one place.
async function exportContent() {
  const list = await articles();
  // Instagram gets the 4:5 poster, not the og card. The og image is 1.905:1,
  // which clears Instagram's 1.91 ceiling by almost nothing and is the weakest
  // shape in the feed. Posters come from tools/build-article-posters.mjs; an
  // article without one falls back to the og image rather than being skipped.
  let posters = 0;
  const image = (a) => {
    const file = path.join(SITE_SOCIAL, `article-${a.slug}.png`);
    if (!existsSync(file)) return a.image;
    posters++;
    return `${ORIGIN}/assets/social/article-${a.slug}.png`;
  };
  const out = {
    generated: new Date().toISOString().slice(0, 10),
    order: ORDER,
    season: SEASON,
    articles: list.map((a) => ({
      slug: a.slug,
      title: a.title,
      url: a.url,
      image: image(a),
      hooks: HOOKS[a.slug] || [a.desc],
    })),
  };
  const file = path.join(ROOT, 'functions', 'social-content.json');
  await writeFile(file, JSON.stringify(out, null, 1), 'utf8');
  console.log(`${out.articles.length} სტატია → ${path.relative(ROOT, file)} (${posters} პოსტერით)`);
  const missing = list.filter((a) => !HOOKS[a.slug]).map((a) => a.slug);
  if (missing.length) console.log(`!! HOOKS აკლია: ${missing.join(', ')} (გამოყენდება meta description)`);
}

async function main() {
  if (flag('export')) return exportContent();

  if (flag('list')) {
    const { id } = await creds();
    const r = await graph(`${id}/scheduled_posts`, { fields: 'id,message,scheduled_publish_time', limit: '50' });
    if (!r.data || !r.data.length) return console.log('რიგი ცარიელია.');
    for (const p of r.data) {
      console.log(`${stamp(Number(p.scheduled_publish_time))}  ${p.id}`);
      console.log(`   ${(p.message || '').split('\n')[0].slice(0, 90)}`);
    }
    return;
  }

  if (flag('cancel')) {
    const id = arg('cancel');
    if (!id) throw new Error('--cancel <post-id>');
    await graph(String(id), {}, 'DELETE');
    return console.log(`გაუქმდა: ${id}`);
  }

  const startArg = arg('start');
  const start = startArg ? new Date(`${startArg}T00:00:00Z`) : new Date(Date.now() + 864e5);
  const list = await articles();
  const hist = await state();
  const all = flag('all');
  // --all sizes the batch to whatever has never been posted, so one run covers
  // the whole catalogue exactly once.
  const done = new Set(hist.posted.map((p) => p.slug));
  const count = all
    ? list.filter((a) => !done.has(a.slug)).length
    : Number(arg('count', 8));
  if (!count) return console.log('ყველა სტატია უკვე დაგეგმილია.');
  const taken = new Set(hist.posted.map((p) => p.at));
  const queue = plan(list, hist, slots(start, count, taken), all);

  const md = [
    '# Facebook queue',
    '',
    `მომზადდა ${new Date().toISOString().slice(0, 10)}. ${queue.length} პოსტი, დრო თბილისის.`,
    '',
    ...queue.flatMap((q) => [
      `## ${stamp(q.at)}`,
      '',
      '```',
      q.message,
      '```',
      `სურათი: ${q.image}`,
      '',
    ]),
  ].join('\n');
  await mkdir(path.dirname(PREVIEW), { recursive: true });
  await writeFile(PREVIEW, md, 'utf8');

  for (const q of queue) console.log(`${stamp(q.at)}  ${q.slug}`);
  console.log(`\n→ ${path.relative(ROOT, PREVIEW)}`);
  if (queue.length < count) {
    const left = count - queue.length;
    console.log(`\n${left} სტატია ${HORIZON_DAYS} დღის ფანჯარაში ვერ ჩაეტია. გაუშვით ხელახლა, როცა რიგი დაიცლება.`);
  }

  if (!flag('publish')) {
    console.log('\nდაგეგმილი არაფერია, ეს dry run იყო. გასაშვებად: node tools/fb-queue.mjs --publish');
    return;
  }

  const { id } = await creds();
  const posted = [...hist.posted];
  for (const q of queue) {
    const r = await graph(`${id}/feed`, {
      message: q.message,
      link: q.url,
      published: 'false',
      scheduled_publish_time: String(q.at),
    }, 'POST');
    console.log(`✓ ${stamp(q.at)}  ${q.slug}  ${r.id}`);
    posted.push({ slug: q.slug, at: q.at, id: r.id });
    // The state file is rewritten after every post so a mid-batch failure
    // cannot make the next run re-queue what already went in.
    await writeFile(STATE, JSON.stringify({ posted }, null, 1), 'utf8');
  }
}

main().catch((e) => { console.error(`!! ${e.message}`); process.exit(1); });
