"use strict";

// The pure half of sitePulse: turn one beacon from site/assets/pulse.js into the
// counters it adds to its day. No Firebase here, so it runs under `node --test`
// (see site-pulse-count.test.js).
//
// Everything that reaches a Firestore map key is validated first. Those keys are
// written by anyone who can send a POST, and a document holds at most 1 MiB, so
// a free-form key would let junk fill a day until its real writes start failing.

const TZ_COUNTRY = require("./tz-country.json");

const has = (obj, key) => Object.prototype.hasOwnProperty.call(obj, key);

// Georgia is UTC+4 all year. A day here starts at 20:00 UTC the evening before.
const TBILISI_OFFSET_MS = 4 * 3600000;

/** The Tbilisi calendar day (YYYY-MM-DD) an instant falls in. */
function tbilisiDay(ms) {
  return new Date(ms + TBILISI_OFFSET_MS).toISOString().slice(0, 10);
}

// Crawlers, link previews and scripts. Most never run pulse.js at all, but
// Googlebot renders pages with JavaScript and would otherwise be a visitor.
const BOTS =
  /bot|crawl|spider|slurp|mediapartners|headless|lighthouse|pagespeed|prerender|phantom|puppeteer|playwright|selenium|facebookexternalhit|meta-externalagent|embedly|preview|curl\/|wget|python|java\/|go-http|okhttp|axios|node-fetch|scrapy/i;

/** A site path, lower-cased and without index.html; "(other)" if it is not one. */
function cleanPath(p) {
  if (typeof p !== "string" || !p.startsWith("/")) return null;
  const s = p.toLowerCase().replace(/\/index\.html$/, "/").replace(/\/{2,}/g, "/");
  // The site's own URLs are all ASCII slugs. Anything else is a 404 someone
  // typed or a probe, and is pooled rather than given a key of its own.
  return s.length <= 120 && /^\/[a-z0-9._~\/-]*$/.test(s) ? s : "(other)";
}

/** A referrer hostname without www., or "" if it does not look like one. */
function cleanHost(h) {
  if (typeof h !== "string") return "";
  const s = h.toLowerCase().replace(/^www\./, "");
  return /^[a-z0-9][a-z0-9.-]{0,99}$/.test(s) ? s : "";
}

/** A utm value, lower-cased; Georgian campaign names are allowed. */
function cleanToken(v, max) {
  if (typeof v !== "string") return "";
  const s = v.trim().toLowerCase().slice(0, max);
  return /^[\p{L}\p{N}][\p{L}\p{N} ._~+-]*$/u.test(s) ? s : "";
}

/**
 * Validate a beacon body. Returns null for anything that is not one.
 *
 *   { t: "view", p, e?, u?, n?, r?, s?, c?, tz? }   a page view
 *   { t: "click", p, k: "play" | "appstore" }       a store link
 *
 * Referrer, utm and time zone only matter on the page that starts a visit, so
 * they are dropped from every other view even if a client sends them.
 */
function normalizeHit(body) {
  if (!body || typeof body !== "object") return null;
  const path = cleanPath(body.p);
  if (!path) return null;

  if (body.t === "click") {
    return body.k === "play" || body.k === "appstore"
      ? { type: "click", path, store: body.k }
      : null;
  }
  if (body.t !== "view") return null;

  // The first page of a visitor's day always starts a visit (pulse.js says the
  // same), so no day can show more visitors than visits.
  const unique = body.u === 1;
  const entry = unique || body.e === 1;
  return {
    type: "view",
    path,
    entry,
    unique,
    isNew: unique && body.n === 1,
    ref: entry ? cleanHost(body.r) : "",
    source: entry ? cleanToken(body.s, 40) : "",
    campaign: entry ? cleanToken(body.c, 60) : "",
    tz: entry && typeof body.tz === "string" ? body.tz.slice(0, 64) : "",
  };
}

// Referrer host → source. Order matters: the AI assistants and webmail live on
// google.com and microsoft.com subdomains and must be caught before search.
const REFERRER_SOURCES = [
  ["chatgpt", /^(chatgpt\.com|chat\.openai\.com)$/],
  ["perplexity", /(^|\.)perplexity\.ai$/],
  ["gemini", /^gemini\.google\.com$/],
  ["claude", /^claude\.ai$/],
  ["copilot", /^copilot\.microsoft\.com$/],
  ["email", /^(mail\.google\.com|com\.google\.android\.gm|outlook\.live\.com|mail\.yahoo\.com)$/],
  ["google", /(^|\.)google\.[a-z]{2,3}(\.[a-z]{2})?$|^com\.google\.android\.googlequicksearchbox$/],
  ["bing", /(^|\.)bing\.com$/],
  ["yandex", /(^|\.)yandex\.[a-z]{2,3}$|^ya\.ru$/],
  ["duckduckgo", /(^|\.)duckduckgo\.com$/],
  ["yahoo", /(^|\.)yahoo\.com$/],
  ["facebook", /(^|\.)facebook\.com$|^fb\.me$|^com\.facebook\.(katana|orca)$/],
  ["instagram", /(^|\.)instagram\.com$/],
  ["youtube", /(^|\.)youtube\.com$|^youtu\.be$/],
  ["x", /^(t\.co|x\.com|twitter\.com)$/],
  ["linkedin", /(^|\.)linkedin\.com$|^lnkd\.in$/],
  ["tiktok", /(^|\.)tiktok\.com$/],
  ["telegram", /^(t\.me|web\.telegram\.org|org\.telegram\.messenger)$/],
];

// Hand-typed utm_source spellings of the same place.
const UTM_ALIASES = {
  fb: "facebook",
  "facebook.com": "facebook",
  "m.facebook.com": "facebook",
  ig: "instagram",
  "instagram.com": "instagram",
  "google.com": "google",
};

/** Where a visit came from: utm first, then the referrer, then the in-app browser. */
function sourceOf(hit, ua) {
  if (hit.source) return has(UTM_ALIASES, hit.source) ? UTM_ALIASES[hit.source] : hit.source;
  if (hit.ref) {
    for (const [name, re] of REFERRER_SOURCES) if (re.test(hit.ref)) return name;
    return "referral";
  }
  // Facebook's and Instagram's in-app browsers usually send no referrer at all,
  // but they do say who they are.
  if (/Instagram/.test(ua)) return "instagram";
  if (/FBAN|FBAV|FB_IAB|FBIOS/.test(ua)) return "facebook";
  return "direct";
}

/** Device class and operating system from a user agent. */
function deviceOf(ua) {
  let os = "other";
  if (/Android/i.test(ua)) os = "android";
  else if (/iPhone|iPad|iPod/i.test(ua)) os = "ios";
  else if (/Windows/i.test(ua)) os = "windows";
  else if (/CrOS/.test(ua)) os = "chromeos";
  else if (/Macintosh|Mac OS X/i.test(ua)) os = "macos";
  else if (/Linux/i.test(ua)) os = "linux";

  let device = "desktop";
  // A Tesla's browser is a Linux desktop by its user agent, and this site has
  // its own reason to count those separately.
  if (/\bTesla\b/.test(ua)) device = "car";
  else if (/iPad|Tablet/i.test(ua) || (os === "android" && !/Mobile/i.test(ua))) device = "tablet";
  else if (/Mobi|iPhone|iPod/i.test(ua)) device = "mobile";
  return { os, device };
}

/** ISO country code for an IANA time zone, or "unknown". */
function countryOf(tz) {
  return typeof tz === "string" && has(TZ_COUNTRY, tz) ? TZ_COUNTRY[tz] : "unknown";
}

/**
 * The counters one hit adds to its day, as a plain nested object of numbers.
 * The caller turns each number into a Firestore increment.
 */
function counts(hit, ua) {
  if (hit.type === "click") {
    return {
      clicks: { [hit.store]: 1 },
      clickPages: { [hit.path]: { [hit.store]: 1 } },
    };
  }

  const out = { views: 1, pages: { [hit.path]: 1 } };
  if (hit.unique) out.visitors = 1;
  if (hit.isNew) out.newVisitors = 1;
  if (!hit.entry) return out;

  // Everything below describes the visit, so it is counted once per visit
  // rather than once per page read during it.
  const source = sourceOf(hit, ua);
  const { os, device } = deviceOf(ua);
  out.visits = 1;
  out.entries = { [hit.path]: 1 };
  out.sources = { [source]: 1 };
  if (hit.ref) out.referrers = { [hit.ref]: 1 };
  if (hit.campaign) out.campaigns = { [`${source} · ${hit.campaign}`]: 1 };
  out.countries = { [countryOf(hit.tz)]: 1 };
  out.devices = { [device]: 1 };
  out.os = { [os]: 1 };
  return out;
}

module.exports = {
  BOTS,
  tbilisiDay,
  cleanPath,
  cleanHost,
  normalizeHit,
  sourceOf,
  deviceOf,
  countryOf,
  counts,
};
