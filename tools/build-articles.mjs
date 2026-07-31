#!/usr/bin/env node
// Renders the hand-written guide articles under site/blog/ and site/en/blog/.
//
//   node tools/build-articles.mjs
//
// Unlike build-pages.mjs, the prose here is AUTHORED, not derived from data:
// to change what an article says, edit the text below. Exact station and
// connector counts ARE injected from the live gist (see liveNumbers), so an
// article can never contradict the catalogue it links to. Anything written as
// a round approximation stays a round approximation.

import { mkdir, writeFile, readFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { CSS, shell, inGeorgia, assignCity, median, tariffStats } from './build-pages.mjs';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const SITE = path.join(ROOT, 'site');
const ORIGIN = 'https://geocharge.ge';
const CACHE = path.join(ROOT, 'tools', '.cache', 'chargers.json');
const GIST = 'https://gist.githubusercontent.com/experto44/36f39392ce7a4abe14ab065aa8e846bd/raw/chargers.json';
const FUEL_CACHE = path.join(ROOT, 'tools', '.cache', 'fuel.json');
const FUEL_SRC = 'https://tarifebi.ge/fuel';

// Comparing an EV against petrol is only worth publishing if the petrol side is
// today's price, so it is read at build time from tarifebi.ge, which lists every
// chain. The median of the chains is what goes in the prose: the cheapest
// station in the country is not what an ordinary driver pays.
async function fuelPrices() {
  try {
    const html = await (await fetch(FUEL_SRC)).text();
    const raw = (/var priceData=(\[[\s\S]*?\]);/.exec(html) || [])[1];
    if (!raw) throw new Error('priceData block not found');
    const data = JSON.parse(raw);
    const cat = (c) => {
      const items = (data.find((d) => d.cat === c) || {}).items || [];
      if (!items.length) throw new Error(`no prices for ${c}`);
      return { med: median(items.map((i) => i.price)), n: items.length,
        min: Math.min(...items.map((i) => i.price)), max: Math.max(...items.map((i) => i.price)) };
    };
    const out = { checked: new Date().toISOString().slice(0, 10),
      regular: cat('regular'), premium: cat('premium'), diesel: cat('diesel') };
    await mkdir(path.dirname(FUEL_CACHE), { recursive: true });
    await writeFile(FUEL_CACHE, JSON.stringify(out, null, 1), 'utf8');
    console.log(`· fuel: regular median ${out.regular.med.toFixed(2)} across ${out.regular.n} chains (${out.checked})`);
    return out;
  } catch (e) {
    if (!existsSync(FUEL_CACHE)) throw new Error(`fuel prices unavailable and no cache: ${e.message}`);
    const cached = JSON.parse(await readFile(FUEL_CACHE, 'utf8'));
    console.warn(`  !! fuel prices unavailable (${e.message}), falling back to ${cached.checked}`);
    return cached;
  }
}

// Figures quoted in the prose come from here, so an article cannot drift away
// from the catalogue it links to. Anything stated as a round approximation in
// the text stays approximate; only the exact counts are injected.
async function liveNumbers() {
  let raw;
  if (existsSync(CACHE)) raw = JSON.parse(await readFile(CACHE, 'utf8'));
  else raw = await (await fetch(GIST)).json();
  const ge = raw.filter(inGeorgia);
  const has = (s, c) => (s.connectors || []).includes(c);
  const count = (c) => ge.filter((s) => has(s, c)).length;
  const gbt = ge.filter((s) => has(s, 'GB/T'));
  const usSpec = ge.filter((s) => has(s, 'CCS1') || has(s, 'NACS') || has(s, 'Type 1'));
  const byProv = (list) => {
    const m = {};
    for (const s of list) m[s.provider] = (m[s.provider] || 0) + 1;
    return Object.entries(m).sort((a, b) => b[1] - a[1]);
  };
  const atCity = (name) => ge.filter((s) => {
    const c = assignCity(s);
    return c && c[0] === name;
  });
  const town = (name) => {
    const l = atCity(name);
    return { n: l.length, dc: l.filter((s) => s.type === 'Fast DC').length };
  };
  const tar = tariffStats(ge);
  return {
    total: ge.length,
    dcMed: median(tar.dc), acMed: median(tar.ac),
    dcMin: Math.min(...tar.dc), dcMax: Math.max(...tar.dc),
    acMin: Math.min(...tar.ac),
    ccs2: count('CCS2'), gbt: gbt.length, type2: count('Type 2'),
    chademo: count('CHAdeMO'), type1: count('Type 1'), nacs: count('NACS'), ccs1: count('CCS1'),
    gbtDc: gbt.filter((s) => s.type === 'Fast DC').length,
    gbtAc: gbt.filter((s) => s.type !== 'Fast DC').length,
    gbtWithCcs2: gbt.filter((s) => has(s, 'CCS2')).length,
    usSpec: usSpec.length,
    usTopProvider: byProv(usSpec)[0],
    gudauri: town('Gudauri'), bakuriani: town('Bakuriani'), kazbegi: town('Stepantsminda'),
  };
}

const PROSE = `
.prose{max-width:760px}
.prose p{color:var(--ink-2);font-size:17px;line-height:1.75;margin:0 0 18px;text-wrap:pretty}
.prose h2{font-size:clamp(21px,2.6vw,27px);margin:40px 0 14px}
.prose h3{font-size:19px;font-weight:600;margin:28px 0 10px}
.prose ul{margin:0 0 18px;padding:0;list-style:none;display:grid;gap:12px}
/* NOT display:flex — that turns a leading <strong> into its own flex column and
   strands the rest of the sentence in a second one. Keep the li a block so the
   bold lead-in stays inline, and float the bullet out with absolute positioning. */
.prose li{position:relative;padding-left:20px;color:var(--ink-2);font-size:16.5px;line-height:1.7;text-wrap:pretty}
.prose li::before{content:"";position:absolute;left:0;top:.6em;width:7px;height:7px;border-radius:50%;background:var(--accent)}
.prose strong{color:var(--ink);font-weight:600}
.prose a{color:var(--accent-d);font-weight:500;text-decoration:none}
.prose a:hover{text-decoration:underline}
.key{background:var(--mint);border:1px solid var(--mint-b);border-radius:16px;padding:22px 24px;margin:0 0 28px}
.key p{margin:0;color:#1B5E42;font-size:16.5px;line-height:1.7}
.key p+p{margin-top:10px}
.meta{color:#8B98A1;font-size:13.5px;margin:0 0 28px}
.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(280px,100%),1fr));gap:16px;margin:0}
.acard{display:block;background:#fff;border:1px solid var(--line);border-radius:18px;padding:24px;text-decoration:none}
.acard:hover{border-color:var(--accent);box-shadow:0 12px 32px -18px rgba(23,153,95,.35)}
.acard b{display:block;font-size:17.5px;font-weight:600;color:var(--ink);line-height:1.4;margin-bottom:8px}
.acard span{display:block;color:var(--ink-2);font-size:14.5px;line-height:1.6}
.links{display:flex;flex-wrap:wrap;gap:10px;margin:0}
`.trim();

const buildArticles = (N, F) => [
  {
    slug: 'datenvis-fasi',
    ka: {
      title: 'რამდენი ღირს ელექტრომობილის დატენვა საქართველოში',
      desc: 'სწრაფი დატენვა 0.50-იდან 1.00 ლარამდე ერთ კილოვატსაათზე, ნელი 0.35-იდან. როგორ გამოვთვალოთ ერთი დატენვის ღირებულება.',
      key: [
        'მოკლე პასუხი: სწრაფ DC დამტენზე კილოვატსაათი ჯერჯერობით 0.50-დან 1.00 ლარამდე ჯდება, ყველაზე ხშირად 0.78 ლარი. ნელ AC დამტენზე 0.35-დან 1.25 ლარამდე, ყველაზე ხშირად 0.65 ლარი.',
        'ერთი სრული დატენვა 60 კილოვატსაათიან ბატარეაზე დაახლოებით 30-დან 47 ლარამდე გამოდის.',
      ],
      body: `
<h2>როგორ გამოითვლება</h2>
<p>ფასი მითითებულია ერთ კილოვატსაათზე, ანუ იმ ენერგიაზე, რომელიც ბატარეაში შედის. ფორმულა მარტივია: აიღეთ იმდენი კილოვატსაათი, რამდენიც ბატარეაში უნდა ჩაასხათ, და გაამრავლეთ ტარიფზე.</p>
<p>მაგალითი. თუ თქვენს მანქანას 60 კილოვატსაათიანი ბატარეა აქვს და 20 პროცენტიდან 80 პროცენტამდე ტენით, ბატარეაში 36 კილოვატსაათი შედის. 0.78 ლარიან ტარიფზე ეს 28 ლარია.</p>
<p>ხელით რომ არ ითვალოთ, ეს გამოთვლა <a href="/kalkulatori/">კალკულატორში</a> ორ წამში კეთდება: შეიყვანთ ბატარეის ტევადობას, მუხტის დონეს და ტარიფს.</p>
<p>ამიტომ ერთი და იმავე მანქანის დატენვა სხვადასხვა ფასი ჯდება იმის მიხედვით, რამდენად ცარიელია ბატარეა. სრულიად ცარიელიდან სავსემდე დატენვა თითქმის ორჯერ მეტი ჯდება, ვიდრე ნახევრიდან.</p>

<h2>რატომ განსხვავდება ტარიფები</h2>
<p>სწრაფი დამტენი ძვირია არა იმიტომ, რომ მეტ ენერგიას იძლევა, არამედ იმიტომ, რომ თავად აპარატი და მისი ქსელთან მიერთება რამდენჯერმე ძვირი უჯდება ოპერატორს. სწორედ ამიტომ ღირს DC დატენვა საშუალოდ 0.13 ლარით მეტი, ვიდრე AC.</p>
<p>განსხვავება პროვაიდერებს შორისაც არსებობს. ჩვენ მონაცემებში ყველაზე დაბალი ტარიფები Electrify Georgia-სა და E-Space-ის ნელ დამტენებზეა, ყველაზე მაღალი კი EV Power-ისა და Tegeta-ს ზოგიერთ სადგურზე.</p>
<p>საქართველოს 600-ზე მეტი საჯარო დამტენიდან დაახლოებით 130 საერთოდ არ აქვეყნებს ტარიფს. ეს ჩვეულებრივ სასტუმროების, სავაჭრო ცენტრებისა და რესტორნების დამტენებია, სადაც დატენვა კლიენტისთვის უფასოა ან ადგილზე თანხმდებით.</p>

<h2>რა ჯდება სახლში დატენვა</h2>
<p>სახლის როზეტიდან დატენვისას იხდით მხოლოდ ელექტროენერგიის ჩვეულებრივ ტარიფს, რომელიც საჯარო დამტენზე მითითებულ ფასზე მნიშვნელოვნად დაბალია. ამიტომ ვისაც ეზო ან პარკინგი აქვს, ყოველდღიურ გარბენს სახლში ტენის და საჯარო დამტენს მხოლოდ გზაში იყენებს.</p>
<p>ჩვეულებრივი როზეტი დაახლოებით 2 კილოვატს იძლევა, ანუ 60 კილოვატსაათიანი ბატარეის სავსემდე დატენვას მთელი ღამე და კიდევ ნახევარი დღე დასჭირდება. სახლის კედლის დამტენი 7 კილოვატზე იმავეს 9 საათში აკეთებს.</p>

<h2>რაზე მიაქციოთ ყურადღება</h2>
<ul>
<li><strong>დამტენის სიმძლავრე და მანქანის ლიმიტი.</strong> თუ თქვენი მანქანა მაქსიმუმ 50 კილოვატს იღებს, 160 კილოვატიან დამტენზე მაინც 50-ს მიიღებთ. ფასი კი იგივე დარჩება.</li>
<li><strong>ბატარეის ტემპერატურა.</strong> ცივ ბატარეაზე დატენვა შესამჩნევად ნელა მიდის. ზამთარში დაგეგმეთ მეტი დრო.</li>
<li><strong>80 პროცენტის შემდეგ.</strong> სწრაფი დამტენი 80 პროცენტის მიღწევის შემდეგ მკვეთრად ანელებს. შორ მგზავრობაზე უფრო სწრაფია 80-ზე გაჩერება და მომდევნო დამტენამდე გასვლა.</li>
<li><strong>გაჩერების საფასური.</strong> ზოგი ოპერატორი დატენვის დასრულების შემდეგ დგომას ცალკე ურიცხავს. აპარატს გაათავისუფლეთ.</li>
</ul>

<h2>სად ნახოთ კონკრეტული ფასი</h2>
<p>თითოეული სადგურის მიმდინარე ტარიფი მითითებულია <a href="/damtenebi/">დამტენების სიაში</a>, ქალაქებისა და ქსელების მიხედვით დაჯგუფებული. ფასები ავტომატურად ახლდება უშუალოდ პროვაიდერებისგან.</p>
`,
      faq: [
        ['რამდენი ღირს ელექტრომობილის სრული დატენვა საქართველოში?',
         '60 კილოვატსაათიან ბატარეაზე დაახლოებით 30-დან 47 ლარამდე, დამტენის ტიპისა და პროვაიდერის მიხედვით. სწრაფ DC დამტენზე კილოვატსაათი ხშირად 0.78 ლარია, ნელ AC დამტენზე 0.65.'],
        ['სად არის ყველაზე იაფი დატენვა?',
         'ნელ AC დამტენებზე, სადაც ტარიფი 0.35 ლარიდან იწყება. სახლის როზეტიდან დატენვა კიდევ უფრო იაფია, რადგან იხდით მხოლოდ ჩვეულებრივ ელექტროენერგიის ტარიფს.'],
        ['არის თუ არა უფასო დამტენები საქართველოში?',
         'დიახ. საქართველოს 600-ზე მეტი საჯარო დამტენიდან დაახლოებით 130 ტარიფს არ აქვეყნებს. ეს ძირითადად სასტუმროების, სავაჭრო ცენტრებისა და რესტორნების დამტენებია, სადაც დატენვა კლიენტისთვის უფასოა.'],
      ],
    },
    en: {
      title: 'How much does it cost to charge an EV in Georgia',
      desc: 'Fast charging runs 0.50 to 1.00 GEL per kWh, slow charging from 0.35. How to work out what one charge will cost you.',
      key: [
        'Short answer: a kilowatt hour on a fast DC charger costs 0.50 to 1.00 GEL, most often 0.78. On a slow AC charger it is 0.35 to 1.25 GEL, most often 0.65.',
        'One full charge of a 60 kWh battery works out to roughly 30 to 47 GEL.',
      ],
      body: `
<h2>How it is calculated</h2>
<p>Prices are quoted per kilowatt hour, meaning the energy that goes into the battery. The formula is simple: take the number of kilowatt hours you need to put in and multiply by the tariff.</p>
<p>An example. If your car has a 60 kWh battery and you charge from 20 percent to 80 percent, you are putting in 36 kWh. At 0.78 GEL that is 28 GEL.</p>
<p>If you would rather not do the arithmetic, the <a href="/en/calculator/">calculator</a> does it in two seconds: enter the battery size, the charge levels and the tariff.</p>
<p>So the same car costs different amounts depending on how empty the battery is. Charging from empty to full costs almost twice what charging from half costs.</p>

<h2>Why tariffs differ</h2>
<p>Fast chargers are expensive not because they deliver more energy, but because the hardware and the grid connection cost the operator several times more. That is why DC charging averages about 0.13 GEL more per kilowatt hour than AC.</p>
<p>There is variation between providers too. In our data the lowest tariffs sit on Electrify Georgia and E-Space slow chargers, the highest on some EV Power and Tegeta stations.</p>
<p>Of Georgia's 600 plus public chargers, roughly 130 publish no tariff at all. These are typically at hotels, shopping centres and restaurants, where charging is free for customers or arranged on the spot.</p>

<h2>What home charging costs</h2>
<p>Charging from a socket at home means you pay only the normal domestic electricity rate, which is well below any public charger tariff. Drivers with a yard or a parking space charge at home for daily driving and use public chargers only on trips.</p>
<p>An ordinary socket delivers about 2 kW, so filling a 60 kWh battery takes all night and half the next day. A 7 kW home wallbox does the same in about 9 hours.</p>

<h2>What to watch for</h2>
<ul>
<li><strong>Charger power versus your car's limit.</strong> If your car accepts 50 kW maximum, a 160 kW charger still gives you 50. The price stays the same.</li>
<li><strong>Battery temperature.</strong> A cold battery charges noticeably slower. Allow more time in winter.</li>
<li><strong>Past 80 percent.</strong> Fast chargers slow down sharply above 80 percent. On a long trip it is quicker to stop at 80 and drive on to the next charger.</li>
<li><strong>Idle fees.</strong> Some operators charge for occupying the bay after charging finishes. Move the car.</li>
</ul>

<h2>Where to check a specific price</h2>
<p>The current tariff for every station is listed in the <a href="/en/chargers/">charger list</a>, grouped by city and by network. Prices update automatically, straight from the providers.</p>
`,
      faq: [
        ['How much does a full EV charge cost in Georgia?',
         'Roughly 30 to 47 GEL for a 60 kWh battery, depending on charger type and provider. On a fast DC charger a kilowatt hour is often 0.78 GEL, on a slow AC charger 0.65.'],
        ['Where is charging cheapest?',
         'On slow AC chargers, where tariffs start at 0.35 GEL per kWh. Charging at home is cheaper still, since you pay only the normal domestic electricity rate.'],
        ['Are there free chargers in Georgia?',
         'Yes. Of the 600 plus public chargers in Georgia, about 130 publish no tariff. Most are at hotels, shopping centres and restaurants, where charging is free for customers.'],
      ],
    },
  },

  {
    slug: 'konektorebi',
    ka: {
      title: 'CCS2, GB/T, Type 2: რომელი კონექტორი გჭირდებათ საქართველოში',
      metaTitle: 'რომელი კონექტორი გჭირდებათ: CCS2, GB/T თუ Type 2',
      desc: 'საქართველოში ყველაზე გავრცელებული კონექტორებია CCS2 და GB/T. რომელი შეესაბამება თქვენს მანქანას და რამდენი ასეთი დამტენია ქვეყანაში.',
      key: [
        'საქართველოში ორი კონექტორი დომინირებს: CCS2 დაახლოებით 370 სადგურზეა, GB/T დაახლოებით 350-ზე. ნელი დატენვისთვის Type 2 ყველაზე გავრცელებულია.',
        'თუ ევროპული მანქანა გყავთ, გჭირდებათ CCS2. თუ ჩინური, GB/T. თუ ამერიკიდან ჩამოყვანილი, შეამოწმეთ CCS1 ან NACS.',
      ],
      body: `
<h2>რა კონექტორები არსებობს საქართველოში</h2>
<p>საქართველოს დამტენებზე შვიდი სხვადასხვა კონექტორი გვხვდება, მაგრამ პრაქტიკულად სამი განსაზღვრავს ყველაფერს.</p>
<ul>
<li><strong>CCS2</strong> დაახლოებით 370 სადგურზე. ევროპული სტანდარტი სწრაფი დატენვისთვის. Volkswagen, BMW, Mercedes, Audi, Porsche, ევროპული Tesla და ევროპისთვის აწყობილი Hyundai და Kia.</li>
<li><strong>GB/T</strong> დაახლოებით 350 სადგურზე. ჩინური სტანდარტი. BYD, Zeekr, Li Auto, NIO, Xpeng და ჩინეთიდან ჩამოყვანილი ყველა სხვა მანქანა.</li>
<li><strong>Type 2</strong> დაახლოებით 240 სადგურზე. ნელი AC დატენვის ევროპული სტანდარტი. თითქმის ყველა თანამედროვე ელექტრომობილს აქვს.</li>
<li><strong>CHAdeMO</strong> მხოლოდ 19 სადგურზე. ძველი იაპონური სტანდარტი, ძირითადად Nissan Leaf-ისთვის.</li>
<li><strong>Type 1</strong> 18 სადგურზე. ამერიკული ნელი დატენვის ძველი სტანდარტი.</li>
<li><strong>NACS</strong> 9 სადგურზე. Tesla-ს ამერიკული კონექტორი.</li>
<li><strong>CCS1</strong> მხოლოდ 2 სადგურზე. ამერიკული სწრაფი დატენვა.</li>
</ul>

<h2>რატომ არის საქართველოში GB/T ასე ბევრი</h2>
<p>ევროპაში GB/T პრაქტიკულად არ არსებობს. საქართველოში კი თითქმის იმდენივეა, რამდენიც CCS2. მიზეზი მარტივია: ქართული ბაზრის დიდი ნაწილი ჩინეთიდან შემოტანილი მანქანებია, და დამტენების ოპერატორებმა ამას მოარგეს ინფრასტრუქტურა.</p>
<p>პრაქტიკაში ეს კარგი ამბავია. საქართველოში სწრაფი დამტენების უმეტესობა ორივე კონექტორს ატარებს, ანუ ერთ აპარატზე CCS2-იც არის და GB/T-იც. ჩვენ მონაცემებში ასეთი წყვილი ყველაზე ხშირად გვხვდება.</p>

<h2>თუ ამერიკიდან ჩამოყვანილი მანქანა გყავთ</h2>
<p>ეს არის ერთადერთი შემთხვევა, სადაც სერიოზული სიფრთხილეა საჭირო. ამერიკული სპეციფიკაციის მანქანებს CCS1 ან NACS აქვთ, და საქართველოში ასეთი დამტენი სულ თითქმის თერთმეტია.</p>
<p>გამოსავალი ორია. ან ადაპტერი, რომელიც CCS1-ს CCS2-ზე გადაიყვანს, ან ნელი დატენვა Type 1 კონექტორით. ორივე შემთხვევაში დაგეგმვა უფრო მეტად დაგჭირდებათ, ვიდრე ევროპული მანქანის მფლობელს.</p>

<h2>Nissan Leaf და CHAdeMO</h2>
<p>თუ Leaf გყავთ, გაითვალისწინეთ: მთელ საქართველოში CHAdeMO სულ 19 სადგურზეა და მათი უმეტესობა თბილისშია. რეგიონებში მგზავრობისას მარშრუტი წინასწარ უნდა შეამოწმოთ.</p>

<h2>როგორ შეამოწმოთ, რომელი გჭირდებათ</h2>
<p>უმარტივესი გზაა მანქანის დატენვის სარქველის გახსნა და კონექტორის ფორმის შედარება. CCS2-ს ორი დიდი ხვრელი აქვს ქვემოთ, GB/T კი მრგვალია და შვიდი ხვრელი აქვს. თუ ეჭვი გაქვთ, მანქანის სახელმძღვანელოში წერია.</p>
<p><a href="/damtenebi/">დამტენების სიაში</a> თითოეულ სადგურთან მითითებულია, რომელი კონექტორები აქვს, ხოლო აპლიკაციაში კონექტორის მიხედვით გაფილტვრაც შეგიძლიათ.</p>
`,
      faq: [
        ['რომელი კონექტორია ყველაზე გავრცელებული საქართველოში?',
         'CCS2 დაახლოებით 370 სადგურზე და GB/T დაახლოებით 350-ზე. სწრაფი დამტენების უმეტესობა ორივეს ატარებს ერთდროულად.'],
        ['ჩინური ელექტრომობილი მყავს, დამტენს ვიპოვი საქართველოში?',
         'დიახ. GB/T კონექტორი საქართველოში დაახლოებით 350 სადგურზეა, ანუ თითქმის იმდენივე, რამდენიც ევროპული CCS2.'],
        ['ამერიკული ელექტრომობილისთვის რა კონექტორი მჭირდება?',
         'CCS1 ან NACS, და საქართველოში ასეთი დამტენი სულ თერთმეტია. საჭირო იქნება ადაპტერი CCS2-ზე ან ნელი დატენვა Type 1 კონექტორით.'],
      ],
    },
    en: {
      title: 'CCS2, GB/T, Type 2: which connector do you need in Georgia',
      metaTitle: 'Which EV connector do you need in Georgia',
      desc: 'CCS2 and GB/T dominate Georgian charging. Which one matches your car, and how many stations of each exist in the country.',
      key: [
        'Two connectors dominate in Georgia: CCS2 on roughly 370 stations, GB/T on roughly 350. For slow charging, Type 2 is the most common.',
        'European car means CCS2. Chinese car means GB/T. Car imported from the US means checking for CCS1 or NACS.',
      ],
      body: `
<h2>Which connectors exist in Georgia</h2>
<p>Seven different connectors appear on Georgian chargers, but in practice three decide everything.</p>
<ul>
<li><strong>CCS2</strong> on roughly 370 stations. The European fast charging standard. Volkswagen, BMW, Mercedes, Audi, Porsche, European Tesla, and Hyundai and Kia built for Europe.</li>
<li><strong>GB/T</strong> on roughly 350 stations. The Chinese standard. BYD, Zeekr, Li Auto, NIO, Xpeng and everything else imported from China.</li>
<li><strong>Type 2</strong> on roughly 240 stations. The European standard for slow AC charging. Almost every modern EV has it.</li>
<li><strong>CHAdeMO</strong> on just 19 stations. The older Japanese standard, mainly for the Nissan Leaf.</li>
<li><strong>Type 1</strong> on 18 stations. The older American slow charging standard.</li>
<li><strong>NACS</strong> on 9 stations. Tesla's American connector.</li>
<li><strong>CCS1</strong> on only 2 stations. American fast charging.</li>
</ul>

<h2>Why Georgia has so much GB/T</h2>
<p>GB/T barely exists in Europe. In Georgia there is almost as much of it as CCS2. The reason is straightforward: a large share of the Georgian market is cars imported from China, and charger operators built for that.</p>
<p>In practice this is good news. Most fast chargers in Georgia carry both connectors, meaning one cabinet has a CCS2 gun and a GB/T gun. That pairing is the most common setup in our data.</p>

<h2>If your car came from the US</h2>
<p>This is the one case that needs real care. US specification cars use CCS1 or NACS, and Georgia has about eleven such chargers in total.</p>
<p>There are two ways round it. Either an adapter that converts CCS1 to CCS2, or slow charging with a Type 1 connector. Either way you will plan more than a European car owner does.</p>

<h2>Nissan Leaf and CHAdeMO</h2>
<p>If you drive a Leaf, note this: there are 19 CHAdeMO stations in all of Georgia and most are in Tbilisi. Check your route before driving to the regions.</p>

<h2>How to check which you need</h2>
<p>The simplest way is to open the charging flap and compare the shape. CCS2 has two large holes underneath the main ring, GB/T is round with seven holes. If in doubt, the car's manual states it.</p>
<p>The <a href="/en/chargers/">charger list</a> shows the connectors at every station, and the app lets you filter the map by connector type.</p>
`,
      faq: [
        ['Which connector is most common in Georgia?',
         'CCS2 on roughly 370 stations and GB/T on roughly 350. Most fast chargers carry both at once.'],
        ['I drive a Chinese EV, will I find chargers in Georgia?',
         'Yes. The GB/T connector is on roughly 350 stations in Georgia, almost as many as European CCS2.'],
        ['What connector do I need for an American EV?',
         'CCS1 or NACS, and Georgia has about eleven such chargers in total. You will need an adapter to CCS2, or slow charging with a Type 1 connector.'],
      ],
    },
  },

  {
    slug: 'ac-da-dc',
    ka: {
      title: 'AC თუ DC: რით განსხვავდება ნელი და სწრაფი დატენვა',
      desc: 'საქართველოს 600-ზე მეტი დამტენიდან დაახლოებით 390 სწრაფი DC-ა, 220 კი ნელი AC. რომელი როდის გამოვიყენოთ.',
      key: [
        'DC დამტენი ბატარეას პირდაპირ ტენის და 20 წუთში აკეთებს იმას, რასაც AC რამდენიმე საათში.',
        'საქართველოში დაახლოებით 390 სწრაფი DC დამტენია და 220 ნელი AC. სწრაფი გზისთვისაა, ნელი გაჩერებისთვის.',
      ],
      body: `
<h2>განსხვავება ერთი წინადადებით</h2>
<p>ყველა ბატარეა მუდმივი დენით ივსება. კითხვა მხოლოდ ისაა, სად ხდება ცვლადი დენის მუდმივად გადაქცევა. AC დამტენზე ამას მანქანის შიგნით მყოფი პატარა გარდამქმნელი აკეთებს, და სწორედ ის ზღუდავს სიჩქარეს. DC დამტენზე გარდაქმნა თავად აპარატში ხდება, რომელიც გაცილებით დიდი და მძლავრია.</p>

<h2>რამდენად სწრაფია თითოეული</h2>
<p>საქართველოში AC დამტენები ძირითადად 7-დან 22 კილოვატამდეა. DC დამტენები 30-დან 360 კილოვატამდე, თუმცა უმეტესობა 120 კილოვატის ფარგლებშია.</p>
<p>60 კილოვატსაათიანი ბატარეისთვის ეს ასე გამოიყურება:</p>
<ul>
<li><strong>სახლის როზეტი, 2 კილოვატი.</strong> 20-დან 80 პროცენტამდე დაახლოებით 18 საათი.</li>
<li><strong>AC დამტენი, 7 კილოვატი.</strong> იგივე დაახლოებით 5 საათი.</li>
<li><strong>AC დამტენი, 22 კილოვატი.</strong> დაახლოებით 1 საათი და 40 წუთი, თუ მანქანა 22 კილოვატს იღებს.</li>
<li><strong>DC დამტენი, 60 კილოვატი.</strong> დაახლოებით 40 წუთი.</li>
<li><strong>DC დამტენი, 150 კილოვატი.</strong> დაახლოებით 20 წუთი.</li>
</ul>
<p>ეს სავარაუდო ციფრებია. რეალური დრო დამოკიდებულია იმაზე, რამდენ სიმძლავრეს იღებს თავად მანქანა, რა ტემპერატურაა ბატარეას და რამდენად სავსეა ის უკვე.</p>

<h2>მთავარი ხაფანგი: მანქანის ლიმიტი</h2>
<p>დამტენის სიმძლავრე ჭერია, არა გარანტია. თუ თქვენი მანქანა AC-ზე მაქსიმუმ 7 კილოვატს იღებს, 22 კილოვატიან დამტენზეც 7-ს მიიღებთ. იგივე DC-ზე: 50 კილოვატის ლიმიტის მქონე მანქანა 160 კილოვატიან აპარატზეც 50-ს აიღებს.</p>
<p>ამიტომ ყველაზე მძლავრი დამტენის ძებნას აზრი აქვს მხოლოდ მაშინ, თუ მანქანაც შესაბამისია.</p>

<h2>რომელი როდის</h2>
<ul>
<li><strong>ნელი AC.</strong> როცა მანქანა მაინც დგას: სახლში ღამით, სამსახურში დღის განმავლობაში, სასტუმროში. იაფია და ბატარეისთვისაც უკეთესია.</li>
<li><strong>სწრაფი DC.</strong> გზაში, როცა დრო გიწევთ. თბილისიდან ბათუმში მიმავალს ერთი გაჩერება სწრაფ დამტენზე ეყოფა.</li>
</ul>

<h2>რატომ ანელებს 80 პროცენტის შემდეგ</h2>
<p>ეს არ არის დამტენის ბრალი. ბატარეა თავად ითხოვს სიმძლავრის შემცირებას, როცა ივსება, რომ არ დაზიანდეს. 80-დან 100 პროცენტამდე ხშირად იმდენივე დრო სჭირდება, რამდენიც 20-დან 80-მდე.</p>
<p>შორ გზაზე ამიტომ უფრო ეფექტურია 80 პროცენტზე გაჩერება და მომდევნო დამტენამდე გასვლა, ვიდრე სრულამდე ლოდინი.</p>
<p>რომელი სადგური რა ტიპისაა, მითითებულია <a href="/damtenebi/">დამტენების სიაში</a>.</p>
`,
      faq: [
        ['რა განსხვავებაა AC და DC დატენვას შორის?',
         'AC დამტენზე ცვლადი დენი მუდმივად მანქანის შიგნით გარდაიქმნება და სწორედ ეს ზღუდავს სიჩქარეს. DC დამტენზე გარდაქმნა თავად აპარატში ხდება, ამიტომ ის ბევრად სწრაფია.'],
        ['რამდენ ხანში იტენება ელექტრომობილი?',
         '60 კილოვატსაათიანი ბატარეა 20-დან 80 პროცენტამდე სწრაფ 150 კილოვატიან DC დამტენზე დაახლოებით 20 წუთში იტენება, 7 კილოვატიან AC დამტენზე კი დაახლოებით 5 საათში.'],
        ['რამდენი სწრაფი დამტენია საქართველოში?',
         'დაახლოებით 390 სწრაფი DC დამტენი და 220 ნელი AC დამტენი, სულ 600-ზე მეტი საჯარო სადგური.'],
      ],
    },
    en: {
      title: 'AC or DC: what actually separates slow and fast charging',
      metaTitle: 'AC or DC: slow versus fast charging explained',
      desc: 'Of Georgia’s 600 plus chargers, roughly 390 are fast DC and 220 are slow AC. When to use which, and how long each takes.',
      key: [
        'A DC charger feeds the battery directly and does in 20 minutes what AC takes several hours to do.',
        'Georgia has roughly 390 fast DC chargers and 220 slow AC ones. Fast is for the road, slow is for wherever you were parked anyway.',
      ],
      body: `
<h2>The difference in one sentence</h2>
<p>Every battery charges on direct current. The only question is where alternating current gets converted. On an AC charger a small converter inside the car does it, and that converter is the bottleneck. On a DC charger the conversion happens in the cabinet itself, which is far larger and more powerful.</p>

<h2>How fast each one is</h2>
<p>AC chargers in Georgia are mostly 7 to 22 kW. DC chargers run from 30 to 360 kW, though most sit around 120 kW.</p>
<p>For a 60 kWh battery that looks like this:</p>
<ul>
<li><strong>Household socket, 2 kW.</strong> 20 to 80 percent takes about 18 hours.</li>
<li><strong>AC charger, 7 kW.</strong> The same takes about 5 hours.</li>
<li><strong>AC charger, 22 kW.</strong> About 1 hour 40 minutes, if the car accepts 22 kW.</li>
<li><strong>DC charger, 60 kW.</strong> About 40 minutes.</li>
<li><strong>DC charger, 150 kW.</strong> About 20 minutes.</li>
</ul>
<p>These are estimates. Real times depend on how much power the car itself accepts, the battery temperature, and how full it already is.</p>

<h2>The main trap: your car's own limit</h2>
<p>Charger power is a ceiling, not a promise. If your car accepts 7 kW on AC, a 22 kW charger still gives you 7. Same on DC: a car limited to 50 kW draws 50 from a 160 kW cabinet.</p>
<p>So hunting for the most powerful charger only pays off if the car can use it.</p>

<h2>Which one when</h2>
<ul>
<li><strong>Slow AC.</strong> Whenever the car is parked anyway: overnight at home, all day at work, at a hotel. Cheaper, and gentler on the battery.</li>
<li><strong>Fast DC.</strong> On the road, when time matters. Tbilisi to Batumi needs one stop at a fast charger.</li>
</ul>

<h2>Why it slows down past 80 percent</h2>
<p>This is not the charger's doing. The battery itself demands lower power as it fills, to avoid damage. Going from 80 to 100 percent often takes as long as going from 20 to 80.</p>
<p>On a long drive it is therefore quicker to stop at 80 percent and continue to the next charger than to wait for full.</p>
<p>Which type each station is, is listed in the <a href="/en/chargers/">charger list</a>.</p>
`,
      faq: [
        ['What is the difference between AC and DC charging?',
         'On an AC charger, alternating current is converted to direct current inside the car, and that converter limits the speed. On a DC charger the conversion happens in the cabinet, which is why it is much faster.'],
        ['How long does it take to charge an EV?',
         'A 60 kWh battery goes from 20 to 80 percent in about 20 minutes on a 150 kW DC charger, or about 5 hours on a 7 kW AC charger.'],
        ['How many fast chargers are there in Georgia?',
         'Roughly 390 fast DC chargers and 220 slow AC ones, out of more than 600 public stations.'],
      ],
    },
  },

  {
    slug: 'shori-mgzavroba',
    ka: {
      title: 'შორი მგზავრობა ელექტრომობილით საქართველოში: პრაქტიკული გზამკვლევი',
      metaTitle: 'შორი მგზავრობა ელექტრომობილით საქართველოში',
      desc: 'თბილისიდან ბათუმამდე ერთი გაჩერება საკმარისია. სად არის დამტენები მთავარ მარშრუტებზე და როგორ დავგეგმოთ გზა.',
      key: [
        'თბილისი და ბათუმი დაახლოებით 370 კილომეტრით არის დაშორებული. თანამედროვე ელექტრომობილს გზაზე ერთი გაჩერება სჭირდება.',
        'მთავარი მაგისტრალი კარგად არის დაფარული. თერჯოლის მიდამოებში 18 დამტენია, აქედან 17 სწრაფი.',
      ],
      body: `
<h2>დაფარვა მთავარ მიმართულებებზე</h2>
<p>ყველაზე ხშირი კითხვა ისაა, გავივლი თუ არა თბილისიდან ბათუმამდე. პასუხი დიახ, და ერთი გაჩერებით.</p>
<p>თბილისიდან დასავლეთისკენ მიმავალ გზაზე დამტენები კონცენტრირებულია რამდენიმე კვანძში. ჩვენ მონაცემებში:</p>
<ul>
<li><strong>თერჯოლა და რიკოთის მიდამოები.</strong> 18 სადგური, აქედან 17 სწრაფი DC. ეს არის მთავარი გამზიდი წერტილი დასავლეთის მიმართულებაზე.</li>
<li><strong>გორი.</strong> 17 სადგური, 14 სწრაფი. თბილისიდან პირველი სერიოზული კვანძი.</li>
<li><strong>ქუთაისი.</strong> 12 სადგური, 9 სწრაფი.</li>
<li><strong>სამტრედია.</strong> 9 სადგური, 6 სწრაფი.</li>
<li><strong>ბათუმი.</strong> 25 სადგური, 17 სწრაფი, 9 სხვადასხვა ქსელი.</li>
</ul>
<p>მთიან მიმართულებაზეც არის დაფარვა. გუდაურში 7 სადგურია, ბაკურიანში 6, ბორჯომში 5. კახეთში თელავს 7 აქვს, ყვარელს 3.</p>

<h2>როგორ დავგეგმოთ</h2>
<h3>დაითვალეთ რეალური მანძილი, არა კატალოგის</h3>
<p>ქარხნული გარბენი იზომება იდეალურ პირობებში. მაგისტრალზე 110 კილომეტრი საათში, ჩართული კონდიციონერით, გზა აღმართში: რეალური გარბენი დეკლარირებულის 70 პროცენტამდე ეცემა. დაგეგმვისას სწორედ ამ ციფრს დაეყრდენით.</p>

<h3>ზამთარში მეტი მარაგი დატოვეთ</h3>
<p>ცივ ამინდში ბატარეა ნაკლებ ენერგიას იძლევა და ნელა იტენება. ზამთარში იმავე მარშრუტს შეიძლება ერთი დამატებითი გაჩერება დასჭირდეს. გუდაურის მიმართულებაზე ეს განსაკუთრებით მნიშვნელოვანია.</p>

<h3>ნუ დაეყრდნობით ერთ დამტენს</h3>
<p>ეს არის ყველაზე ხშირი შეცდომა. დაგეგმეთ ისე, რომ თქვენს სამიზნე დამტენამდე მისვლისას ბატარეაში იმდენი დარჩეს, რომ მომდევნო წერტილამდე მაინც მიხვიდეთ. აპარატი შეიძლება დაკავებული აღმოჩნდეს ან არ მუშაობდეს.</p>

<h3>გაჩერეთ 20-დან 80 პროცენტამდე</h3>
<p>ეს არის ყველაზე სწრაფი დიაპაზონი. სრულამდე დატენვის ლოდინი დროის კარგვაა, თუ გზაზე კიდევ ერთი დამტენია.</p>

<h2>ტიპური მარშრუტი: თბილისი და ბათუმი</h2>
<p>სავსე ბატარეით თბილისიდან გასვლა, ერთი გაჩერება თერჯოლის ან ქუთაისის მიდამოებში სწრაფ დამტენზე დაახლოებით 25 წუთით, და ბათუმში ჩასვლა მარაგით. თუ მანქანის რეალური გარბენი 250 კილომეტრზე ნაკლებია, დაგეგმეთ ორი გაჩერება: გორი და შემდეგ ქუთაისი.</p>

<h2>რა უნდა გქონდეთ თან</h2>
<ul>
<li>Type 2 კაბელი. ბევრი AC დამტენი კაბელის გარეშეა და საკუთარი მოგაქვთ.</li>
<li>ადაპტერი, თუ ამერიკული სპეციფიკაციის მანქანა გყავთ.</li>
<li>რამდენიმე პროვაიდერის აპლიკაცია ან ბარათი, თუ კონკრეტული ქსელი გჭირდებათ.</li>
</ul>
<p>მარშრუტის დაგეგმვა დატენვის გაჩერებებით GeoCharge-ის აპლიკაციაშია, სადაც ცოცხალი სტატუსიც ჩანს. სადგურების სრული სია ქალაქების მიხედვით <a href="/damtenebi/">აქ არის</a>.</p>
`,
      faq: [
        ['შემიძლია თბილისიდან ბათუმში ელექტრომობილით?',
         'დიახ. დაახლოებით 370 კილომეტრია და თანამედროვე ელექტრომობილს ერთი გაჩერება სჭირდება, ჩვეულებრივ თერჯოლის ან ქუთაისის მიდამოებში.'],
        ['სად არის დამტენები თბილისი ბათუმის მაგისტრალზე?',
         'მთავარი კვანძებია გორი 17 სადგურით, თერჯოლისა და რიკოთის მიდამოები 18 სადგურით, ქუთაისი 12-ით და სამტრედია 9-ით.'],
        ['რამდენად მცირდება გარბენი ზამთარში?',
         'ცივ ამინდში ბატარეა ნაკლებ ენერგიას იძლევა და გარბენი შესამჩნევად ეცემა. იმავე მარშრუტს ზამთარში შეიძლება ერთი დამატებითი გაჩერება დასჭირდეს.'],
      ],
    },
    en: {
      title: 'Driving long distance in Georgia by EV: a practical guide',
      metaTitle: 'Long distance EV driving in Georgia',
      desc: 'Tbilisi to Batumi needs one stop. Where the chargers are on the main routes, and how to plan the drive.',
      key: [
        'Tbilisi and Batumi are about 370 km apart. A modern EV needs one stop on the way.',
        'The main highway is well covered. The Terjola area alone has 18 chargers, 17 of them fast.',
      ],
      body: `
<h2>Coverage on the main routes</h2>
<p>The most common question is whether you can make Tbilisi to Batumi. You can, with one stop.</p>
<p>Heading west from Tbilisi, chargers cluster at a few hubs. From our data:</p>
<ul>
<li><strong>Terjola and the Rikoti area.</strong> 18 stations, 17 of them fast DC. This is the main relay point on the western route.</li>
<li><strong>Gori.</strong> 17 stations, 14 fast. The first serious hub out of Tbilisi.</li>
<li><strong>Kutaisi.</strong> 12 stations, 9 fast.</li>
<li><strong>Samtredia.</strong> 9 stations, 6 fast.</li>
<li><strong>Batumi.</strong> 25 stations, 17 fast, across 9 different networks.</li>
</ul>
<p>The mountain routes are covered too. Gudauri has 7 stations, Bakuriani 6, Borjomi 5. In Kakheti, Telavi has 7 and Kvareli 3.</p>

<h2>How to plan</h2>
<h3>Use real range, not the brochure figure</h3>
<p>Rated range is measured in ideal conditions. At 110 km/h on the highway, with air conditioning on and climbing: real range drops to about 70 percent of the rated figure. Plan against that number.</p>

<h3>Leave more margin in winter</h3>
<p>In cold weather the battery delivers less and charges slower. The same route may need one extra stop in winter. On the Gudauri route this matters most.</p>

<h3>Do not bet on a single charger</h3>
<p>This is the most common mistake. Plan so that when you reach your target charger you still have enough to get to the next one. The unit may be occupied or out of service.</p>

<h3>Stop between 20 and 80 percent</h3>
<p>That is the fastest window. Waiting for a full battery wastes time if there is another charger further along.</p>

<h2>A typical run: Tbilisi to Batumi</h2>
<p>Leave Tbilisi full, stop once near Terjola or Kutaisi at a fast charger for about 25 minutes, arrive in Batumi with margin. If your car's real range is under 250 km, plan two stops: Gori, then Kutaisi.</p>

<h2>What to carry</h2>
<ul>
<li>A Type 2 cable. Many AC chargers have no attached cable and expect you to bring your own.</li>
<li>An adapter, if your car is US specification.</li>
<li>Apps or cards for a few providers, if you need a specific network.</li>
</ul>
<p>Route planning with charging stops is in the GeoCharge app, which also shows live availability. The full station list by city is <a href="/en/chargers/">here</a>.</p>
`,
      faq: [
        ['Can I drive from Tbilisi to Batumi in an EV?',
         'Yes. It is about 370 km and a modern EV needs one stop, usually near Terjola or Kutaisi.'],
        ['Where are the chargers on the Tbilisi to Batumi highway?',
         'The main hubs are Gori with 17 stations, the Terjola and Rikoti area with 18, Kutaisi with 12 and Samtredia with 9.'],
        ['How much range do you lose in winter?',
         'In cold weather the battery delivers less energy and range drops noticeably. The same route can need one extra stop in winter.'],
      ],
    },
  },

  {
    slug: 'amerikuli-importi',
    ka: {
      title: 'ამერიკიდან ჩამოყვანილი ელექტრომობილი: სად დატენავთ საქართველოში',
      metaTitle: 'ამერიკული ელექტრომობილი საქართველოში: დატენვა',
      desc: `ამერიკული სპეციფიკაციის მანქანას CCS1, NACS ან Type 1 აქვს. საქართველოში ასეთი დამტენი სულ ${N.usSpec}-ია. რა ვქნათ ადაპტერით და რა შევამოწმოთ ყიდვამდე.`,
      key: [
        `ამერიკული სპეციფიკაციის ელექტრომობილს ევროპულისგან განსხვავებული კონექტორი აქვს. საქართველოში CCS1 მხოლოდ ${N.ccs1} სადგურზეა, NACS ${N.nacs}-ზე, Type 1 კი ${N.type1}-ზე. შედარებისთვის, ევროპული CCS2 ${N.ccs2} სადგურზეა.`,
        `უფრო მნიშვნელოვანი: ამ დამტენების უმეტესობა ერთ ქსელს ეკუთვნის, ${N.usTopProvider[0]}-ს. ანუ პრაქტიკულად ერთ ოპერატორზე ხართ დამოკიდებული.`,
      ],
      body: `
<h2>ვის ეხება ეს</h2>
<p>საქართველოში ბევრი ელექტრომობილი ამერიკული აუქციონებიდან შემოდის. ამერიკული ბაზრისთვის აწყობილ მანქანას კი სხვა შტეფსელი აქვს, ვიდრე ევროპულს. ეს არ არის მცირე დეტალი, ეს განსაზღვრავს, საერთოდ დატენავთ თუ არა მანქანას.</p>
<p>ყველაზე ხშირად შემდეგი მოდელები გვხვდება:</p>
<ul>
<li><strong>Tesla Model 3 და Model Y ამერიკული ბაზრიდან.</strong> NACS კონექტორი, რომელსაც Tesla-ს საკუთარ სტანდარტს ეძახიან.</li>
<li><strong>Chevrolet Bolt, Ford Mustang Mach-E, Volkswagen ID.4 ამერიკული ვერსია.</strong> CCS1 სწრაფი დატენვისთვის და Type 1 ნელისთვის.</li>
<li><strong>Nissan Leaf ამერიკული ვერსია.</strong> CHAdeMO სწრაფი დატენვისთვის, Type 1 ნელისთვის.</li>
</ul>

<h2>რეალური ციფრები საქართველოში</h2>
<p>ქვემოთ იმდენი სადგურია, რამდენზეც შესაბამისი კონექტორი ფიზიკურად არსებობს:</p>
<ul>
<li><strong>CCS1:</strong> ${N.ccs1} სადგური მთელ ქვეყანაში.</li>
<li><strong>NACS:</strong> ${N.nacs} სადგური.</li>
<li><strong>Type 1:</strong> ${N.type1} სადგური, ნელი AC დატენვისთვის.</li>
<li><strong>CHAdeMO:</strong> ${N.chademo} სადგური.</li>
</ul>
<p>ჯამში ${N.usSpec} სადგური, საქართველოს ${N.total} საჯარო დამტენიდან. ევროპული CCS2 კი ${N.ccs2}-ზეა.</p>

<h2>მთავარი, რაც უნდა იცოდეთ</h2>
<p>ეს დამტენები თანაბრად არ არის გადანაწილებული ოპერატორებს შორის. Type 1 კონექტორის ყველა სადგური და NACS-ის დიდი ნაწილი ${N.usTopProvider[0]}-ს ეკუთვნის.</p>
<p>ეს ნიშნავს, რომ ამერიკული მანქანით საქართველოში პრაქტიკულად ერთი ქსელის კლიენტი ხდებით. თუ იმ ქსელს რომელიმე ქალაქში დამტენი არ აქვს, ალტერნატივა არ გრჩებათ.</p>

<h2>ადაპტერი: რა მუშაობს და რა არა</h2>
<h3>ნელი AC დატენვა</h3>
<p>Type 1 კონექტორიდან Type 2-ზე ადაპტერი მარტივია, იაფია და საიმედოდ მუშაობს. AC დატენვისას მანქანასა და დამტენს შორის რთული მოლაპარაკება არ ხდება, ამიტომ ფიზიკური გადაყვანა საკმარისია. ასეთი ადაპტერით ქვეყნის ყველა Type 2 სადგური გეხსნებათ, რომელიც ${N.type2} სადგურზეა.</p>
<p>პრაქტიკულად ეს ყველაზე მარტივი გამოსავალია და ღირს ყიდვამდე გათვალისწინება.</p>
<h3>სწრაფი DC დატენვა</h3>
<p>აქ სიტუაცია სხვაა. სწრაფი დატენვისას მანქანა და დამტენი ერთმანეთს პროტოკოლით ესაუბრებიან და ადაპტერმა ეს კომუნიკაციაც უნდა გაატაროს. CCS1-დან CCS2-ზე ადაპტერები არსებობს, მაგრამ ძვირია, ყველა მანქანა არ უჭერს მხარს და მწარმოებლები ხშირად არ იძლევიან გარანტიას.</p>
<p>Tesla-ს NACS-იდან CCS2-ზე ადაპტერი უფრო ხელმისაწვდომია, თუმცა აქაც კონკრეტული მოდელისა და პროგრამული ვერსიის შემოწმებაა საჭირო.</p>
<p>ამიტომ ადაპტერზე დაყრდნობა სწრაფი დატენვისთვის რისკია. ჯერ დარწმუნდით, რომ კონკრეტულ მოდელზე მუშაობს, მერე იყიდეთ.</p>

<h2>პრაქტიკული სტრატეგია</h2>
<p>თუ ამერიკული მანქანა უკვე გყავთ ან აპირებთ ყიდვას, რეალისტური გეგმა ასეთია.</p>
<ul>
<li><strong>სახლის დატენვა აუცილებელი ხდება, არა სასურველი.</strong> ევროპული მანქანის მფლობელს საჯარო ქსელი აქვს სარეზერვოდ, თქვენ ის თითქმის არ გაქვთ.</li>
<li><strong>Type 1 ადაპტერი იყიდეთ პირველივე დღეს.</strong> ის ნელი დატენვის პრობლემას მთლიანად ხსნის.</li>
<li><strong>შორი მგზავრობა წინასწარ დაგეგმეთ.</strong> სწრაფი დამტენი, რომელიც თქვენ გამოგადგებათ, თითებზე ჩამოსათვლელია.</li>
<li><strong>გაითვალისწინეთ გადაყიდვის ფასი.</strong> ქართულ ბაზარზე ევროპული სპეციფიკაციის მანქანა უფრო ადვილად იყიდება, სწორედ ამ მიზეზით.</li>
</ul>

<h2>რა შეამოწმოთ ყიდვამდე</h2>
<ul>
<li>რომელი ბაზრისთვისაა მანქანა აწყობილი და რომელი კონექტორი აქვს ფიზიკურად.</li>
<li>აქვს თუ არა ცალკე AC პორტი და რომელი ტიპის.</li>
<li>არსებობს თუ არა ამ კონკრეტული მოდელისთვის დამოწმებული DC ადაპტერი.</li>
<li>რამდენ კილოვატს იღებს მანქანა AC-ზე, რადგან ეს განსაზღვრავს, ღამით რამდენს დატენავთ.</li>
</ul>
<p>რომელი კონექტორი როგორ გამოიყურება და რომელ მანქანას რა აქვს, ცალკე გვაქვს აღწერილი: <a href="/blog/konektorebi/">კონექტორების გზამკვლევი</a>. კონკრეტული სადგურების კონექტორები კი <a href="/damtenebi/">დამტენების სიაშია</a>.</p>
`,
      faq: [
        [`შემიძლია ამერიკული ელექტრომობილის დატენვა საქართველოში?`,
          `დიახ, მაგრამ შეზღუდულად. CCS1 კონექტორი ${N.ccs1} სადგურზეა, NACS ${N.nacs}-ზე, Type 1 კი ${N.type1}-ზე, სულ ${N.usSpec} სადგური საქართველოს ${N.total}-დან. Type 1-დან Type 2-ზე ადაპტერით ნელი დატენვის ბევრად მეტი ვარიანტი გეხსნებათ.`],
        [`მუშაობს თუ არა CCS1-დან CCS2-ზე ადაპტერი?`,
          `ასეთი ადაპტერები არსებობს, მაგრამ ძვირია, ყველა მანქანა არ უჭერს მხარს და მწარმოებლები ხშირად არ იძლევიან გარანტიას. ნელი AC დატენვისთვის Type 1-დან Type 2-ზე ადაპტერი კი მარტივი და საიმედოა.`],
        [`რომელი ქსელი ემსახურება ამერიკულ მანქანებს საქართველოში?`,
          `ძირითადად ${N.usTopProvider[0]}. Type 1 კონექტორის სადგურების უმეტესობა და NACS-ის დიდი ნაწილი სწორედ ამ ქსელს ეკუთვნის, ამიტომ პრაქტიკულად ერთ ოპერატორზე ხართ დამოკიდებული.`],
      ],
    },
    en: {
      title: 'Importing an EV from the US: where you will charge it in Georgia',
      metaTitle: 'US-spec EVs in Georgia: the charging problem',
      desc: `A US-spec car has CCS1, NACS or Type 1. Georgia has ${N.usSpec} such stations in total. What adapters do and what to check before you buy.`,
      key: [
        `A US-market EV uses different plugs from a European one. In Georgia CCS1 is on just ${N.ccs1} stations, NACS on ${N.nacs} and Type 1 on ${N.type1}. European CCS2, for comparison, is on ${N.ccs2}.`,
        `More to the point, most of those chargers belong to one network, ${N.usTopProvider[0]}. In practice you depend on a single operator.`,
      ],
      body: `
<h2>Who this affects</h2>
<p>A lot of the EVs arriving in Georgia come from US auctions, and a car built for the US market carries a different plug from a European one. This is not a detail. It decides whether you can charge at all.</p>
<p>The models that turn up most often:</p>
<ul>
<li><strong>Tesla Model 3 and Model Y from the US market.</strong> The NACS connector, Tesla's own standard.</li>
<li><strong>Chevrolet Bolt, Ford Mustang Mach-E, US-version Volkswagen ID.4.</strong> CCS1 for fast charging, Type 1 for slow.</li>
<li><strong>US-version Nissan Leaf.</strong> CHAdeMO for fast charging, Type 1 for slow.</li>
</ul>

<h2>The real numbers in Georgia</h2>
<ul>
<li><strong>CCS1:</strong> ${N.ccs1} stations in the whole country.</li>
<li><strong>NACS:</strong> ${N.nacs} stations.</li>
<li><strong>Type 1:</strong> ${N.type1} stations, for slow AC charging.</li>
<li><strong>CHAdeMO:</strong> ${N.chademo} stations.</li>
</ul>
<p>That is ${N.usSpec} stations out of Georgia's ${N.total}. European CCS2 sits on ${N.ccs2}.</p>

<h2>The part most people miss</h2>
<p>These chargers are not spread evenly across operators. Every Type 1 station and most of the NACS ones belong to ${N.usTopProvider[0]}.</p>
<p>So with a US car you effectively become one network's customer. Where that network has no charger, you have no alternative.</p>

<h2>Adapters: what works and what does not</h2>
<h3>Slow AC charging</h3>
<p>A Type 1 to Type 2 adapter is simple, cheap and reliable. AC charging involves no complex negotiation between car and charger, so converting the plug is enough. With one of these, every Type 2 station in the country opens up, and that is ${N.type2} stations.</p>
<p>This is the easiest fix available and worth budgeting for before you buy.</p>
<h3>Fast DC charging</h3>
<p>Here it is different. Fast charging involves the car and the charger talking over a protocol, and the adapter has to carry that conversation too. CCS1 to CCS2 adapters exist, but they are expensive, not every car supports them, and manufacturers often will not warrant them.</p>
<p>A Tesla NACS to CCS2 adapter is easier to come by, though you still need to check your specific model and software version.</p>
<p>Relying on an adapter for fast charging is therefore a risk. Confirm it works on your exact model before you spend money on it.</p>

<h2>A realistic plan</h2>
<ul>
<li><strong>Home charging becomes essential, not a nice to have.</strong> A European car has the public network as a fallback. You largely do not.</li>
<li><strong>Buy the Type 1 adapter on day one.</strong> It removes the slow charging problem entirely.</li>
<li><strong>Plan long trips in advance.</strong> The fast chargers that will work for you can be counted on your fingers.</li>
<li><strong>Factor in resale.</strong> European-spec cars sell more easily on the Georgian market, for exactly this reason.</li>
</ul>

<h2>What to check before buying</h2>
<ul>
<li>Which market the car was built for and which connector it physically has.</li>
<li>Whether it has a separate AC port and of which type.</li>
<li>Whether a proven DC adapter exists for that exact model.</li>
<li>How many kW the car accepts on AC, since that decides how much you gain overnight.</li>
</ul>
<p>What each connector looks like and which car uses which is covered separately in the <a href="/en/blog/konektorebi/">connector guide</a>. The connectors at individual stations are in the <a href="/en/chargers/">charger list</a>.</p>
`,
      faq: [
        [`Can I charge a US-spec EV in Georgia?`,
          `Yes, but with limits. CCS1 is on ${N.ccs1} stations, NACS on ${N.nacs} and Type 1 on ${N.type1}, which is ${N.usSpec} out of Georgia's ${N.total}. A Type 1 to Type 2 adapter opens up far more options for slow charging.`],
        [`Does a CCS1 to CCS2 adapter work?`,
          `Such adapters exist, but they are expensive, not every car supports them and manufacturers often will not warrant them. For slow AC charging, a Type 1 to Type 2 adapter is simple and reliable.`],
        [`Which network serves US cars in Georgia?`,
          `Mainly ${N.usTopProvider[0]}. Most Type 1 stations and a large share of the NACS ones belong to that network, so you effectively depend on a single operator.`],
      ],
    },
  },

  {
    slug: 'chinuri-importi',
    ka: {
      title: 'ჩინური ელექტრომობილი საქართველოში: GB/T კონექტორი და დატენვა',
      metaTitle: 'ჩინური ელექტრომობილი და GB/T საქართველოში',
      desc: `GB/T კონექტორი საქართველოში ${N.gbt} სადგურზეა, თითქმის იმდენზე, რამდენზეც ევროპული CCS2. რატომ არის ეს კარგი ამბავი ჩინური მანქანის მფლობელისთვის.`,
      key: [
        `GB/T საქართველოში ${N.gbt} სადგურზეა, ევროპული CCS2 კი ${N.ccs2}-ზე. ევროპაში GB/T პრაქტიკულად არ არსებობს, აქ კი თითქმის თანაბარია.`,
        `${N.gbt}-დან ${N.gbtWithCcs2} იმავე აპარატზეა CCS2-თან ერთად. ანუ ეს ცალკე ინფრასტრუქტურა არ არის, ერთი და იგივე სწრაფი დამტენები ორივე შტეფსელს ატარებს.`,
      ],
      body: `
<h2>რომელ მანქანებს ეხება</h2>
<p>GB/T ჩინური ეროვნული სტანდარტია და მას ატარებს ჩინეთის ბაზრისთვის აწყობილი თითქმის ყველა ელექტრომობილი: BYD, Zeekr, Li Auto, NIO, Xpeng, Wuling, Chery, Changan და სხვები.</p>
<p>საქართველოში ასეთი მანქანები ბოლო წლებში მასობრივად შემოვიდა, დამტენების ოპერატორებმა კი ამას ინფრასტრუქტურა მოარგეს.</p>

<h2>GB/T-ს ორი სახე აქვს</h2>
<p>ეს ის ადგილია, სადაც ყველაზე ხშირად ერევათ. GB/T ერთი კონექტორი არ არის, ორია: ერთი ნელი AC დატენვისთვის, მეორე სწრაფი DC-სთვის. ისინი ერთმანეთს ჰგვანან, მაგრამ სხვადასხვა ფიზიკური შტეფსელია და ურთიერთშენაცვლებადი არ არის.</p>
<p>ბევრ ჩინურ ელექტრომობილს ორივე პორტი აქვს, ხშირად მანქანის სხვადასხვა მხარეს. თუ ახალი მფლობელი ხართ, ჯერ გაარკვიეთ, რომელი პორტი რომელია.</p>
<p>საქართველოში GB/T ძირითადად სწრაფი დატენვისთვის დგას: ${N.gbtDc} სადგური DC-ია და მხოლოდ ${N.gbtAc} AC.</p>

<h2>რატომ არის ეს კარგი ამბავი</h2>
<p>ჩინური მანქანის მფლობელს ხშირად ეშინია, რომ ცალკე, იშვიათ ინფრასტრუქტურაზე იქნება დამოკიდებული. საქართველოში ეს ასე არ არის.</p>
<p>GB/T-ს ${N.gbt} სადგურიდან ${N.gbtWithCcs2} სწორედ იმ აპარატებზეა, სადაც CCS2-იც დგას. ეს ორთოფიანი სწრაფი დამტენებია: ერთ კაბინეტს ორი კაბელი აქვს, ერთი ევროპული, მეორე ჩინური. ანუ იმავე სადგურებზე ტენით, სადაც ევროპული მანქანები.</p>
<p>პრაქტიკული დასკვნა: ჩინური მანქანით საქართველოში დაფარვის პრობლემა თითქმის არ გაქვთ.</p>

<h2>რა სიმძლავრეს მიიღებთ</h2>
<p>GB/T სადგურების უმეტესობა საქართველოში 120 კილოვატიანია. საკმაოდ ბევრია 30 და 47 კილოვატიანიც, რომლებიც შესამჩნევად ნელია, ხოლო ყველაზე მძლავრი აპარატები 160 კილოვატამდე ადის.</p>
<p>გახსოვდეთ, რომ ჭერს მანქანაც აწესებს. თუ თქვენი მოდელი 60 კილოვატს იღებს, 120 კილოვატიან დამტენზეც 60-ს მიიღებთ.</p>

<h2>AC დატენვა და Type 2</h2>
<p>ევროპისთვის ოფიციალურად შემოტანილ ჩინურ მანქანებს ჩვეულებრივ Type 2 AC პორტი აქვთ, ჩინეთის ბაზრიდან ჩამოყვანილებს კი GB/T AC. ეს განსხვავება მნიშვნელოვანია, რადგან საქართველოში Type 2 ${N.type2} სადგურზეა, GB/T AC კი მხოლოდ ${N.gbtAc}-ზე.</p>
<p>თუ ჩინეთიდან ჩამოყვანილი მანქანა გყავთ და სახლში დატენვას გეგმავთ, კედლის დამტენი სწორედ თქვენს AC პორტს უნდა შეესაბამებოდეს.</p>

<h2>რა შეამოწმოთ ყიდვამდე</h2>
<ul>
<li>რომელი ბაზრისთვისაა მანქანა აწყობილი, ჩინეთისთვის თუ ევროპისთვის.</li>
<li>რომელი AC პორტი აქვს, Type 2 თუ GB/T AC. ეს განსაზღვრავს სახლის დამტენს.</li>
<li>რამდენ კილოვატს იღებს DC-ზე, რომ სწრაფი დამტენის რჩევა აზრიანი იყოს.</li>
<li>არის თუ არა მანქანის პროგრამული უზრუნველყოფა ინგლისურად ან ქართულად, რაც ჩინეთის ბაზრის ვერსიებში ხშირად პრობლემაა.</li>
</ul>
<p>კონექტორების საერთო სურათი ცალკე გვაქვს: <a href="/blog/konektorebi/">რომელი კონექტორი გჭირდებათ</a>. კონკრეტული სადგურების სია კი <a href="/damtenebi/">დამტენების კატალოგშია</a>.</p>
`,
      faq: [
        [`GB/T კონექტორი გვაქვს საქართველოში?`,
          `დიახ, ${N.gbt} სადგურზე, რაც თითქმის იმდენია, რამდენზეც ევროპული CCS2 (${N.ccs2}). ევროპაში GB/T პრაქტიკულად არ არსებობს, საქართველოში კი ფართოდაა.`],
        [`ჩინური ელექტრომობილით პრობლემა მექნება დატენვაში?`,
          `არა. GB/T-ს ${N.gbt} სადგურიდან ${N.gbtWithCcs2} იმავე აპარატებზეა, სადაც CCS2 დგას, ანუ ორთოფიან სწრაფ დამტენებზე. იმავე სადგურებს იყენებთ, რასაც ევროპული მანქანები.`],
        [`რა განსხვავებაა GB/T AC-სა და GB/T DC-ს შორის?`,
          `ეს ორი სხვადასხვა ფიზიკური კონექტორია, ერთი ნელი AC დატენვისთვის, მეორე სწრაფი DC-სთვის, და ისინი ურთიერთშენაცვლებადი არ არის. ბევრ ჩინურ მანქანას ორივე პორტი აქვს. საქართველოში GB/T ძირითადად DC-ია: ${N.gbtDc} სადგური DC და მხოლოდ ${N.gbtAc} AC.`],
      ],
    },
    en: {
      title: 'Chinese EVs in Georgia: the GB/T connector and where to charge',
      metaTitle: 'Chinese EVs and GB/T charging in Georgia',
      desc: `GB/T is on ${N.gbt} stations in Georgia, almost as many as European CCS2. Why that is good news if you drive a Chinese import.`,
      key: [
        `GB/T is on ${N.gbt} stations in Georgia against ${N.ccs2} for European CCS2. In Europe GB/T barely exists; here the two are nearly level.`,
        `${N.gbtWithCcs2} of those ${N.gbt} sit on the same cabinet as a CCS2 gun. This is not separate infrastructure, it is the same fast chargers carrying both plugs.`,
      ],
      body: `
<h2>Which cars this covers</h2>
<p>GB/T is the Chinese national standard, carried by almost every EV built for the Chinese market: BYD, Zeekr, Li Auto, NIO, Xpeng, Wuling, Chery, Changan and others.</p>
<p>Georgia has taken in a lot of these cars in recent years, and charger operators built for them.</p>

<h2>GB/T comes in two forms</h2>
<p>This is where people most often get confused. GB/T is not one connector but two: one for slow AC charging, one for fast DC. They look similar, but they are different physical plugs and are not interchangeable.</p>
<p>Many Chinese EVs have both ports, often on opposite sides of the car. If you are a new owner, work out which port is which first.</p>
<p>In Georgia GB/T is mostly there for fast charging: ${N.gbtDc} stations are DC and only ${N.gbtAc} are AC.</p>

<h2>Why this is good news</h2>
<p>Owners of Chinese cars often worry they will depend on separate, rare infrastructure. In Georgia that is not the case.</p>
<p>Of the ${N.gbt} GB/T stations, ${N.gbtWithCcs2} are on cabinets that also carry CCS2. These are dual-gun fast chargers: one cabinet, two cables, one European and one Chinese. You charge at the same stations European cars do.</p>
<p>The practical conclusion is that a Chinese car has almost no coverage problem in Georgia.</p>

<h2>What power you will get</h2>
<p>Most GB/T stations in Georgia are 120 kW. There are also a good number of 30 and 47 kW units, which are noticeably slower, while the most powerful cabinets reach 160 kW.</p>
<p>Remember the car sets a ceiling too. If your model accepts 60 kW, a 120 kW charger still gives you 60.</p>

<h2>AC charging and Type 2</h2>
<p>Chinese cars imported officially for Europe usually have a Type 2 AC port, while cars brought in from the Chinese market have GB/T AC. The difference matters: Type 2 is on ${N.type2} stations in Georgia, GB/T AC on only ${N.gbtAc}.</p>
<p>If your car came from China and you plan to charge at home, the wallbox has to match your actual AC port.</p>

<h2>What to check before buying</h2>
<ul>
<li>Which market the car was built for, China or Europe.</li>
<li>Which AC port it has, Type 2 or GB/T AC. This decides your home charger.</li>
<li>How many kW it accepts on DC, so fast charger advice actually means something.</li>
<li>Whether the car's software is available in English, which is often a problem on Chinese market versions.</li>
</ul>
<p>The overall connector picture is covered separately in the <a href="/en/blog/konektorebi/">connector guide</a>, and individual stations are in the <a href="/en/chargers/">charger catalogue</a>.</p>
`,
      faq: [
        [`Is the GB/T connector available in Georgia?`,
          `Yes, on ${N.gbt} stations, which is almost as many as European CCS2 (${N.ccs2}). GB/T barely exists in Europe but is widespread in Georgia.`],
        [`Will I have trouble charging a Chinese EV in Georgia?`,
          `No. ${N.gbtWithCcs2} of the ${N.gbt} GB/T stations sit on the same cabinets as CCS2, meaning dual-gun fast chargers. You use the same stations European cars do.`],
        [`What is the difference between GB/T AC and GB/T DC?`,
          `They are two different physical connectors, one for slow AC and one for fast DC, and they are not interchangeable. Many Chinese cars have both ports. In Georgia GB/T is mostly DC: ${N.gbtDc} stations against only ${N.gbtAc} on AC.`],
      ],
    },
  },

  {
    slug: 'zamtari',
    ka: {
      title: 'ელექტრომობილი ზამთარში საქართველოში: გარბენი, დატენვა და მთა',
      metaTitle: 'ელექტრომობილი ზამთარში საქართველოში',
      desc: `ცივ ამინდში გარბენი მესამედამდე ეცემა. ბაკურიანში ${N.bakuriani.n} დამტენია და არცერთი სწრაფი, სტეფანწმინდაში ${N.kazbegi.n}. როგორ დავგეგმოთ ზამთარი.`,
      key: [
        'ცივ ამინდში ელექტრომობილის რეალური გარბენი ჩვეულებრივ 20-დან 35 პროცენტამდე ეცემა. მიზეზი ორია: ბატარეა ცივზე ნაკლებ ენერგიას იძლევა, გათბობა კი დამატებით ხარჯავს.',
        `საქართველოს სპეციფიკა ისაა, რომ სასრიალო კურორტებში სწრაფი დამტენი თითქმის არ არის. ბაკურიანში ${N.bakuriani.n} სადგურია და არცერთი სწრაფი, სტეფანწმინდაში ${N.kazbegi.n}, გუდაურში კი ${N.gudauri.n}, აქედან ${N.gudauri.dc} სწრაფი.`,
      ],
      body: `
<h2>რატომ ეცემა გარბენი</h2>
<p>ორი დამოუკიდებელი მიზეზია და ისინი ერთმანეთს ემატება.</p>
<p>პირველი: ლითიუმის ბატარეაში ქიმიური რეაქციები ცივზე ნელდება. ბატარეა იმავე ენერგიას ინახავს, მაგრამ მისი გაცემა უჭირს. ეს ზოგჯერ დროებითია და გათბობის შემდეგ ნაწილობრივ ბრუნდება.</p>
<p>მეორე და უფრო მნიშვნელოვანი: ბენზინის მანქანაში სალონს ძრავის ნარჩენი სითბო ათბობს, ანუ უფასოდ. ელექტრომობილს ეს სითბო არ აქვს და გათბობა პირდაპირ ბატარეიდან იკვებება. ცივ დღეს ეს რამდენიმე კილოვატია, რაც გარბენს შესამჩნევად ჭამს.</p>

<h2>დატენვაც ნელდება</h2>
<p>ცივი ბატარეა სწრაფად ვერ იტენება. თუ ზამთარში სწრაფ დამტენზე მიხვედით და მანქანა ცივია, დაპირებული 20 წუთის ნაცვლად შეიძლება 40 დაგჭირდეთ.</p>
<p>ბევრ თანამედროვე მოდელს აქვს ბატარეის წინასწარი გახურების ფუნქცია. თუ ნავიგაციაში დამტენს მიუთითებთ, მანქანა გზაში ბატარეას ამზადებს და მისვლისას ის უკვე სწორ ტემპერატურაზეა. თუ ეს ფუნქცია გაქვთ, ზამთარში აუცილებლად გამოიყენეთ.</p>

<h2>საქართველოს მთავარი პრობლემა ზამთარში</h2>
<p>აქ საქმე მხოლოდ სიცივეში არ არის. საქართველოში ზამთრის მთავარი მიმართულებები სწორედ ის ადგილებია, სადაც სწრაფი დატენვა ყველაზე ნაკლებადაა.</p>
<ul>
<li><strong>ბაკურიანი:</strong> ${N.bakuriani.n} დამტენი და არცერთი სწრაფი. ყველა ნელი AC, 22 კილოვატამდე.</li>
<li><strong>სტეფანწმინდა, ყაზბეგის მიმართულება:</strong> ${N.kazbegi.n} დამტენი, სწრაფი არცერთი.</li>
<li><strong>გუდაური:</strong> ${N.gudauri.n} დამტენი, აქედან ${N.gudauri.dc} სწრაფი. ეს ერთადერთი ზამთრის კურორტია, სადაც სწრაფად დატენვა შეგიძლიათ.</li>
</ul>
<p>ანუ სწორედ მაშინ, როცა გარბენი ყველაზე დაბალია, ინფრასტრუქტურაც ყველაზე თხელია. ეს ორი გარემოება ერთად უნდა გაითვალისწინოთ.</p>

<h2>რას ნიშნავს ეს პრაქტიკულად</h2>
<p>ნელი AC დამტენი კურორტზე არ არის ცუდი ამბავი, თუ ღამით ტენით. 22 კილოვატიან დამტენზე 60 კილოვატსაათიანი ბატარეა 20-დან 80 პროცენტამდე დაახლოებით ორ საათში ივსება, 7 კილოვატიანზე კი ხუთში. ორივე შემთხვევაში ღამე საკმარისია.</p>
<p>პრობლემა მაშინ ჩნდება, თუ სასტუმროში დამტენი დაკავებულია ან საერთოდ არ არის და დაბრუნების ენერგია არ გაქვთ.</p>

<h2>ზამთრის წესები</h2>
<ul>
<li><strong>დაგეგმეთ 30 პროცენტით მეტი მარაგი.</strong> ზაფხულის გამოცდილება ზამთარში არ მუშაობს.</li>
<li><strong>გახურდით ჩართულ კაბელზე.</strong> თუ სალონს გასვლამდე ათბობთ მაშინ, როცა მანქანა დამტენზეა, ენერგია ქსელიდან მიდის და არა ბატარეიდან.</li>
<li><strong>ბოლო სწრაფი დამტენი დაიმახსოვრეთ.</strong> გუდაურის შემდეგ ყაზბეგის მიმართულებით სწრაფი აღარაა, ბორჯომის შემდეგ ბაკურიანისკენ იგივე.</li>
<li><strong>დატენეთ 90 პროცენტამდე მთაში ასვლის წინ.</strong> ჩვეულებრივ 80 პროცენტზე გაჩერება სწორია, მაგრამ აღმართი და სიცივე ერთად გამონაკლისს ამართლებს.</li>
<li><strong>დახურულ პარკინგში დატოვება ეხმარება.</strong> ღამით გარეთ გაყინული ბატარეა დილით შესამჩნევად ნაკლებ გარბენს აჩვენებს.</li>
</ul>

<h2>რა არ არის პრობლემა</h2>
<p>სიცივე ბატარეას მუდმივად არ აზიანებს. გარბენის დაცემა დროებითია და გაზაფხულზე ბრუნდება. ასევე, ელექტრომობილი ცივ ამინდში უფრო საიმედოდ იშვება, ვიდრე ბენზინის მანქანა, რადგან სტარტერიც და ცივი ძრავის პრობლემაც არ აქვს.</p>
<p>მთის მარშრუტების დეტალური სურათი ცალკე გვაქვს: <a href="/marshruti/tbilisi-kazbegi/">თბილისი ყაზბეგი</a> და <a href="/marshruti/tbilisi-bakuriani/">თბილისი ბაკურიანი</a>. რატომ ტენის AC ნელა, აქ არის ახსნილი: <a href="/blog/ac-da-dc/">AC თუ DC</a>.</p>
`,
      faq: [
        [`რამდენით მცირდება ელექტრომობილის გარბენი ზამთარში?`,
          'ჩვეულებრივ 20-დან 35 პროცენტამდე. მიზეზი ორია: ცივი ბატარეა ნაკლებ ენერგიას იძლევა, სალონის გათბობა კი პირდაპირ ბატარეიდან იკვებება, რადგან ძრავის ნარჩენი სითბო ელექტრომობილს არ აქვს.'],
        [`არის თუ არა სწრაფი დამტენი ბაკურიანსა და ყაზბეგში?`,
          `არა. ბაკურიანში ${N.bakuriani.n} დამტენია და ყველა ნელი AC, სტეფანწმინდაში ${N.kazbegi.n}, ისიც AC. გუდაური ერთადერთი ზამთრის კურორტია სწრაფი დამტენებით, სადაც ${N.gudauri.n} სადგურიდან ${N.gudauri.dc} სწრაფია.`],
        [`ზიანდება თუ არა ბატარეა სიცივისგან?`,
          'მუდმივად არა. გარბენის დაცემა დროებითია და თბილ ამინდში ბრუნდება. ცივ ბატარეაზე სწრაფი დატენვა კი ნელა მიდის, ამიტომ ღირს წინასწარი გახურების ფუნქციის გამოყენება, თუ მანქანას აქვს.'],
      ],
    },
    en: {
      title: 'Driving an EV through a Georgian winter: range, charging and the mountains',
      metaTitle: 'EVs in winter in Georgia',
      desc: `Cold weather costs up to a third of your range. Bakuriani has ${N.bakuriani.n} chargers and none of them fast, Stepantsminda ${N.kazbegi.n}. How to plan for it.`,
      key: [
        'In cold weather real range typically drops by 20 to 35 percent. Two things cause it: a cold battery delivers less, and cabin heating draws power on top.',
        `What is specific to Georgia is that the ski destinations have almost no fast charging. Bakuriani has ${N.bakuriani.n} stations and none are fast, Stepantsminda ${N.kazbegi.n}, and Gudauri ${N.gudauri.n} of which ${N.gudauri.dc} are fast.`,
      ],
      body: `
<h2>Why range falls</h2>
<p>There are two separate causes and they stack.</p>
<p>First, the chemical reactions in a lithium battery slow down in the cold. The battery holds the same energy but struggles to deliver it. Some of this is temporary and comes back once the pack warms.</p>
<p>Second, and more significant: a petrol car heats the cabin with waste heat from the engine, essentially for free. An EV has no such heat, so heating draws straight from the battery. On a cold day that is several kilowatts, and it eats range noticeably.</p>

<h2>Charging slows down too</h2>
<p>A cold battery cannot take a fast charge. Arrive at a fast charger in winter with a cold car and the promised 20 minutes can turn into 40.</p>
<p>Many modern models can precondition the battery. Set the charger as your navigation destination and the car warms the pack on the way, so it is at the right temperature when you arrive. If your car has this, use it in winter.</p>

<h2>Georgia's particular winter problem</h2>
<p>This is not only about the cold. In Georgia the main winter destinations happen to be exactly the places with the least fast charging.</p>
<ul>
<li><strong>Bakuriani:</strong> ${N.bakuriani.n} chargers, none of them fast. All slow AC up to 22 kW.</li>
<li><strong>Stepantsminda, on the Kazbegi road:</strong> ${N.kazbegi.n} chargers, none fast.</li>
<li><strong>Gudauri:</strong> ${N.gudauri.n} chargers, ${N.gudauri.dc} of them fast. It is the only winter resort where you can charge quickly.</li>
</ul>
<p>So exactly when range is at its lowest, the infrastructure is at its thinnest. Those two facts have to be planned for together.</p>

<h2>What this means in practice</h2>
<p>A slow AC charger at a resort is not a bad thing if you charge overnight. On a 22 kW charger a 60 kWh battery goes from 20 to 80 percent in about two hours, on a 7 kW one in about five. Either way, a night is enough.</p>
<p>The problem appears when the hotel charger is occupied or absent and you have no energy left to get back.</p>

<h2>Winter rules</h2>
<ul>
<li><strong>Plan 30 percent more margin.</strong> Summer experience does not transfer.</li>
<li><strong>Preheat while still plugged in.</strong> Warming the cabin before you leave while the car is on the charger draws from the grid, not the battery.</li>
<li><strong>Know your last fast charger.</strong> Past Gudauri towards Kazbegi there is none, and the same past Borjomi towards Bakuriani.</li>
<li><strong>Charge to 90 percent before a climb.</strong> Stopping at 80 is normally right, but altitude plus cold together justify the exception.</li>
<li><strong>Park indoors where you can.</strong> A pack left out overnight in the freezing cold shows noticeably less range in the morning.</li>
</ul>

<h2>What is not a problem</h2>
<p>Cold does not permanently damage the battery. The range loss is temporary and returns in spring. An EV also starts more reliably in the cold than a petrol car, having neither a starter motor nor a cold engine to deal with.</p>
<p>The mountain routes are covered in detail separately: <a href="/en/routes/tbilisi-kazbegi/">Tbilisi to Kazbegi</a> and <a href="/en/routes/tbilisi-bakuriani/">Tbilisi to Bakuriani</a>. Why AC charging is slow is explained in <a href="/en/blog/ac-da-dc/">AC or DC</a>.</p>
`,
      faq: [
        [`How much range does an EV lose in winter?`,
          'Typically 20 to 35 percent. Two causes: a cold battery delivers less energy, and cabin heating draws straight from the pack because an EV has no engine waste heat to use.'],
        [`Are there fast chargers in Bakuriani and Kazbegi?`,
          `No. Bakuriani has ${N.bakuriani.n} chargers, all slow AC, and Stepantsminda has ${N.kazbegi.n}, also AC. Gudauri is the only winter resort with fast charging, where ${N.gudauri.dc} of its ${N.gudauri.n} stations are fast.`],
        [`Does cold damage the battery?`,
          'Not permanently. The range loss is temporary and returns in warmer weather. Fast charging a cold pack is slow, though, so use the preconditioning function if your car has one.'],
      ],
    },
  },
  {
    slug: 'sakhlis-damteni',
    ka: {
      title: 'სახლის დამტენი: რა სჭირდება და რაზეა დამოკიდებული ფასი',
      metaTitle: 'სახლის დამტენის დაყენება საქართველოში',
      desc: 'ჩვეულებრივი როზეტი, შვიდკილოვატიანი კედლის დამტენი თუ სამფაზიანი. რა სჭირდება ბინას და კერძო სახლს, რა მოსთხოვოთ ელექტრიკს და როდის არ ღირს დამტენის ყიდვა.',
      key: [
        'მოკლე პასუხი: თუ დღეში 50 კილომეტრამდე დადიხართ, ჩვეულებრივი როზეტიც კმარა. კედლის დამტენი მაშინაა საჭირო, როცა ერთ ღამეში ბატარეის ნახევარზე მეტის შევსება გჭირდებათ.',
        'ხარჯში მთავარი თავად დამტენი არ არის. კაბელის გაყვანა მრიცხველიდან სადგომამდე და, საჭიროების შემთხვევაში, სიმძლავრის გაზრდა ხშირად აპარატზე ძვირი ჯდება. სწორედ ამიტომ განსხვავდება ბინისა და კერძო სახლის ფასი რამდენჯერმე.',
      ],
      body: `
<h2>სამი რეალური ვარიანტი</h2>
<p>არჩევანი სამ დონეზეა და მათ შორის სხვაობა მხოლოდ სისწრაფეა. ქვემოთ ნაჩვენებია, რამდენი დასჭირდება 60 კილოვატსაათიან ბატარეას 20-დან 80 პროცენტამდე, ანუ 36 კილოვატსაათის შევსებას.</p>
<div class="tw"><table>
<thead><tr><th>მიერთება</th><th>სიმძლავრე</th><th>20-დან 80 პროცენტამდე</th></tr></thead>
<tbody>
<tr><td>ჩვეულებრივი საყოფაცხოვრებო როზეტი</td><td>2.3 kW</td><td>დაახლოებით 16 საათი</td></tr>
<tr><td>გაძლიერებული როზეტი, მანქანის კომპლექტის კაბელი</td><td>3.5 kW</td><td>დაახლოებით 10 საათი</td></tr>
<tr><td>ერთფაზიანი კედლის დამტენი</td><td>7.4 kW</td><td>დაახლოებით 5 საათი</td></tr>
<tr><td>სამფაზიანი კედლის დამტენი</td><td>11 kW</td><td>დაახლოებით 3 საათი 20 წუთი</td></tr>
<tr><td>სამფაზიანი კედლის დამტენი</td><td>22 kW</td><td>დაახლოებით 1 საათი 40 წუთი</td></tr>
</tbody></table></div>
<p>ღამე რვა საათია. ცხრილიდან ჩანს, რომ შვიდკილოვატიანი დამტენი ამ დროში თითქმის ნებისმიერ ბატარეას ავსებს. სწორედ ამიტომ არის 7.4 კილოვატი სახლისთვის ყველაზე გავრცელებული არჩევანი და არა იმიტომ, რომ უფრო ძლიერი არ არსებობს.</p>

<h2>რამდენ კილოვატს იღებს თქვენი მანქანა</h2>
<p>დამტენის ყიდვამდე ერთი რამ შეამოწმეთ: რამდენ კილოვატს იღებს მანქანა ნელ დატენვაზე. ეს ბორტზე მყოფი დამმუხტველის ლიმიტია და ის დამტენზე არ არის დამოკიდებული.</p>
<p>ბევრი მოდელი მაქსიმუმ 7.4 კილოვატს იღებს, ნაწილი 11-ს, 22 კილოვატი კი შედარებით იშვიათია. თუ თქვენი მანქანა 7.4-ზე ჩერდება, 22 კილოვატიან დამტენზეც 7.4-ს მიიღებთ. ანუ გადაიხდით იმაში, რასაც ვერასოდეს გამოიყენებთ.</p>
<p>იგივე ეხება ფაზას. სამფაზიან დამტენს სამფაზიანი შემოყვანა სჭირდება. თუ ბინაში ერთი ფაზაა, სამფაზიანი აპარატი უბრალოდ ერთ ფაზაზე იმუშავებს და 7.4 კილოვატს მოგცემთ.</p>

<h2>კერძო სახლი და ბინა ორი სხვადასხვა ამბავია</h2>
<p>კერძო სახლში საქმე მარტივია. მრიცხველი თქვენია, სადგომი თქვენია, კაბელის მანძილი მოკლეა და სამი ფაზა ხშირად უკვე შემოყვანილია. აქ დამტენის დაყენება ჩვეულებრივი ელექტროსამონტაჟო სამუშაოა.</p>
<p>ბინაში სამი დამოუკიდებელი დაბრკოლებაა და თითოეული მათგანი ცალკე წყდება.</p>
<ul>
<li><strong>სადგომის სტატუსი.</strong> ეზო და მიწისქვეშა პარკინგი ჩვეულებრივ საერთო ქონებაა. კედელზე აპარატის დამაგრებას და საერთო სივრცეში კაბელის გაყვანას მესაკუთრეთა ამხანაგობის თანხმობა სჭირდება. ეს პირველი ნაბიჯია და არა ბოლო.</li>
<li><strong>ცალკე აღრიცხვა.</strong> თუ დამტენი საერთო ხაზზე ჩაერთვება, დენს მთელი სადარბაზო გადაიხდის. საჭიროა თქვენი ბინის მრიცხველიდან ცალკე ხაზი ან დამტენისთვის ცალკე მრიცხველი.</li>
<li><strong>შენობის მარაგი.</strong> ძველ კორპუსებში სადარბაზოს შემოყვანას თავისუფალი სიმძლავრე ხშირად საერთოდ არ აქვს. ამ შემთხვევაში დამტენამდე სიმძლავრის გაზრდაა საჭირო, რაც განაწილების კომპანიის ოფიციალური სერვისია და განცხადებით იწყება.</li>
</ul>
<p>ამ სამიდან მესამე ყველაზე ხშირად აჩერებს პროექტს. ამიტომ სანამ აპარატს შეარჩევთ, ჯერ გაარკვიეთ, რამდენი ამპერია თქვენს მრიცხველზე დაშვებული და რამდენს იკავებს უკვე ბინა.</p>

<h2>რას მოსთხოვოთ ელექტრიკს</h2>
<p>დამტენი ერთადერთი მოწყობილობაა სახლში, რომელიც საათობით მუშაობს სრულ დატვირთვაზე. ჩვეულებრივი საყოფაცხოვრებო გაყვანილობა ამაზე გათვლილი არ არის.</p>
<ul>
<li><strong>ცალკე ხაზი მრიცხველიდან.</strong> დამტენი არ უნდა ჩაერთოს არსებულ როზეტების ხაზში, სამზარეულოს ხაზში ან დამატებით სოკეტში. ცალკე კაბელი, ცალკე ავტომატი.</li>
<li><strong>კაბელის კვეთა დენზე გათვლილი.</strong> კვეთას ორი რამ განსაზღვრავს: დამტენის დენი და მანძილი. გრძელ ტრასაზე იმავე დენისთვის უფრო სქელი კაბელი სჭირდება. ეს ის ადგილია, სადაც დაზოგვა ყველაზე საშიშია.</li>
<li><strong>დიფავტომატი, რომელიც მუდმივ დენს ხედავს.</strong> ჩვეულებრივი დიფავტომატი მუდმივი დენის გაჟონვას ვერ ამჩნევს, დამტენში კი სწორედ ასეთი შეიძლება გაჩნდეს. საჭიროა B ტიპის დიფავტომატი ან დამტენი, რომელსაც ეს დაცვა შიგნით აქვს ჩაშენებული.</li>
<li><strong>რეალური მიწისმიმართვა.</strong> ძველ თბილისურ კორპუსებში დამცავი მიწა ხშირად საერთოდ არ არის ან ნულთანაა შეერთებული. დამტენი ასეთ ქსელში ან საერთოდ არ ჩაირთვება, ან ჩაირთვება და დაცვის გარეშე იმუშავებს. ეს ცალკე შესამოწმებელი პუნქტია და არა თავისთავად ცხადი.</li>
<li><strong>დენის შეზღუდვის შესაძლებლობა.</strong> კარგი დამტენი საშუალებას გაძლევთ მაქსიმალური დენი პროგრამულად შეზღუდოთ. თუ შემოყვანა სუსტია, 7.4 კილოვატიანი აპარატი 3.7-ზე დააყენეთ და ღამით მაინც სრულად დაიტენება.</li>
</ul>

<h2>რაზეა დამოკიდებული ფასი</h2>
<p>ხარჯი ოთხ ნაწილად იშლება და მათი წონა ერთმანეთისგან ძალიან განსხვავდება.</p>
<ul>
<li><strong>თავად დამტენი.</strong> ყველაზე პროგნოზირებადი პუნქტი. მარტივი აპარატი და ეკრანიანი, აპლიკაციით მართვადი მოდელი რამდენჯერმე განსხვავდება, ფუნქციონალურად კი ორივე ერთსა და იმავეს აკეთებს.</li>
<li><strong>კაბელი და მისი გაყვანა.</strong> აქ იმალება მთავარი გაურკვევლობა. ხუთი მეტრი კედლის გასწვრივ და ორმოცი მეტრი მიწისქვეშა პარკინგში ერთი და იგივე სამუშაო არ არის.</li>
<li><strong>დამცავი აპარატურა და ფარი.</strong> ავტომატი, დიფავტომატი და საჭიროების შემთხვევაში ცალკე მრიცხველი.</li>
<li><strong>სიმძლავრის გაზრდა.</strong> ეს პუნქტი ან საერთოდ არ არსებობს, ან ყველაზე დიდი აღმოჩნდება. დამოკიდებულია იმაზე, რა მარაგი აქვს თქვენს შემოყვანას.</li>
</ul>
<p>კონკრეტულ ციფრებს განზრახ არ ვწერთ. აპარატის ფასი ბაზარზე იცვლება, მონტაჟი კი ყოველ შემთხვევაში ინდივიდუალურად ითვლება და ერთი და იმავე დამტენის დაყენება ორ სხვადასხვა ბინაში სამჯერ განსხვავებული შეიძლება იყოს. სამაგიეროდ იცით, რომელი ოთხი პუნქტი უნდა იყოს ხარჯთაღრიცხვაში ჩაშლილი. თუ ელექტრიკი ერთ ჯამურ ციფრს გეუბნებათ, სთხოვეთ დაშალოს.</p>

<h2>ღირს თუ არა საერთოდ</h2>
<p>ეს ის კითხვაა, რომელსაც ყველაზე იშვიათად სვამენ. თუ დღეში 50 კილომეტრს გადიხართ, ეს დაახლოებით 9 კილოვატსაათია. ჩვეულებრივი როზეტი მას ოთხ საათში ავსებს. კედლის დამტენი ამ შემთხვევაში სისწრაფეს ყიდულობს, რომელიც არ გჭირდებათ.</p>
<p>დამტენს აზრი მაშინ აქვს, თუ დღეში 150 კილომეტრზე მეტს გადიხართ, თუ სახლში მხოლოდ რამდენიმე საათით ჩერდებით, ან თუ ორი ელექტრომობილი გყავთ.</p>
<p>ფულადი მხარე კი მარტივად ითვლება. საჯარო ნელ დამტენზე კილოვატსაათი მედიანურად ${N.acMed.toFixed(2)} ლარია, სწრაფზე ${N.dcMed.toFixed(2)}. სახლის ტარიფი ამაზე დაბალია და ზუსტ ციფრს თქვენივე ქვითრიდან აიღებთ, რადგან ის საფეხურებრივია და ელექტრომობილი ჩვეულებრივ ზედა საფეხურზე გადაგიყვანთ. სხვაობა ერთ კილოვატსაათზე გაამრავლეთ თვეში დახარჯულ კილოვატსაათებზე და დანაზოგი ხელთაა.</p>

<h2>რა არ გააკეთოთ</h2>
<ul>
<li><strong>დამაგრძელებელი.</strong> ჩვეულებრივი დამაგრძელებელი საათობით 10 ამპერზე არ არის გათვლილი და ის თბება. თუ როზეტიდან ტენით, პირდაპირ ჩართეთ.</li>
<li><strong>საერთო როზეტი.</strong> ის, რასაც ერთდროულად ბოილერი ან გამათბობელი იყენებს, დამტენს არ გამოადგება.</li>
<li><strong>ღია ცის ქვეშ დაუცველი როზეტი.</strong> გარეთ მიერთებას ტენისგან დაცვა და შესაბამისი კლასის სოკეტი სჭირდება.</li>
<li><strong>მაქსიმალური დენი ძველ გაყვანილობაზე.</strong> თუ კაბელი ძველია, დამტენში დენი შეზღუდეთ და არა პირიქით.</li>
</ul>
<p>რას ნიშნავს AC და DC და რატომ ტენის ნელი დამტენი ასე დიდხანს, ცალკე გვაქვს ახსნილი: <a href="/blog/ac-da-dc/">AC თუ DC</a>. საჯარო დამტენების ტარიფები კი <a href="/tarifebi/">ტარიფების გვერდზეა</a>.</p>
`,
      faq: [
        ['რამდენ ხანში იტენება ელექტრომობილი სახლის როზეტიდან?',
          'ჩვეულებრივი როზეტი დაახლოებით 2.3 კილოვატს იძლევა. 60 კილოვატსაათიანი ბატარეის 20-დან 80 პროცენტამდე შევსებას ეს დაახლოებით 16 საათს ანდომებს. ერთი დღის ჩვეულებრივი გარბენი, დაახლოებით 9 კილოვატსაათი, ოთხ საათში ივსება.',
        ],
        ['შემიძლია თუ არა ბინაში დამტენის დაყენება?',
          'შესაძლებელია, მაგრამ სამი პირობა უნდა შესრულდეს: სადგომზე მესაკუთრეთა ამხანაგობის თანხმობა, თქვენი მრიცხველიდან ცალკე ხაზი და შემოყვანაზე თავისუფალი სიმძლავრე. სამივე ცალკე მოგვარებადია, თუმცა სწორედ მესამე აჩერებს პროექტს ყველაზე ხშირად.',
        ],
        ['სამფაზიანი დამტენი უკეთესია თუ ერთფაზიანი?',
          'უკეთესია მხოლოდ მაშინ, თუ სამი ფაზა შემოყვანილი გაქვთ და მანქანაც 11 ან 22 კილოვატს იღებს. ერთფაზიან შემოყვანაზე სამფაზიანი აპარატი იმავე 7.4 კილოვატს მოგცემთ, რასაც ერთფაზიანი.',
        ],
      ],
    },
    en: {
      title: 'Home charger installation: what it needs and what drives the price',
      metaTitle: 'Installing a home EV charger in Georgia',
      desc: 'A normal socket, a 7 kW wallbox or three phase. What a flat and a house each need, what to insist on from the electrician, and when a wallbox is not worth buying.',
      key: [
        'Short answer: if you drive up to 50 km a day, an ordinary socket is enough. A wallbox earns its place only when you need to put back more than half a battery in one night.',
        'The charger itself is not the main cost. Running the cable from the meter to the parking space, and raising your supply capacity if it comes to that, often costs more than the unit. That is why a flat and a house are priced nothing alike.',
      ],
      body: `
<h2>Three real options</h2>
<p>The choice comes in three levels and the only thing separating them is speed. Below is how long each takes to put 36 kWh into a 60 kWh battery, which is 20 to 80 percent.</p>
<div class="tw"><table>
<thead><tr><th>Connection</th><th>Power</th><th>20 to 80 percent</th></tr></thead>
<tbody>
<tr><td>Ordinary household socket</td><td>2.3 kW</td><td>about 16 hours</td></tr>
<tr><td>Heavy duty socket, the cable that came with the car</td><td>3.5 kW</td><td>about 10 hours</td></tr>
<tr><td>Single phase wallbox</td><td>7.4 kW</td><td>about 5 hours</td></tr>
<tr><td>Three phase wallbox</td><td>11 kW</td><td>about 3 hours 20 minutes</td></tr>
<tr><td>Three phase wallbox</td><td>22 kW</td><td>about 1 hour 40 minutes</td></tr>
</tbody></table></div>
<p>A night is eight hours. As the table shows, a 7 kW unit fills almost any battery in that window. That, and not the absence of anything stronger, is why 7.4 kW is the usual home choice.</p>

<h2>How much your car can actually take</h2>
<p>Before buying anything, check one number: how many kilowatts your car accepts on AC. That is a limit of its onboard charger and no wallbox can raise it.</p>
<p>Many models stop at 7.4 kW, some take 11, and 22 is rare. If your car stops at 7.4, a 22 kW wallbox will still give it 7.4. You would be paying for capacity you can never use.</p>
<p>The same goes for phases. A three phase charger needs a three phase supply. On a single phase supply it simply runs on one phase and gives you 7.4 kW.</p>

<h2>A house and a flat are two different projects</h2>
<p>In a house it is straightforward. The meter is yours, the parking is yours, the cable run is short and three phase is often already there. Installing a charger is ordinary electrical work.</p>
<p>In a flat there are three separate obstacles, each solved on its own.</p>
<ul>
<li><strong>Who owns the parking.</strong> Yards and underground car parks are normally common property. Fixing a unit to the wall and running cable through shared space needs the owners' association to agree. That is the first step, not the last.</li>
<li><strong>Separate metering.</strong> Wired into a communal circuit, your charging appears on everyone's bill. You need a dedicated run from your own meter, or a separate meter for the charger.</li>
<li><strong>What the building can spare.</strong> Older blocks frequently have no headroom at the supply point at all. Then the job starts with a capacity increase, which is a formal service from the distribution company and begins with an application.</li>
</ul>
<p>Of the three, the last is what stops most projects. So before choosing a unit, find out how many amps your meter is rated for and how much of that the flat already uses.</p>

<h2>What to insist on from the electrician</h2>
<p>A charger is the only appliance in a home that runs at full load for hours. Ordinary domestic wiring is not designed for that.</p>
<ul>
<li><strong>A dedicated run from the meter.</strong> Not spliced into an existing socket circuit, not off the kitchen ring, not through an added outlet. Its own cable and its own breaker.</li>
<li><strong>Cable sized for the current.</strong> Two things set the cross section: the charger's current and the distance. A long run needs thicker cable for the same current. This is the worst possible place to economise.</li>
<li><strong>Residual current protection that sees DC.</strong> A standard RCD cannot detect a DC leakage fault, and a charger is exactly where one can appear. You need a type B device, or a charger with that protection built in.</li>
<li><strong>Real earthing.</strong> In older Tbilisi blocks the protective earth is often absent, or bonded to neutral. On such a supply a charger either refuses to start or starts and runs unprotected. Treat it as something to verify, not to assume.</li>
<li><strong>Adjustable current.</strong> A good charger lets you cap its maximum current in software. If the supply is weak, set a 7.4 kW unit to 3.7 and it will still fill the car overnight.</li>
</ul>

<h2>What drives the price</h2>
<p>The bill splits into four parts, and their weights differ wildly.</p>
<ul>
<li><strong>The charger itself.</strong> The most predictable line. A plain unit and a screened, app controlled one differ several times over while doing functionally the same job.</li>
<li><strong>Cable and the run.</strong> This is where the uncertainty hides. Five metres along a wall and forty metres across an underground car park are not the same work.</li>
<li><strong>Protective gear and the board.</strong> Breaker, residual current device, and a separate meter if you need one.</li>
<li><strong>Capacity increase.</strong> This line is either absent entirely or the largest one on the page, depending on what headroom your supply has.</li>
</ul>
<p>We deliberately publish no figures. Hardware prices move, installation is quoted case by case, and the same charger can cost three times as much to fit in two different flats. What you do have is the four lines that should appear on the quote. If an electrician gives you a single number, ask for it broken down.</p>

<h2>Do you even need one</h2>
<p>This is the question asked least often. Driving 50 km a day uses roughly 9 kWh. An ordinary socket replaces that in four hours. In that case a wallbox buys speed you have no use for.</p>
<p>It starts to make sense above about 150 km a day, if the car is only home for a few hours at a time, or if there are two EVs in the household.</p>
<p>The money side is simple arithmetic. The median public AC tariff is ${N.acMed.toFixed(2)} GEL per kWh and the median DC tariff is ${N.dcMed.toFixed(2)}. Your home tariff is lower than both, and the exact figure belongs on your own bill, because it is tiered and an EV will usually push you into the top band. Multiply the difference per kWh by the kilowatt hours you use in a month and you have the saving.</p>

<h2>What not to do</h2>
<ul>
<li><strong>Extension leads.</strong> An ordinary extension lead is not rated for 10 amps for hours on end, and it gets hot. If you charge from a socket, plug straight into it.</li>
<li><strong>A shared socket.</strong> Anything that also feeds a water heater or a fan heater is not a charging point.</li>
<li><strong>An unprotected outdoor socket.</strong> Connecting outside needs weather protection and a socket rated for it.</li>
<li><strong>Maximum current on old wiring.</strong> If the cable is old, turn the current down in the charger rather than hoping.</li>
</ul>
<p>What AC and DC mean, and why slow charging takes as long as it does, is covered separately in <a href="/en/blog/ac-da-dc/">AC or DC</a>. Public tariffs are on the <a href="/en/tariffs/">tariffs page</a>.</p>
`,
      faq: [
        ['How long does it take to charge an EV from a household socket?',
          'An ordinary socket delivers about 2.3 kW. Taking a 60 kWh battery from 20 to 80 percent takes roughly 16 hours on it. A normal day of driving, around 9 kWh, goes back in about four.',
        ],
        ['Can I install a charger at a flat?',
          'You can, but three conditions have to be met: the owners’ association has to agree to the parking space, you need a dedicated run from your own meter, and the supply has to have spare capacity. All three are solvable, though the third is what stops most projects.',
        ],
        ['Is a three phase charger better than single phase?',
          'Only if you actually have a three phase supply and a car that accepts 11 or 22 kW. On a single phase supply a three phase unit gives you the same 7.4 kW a single phase one would.',
        ],
      ],
    },
  },

  {
    slug: '100-km-fasi',
    ka: {
      title: 'ელექტრომობილი თუ ბენზინი: 100 კილომეტრის რეალური ღირებულება',
      metaTitle: '100 კილომეტრი ელექტრომობილით და ბენზინით',
      desc: `100 კილომეტრი სწრაფ დამტენზე ${(18 * N.dcMed).toFixed(2)} ლარია, ბენზინის მანქანით კი ${(8 * F.regular.med).toFixed(2)}. სად ჩერდება ეს სხვაობა და რა არ შედის ამ ანგარიშში.`,
      key: [
        `მოკლე პასუხი: 100 კილომეტრი ელექტრომობილით საჯარო სწრაფ დამტენზე დაახლოებით ${(18 * N.dcMed).toFixed(2)} ლარია, ნელ დამტენზე ${(18 * N.acMed).toFixed(2)}. იმავე გზას ბენზინის მანქანა რვალიტრიანი ხარჯით ${(8 * F.regular.med).toFixed(2)} ლარად გადის.`,
        `ანუ ყველაზე ძვირ საჯარო დატენვაზეც ელექტრომობილი ბენზინზე დაახლოებით ${((8 * F.regular.med) / (18 * N.dcMed)).toFixed(1).replace(/\.0$/, '')}-ჯერ იაფია. სახლში დატენვისას სხვაობა კიდევ ორჯერ იზრდება.`,
      ],
      body: `
<h2>საიდან მოდის ეს ციფრები</h2>
<p>ორი მხარე ორი სხვადასხვა წყაროდან მოდის და ორივე შემოწმებადია.</p>
<p>დატენვის ტარიფი საქართველოს ${N.total} საჯარო დამტენის კატალოგის მედიანაა: სწრაფ DC დამტენზე ${N.dcMed.toFixed(2)} ლარი კილოვატსაათზე, ნელ AC დამტენზე ${N.acMed.toFixed(2)}. ეს იგივე მონაცემია, რომელზეც აპლიკაცია მუშაობს.</p>
<p>საწვავის ფასი საქართველოს ${F.regular.n} ქსელის მედიანაა და ${F.checked}-ის მდგომარეობითაა აღებული: რეგულარი ${F.regular.med.toFixed(2)} ლარი ლიტრზე, დიზელი ${F.diesel.med.toFixed(2)}. მედიანა იმიტომ, რომ ქვეყანაში ყველაზე იაფი გასამართი სადგური არ არის ის, სადაც ჩვეულებრივი მძღოლი ამართავს.</p>
<p>ხარჯად აღებულია 18 კილოვატსაათი 100 კილომეტრზე ელექტრომობილისთვის და 8 ლიტრი ბენზინის მანქანისთვის. ეს საშუალო ციფრებია შერეულ რეჟიმში.</p>

<h2>100 კილომეტრის ღირებულება</h2>
<div class="tw"><table>
<thead><tr><th>როგორ ივსება</th><th>ხარჯი 100 კმ-ზე</th><th>ტარიფი</th><th>ღირებულება</th></tr></thead>
<tbody>
<tr><td>სახლში, მაგალითისთვის აღებულ ტარიფზე</td><td>18 kWh</td><td>0.25 ₾</td><td><strong>4.50 ₾</strong></td></tr>
<tr><td>საჯარო ნელი AC დამტენი</td><td>18 kWh</td><td>${N.acMed.toFixed(2)} ₾</td><td><strong>${(18 * N.acMed).toFixed(2)} ₾</strong></td></tr>
<tr><td>საჯარო სწრაფი DC დამტენი</td><td>18 kWh</td><td>${N.dcMed.toFixed(2)} ₾</td><td><strong>${(18 * N.dcMed).toFixed(2)} ₾</strong></td></tr>
<tr><td>ბენზინი, ეკონომიური მანქანა</td><td>6 ლ</td><td>${F.regular.med.toFixed(2)} ₾</td><td><strong>${(6 * F.regular.med).toFixed(2)} ₾</strong></td></tr>
<tr><td>ბენზინი, საშუალო მანქანა</td><td>8 ლ</td><td>${F.regular.med.toFixed(2)} ₾</td><td><strong>${(8 * F.regular.med).toFixed(2)} ₾</strong></td></tr>
<tr><td>ბენზინი, ჯიპი ან ქალაქის საცობი</td><td>11 ლ</td><td>${F.regular.med.toFixed(2)} ₾</td><td><strong>${(11 * F.regular.med).toFixed(2)} ₾</strong></td></tr>
<tr><td>დიზელი</td><td>6 ლ</td><td>${F.diesel.med.toFixed(2)} ₾</td><td><strong>${(6 * F.diesel.med).toFixed(2)} ₾</strong></td></tr>
</tbody></table></div>
<p>სახლის ხაზში 0.25 ლარი მაგალითია და არა ციტირებული ტარიფი. საყოფაცხოვრებო ტარიფი საფეხურებრივია და ელექტრომობილი ჩვეულებრივ ზედა საფეხურზე გადაგიყვანთ, ამიტომ ზუსტი ციფრი თქვენივე ქვითრიდან აიღეთ და 18-ზე გაამრავლეთ.</p>
<p>თქვენს ბატარეაზე და თქვენს ტარიფზე იგივე გამოთვლა <a href="/kalkulatori/">კალკულატორში</a> ორ წამში კეთდება.</p>

<h2>რა ცვლის ამ სურათს</h2>
<ul>
<li><strong>ზამთარი.</strong> ცივ ამინდში ელექტრომობილის ხარჯი 20-დან 35 პროცენტამდე იზრდება, ანუ 18 კილოვატსაათი 23-მდე ადის. ბენზინის მანქანაც უარესდება ზამთარში, მაგრამ ნაკლებად. სხვაობა ზამთარში იკლებს, თუმცა არ ქრება.</li>
<li><strong>ქალაქი და ტრასა.</strong> აქ პირიქითაა. საცობში ბენზინის მანქანა ლიტრებს წვავს, ელექტრომობილი კი თითქმის არაფერს ხარჯავს და დამუხრუჭებისას ენერგიის ნაწილს იბრუნებს. ქალაქში სხვაობა ყველაზე დიდია.</li>
<li><strong>რამდენად სავსე ბატარეიდან ტენით.</strong> ღირებულებაზე არ მოქმედებს, დროზე კი მოქმედებს. 80 პროცენტის შემდეგ სწრაფი დამტენი მკვეთრად ანელებს.</li>
<li><strong>უფასო დატენვა.</strong> საქართველოს ${N.total} დამტენიდან ნაწილი სასტუმროებისა და სავაჭრო ცენტრების დამტენია, სადაც კლიენტისთვის დატენვა ხშირად უფასოა. ეს ცხრილში არ არის.</li>
</ul>

<h2>რა არ შედის ამ ანგარიშში</h2>
<p>საწვავი მთელი ხარჯი არ არის და ამის თქმა პატიოსანია.</p>
<ul>
<li><strong>მომსახურება.</strong> ელექტრომობილს ზეთი, ფილტრები, სანთლები და გამონაბოლქვის სისტემა არ აქვს. სამუხრუჭე ხუნდები ბევრად ნელა ცვდება, რადგან შენელების დიდ ნაწილს ძრავა აკეთებს.</li>
<li><strong>საბურავები.</strong> პირიქით, ელექტრომობილი უფრო მძიმეა და საბურავი უფრო სწრაფად ცვდება.</li>
<li><strong>ბატარეა.</strong> გრძელვადიან ხარჯში ბატარეის ცვეთა შედის. ეს ცალკე თემაა და <a href="/blog/batarea/">ცალკე გვაქვს გარჩეული</a>.</li>
<li><strong>განბაჟება.</strong> აქ ელექტრომობილს დიდი უპირატესობა აქვს: აქციზი და იმპორტის გადასახადი ნულია. <a href="/ganbajeba/">ციფრები და შედარება</a>.</li>
</ul>

<h2>როდის არ იხდის თავს</h2>
<p>ორი შემთხვევაა, როცა ეს ანგარიში აღარ მუშაობს.</p>
<p>პირველი: თუ წელიწადში 5000 კილომეტრზე ნაკლებს გადიხართ. საწვავზე დანაზოგი ამ დროს იმდენად მცირეა, რომ მანქანის ფასის სხვაობას ვერასოდეს დაფარავს.</p>
<p>მეორე: თუ სახლში დატენვის საშუალება საერთოდ არ გაქვთ და მხოლოდ სწრაფ დამტენს იყენებთ. ${(18 * N.dcMed).toFixed(2)} ლარი ასი კილომეტრისთვის ჯერ კიდევ ბენზინზე იაფია, მაგრამ სახლის ტარიფთან შედარებით სამჯერ ძვირი. ბინაში მცხოვრებმა ეს წინასწარ უნდა გაითვალისწინოს, სანამ ელექტრომობილს იყიდის. <a href="/blog/sakhlis-damteni/">სახლის დამტენის ვარიანტები</a> ცალკე გვაქვს აღწერილი.</p>
`,
      faq: [
        ['რამდენი ჯდება 100 კილომეტრი ელექტრომობილით საქართველოში?',
          `საჯარო სწრაფ DC დამტენზე დაახლოებით ${(18 * N.dcMed).toFixed(2)} ლარი, ნელ AC დამტენზე ${(18 * N.acMed).toFixed(2)}, სახლში კი ჩვეულებრივ 5 ლარამდე. გამოთვლა 18 კილოვატსაათია 100 კილომეტრზე და საქართველოს დამტენების მედიანური ტარიფი.`],
        ['რამდენად იაფია ელექტრომობილი ბენზინზე?',
          `100 კილომეტრი რვალიტრიანი ბენზინის მანქანით ${(8 * F.regular.med).toFixed(2)} ლარია, ელექტრომობილით სწრაფ დამტენზე ${(18 * N.dcMed).toFixed(2)}. ანუ დაახლოებით ${((8 * F.regular.med) / (18 * N.dcMed)).toFixed(1).replace(/\.0$/, '')}-ჯერ იაფი. სახლში დატენვისას სხვაობა კიდევ იზრდება.`],
        ['ზამთარში რჩება თუ არა ელექტრომობილი უფრო იაფი?',
          'რჩება. ცივ ამინდში ხარჯი 20-დან 35 პროცენტამდე იზრდება, ანუ 100 კილომეტრი დაახლოებით მესამედით ძვირდება. ბენზინის მანქანასთან სხვაობა მცირდება, მაგრამ არ ქრება.'],
      ],
    },
    en: {
      title: 'Electric or petrol: what 100 km actually costs in Georgia',
      metaTitle: 'Cost per 100 km: electric versus petrol',
      desc: `100 km on a fast charger is ${(18 * N.dcMed).toFixed(2)} GEL against ${(8 * F.regular.med).toFixed(2)} on petrol. Where that gap comes from and what the calculation leaves out.`,
      key: [
        `Short answer: 100 km in an EV costs about ${(18 * N.dcMed).toFixed(2)} GEL on a public fast charger and ${(18 * N.acMed).toFixed(2)} on a slow one. The same distance in a petrol car using 8 litres costs ${(8 * F.regular.med).toFixed(2)}.`,
        `So even on the most expensive public charging, an EV is roughly ${((8 * F.regular.med) / (18 * N.dcMed)).toFixed(1).replace(/\.0$/, '')} times cheaper. Charge at home and the gap roughly doubles again.`,
      ],
      body: `
<h2>Where these numbers come from</h2>
<p>The two sides come from two different sources and both can be checked.</p>
<p>The charging tariff is the median of Georgia's catalogue of ${N.total} public chargers: ${N.dcMed.toFixed(2)} GEL per kWh on fast DC and ${N.acMed.toFixed(2)} on slow AC. It is the same data the app runs on.</p>
<p>The fuel price is the median across Georgia's ${F.regular.n} chains as of ${F.checked}: regular at ${F.regular.med.toFixed(2)} GEL a litre and diesel at ${F.diesel.med.toFixed(2)}. The median, because the cheapest station in the country is not where an ordinary driver fills up.</p>
<p>Consumption is taken as 18 kWh per 100 km for the EV and 8 litres for the petrol car, both mixed driving averages.</p>

<h2>What 100 km costs</h2>
<div class="tw"><table>
<thead><tr><th>How it is filled</th><th>Per 100 km</th><th>Tariff</th><th>Cost</th></tr></thead>
<tbody>
<tr><td>At home, at an illustrative tariff</td><td>18 kWh</td><td>0.25 GEL</td><td><strong>4.50 GEL</strong></td></tr>
<tr><td>Public slow AC charger</td><td>18 kWh</td><td>${N.acMed.toFixed(2)} GEL</td><td><strong>${(18 * N.acMed).toFixed(2)} GEL</strong></td></tr>
<tr><td>Public fast DC charger</td><td>18 kWh</td><td>${N.dcMed.toFixed(2)} GEL</td><td><strong>${(18 * N.dcMed).toFixed(2)} GEL</strong></td></tr>
<tr><td>Petrol, economical car</td><td>6 L</td><td>${F.regular.med.toFixed(2)} GEL</td><td><strong>${(6 * F.regular.med).toFixed(2)} GEL</strong></td></tr>
<tr><td>Petrol, mid size car</td><td>8 L</td><td>${F.regular.med.toFixed(2)} GEL</td><td><strong>${(8 * F.regular.med).toFixed(2)} GEL</strong></td></tr>
<tr><td>Petrol, SUV or heavy city traffic</td><td>11 L</td><td>${F.regular.med.toFixed(2)} GEL</td><td><strong>${(11 * F.regular.med).toFixed(2)} GEL</strong></td></tr>
<tr><td>Diesel</td><td>6 L</td><td>${F.diesel.med.toFixed(2)} GEL</td><td><strong>${(6 * F.diesel.med).toFixed(2)} GEL</strong></td></tr>
</tbody></table></div>
<p>The 0.25 GEL on the home row is an illustration, not a quoted tariff. Household electricity is tiered and an EV will normally push you into the top band, so take the exact figure from your own bill and multiply it by 18.</p>
<p>For your battery and your tariff, the same sum takes two seconds in the <a href="/en/calculator/">calculator</a>.</p>

<h2>What changes the picture</h2>
<ul>
<li><strong>Winter.</strong> In cold weather an EV uses 20 to 35 percent more, so 18 kWh becomes about 23. Petrol cars also get worse in winter, but less so. The gap narrows without closing.</li>
<li><strong>City against highway.</strong> Here it works the other way. In traffic a petrol car burns litres while an EV uses almost nothing and recovers part of what it does use when braking. The gap is widest in town.</li>
<li><strong>How full the battery is.</strong> It does not change the cost, only the time. Above 80 percent a fast charger slows down sharply.</li>
<li><strong>Free charging.</strong> Some of Georgia's ${N.total} chargers belong to hotels and shopping centres, where charging is often free for customers. None of that is in the table.</li>
</ul>

<h2>What this calculation leaves out</h2>
<p>Fuel is not the whole cost, and it is only honest to say so.</p>
<ul>
<li><strong>Servicing.</strong> An EV has no oil, filters, plugs or exhaust. Brake pads last far longer because the motor does most of the slowing.</li>
<li><strong>Tyres.</strong> The other way round: an EV is heavier and goes through tyres faster.</li>
<li><strong>The battery.</strong> Pack wear belongs in any long term figure. That is its own subject and has <a href="/en/blog/batarea/">its own guide</a>.</li>
<li><strong>Import duty.</strong> Here the EV has a large advantage: excise and import duty are both zero. <a href="/en/customs/">The figures and the comparison</a>.</li>
</ul>

<h2>When it does not pay off</h2>
<p>There are two cases where this arithmetic stops working.</p>
<p>First, if you drive less than 5000 km a year. The fuel saving is then so small that it never covers the difference in purchase price.</p>
<p>Second, if you have no way to charge at home and use only fast chargers. At ${(18 * N.dcMed).toFixed(2)} GEL per 100 km that is still cheaper than petrol, but three times what home charging costs. Anyone living in a flat should work that out before buying, not after. The options are covered in <a href="/en/blog/sakhlis-damteni/">home charger installation</a>.</p>
`,
      faq: [
        ['How much does 100 km cost in an electric car in Georgia?',
          `About ${(18 * N.dcMed).toFixed(2)} GEL on a public fast DC charger, ${(18 * N.acMed).toFixed(2)} on a slow AC one, and usually under 5 GEL at home. The figures assume 18 kWh per 100 km and the median tariffs across Georgia's chargers.`],
        ['How much cheaper is an EV than petrol?',
          `100 km in a petrol car using 8 litres costs ${(8 * F.regular.med).toFixed(2)} GEL, against ${(18 * N.dcMed).toFixed(2)} in an EV on a fast charger, roughly ${((8 * F.regular.med) / (18 * N.dcMed)).toFixed(1).replace(/\.0$/, '')} times less. Charging at home widens the gap further.`],
        ['Is an EV still cheaper in winter?',
          'Yes. Cold weather raises consumption by 20 to 35 percent, so 100 km costs about a third more. The gap against petrol narrows but does not close.'],
      ],
    },
  },

  {
    slug: 'batarea',
    ka: {
      title: 'ბატარეის დეგრადაცია: რა ხდება რეალურად და რას ნიშნავს ეს საქართველოში',
      metaTitle: 'ელექტრომობილის ბატარეის დეგრადაცია',
      desc: 'ბატარეა წელიწადში დაახლოებით 1-2 პროცენტს კარგავს. რატომ არის საქართველოს სიცხე და ბინაში ცხოვრება ორი მთავარი რისკი და რა შეამოწმოთ მეორადი მანქანის ყიდვისას.',
      key: [
        'მოკლე პასუხი: თანამედროვე ელექტრომობილის ბატარეა წელიწადში დაახლოებით 1-დან 2 პროცენტამდე კარგავს და რვა წელში ჩვეულებრივ 85-დან 90 პროცენტამდე რჩება. ეს ჩვეულებრივი ცვეთაა და არა გაუმართაობა.',
        'საქართველოში ორი გარემოება აჩქარებს ამ პროცესს: ზაფხულის სიცხე ქვემო ქართლსა და კახეთში, და ის, რომ ბინაში მცხოვრები მძღოლების უმეტესობა თითქმის მხოლოდ სწრაფ დამტენს იყენებს.',
      ],
      body: `
<h2>რას ნიშნავს დეგრადაცია</h2>
<p>ბატარეის ჯანმრთელობა იზომება იმით, თუ დღეს რამდენ ენერგიას იტევს ის ქარხნულთან შედარებით. თუ 60 კილოვატსაათიანი ბატარეა ახლა 54-ს იტევს, მისი მდგომარეობა 90 პროცენტია.</p>
<p>პრაქტიკულად ეს ნიშნავს, რომ გარბენი პროპორციულად მცირდება და მეტი არაფერი. მანქანა არ უფუჭდება, სიმძლავრეს არ კარგავს და უცებ არ ჩერდება. უბრალოდ სავსე ბატარეით უფრო ნაკლებ კილომეტრს გადის, ვიდრე ახალი.</p>
<p>მთავარი გასაგები ისაა, რომ დეგრადაცია ხაზოვანი არ არის. პირველ წელს ვარდნა ყველაზე შესამჩნევია, დაახლოებით 3-დან 5 პროცენტამდე, შემდეგ კი მრუდი ბრტყელდება და წელიწადში ერთ ან ორ პროცენტს აღწევს. ვინც პირველი წლის შემდეგ პანიკაში ვარდება, ჩვეულებრივ სწორედ ამ მრუდის ფორმას არ იცნობს.</p>

<h2>ორი სხვადასხვა ცვეთა</h2>
<p>ბატარეა ორი დამოუკიდებელი მიზეზით ცვდება და ისინი ერთმანეთს ემატება.</p>
<p><strong>კალენდარული ცვეთა</strong> უბრალოდ დროზეა დამოკიდებული. ბატარეა ცვდება მაშინაც, როცა მანქანა გარაჟში დგას. ამ ცვეთას აჩქარებს ორი რამ: მაღალი ტემპერატურა და მაღალი მუხტის დონე. სავსე ბატარეა ცხელ დღეს იმაზე ბევრად სწრაფად ბერდება, ვიდრე ნახევრად სავსე გრილში.</p>
<p><strong>ციკლური ცვეთა</strong> გარბენზეა დამოკიდებული, ანუ იმაზე, რამდენჯერ დაცალეთ და აავსეთ ბატარეა.</p>
<p>საქართველოში მძღოლების უმეტესობისთვის პირველი უფრო მნიშვნელოვანია, ვიდრე მეორე. წლიური გარბენი აქ ჩვეულებრივ დაბალია, ზაფხულის ტემპერატურა კი მაღალი. ანუ თქვენი ბატარეა უფრო კალენდრისგან ცვდება, ვიდრე ტარებისგან.</p>

<h2>რატომ არის საქართველო განსაკუთრებული შემთხვევა</h2>
<p>ზოგადი რჩევები დეგრადაციაზე ევროპისა და ამერიკის პირობებზეა დაწერილი. აქ ორი განსხვავებაა და ორივე მნიშვნელოვანია.</p>
<h3>სიცხე და ბატარეის გაგრილება</h3>
<p>თანამედროვე ელექტრომობილების უმეტესობას ბატარეის თხევადი გაგრილება აქვს. ასეთი მანქანისთვის თბილისის ან რუსთავის ზაფხული პრობლემა არ არის.</p>
<p>პრობლემა იმ მოდელებთანაა, სადაც ბატარეა მხოლოდ ჰაერით გრილდება. ყველაზე ცნობილი მაგალითი პირველი და მეორე თაობის Nissan Leaf-ია, რომელიც საქართველოში ერთ-ერთი ყველაზე გავრცელებული ელექტრომობილია. ასეთი მანქანა აგვისტოში მზეზე გაჩერებული მთელი დღე მაღალ ტემპერატურაზე რჩება და ბატარეას გაგრილების საშუალება არ აქვს. სწორედ ამიტომ ცვდება ცხელ კლიმატში ჩამოსული Leaf-ები იმაზე ბევრად სწრაფად, ვიდრე ჩრდილოეთ ევროპაში მოსიარულე იგივე მანქანა.</p>
<p>ეს არ ნიშნავს, რომ ასეთი მანქანა არ უნდა იყიდოთ. ნიშნავს, რომ მისი ბატარეის მდგომარეობა ყიდვამდე უნდა შეამოწმოთ და ჩრდილში დგომას მნიშვნელობა უნდა მიანიჭოთ.</p>
<h3>სწრაფი დატენვის წილი</h3>
<p>დასავლეთში ელექტრომობილის მფლობელების უმეტესობა სახლში ტენის და სწრაფ დამტენს მხოლოდ მგზავრობისას იყენებს. თბილისში პირიქითაა: მძღოლების დიდი ნაწილი ბინაში ცხოვრობს, სახლის დამტენი არ აქვს და თითქმის მთელ ენერგიას საჯარო DC დამტენიდან იღებს.</p>
<p>ცალკე აღებული, ერთი სწრაფი დატენვა ბატარეას არ აზიანებს. მაგრამ როცა ეს წლების განმავლობაში ერთადერთი მეთოდია, განსაკუთრებით გაუგრილებელ ბატარეაზე და ზაფხულში, ეფექტი გროვდება. თუ სახლში დატენვის მოწყობის საშუალება გაქვთ, ეს ბატარეისთვისაც სასარგებლოა და არა მხოლოდ ჯიბისთვის. <a href="/blog/sakhlis-damteni/">რა სჭირდება სახლის დამტენს</a>.</p>
<h3>მთა</h3>
<p>გუდაურის ან ყაზბეგის მიმართულება ბატარეისთვის საშიში არ არის. ასვლაზე ხარჯი დიდია, დაშვებაზე კი ენერგიის ნაწილი ბრუნდება. ეს ჩვეულებრივი რეჟიმია და დამატებით ცვეთას არ იწვევს. სიმაღლეც პრობლემა არ არის.</p>

<h2>რა შეამოწმოთ მეორადი მანქანის ყიდვისას</h2>
<p>ელექტრომობილზე გარბენი ბევრად ნაკლებს ამბობს, ვიდრე ბენზინის მანქანაზე. მთავარი ციფრი ბატარეის მდგომარეობაა.</p>
<ul>
<li><strong>მოითხოვეთ ბატარეის ჯანმრთელობის ჩვენება.</strong> ეს პროცენტული ციფრია და დიაგნოსტიკური აპარატით ან სპეციალური აპლიკაციით იკითხება. თუ გამყიდველი ამის ჩვენებაზე უარს ამბობს, ეს თავისთავად პასუხია.</li>
<li><strong>Leaf-ზე შეხედეთ ჯანმრთელობის ზოლებს და სწრაფი დატენვების რაოდენობას.</strong> ეს მანქანა ორივეს პირდაპირ აჩვენებს და შედარებით ადვილად იკითხება.</li>
<li><strong>სავსე ბატარეაზე ნაჩვენებ გარბენს ნუ დაუჯერებთ.</strong> ეს ციფრი ბოლო მგზავრობების ხარჯზეა გათვლილი და ადვილად შეიძლება მოტყუებით გამოიყურებოდეს. რეალურ სურათს მხოლოდ ჯანმრთელობის ჩვენება იძლევა.</li>
<li><strong>იკითხეთ, სად იდგა მანქანა.</strong> ცხელი ქვეყნიდან ჩამოსული, გაუგრილებელი ბატარეის მქონე მანქანა და იმავე წლის ჩრდილოეთიდან ჩამოსული მანქანა ერთი და იგივე არ არის.</li>
<li><strong>დაათვალიერეთ ნებისმიერი შეკეთების ისტორია.</strong> უკვე შეცვლილი ბატარეა ცუდი ამბავი არ არის, პირიქით.</li>
</ul>
<p>საიდან და როგორ შემოდის საქართველოში ეს მანქანები, ცალკე გვაქვს აღწერილი: <a href="/blog/amerikuli-importi/">ამერიკული იმპორტი</a> და <a href="/blog/chinuri-importi/">ჩინური იმპორტი</a>.</p>

<h2>რას ფარავს გარანტია</h2>
<p>მწარმოებლები ბატარეაზე ჩვეულებრივ რვაწლიან ან 160 000 კილომეტრიან გარანტიას იძლევიან და ის მოქმედებს მაშინ, თუ ბატარეის მდგომარეობა დადგენილ ზღვარზე, ხშირად 70 პროცენტზე, ქვემოთ ჩავარდა.</p>
<p>ორი რამ უნდა გაითვალისწინოთ. პირველი: ეს ზღვარი დაბალია. 75 პროცენტიანი ბატარეა გარანტიაში არ ხვდება, თუმცა გარბენი უკვე მკვეთრად შემცირებულია. მეორე: კერძოდ შემოყვანილ მანქანაზე გარანტია იმ ბაზრისაა, სადაც ის თავდაპირველად გაიყიდა, და საქართველოში მისი გამოყენება ხშირად ვერ ხერხდება. ყიდვამდე ეს ცალკე დააზუსტეთ და ნუ ჩათვლით ნაგულისხმევად.</p>

<h2>როგორ გავახანგრძლივოთ</h2>
<ul>
<li><strong>ყოველდღიურად 20-დან 80 პროცენტამდე.</strong> სავსე ბატარეა ყველაზე სწრაფად ბერდება. 100 პროცენტამდე მაშინ დატენეთ, როცა შორ გზაზე მიდიხართ.</li>
<li><strong>დიდხანს არ დატოვოთ სავსე ან თითქმის ცარიელი.</strong> თუ მანქანა კვირებით ჩერდება, დაახლოებით ნახევრად სავსე დატოვეთ.</li>
<li><strong>ზაფხულში ჩრდილში გააჩერეთ.</strong> გაუგრილებელი ბატარეისთვის ეს ყველაზე ეფექტური და ყველაზე იაფი ზომაა.</li>
<li><strong>სადაც შეგიძლიათ, ნელა დატენეთ.</strong> ეს არ ნიშნავს სწრაფ დამტენზე უარის თქმას. ნიშნავს, რომ როცა ორივე ხელმისაწვდომია, ნელი ჯობია.</li>
<li><strong>ცივი ბატარეა ჯერ გაათბეთ.</strong> თუ მანქანას ბატარეის წინასწარი გახურების ფუნქცია აქვს, ზამთარში სწრაფ დამტენამდე ჩართეთ.</li>
</ul>

<h2>რა არ არის პრობლემა</h2>
<p>ბევრი შიში უსაფუძვლოა და მათზე ენერგიის დახარჯვა არ ღირს.</p>
<ul>
<li><strong>ერთეული სრული დატენვა.</strong> შორ გზაზე 100 პროცენტამდე დატენვა ჩვეულებრივი რამაა.</li>
<li><strong>სიცივე.</strong> ზამთარში გარბენის დაცემა დროებითია და გაზაფხულზე ბრუნდება. ეს დეგრადაცია არ არის.</li>
<li><strong>რეკუპერაცია.</strong> დამუხრუჭებისას ენერგიის დაბრუნება ბატარეას არ ტვირთავს.</li>
<li><strong>მანქანის ყოველდღიური გამოყენება.</strong> გაჩერებული ელექტრომობილი უფრო ცუდად გრძნობს თავს, ვიდრე მოსიარულე.</li>
</ul>
`,
      faq: [
        ['რამდენ ხანს ძლებს ელექტრომობილის ბატარეა?',
          'თანამედროვე ბატარეა წელიწადში დაახლოებით 1-დან 2 პროცენტამდე კარგავს და რვა წელში ჩვეულებრივ 85-დან 90 პროცენტამდე რჩება. პირველ წელს ვარდნა უფრო შესამჩნევია, დაახლოებით 3-დან 5 პროცენტამდე, შემდეგ კი მრუდი ბრტყელდება.'],
        ['აზიანებს თუ არა სწრაფი დატენვა ბატარეას?',
          'ცალკე აღებული დატენვა არა. პრობლემა მაშინ ჩნდება, როცა სწრაფი დამტენი წლების განმავლობაში ერთადერთი მეთოდია, განსაკუთრებით ისეთ მანქანაზე, სადაც ბატარეის თხევადი გაგრილება არ არის, და ცხელ ამინდში.'],
        ['რა შევამოწმო მეორადი ელექტრომობილის ყიდვისას?',
          'ბატარეის ჯანმრთელობის პროცენტული მაჩვენებელი, დიაგნოსტიკური აპარატით წაკითხული. გარბენი და სავსე ბატარეაზე ნაჩვენები კილომეტრები საკმარისი არ არის. ასევე იკითხეთ, რომელი ქვეყნიდან ჩამოვიდა მანქანა, რადგან ცხელ კლიმატში გატარებული წლები გაუგრილებელ ბატარეაზე შესამჩნევად აისახება.'],
      ],
    },
    en: {
      title: 'Battery degradation: what actually happens, and what it means in Georgia',
      metaTitle: 'EV battery degradation',
      desc: 'A battery loses roughly 1 to 2 percent a year. Why Georgian summers and living in a flat are the two real risks here, and what to check when buying used.',
      key: [
        'Short answer: a modern EV battery loses roughly 1 to 2 percent a year and is usually at 85 to 90 percent after eight years. That is normal wear, not a fault.',
        'Two things accelerate it in Georgia: summer heat in Kvemo Kartli and Kakheti, and the fact that most drivers living in flats charge almost exclusively on fast chargers.',
      ],
      body: `
<h2>What degradation means</h2>
<p>Battery health is measured by how much energy the pack holds today against when it was new. A 60 kWh battery that now holds 54 is at 90 percent.</p>
<p>In practice that means range falls proportionally and nothing else. The car does not break down, does not lose power and does not stop without warning. It simply covers fewer kilometres on a full charge than it once did.</p>
<p>The important part is that degradation is not linear. The first year shows the steepest drop, roughly 3 to 5 percent, after which the curve flattens to one or two percent a year. People who panic after year one are usually just unfamiliar with the shape of that curve.</p>

<h2>Two different kinds of wear</h2>
<p>A battery ages for two independent reasons and they add up.</p>
<p><strong>Calendar ageing</strong> depends only on time. The pack ages while the car sits in a garage. Two things speed it up: high temperature and a high state of charge. A full battery on a hot day ages far faster than a half full one somewhere cool.</p>
<p><strong>Cycle ageing</strong> depends on distance, that is, on how many times you have emptied and refilled the pack.</p>
<p>For most drivers in Georgia the first matters more than the second. Annual mileage here is typically low and summer temperatures are high. Your battery is ageing more from the calendar than from being driven.</p>

<h2>Why Georgia is a particular case</h2>
<p>General advice on degradation is written for European and American conditions. Two differences matter here.</p>
<h3>Heat and battery cooling</h3>
<p>Most modern EVs cool the pack with liquid. For such a car a Tbilisi or Rustavi summer is not a problem.</p>
<p>The problem is models where the pack is only air cooled. The best known example is the first and second generation Nissan Leaf, one of the most common EVs in Georgia. Parked in the sun in August, such a car sits at high temperature all day with no way to cool the pack. That is why Leafs that have lived in hot climates degrade markedly faster than the same car driven in northern Europe.</p>
<p>None of that means you should not buy one. It means checking the pack before you buy, and taking shade seriously afterwards.</p>
<h3>The share of fast charging</h3>
<p>In the West most EV owners charge at home and use fast chargers on trips. In Tbilisi it is the other way round: a large share of drivers live in flats, have no home charger, and take almost all their energy from public DC.</p>
<p>Taken alone, one fast charge harms nothing. But when it is the only method for years, especially on an uncooled pack in summer, the effect accumulates. If you can arrange home charging, the battery benefits as much as your wallet does. <a href="/en/blog/sakhlis-damteni/">What a home charger needs</a>.</p>
<h3>The mountains</h3>
<p>The Gudauri and Kazbegi roads are not a threat to the battery. Climbing uses a lot and descending gives part of it back. That is ordinary operation and causes no extra wear. Altitude itself is not a problem either.</p>

<h2>What to check when buying used</h2>
<p>On an EV the odometer tells you far less than it does on a petrol car. The number that matters is battery health.</p>
<ul>
<li><strong>Ask to see the state of health.</strong> It is a percentage, read with a diagnostic tool or a dedicated app. A seller who will not show it has answered the question.</li>
<li><strong>On a Leaf, look at the health bars and the quick charge count.</strong> That car reports both directly and they are comparatively easy to read.</li>
<li><strong>Do not trust the range shown on a full charge.</strong> That figure is computed from recent consumption and can flatter the car badly. Only the health reading tells you the truth.</li>
<li><strong>Ask where the car has lived.</strong> An uncooled pack that spent years in a hot country and the same model year from the north are not the same car.</li>
<li><strong>Look at any repair history.</strong> A pack that has already been replaced is not bad news; it is the opposite.</li>
</ul>
<p>How these cars reach Georgia in the first place is covered separately: <a href="/en/blog/amerikuli-importi/">importing from America</a> and <a href="/en/blog/chinuri-importi/">importing from China</a>.</p>

<h2>What the warranty covers</h2>
<p>Manufacturers normally warrant the battery for eight years or 160,000 km, and it pays out only if health falls below a set threshold, frequently 70 percent.</p>
<p>Two things follow. First, that threshold is low: a pack at 75 percent is outside the warranty while range is already well down. Second, on a privately imported car the warranty belongs to the market where it was originally sold and often cannot be used in Georgia at all. Check that specifically before buying rather than assuming it.</p>

<h2>How to make it last</h2>
<ul>
<li><strong>Live between 20 and 80 percent.</strong> A full pack ages fastest. Charge to 100 when you are about to set off on a long trip.</li>
<li><strong>Do not leave it full or nearly empty for long.</strong> If the car will sit for weeks, leave it around half.</li>
<li><strong>Park in the shade in summer.</strong> For an uncooled pack this is the single most effective and cheapest measure there is.</li>
<li><strong>Charge slowly where you can.</strong> This is not an argument against fast charging. It means that when both are available, slow is kinder.</li>
<li><strong>Warm a cold pack first.</strong> If the car can precondition the battery, use it before a fast charger in winter.</li>
</ul>

<h2>What is not a problem</h2>
<p>Plenty of the worry is misplaced and not worth spending energy on.</p>
<ul>
<li><strong>The occasional full charge.</strong> Charging to 100 percent before a long drive is entirely ordinary.</li>
<li><strong>Cold.</strong> The winter drop in range is temporary and returns in spring. It is not degradation.</li>
<li><strong>Regenerative braking.</strong> Recovering energy while slowing does not stress the pack.</li>
<li><strong>Driving the car every day.</strong> A parked EV is worse off than a used one.</li>
</ul>
`,
      faq: [
        ['How long does an EV battery last?',
          'A modern pack loses roughly 1 to 2 percent a year and is usually at 85 to 90 percent after eight years. The first year is steeper, around 3 to 5 percent, after which the curve flattens.'],
        ['Does fast charging damage the battery?',
          'A single fast charge does not. The problem appears when fast charging is the only method for years, particularly on a car without liquid battery cooling and in hot weather.'],
        ['What should I check when buying a used EV?',
          'The battery state of health as a percentage, read with a diagnostic tool. Mileage and the range shown on a full charge are not enough. Also ask which country the car came from, because years spent in a hot climate show up clearly on an uncooled pack.'],
      ],
    },
  },
];

const L = {
  ka: { base: '', dir: 'blog', home: 'მთავარი', blog: 'სტატიები',
    idxTitle: 'სტატიები ელექტრომობილებზე', catalog: 'დამტენების სია', catalogHref: '/damtenebi/',
    idxDesc: 'პრაქტიკული გზამკვლევები ელექტრომობილის მფლობელებისთვის საქართველოში: დატენვის ფასი, კონექტორები, სწრაფი და ნელი დატენვა, შორი მგზავრობა.',
    idxIntro: 'მოკლე და პირდაპირი პასუხები კითხვებზე, რომლებიც ელექტრომობილის მფლობელს საქართველოში ყველაზე ხშირად უჩნდება. ყველა ციფრი აღებულია იმავე მონაცემებიდან, რაზეც აპლიკაცია მუშაობს.',
    faqH: 'ხშირად დასმული კითხვები', more: 'სხვა სტატიები', seeAlso: 'იხილეთ ასევე',
    related: [['დამტენების სია', '/damtenebi/'], ['ტარიფების შედარება', '/tarifebi/'],
      ['დატენვის კალკულატორი', '/kalkulatori/'], ['მარშრუტები', '/marshruti/'], ['ქსელები', '/qselebi/']],
    ctaTitle: 'იპოვე დამტენი ერთ აპლიკაციაში',
    ctaBody: 'საქართველოს ყველა ქსელი ერთ რუკაზე, ცოცხალი სტატუსით და მარშრუტის დაგეგმვით. უფასოდ.',
    play: 'ჩამოტვირთვა Google Play-დან', store: 'ჩამოტვირთვა App Store-დან' },
  en: { base: '/en', dir: 'blog', home: 'Home', blog: 'Guides',
    idxTitle: 'EV guides for Georgia', catalog: 'Charger list', catalogHref: '/en/chargers/',
    idxDesc: 'Practical guides for EV drivers in Georgia: charging costs, connectors, fast versus slow charging, and long distance trips.',
    idxIntro: 'Short, direct answers to the questions EV drivers in Georgia actually ask. Every figure comes from the same data the app runs on.',
    faqH: 'Frequently asked questions', more: 'More guides', seeAlso: 'See also',
    related: [['Charger list', '/en/chargers/'], ['Tariff comparison', '/en/tariffs/'],
      ['Charging cost calculator', '/en/calculator/'], ['Routes', '/en/routes/'], ['Networks', '/en/networks/']],
    ctaTitle: 'Find a charger in one app',
    ctaBody: 'Every network in Georgia on one map, with live status and route planning. Free.',
    play: 'Get it on Google Play', store: 'Download on the App Store' },
};

const esc = (s) => String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;')
  .replace(/>/g, '&gt;').replace(/"/g, '&quot;');

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

function articlePage(lang, art, ARTICLES) {
  const t = L[lang], a = art[lang];
  const o = L[lang === 'ka' ? 'en' : 'ka'];
  const url = `${ORIGIN}${t.base}/${t.dir}/${art.slug}/`;
  const alt = `${ORIGIN}${o.base}/${o.dir}/${art.slug}/`;
  const bc = [{ name: t.home, href: `${t.base}/` },
    { name: t.blog, href: `${t.base}/${t.dir}/` }, { name: a.title }];
  const others = ARTICLES.filter((x) => x.slug !== art.slug);

  const body = `${crumbs(bc)}
<div class="prose">
<h1>${esc(a.title)}</h1>
<p class="meta">${lang === 'ka' ? 'განახლდა 2026 წლის ივლისში' : 'Updated July 2026'}</p>
<div class="key">${a.key.map((k) => `<p>${esc(k)}</p>`).join('')}</div>
${a.body.trim()}

<h2>${esc(t.faqH)}</h2>
<div class="faq">
${a.faq.map(([q, ans]) => `<details><summary>${esc(q)}</summary><p>${esc(ans)}</p></details>`).join('\n')}
</div>
</div>

<h2>${esc(t.more)}</h2>
<div class="cards">
${others.map((x) => `<a class="acard" href="${t.base}/${t.dir}/${x.slug}/"><b>${esc(x[lang].title)}</b><span>${esc(x[lang].desc)}</span></a>`).join('\n')}
</div>

<h2>${esc(t.seeAlso)}</h2>
<div class="links">
${t.related.map(([label, href]) => `<a href="${href}">${esc(label)}</a>`).join('')}
</div>`;

  return {
    file: path.join(SITE, t.base.replace('/', ''), t.dir, art.slug, 'index.html'),
    url,
    html: shell({
      lang, title: `${a.metaTitle || a.title} | GeoCharge`, desc: a.desc, canonical: url, altHref: alt,
      body: `<style>${PROSE}</style>\n${body}`,
      jsonld: {
        '@context': 'https://schema.org',
        '@graph': [
          breadcrumbLd(bc),
          {
            '@type': 'Article', '@id': url + '#article', headline: a.title, description: a.desc,
            url, inLanguage: lang, datePublished: '2026-07-30', dateModified: '2026-07-30',
            author: { '@type': 'Organization', '@id': `${ORIGIN}/#org`, name: 'GeoCharge' },
            publisher: { '@id': `${ORIGIN}/#org` },
            image: `${ORIGIN}/assets/og-image.png`,
            isPartOf: { '@type': 'WebSite', '@id': `${ORIGIN}/#website` },
          },
          {
            '@type': 'FAQPage', inLanguage: lang,
            mainEntity: a.faq.map(([q, ans]) => ({
              '@type': 'Question', name: q,
              acceptedAnswer: { '@type': 'Answer', text: ans },
            })),
          },
        ],
      },
    }),
  };
}

function indexPage(lang, ARTICLES) {
  const t = L[lang], o = L[lang === 'ka' ? 'en' : 'ka'];
  const url = `${ORIGIN}${t.base}/${t.dir}/`;
  const alt = `${ORIGIN}${o.base}/${o.dir}/`;
  const bc = [{ name: t.home, href: `${t.base}/` }, { name: t.blog }];

  const body = `${crumbs(bc)}
<h1>${esc(t.idxTitle)}</h1>
<p class="intro" style="margin-bottom:36px">${esc(t.idxIntro)}</p>
<div class="cards">
${ARTICLES.map((x) => `<a class="acard" href="${t.base}/${t.dir}/${x.slug}/"><b>${esc(x[lang].title)}</b><span>${esc(x[lang].desc)}</span></a>`).join('\n')}
</div>

<h2>${esc(t.seeAlso)}</h2>
<div class="links">
${t.related.map(([label, href]) => `<a href="${href}">${esc(label)}</a>`).join('')}
</div>`;

  return {
    file: path.join(SITE, t.base.replace('/', ''), t.dir, 'index.html'),
    url,
    html: shell({
      lang, title: `${t.idxTitle} | GeoCharge`, desc: t.idxDesc, canonical: url, altHref: alt,
      body: `<style>${PROSE}</style>\n${body}`,
      jsonld: {
        '@context': 'https://schema.org',
        '@graph': [
          breadcrumbLd(bc),
          {
            '@type': 'CollectionPage', '@id': url + '#page', name: t.idxTitle, url,
            inLanguage: lang, description: t.idxDesc,
            isPartOf: { '@type': 'WebSite', '@id': `${ORIGIN}/#website` },
          },
        ],
      },
    }),
  };
}

async function main() {
  const N = await liveNumbers();
  const F = await fuelPrices();
  const ARTICLES = buildArticles(N, F);
  console.log(`· live figures: ${N.total} stations, CCS2 ${N.ccs2}, GB/T ${N.gbt}, US-spec ${N.usSpec}`);
  console.log(`· tariffs: DC median ${N.dcMed.toFixed(2)} ₾, AC median ${N.acMed.toFixed(2)} ₾`);
  const pages = [];
  for (const lang of ['ka', 'en']) {
    pages.push(indexPage(lang, ARTICLES));
    for (const art of ARTICLES) pages.push(articlePage(lang, art, ARTICLES));
  }
  for (const p of pages) {
    await mkdir(path.dirname(p.file), { recursive: true });
    await writeFile(p.file, p.html, 'utf8');
  }

  // The house style for these guides forbids dashes as punctuation. Catch any
  // that slip into the prose (brand names like E-Space and suffixes like
  // GeoCharge-ის are fine; a dash surrounded by spaces is not).
  const offenders = [];
  for (const p of pages) {
    const prose = (p.html.match(/<div class="prose">[\s\S]*?<\/div>/) || [''])[0]
      + (p.html.match(/<div class="key">[\s\S]*?<\/div>/) || [''])[0];
    for (const m of prose.matchAll(/(\S{0,18})\s[—–-]\s(\S{0,18})/g)) {
      offenders.push(`${p.file}: …${m[1]} ${m[0].trim().slice(m[1].length).trim()} ${m[2]}…`);
    }
  }
  if (offenders.length) {
    console.error(`  !! ${offenders.length} dash(es) used as punctuation:`);
    for (const o of offenders.slice(0, 12)) console.error('     ' + o);
    process.exit(1);
  }

  console.log(`· wrote ${pages.length} pages (${ARTICLES.length} articles × 2 langs + 2 indexes)`);
  console.log('· dash check passed: no dashes used as punctuation in the prose');
  console.log('\n  Remember: these URLs are not in sitemap.xml until build-pages.mjs knows about them.');
  for (const p of pages) console.log('   ' + p.url);
}

main().catch((e) => { console.error(e); process.exit(1); });
