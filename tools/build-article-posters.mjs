#!/usr/bin/env node
// Builds one 1080x1350 Instagram poster per blog article.
//
//   node tools/build-article-posters.mjs     # writes marketing/posters/article-*.html
//   node tools/render-posters.mjs article-   # turns them into PNG
//
// Why these exist: Instagram accepts aspect ratios from 4:5 to 1.91:1, and the
// site's og images are 1200x630, i.e. 1.905:1. They squeak past the ceiling but
// landscape is the weakest shape in the feed. 1080x1350 is 4:5, the tallest
// allowed, and takes the most screen on a phone.
//
// Everything on the poster is read from the BUILT article page, so a poster
// cannot claim a number the article does not. The look is marketing/posters/base.css,
// shared with the product poster series.

import { readFile, writeFile, readdir } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const BLOG = path.join(ROOT, 'site', 'blog');
const OUT = path.join(ROOT, 'marketing', 'posters');

// The blog index tags every card with a category; it reads better on a poster
// than a generic "article" label would.
const CATEGORY = {
  charging: 'დატენვა',
  battery: 'ბატარეა',
  travel: 'მგზავრობა',
  buying: 'ყიდვამდე',
};

const esc = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

// A Georgian headline runs long. Rather than truncate a title into nonsense,
// the type shrinks in three steps so the longest ones still fit the box.
const titleSize = (s) => (s.length > 62 ? 46 : s.length > 44 ? 54 : 64);

// The key block is the article's own short answer, which is exactly what a
// poster wants. It can run to several sentences, so it is cut on a sentence
// boundary rather than mid word.
function shorten(text, max = 190) {
  // "მოკლე პასუხი:" introduces the answer in the article, where a reader has
  // just met a heading. On a poster the card IS the answer, so the lead in is
  // noise and eats the line that should carry the number.
  const clean = text.replace(/\s+/g, ' ').replace(/^მოკლე პასუხი:\s*/, '').trim();
  if (clean.length <= max) return clean;
  const cut = clean.slice(0, max);
  const stop = Math.max(cut.lastIndexOf('. '), cut.lastIndexOf('! '), cut.lastIndexOf('? '));
  return stop > 80 ? cut.slice(0, stop + 1) : `${cut.slice(0, cut.lastIndexOf(' '))}…`;
}

async function categories() {
  const index = path.join(BLOG, 'index.html');
  if (!existsSync(index)) return {};
  const html = await readFile(index, 'utf8');
  const map = {};
  const re = /href="\/blog\/([a-z0-9-]+)\/"[^>]*data-cat="([a-z]+)"/g;
  let m;
  while ((m = re.exec(html))) map[m[1]] = m[2];
  return map;
}

async function article(slug) {
  const html = await readFile(path.join(BLOG, slug, 'index.html'), 'utf8');
  const meta = (p) => (new RegExp(`<meta property="${p}" content="([^"]*)"`).exec(html) || [])[1];
  const url = meta('og:url');
  if (!url) return null;
  const keyBlock = /<div class="key">([\s\S]*?)<\/div>/.exec(html);
  const paras = keyBlock
    ? [...keyBlock[1].matchAll(/<p>([\s\S]*?)<\/p>/g)].map((p) => p[1].replace(/<[^>]*>/g, ''))
    : [];
  return {
    slug,
    url,
    title: (meta('og:title') || '').replace(/ \| GeoCharge$/, ''),
    desc: meta('og:description') || '',
    // The first key paragraph is the short answer; the second, when present,
    // is usually the Georgia-specific detail. Both earn their place.
    facts: paras.slice(0, 2).map((p) => shorten(p, paras.length > 1 ? 150 : 190)),
  };
}

const page = (a, cat) => `<!doctype html>
<html lang="ka">
<head>
<meta charset="utf-8">
<title>GeoCharge · ${esc(a.slug)}</title>
<link rel="stylesheet" href="base.css">
<style>
    h1 { font-size: ${titleSize(a.title)}px; }
    .facts { display: flex; flex-direction: column; gap: 18px; width: 100%; }
    .fact { text-align: left; border: 1px solid #22332b; border-radius: 24px;
      padding: 30px 34px; background: linear-gradient(150deg, #101c17 0%, #0c1512 100%);
      box-shadow: 0 26px 55px -34px rgba(0,0,0,.85);
      font-size: 27px; line-height: 1.5; color: #DCE6E1; }
    .fact.lead { font-size: 30px; color: #F3F6F5; border-color: #2bd59433; }
    .fact.lead::before { content: ""; display: block; width: 56px; height: 4px;
      border-radius: 4px; background: #2BD594; margin-bottom: 20px; }
    .link { display: inline-flex; align-items: center; gap: 12px;
      font-size: 23px; font-weight: 600; color: #9fe9cd;
      border: 1px solid #2bd59440; background: #2bd5940f;
      padding: 13px 26px; border-radius: 999px; }</style>
</head>
<body>
<div class="post">
  <div class="bg"></div>
  <div class="scan"></div>
  <div class="inner">
    <div class="eyebrow">${esc(cat)}</div>
    <div class="brand">
      <img src="mark.svg" alt="">
      <span class="word"><span class="w-geo">Geo</span><span class="w-charge">Charge</span></span>
    </div>
    <h1>${esc(a.title)}</h1>
    <div class="stage">
      <div class="facts">
${a.facts.map((f, i) => `        <div class="fact${i === 0 ? ' lead' : ''}">${esc(f)}</div>`).join('\n')}
      </div>
    </div>
    <div class="cta">
      <div class="cta-btn">
        <svg width="30" height="30" viewBox="0 0 24 24" fill="none" stroke="#04140E" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"><path d="M4 5.5h7a3 3 0 0 1 3 3V20a2.5 2.5 0 0 0-2.5-2.5H4Z"/><path d="M20 5.5h-7a3 3 0 0 0-3 3V20a2.5 2.5 0 0 1 2.5-2.5H20Z"/></svg>
        წაიკითხე სრულად
      </div>
      <div class="link">${esc(a.url.replace(/^https:\/\//, '').replace(/\/$/, ''))}</div>
    </div>
    <div class="foot">ყველა დამტენი ერთ აპლიკაციაში</div>
  </div>
</div>
</body>
</html>
`;

const cats = await categories();
const slugs = (await readdir(BLOG)).filter((s) => existsSync(path.join(BLOG, s, 'index.html')));

let n = 0;
for (const slug of slugs) {
  const a = await article(slug);
  if (!a) continue;
  if (!a.facts.length) {
    console.warn(`  !! ${slug}: no key block, falling back to the description`);
    a.facts = [shorten(a.desc, 190)];
  }
  const cat = CATEGORY[cats[slug]] || 'GeoCharge ბლოგი';
  await writeFile(path.join(OUT, `article-${slug}.html`), page(a, cat), 'utf8');
  n++;
}

console.log(`${n} პოსტერი → ${path.relative(ROOT, OUT)}/article-*.html`);
console.log('რენდერი: node tools/render-posters.mjs article-');
