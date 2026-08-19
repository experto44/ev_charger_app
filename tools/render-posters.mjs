#!/usr/bin/env node
// Renders the social posters in marketing/posters/ to PNG at their native size.
//
//   node tools/render-posters.mjs            # every *.html in marketing/posters
//   node tools/render-posters.mjs 01 04      # only the files whose name starts so
//
// The posters are hand written HTML sized to an exact pixel box (1080x1350 for
// the Facebook and Instagram feed). The viewport is set to that same box and the
// screenshot is taken without fullPage, so what the browser paints is what the
// feed gets, one pixel to one pixel.

import { readdir, mkdir } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

// Playwright is the one dependency this repo does not vendor: everything else
// under tools/ runs on node builtins. Point PLAYWRIGHT_DIR at any folder that
// has playwright installed, or run `npm i playwright` beside this script.
//   npm i playwright && npx playwright install chromium
const pw = process.env.PLAYWRIGHT_DIR
  ? pathToFileURL(path.join(process.env.PLAYWRIGHT_DIR, 'node_modules', 'playwright', 'index.mjs')).href
  : 'playwright';
const { chromium } = await import(pw);

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const DIR = path.join(ROOT, 'marketing', 'posters');
const W = 1080, H = 1350;

const filters = process.argv.slice(2);
const files = (await readdir(DIR))
  .filter(f => f.endsWith('.html'))
  .filter(f => !filters.length || filters.some(p => f.startsWith(p)))
  .sort();

if (!files.length) { console.error('no posters matched'); process.exit(1); }

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: W, height: H }, deviceScaleFactor: 1 });

for (const f of files) {
  const out = path.join(DIR, f.replace(/\.html$/, '.png'));
  await page.goto(pathToFileURL(path.join(DIR, f)).href, { waitUntil: 'load' });
  await page.evaluate(() => document.fonts.ready);
  await page.screenshot({ path: out });
  console.log('rendered', path.basename(out));
}

await browser.close();
