#!/usr/bin/env node
// Builds the GeoCharge social poster series into marketing/posters/*.html.
//
//   node tools/build-posters.mjs        # writes the HTML
//   node tools/render-posters.mjs       # turns it into PNG at 1080x1350
//
// The posters are generated rather than hand written for the same reason the
// site is: nine files that share a header, a brand lockup and a call to action
// drift apart the moment somebody edits one of them by hand. Copy lives here,
// the shared look lives in marketing/posters/base.css.
//
// Every number below is checked against the live data behind geocharge.ge:
// station counts from the coverage section, tariffs from site/tarifebi.

import { writeFile, mkdir } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const OUT = path.join(ROOT, 'marketing', 'posters');

const BRAND = `<div class="brand">
      <img src="mark.svg" alt="">
      <span class="word"><span class="w-geo">Geo</span><span class="w-charge">Charge</span></span>
    </div>`;

const CTA = `<div class="cta">
      <div class="cta-btn">
        <svg width="30" height="30" viewBox="0 0 24 24" fill="none" stroke="#04140E" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3v12"/><path d="m6.5 10.5 5.5 5.5 5.5-5.5"/><path d="M4 20h16"/></svg>
        ჩამოტვირთე ახლავე
      </div>
      <div class="badges">
        <div class="badge">
          <svg width="28" height="28" viewBox="0 0 24 24" fill="#FFFFFF"><path d="M16.365 1.43c0 1.14-.42 2.2-1.12 2.99-.85.94-2.23 1.67-3.38 1.58-.14-1.13.42-2.32 1.05-3.06.71-.85 1.94-1.5 2.97-1.54.03.01.05.02.06.03.02.32-.02.35 0 0Zm2.86 15.7c-.51 1.19-.76 1.72-1.42 2.77-.92 1.47-2.22 3.3-3.83 3.31-1.43.02-1.8-.94-3.74-.93-1.94.01-2.35.94-3.78.92-1.61-.02-2.84-1.67-3.76-3.14-2.58-4.11-2.85-8.94-1.26-11.51 1.13-1.82 2.91-2.89 4.58-2.89 1.7 0 2.77.94 4.18.94 1.36 0 2.19-.94 4.16-.94 1.49 0 3.06.82 4.19 2.23-3.68 2.02-3.08 7.28.68 9.24Z"/></svg>
          <span class="btxt"><span class="top">ჩამოტვირთეთ</span><span class="main">App Store</span></span>
        </div>
        <div class="badge">
          <svg width="28" height="28" viewBox="0 0 24 24"><path d="M4 2.8v18.4c0 .6.7 1 1.2.7L8 20.2 16.5 15 19.8 13c.8-.45.8-1.55 0-2L5.2 2.1C4.7 1.8 4 2.2 4 2.8Z" fill="#2BD594"/><path d="M4.4 2.2 14.6 12 4.4 21.8" fill="none" stroke="#0D1A13" stroke-width=".9"/></svg>
          <span class="btxt"><span class="top">ჩამოტვირთეთ</span><span class="main">Google Play</span></span>
        </div>
      </div>
      <div class="foot">geocharge.ge</div>
    </div>`;

const bolt = (c = '#2BD594') =>
  `<svg viewBox="0 0 24 24" width="30" height="30" fill="${c}"><path d="M11 2 L4 13 h6 l-1 9 9-13 h-6 l2-7 z"/></svg>`;

// the twelve public networks the map carries, ordered by station count
const NETWORKS = [
  ['martev.svg', 'mart EV'], ['ecocars.png', 'EcoCars'], ['datene.png', 'Da-Tene'],
  ['espace.svg', 'E-Space'], ['chargerplus.png', 'Charger Plus'], ['evpower.png', 'EV Power'],
  ['tegeta_appicon.png', 'Tegeta'], ['electrify.png', 'Electrify Georgia'],
  ['solarstation.png', 'Solar Station'], ['moveo-icon.png', 'MOVEO'],
  ['gadatene-dark.svg', 'Gadatene'], ['socar.png', 'SOCAR'],
];

// a connector face drawn from its real pin layout, so the tiles read as plugs
const pins = (set) => `<svg viewBox="0 0 100 100" width="132" height="132">${set}</svg>`;
const circle = (cx, cy, r, o = 1) => `<circle cx="${cx}" cy="${cy}" r="${r}" fill="currentColor" opacity="${o}"/>`;
const ring = `<circle cx="50" cy="50" r="46" fill="none" stroke="currentColor" stroke-width="3" opacity=".35"/>`;

const TYPE2 = ring + circle(50, 26, 7) + circle(29, 36, 7) + circle(71, 36, 7) +
  circle(31, 60, 8) + circle(69, 60, 8) + circle(41, 78, 6) + circle(59, 78, 6);
const CCS2 = `<circle cx="50" cy="38" r="34" fill="none" stroke="currentColor" stroke-width="3" opacity=".35"/>` +
  circle(50, 18, 5.5) + circle(33, 27, 5.5) + circle(67, 27, 5.5) + circle(34, 46, 6) + circle(66, 46, 6) +
  `<circle cx="33" cy="79" r="14" fill="currentColor"/><circle cx="67" cy="79" r="14" fill="currentColor"/>`;
const CHADEMO = ring + circle(50, 22, 6) + circle(28, 34, 6) + circle(72, 34, 6) +
  circle(24, 56, 6) + circle(76, 56, 6) + circle(38, 50, 9) + circle(62, 50, 9) +
  circle(40, 76, 6) + circle(60, 76, 6);
const GBT = ring + circle(50, 24, 6.5) + circle(27, 38, 6.5) + circle(73, 38, 6.5) +
  circle(35, 58, 9) + circle(65, 58, 9) + circle(50, 78, 6.5);

const posters = [
  {
    slug: '01-ufaso',
    eyebrow: `<div class="eyebrow">სრულიად უფასო</div>`,
    h1: `ყველა დამტენი ერთ რუკაზე.<br><span class="accent">ფასი 0 ₾</span>`,
    sub: `არც აბონენტი, არც სარეგისტრაციო საფასური. აპლიკაციის ყველა ფუნქცია ღიაა ყველა მძღოლისთვის.`,
    css: `
    .price { width: 100%; border: 1px solid #22332b; border-radius: 28px; padding: 34px 40px 30px;
      background: linear-gradient(160deg, #12211b 0%, #0c1512 100%);
      box-shadow: 0 30px 70px -40px rgba(0,0,0,.9); }
    .amount { font-size: 168px; font-weight: 800; line-height: .92; letter-spacing: -6px; color: #2BD594; }
    .amount .cur { font-size: 92px; margin-left: 8px; letter-spacing: 0; }
    .per { margin-top: 6px; font-size: 24px; color: #8ea69b; letter-spacing: .06em; text-transform: uppercase; }
    .incl { list-style: none; margin-top: 28px; border-top: 1px solid #1d2c25; padding-top: 24px;
      display: grid; grid-template-columns: 1fr 1fr; gap: 18px 26px; }
    .incl li { display: flex; align-items: center; gap: 13px; text-align: left;
      font-size: 24px; font-weight: 500; color: #DCE6E1; }
    .incl svg { flex: none; }`,
    stage: `<div class="price">
        <div class="amount">0<span class="cur">₾</span></div>
        <div class="per">სამუდამოდ</div>
        <ul class="incl">
          ${['800+ დამტენი სადგური', '12 ქსელი ერთ რუკაზე', 'ცოცხალი სტატუსი', 'მარშრუტი დატენვით',
             'ტარიფები და კონექტორები', 'ევროპის დამტენებიც']
            .map(t => `<li><svg width="26" height="26" viewBox="0 0 24 24" fill="none" stroke="#2BD594" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><path d="m4 12.5 5 5L20 6.5"/></svg>${t}</li>`).join('\n          ')}
        </ul>
      </div>`,
  },
  {
    slug: '02-erti-ruka',
    eyebrow: `<div class="eyebrow">12 ქსელი, ერთი რუკა</div>`,
    h1: `იპოვე ერთ რუკაზე,<br><span class="accent">დატენე შენს ქსელში</span>`,
    sub: `აღარ გჭირდება რიგრიგობით თორმეტი აპლიკაციის გახსნა, სანამ თავისუფალ დამტენს იპოვი. GeoCharge გაჩვენებს სად არის, რომელი ქსელია და თავისუფალია თუ არა.`,
    css: `
    .wall { display: grid; grid-template-columns: repeat(4, 1fr); gap: 16px; width: 100%; margin-top: 6px; }
    .chip { height: 96px; border-radius: 18px; background: #fff; border: 1px solid #ffffff1a;
      display: flex; align-items: center; justify-content: center; padding: 14px 18px; }
    .chip img { max-width: 100%; max-height: 100%; object-fit: contain; }
    .net { font-size: 19px; font-weight: 700; color: #2BD594; background: #2bd5941a;
      border-radius: 8px; padding: 4px 11px; }`,
    stage: `<div class="card">
        <div class="ico">${bolt()}</div>
        <div class="meta">
          <span class="name">ბათუმი, ბულვარი</span>
          <span class="det"><span class="net">E-Space</span> &nbsp;CCS2 · 120 კვტ · 0.60 ₾/კვტ.სთ</span>
        </div>
        <div class="status free"><span class="sdot"></span>2 თავისუფალი</div>
      </div>
      <div class="wall">
        ${NETWORKS.map(([f, n]) => `<div class="chip"><img src="../provider-logos/${f}" alt="${n}"></div>`).join('\n        ')}
      </div>`,
  },
  {
    slug: '03-shematyobine',
    eyebrow: `<div class="eyebrow warm">შეტყობინება დაკავებულ დამტენზე</div>`,
    h1: `დაკავებულია?<br><span class="accent">გაცნობებ, როცა გათავისუფლდება</span>`,
    sub: `ჩართე შეტყობინება და ტელეფონი თავად შეგატყობინებს, როგორც კი პორტი გათავისუფლდება. ერთდროულად ოთხ სადგურამდე.`,
    css: `
    .bell { display: inline-flex; align-items: center; gap: 10px; white-space: nowrap;
      font-size: 22px; font-weight: 700; padding: 12px 22px; border-radius: 999px;
      background: linear-gradient(180deg, #34e2a2, #21c489); color: #04140E; }
    .link { width: 3px; height: 54px; border-radius: 3px;
      background: repeating-linear-gradient(to bottom, #2bd59466 0 8px, transparent 8px 16px); }
    .push { display: flex; align-items: center; gap: 20px; width: 100%;
      background: #f2f5f4; color: #10201a; border-radius: 26px; padding: 22px 26px;
      box-shadow: 0 30px 60px -28px rgba(0,0,0,.85); text-align: left; }
    .push .pic { width: 62px; height: 62px; flex: none; border-radius: 15px; background: #0b1512;
      display: flex; align-items: center; justify-content: center; }
    .push .pic img { width: 44px; height: 44px; }
    .ptop { display: flex; align-items: baseline; gap: 10px; font-size: 20px; font-weight: 700; color: #4a5a54; }
    .ptop .now { font-weight: 500; color: #8a9a94; }
    .pbody { margin-top: 4px; font-size: 26px; font-weight: 600; line-height: 1.35; }`,
    stage: `<div class="card">
        <div class="ico">${bolt('#FFB02E')}</div>
        <div class="meta">
          <span class="name">თბილისი, ვაკე</span>
          <span class="det">CCS2 · 120 კვტ · იტენება 24+ წთ</span>
        </div>
        <div class="bell">
          <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="#04140E" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M18 8a6 6 0 1 0-12 0c0 7-3 9-3 9h18s-3-2-3-9"/><path d="M13.7 21a2 2 0 0 1-3.4 0"/></svg>
          შემატყობინე!
        </div>
      </div>
      <div class="link"></div>
      <div class="push">
        <div class="pic"><img src="mark.svg" alt=""></div>
        <div>
          <div class="ptop">GeoCharge <span class="now">ახლა</span></div>
          <div class="pbody">თბილისი, ვაკე გათავისუფლდა. დაასწარი!</div>
        </div>
      </div>`,
  },
  {
    slug: '04-cocxali-statusi',
    eyebrow: `<div class="eyebrow hot"><span class="tag"><span class="ldot"></span>LIVE</span> სტატუსი რეალურ დროში</div>`,
    h1: `გასვლამდე იცოდე,<br><span class="accent">თავისუფალია თუ არა</span>`,
    sub: `GeoCharge ყველა პორტის სტატუსს რეალურ დროში აახლებს, ტყუილად აღარ გაივლი გზას დაკავებულ სადგურამდე.`,
    css: `
    .upd { font-size: 20px; color: #6f817a; }`,
    stage: `<div class="card">
        <div class="ico">${bolt()}</div>
        <div class="meta"><span class="name">თბილისი, ვაკე</span><span class="det">CCS2 · 120 კვტ</span></div>
        <div class="status free"><span class="sdot"></span>თავისუფალი</div>
      </div>
      <div class="card">
        <div class="ico">${bolt('#FFB02E')}</div>
        <div class="meta"><span class="name">მცხეთა, ცენტრი</span><span class="det">Type 2 · 22 კვტ</span></div>
        <div class="status busy"><span class="sdot"></span>დაკავებული</div>
      </div>
      <div class="card">
        <div class="ico">${bolt('#ff6b6b')}</div>
        <div class="meta"><span class="name">გორი, ავტობანი</span><span class="det">CHAdeMO · 50 კვტ</span></div>
        <div class="status out"><span class="sdot"></span>მწყობრიდან</div>
      </div>
      <div class="upd">განახლდა ახლახ</div>`,
  },
  {
    slug: '05-marshruti',
    eyebrow: `<div class="eyebrow">მარშრუტის დაგეგმვა</div>`,
    h1: `დაგეგმე გზა,<br><span class="accent">დატენვაზე აპლიკაცია იზრუნებს</span>`,
    sub: `სად გაჩერდე, რამდენი პროცენტით ჩახვალ და რომელი დამტენია გზის სწორ მხარეს. ყველაფერი ერთ ეკრანზე.`,
    css: `
    .route { width: 100%; display: flex; flex-direction: column; align-items: stretch; gap: 0; }
    .rrow { display: flex; align-items: center; gap: 18px; text-align: left; }
    .rdot { width: 22px; height: 22px; border-radius: 50%; flex: none; }
    .rdot.a { background: #2BD594; box-shadow: 0 0 0 7px #2bd59426; }
    .rdot.b { background: #ff6b6b; box-shadow: 0 0 0 7px #ff6b6b26; }
    .rlab { font-size: 32px; font-weight: 700; }
    .rline { width: 3px; height: 40px; margin-left: 9px;
      background: repeating-linear-gradient(to bottom, #2bd59455 0 8px, transparent 8px 16px); }
    .stop { display: flex; align-items: center; gap: 20px; margin-left: 40px;
      background: linear-gradient(150deg, #101c17, #0d1713); border: 1px solid #22332b;
      border-radius: 20px; padding: 20px 24px; text-align: left; }
    .stopno { width: 46px; height: 46px; flex: none; border-radius: 12px; background: #2bd5941a;
      color: #2BD594; font-size: 24px; font-weight: 800; display: flex; align-items: center; justify-content: center; }
    .stopname { font-size: 27px; font-weight: 700; }
    .stopdet { font-size: 20px; color: #8ea69b; margin-top: 4px; }
    .chips { display: flex; gap: 14px; margin-top: 8px; }
    .chips span { font-size: 22px; font-weight: 600; padding: 12px 22px; border-radius: 999px;
      background: #2bd5941a; color: #2BD594; border: 1px solid #2bd59433; }
    .chips span.warm { background: #ffb02e1a; color: #FFB02E; border-color: #ffb02e33; }`,
    stage: `<div class="route">
        <div class="rrow"><span class="rdot a"></span><span class="rlab">თბილისი</span></div>
        <div class="rline"></div>
        <div class="stop">
          <div class="stopno">1</div>
          <div>
            <div class="stopname">GULF სიმონეთი</div>
            <div class="stopdet">120 კვტ · ბატარეა 16% ჩასვლისას · გზის სწორ მხარეს</div>
          </div>
        </div>
        <div class="rline"></div>
        <div class="rrow"><span class="rdot b"></span><span class="rlab">ბათუმი</span></div>
      </div>
      <div class="chips"><span>380 კმ</span><span class="warm">1 გაჩერება</span><span>52% ჩასვლისას</span></div>`,
  },
  {
    slug: '06-konektori',
    eyebrow: `<div class="eyebrow">ჭკვიანი ფილტრები</div>`,
    h1: `ნახე მხოლოდ ის,<br><span class="accent">რაც შენს მანქანას სჭირდება</span>`,
    sub: `გაფილტრე კონექტორის ტიპით, სიმძლავრით და ოპერატორით. ერთხელ შეავსე მანქანის პროფილი და რუკა შემდეგ თავად მოირგებს.`,
    css: `
    .plugs { display: grid; grid-template-columns: repeat(4, 1fr); gap: 18px; width: 100%; }
    .plug { border-radius: 24px; padding: 40px 10px 30px; border: 1px solid #1d2c25;
      background: #0c1512; color: #56695f; display: flex; flex-direction: column; align-items: center; gap: 24px; }
    .plug.on { color: #2BD594; border-color: #2bd59455; background: #10241c;
      box-shadow: 0 0 0 2px #2bd5941f, 0 26px 50px -28px rgba(43,213,148,.5); }
    .plug .pname { font-size: 24px; font-weight: 700; color: #7c8e85; }
    .plug.on .pname { color: #F3F6F5; }
    .filters { display: flex; gap: 14px; margin-top: 8px; }
    .filters span { font-size: 22px; font-weight: 600; padding: 12px 22px; border-radius: 999px;
      background: #101c17; border: 1px solid #22332b; color: #AEBEB7; }
    .filters span.on { background: #2bd5941a; border-color: #2bd59444; color: #2BD594; }`,
    stage: `<div class="plugs">
        <div class="plug on">${pins(CCS2)}<span class="pname">CCS2</span></div>
        <div class="plug">${pins(TYPE2)}<span class="pname">Type 2</span></div>
        <div class="plug">${pins(CHADEMO)}<span class="pname">CHAdeMO</span></div>
        <div class="plug">${pins(GBT)}<span class="pname">GB/T</span></div>
      </div>
      <div class="filters">
        <span class="on">სწრაფი DC</span><span class="on">50 კვტ და მეტი</span><span>ყველა ოპერატორი</span>
      </div>`,
  },
  {
    slug: '07-tarifebi',
    eyebrow: `<div class="eyebrow">ტარიფები</div>`,
    h1: `ვინ რამდენს იღებს<br><span class="accent">1 კვტ.სთ-ზე</span>`,
    sub: `ფასი ყველა სადგურის ბარათზე წერია და პროვაიდერებისგან ავტომატურად ახლდება. სწრაფი დატენვის მედიანა 0.78 ₾, ნელის 0.65 ₾.`,
    css: `
    .rate { width: 100%; display: flex; flex-direction: column; gap: 12px; }
    .row { display: flex; align-items: center; gap: 20px; padding: 18px 26px; border-radius: 18px;
      background: linear-gradient(150deg, #101c17, #0d1713); border: 1px solid #1d2c25; }
    .row.best { border-color: #2bd59455; background: #10241c; }
    .rname { flex: 1 1 auto; text-align: left; font-size: 27px; font-weight: 600; }
    .rbar { width: 240px; height: 12px; border-radius: 999px; background: #16241e; overflow: hidden; }
    .rbar i { display: block; height: 100%; border-radius: 999px; background: #3f7f68; }
    .row.best .rbar i { background: #2BD594; }
    .rval { width: 130px; text-align: right; font-size: 28px; font-weight: 700; }
    .row.best .rval { color: #2BD594; }
    .note { font-size: 20px; color: #6f817a; }`,
    stage: `<div class="rate">
        ${[['Electrify Georgia', 0.55, true], ['Da-Tene', 0.69, false], ['E-Space', 0.75, false],
           ['mart EV', 0.80, false], ['Tegeta', 1.00, false]]
          .map(([n, v, best]) => `<div class="row${best ? ' best' : ''}">
          <span class="rname">${n}</span>
          <span class="rbar"><i style="width:${Math.round(v * 100)}%"></i></span>
          <span class="rval">${v.toFixed(2)} ₾</span>
        </div>`).join('\n        ')}
      </div>
      <div class="note">სწრაფი DC დატენვის მედიანური ტარიფი ქსელების მიხედვით</div>`,
  },
  {
    slug: '08-dafarva',
    eyebrow: `<div class="eyebrow">დაფარვა</div>`,
    h1: `<span class="accent">800+</span> სადგური და<br>ყოველ კვირას ახლები`,
    sub: `ახალი დამტენი რუკაზე ავტომატურად ჩნდება, აპლიკაციის განახლების ლოდინი არ გჭირდება.`,
    css: `
    .stage { flex-direction: row; align-items: center; justify-content: center; gap: 40px; }
    /* the frame is cropped onto the map itself, so the app chrome around it
       stays out of the poster and the pins get the whole screen */
    .phone { width: 366px; height: 520px; flex: none; border-radius: 40px; padding: 9px;
      background: linear-gradient(160deg, #2b3a34, #131c18); box-shadow: 0 40px 80px -34px rgba(0,0,0,.95); }
    .phone .scr { position: relative; width: 100%; height: 100%; border-radius: 33px; overflow: hidden; background: #000; }
    .phone img { position: absolute; width: 130%; left: -12%; top: -190px; }
    .stats { display: flex; flex-direction: column; gap: 16px; text-align: left; }
    .stat { border: 1px solid #22332b; border-radius: 20px; padding: 20px 26px;
      background: linear-gradient(150deg, #101c17, #0d1713); }
    .snum { font-size: 50px; font-weight: 800; color: #2BD594; line-height: 1; letter-spacing: -1.5px; }
    .slab { margin-top: 8px; font-size: 20px; color: #AEBEB7; line-height: 1.35; }`,
    stage: `<div class="phone"><div class="scr"><img src="../../site/assets/shot-nationwide.jpg" alt=""></div></div>
      <div class="stats">
        <div class="stat"><div class="snum">800+</div><div class="slab">დამტენი სადგური<br>საქართველოსა და რეგიონში</div></div>
        <div class="stat"><div class="snum">12</div><div class="slab">ქსელი ერთ რუკაზე</div></div>
        <div class="stat"><div class="snum">0 ₾</div><div class="slab">ღირს აპლიკაცია</div></div>
      </div>`,
  },
  {
    slug: '09-ucxo-qalaqshi',
    eyebrow: `<div class="eyebrow warm">ნებისმიერ ქალაქში</div>`,
    h1: `უცხო ქალაქშიც იცი,<br><span class="accent">სად დატენო</span>`,
    sub: `ბატარეა თუ იწურება და ქალაქს არ იცნობ, GeoCharge უახლოეს თავისუფალ დამტენს გაჩვენებს და ნავიგაციას იმავე ღილაკიდან გაუშვებს.`,
    css: `
    .batt { display: flex; align-items: center; gap: 4px; }
    .bshell { width: 210px; height: 72px; border: 4px solid #ff6b6b; border-radius: 16px; padding: 7px; }
    .bshell i { display: block; width: 14%; height: 100%; border-radius: 6px; background: #ff6b6b; }
    .bcap { width: 11px; height: 30px; border-radius: 0 6px 6px 0; background: #ff6b6b; }
    .bpct { font-size: 62px; font-weight: 800; color: #ff6b6b; letter-spacing: -2px; margin-left: 22px; }
    .near { font-size: 22px; color: #8ea69b; }
    .cities { display: flex; flex-wrap: wrap; justify-content: center; gap: 12px; margin-top: 6px; }
    .cities span { font-size: 21px; font-weight: 600; padding: 10px 20px; border-radius: 999px;
      background: #101c17; border: 1px solid #22332b; color: #AEBEB7; }
    .go { display: inline-flex; align-items: center; gap: 10px; white-space: nowrap;
      font-size: 22px; font-weight: 700; padding: 12px 22px; border-radius: 999px;
      background: #2bd5941f; color: #2BD594; border: 1px solid #2bd59444; }`,
    stage: `<div class="batt">
        <div class="bshell"><i></i></div><div class="bcap"></div>
        <div class="bpct">9%</div>
      </div>
      <div class="near">უახლოესი თავისუფალი დამტენი</div>
      <div class="card">
        <div class="ico">${bolt()}</div>
        <div class="meta">
          <span class="name">ქუთაისი, ავტოსადგური</span>
          <span class="det">2.4 კმ · CCS2 · 120 კვტ · თავისუფალი</span>
        </div>
        <div class="go">
          <svg width="22" height="22" viewBox="0 0 24 24" fill="#2BD594"><path d="M12 2 21 22 12 17.5 3 22z"/></svg>
          ნავიგაცია
        </div>
      </div>
      <div class="cities">
        <span>ბათუმი</span><span>ქუთაისი</span><span>თელავი</span><span>გუდაური</span><span>ზუგდიდი</span><span>გორი</span>
      </div>`,
  },
];

const page = (p) => `<!doctype html>
<html lang="ka">
<head>
<meta charset="utf-8">
<title>GeoCharge · ${p.slug}</title>
<link rel="stylesheet" href="base.css">
<style>${p.css}</style>
</head>
<body>
<div class="post">
  <div class="bg"></div>
  <div class="scan"></div>
  <div class="inner">
    ${p.eyebrow}
    ${BRAND}
    <h1>${p.h1}</h1>
    <p class="sub">${p.sub}</p>
    <div class="stage">
      ${p.stage}
    </div>
    ${CTA}
  </div>
</div>
</body>
</html>
`;

await mkdir(OUT, { recursive: true });
for (const p of posters) {
  await writeFile(path.join(OUT, `${p.slug}.html`), page(p), 'utf8');
  console.log('built', `${p.slug}.html`);
}
