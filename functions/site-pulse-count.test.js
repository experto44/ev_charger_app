"use strict";

// Fixtures for the visitor counter behind the admin panel's Site tab.
//
//   cd functions && node --test
//
// Pure, no Firestore. What matters is that a beacon lands in the right buckets,
// and that nothing a stranger can POST becomes a map key of its own.

const test = require("node:test");
const assert = require("node:assert");

const {
  BOTS,
  tbilisiDay,
  cleanPath,
  normalizeHit,
  sourceOf,
  deviceOf,
  countryOf,
  counts,
} = require("./site-pulse-count");

const IPHONE =
  "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1";
const ANDROID =
  "Mozilla/5.0 (Linux; Android 14; SM-S918B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/139.0.0.0 Mobile Safari/537.36";
const ANDROID_TABLET =
  "Mozilla/5.0 (Linux; Android 13; SM-X700) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/139.0.0.0 Safari/537.36";
const WINDOWS =
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/139.0.0.0 Safari/537.36";
const TESLA =
  "Mozilla/5.0 (X11; GNU/Linux) AppleWebKit/537.36 (KHTML, like Gecko) Chromium/136.0.0.0 Chrome/136.0.0.0 Safari/537.36 Tesla/2025.20.6";
const FB_IAB =
  "Mozilla/5.0 (Linux; Android 14; SM-A546B Build/UP1A.231005.007; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/139.0.0.0 Mobile Safari/537.36 [FB_IAB/FB4A;FBAV/520.0.0.51.109;]";
const GOOGLEBOT =
  "Mozilla/5.0 (Linux; Android 6.0.1; Nexus 5X Build/MMB29P) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/139.0.0.0 Mobile Safari/537.36 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)";

test("the first page of a visitor's day counts the visitor, the visit and where it came from", () => {
  // No `e` flag: a first page of the day starts a visit by definition.
  const hit = normalizeHit({
    t: "view", p: "/damtenebi/", u: 1, n: 1, r: "www.google.com", tz: "Asia/Tbilisi",
  });
  assert.deepStrictEqual(counts(hit, ANDROID), {
    views: 1,
    pages: { "/damtenebi/": 1 },
    visitors: 1,
    newVisitors: 1,
    visits: 1,
    entries: { "/damtenebi/": 1 },
    sources: { google: 1 },
    referrers: { "google.com": 1 },
    countries: { GE: 1 },
    devices: { mobile: 1 },
    os: { android: 1 },
  });
});

test("a page read later in the same visit is a view and nothing else", () => {
  // Whatever a client claims about referrer or source, only a visit's first
  // page describes where the visit came from.
  const hit = normalizeHit({
    t: "view", p: "/qselebi/", r: "spam.example", s: "spam", tz: "Asia/Tbilisi",
  });
  assert.deepStrictEqual(counts(hit, IPHONE), { views: 1, pages: { "/qselebi/": 1 } });
});

test("a store click is filed under the page it happened on", () => {
  const hit = normalizeHit({ t: "click", p: "/get/", k: "appstore" });
  assert.deepStrictEqual(counts(hit, IPHONE), {
    clicks: { appstore: 1 },
    clickPages: { "/get/": { appstore: 1 } },
  });
  assert.strictEqual(normalizeHit({ t: "click", p: "/", k: "huawei" }), null);
});

test("a campaign is keyed by its source, so two networks never share a row", () => {
  const hit = normalizeHit({ t: "view", p: "/", e: 1, s: "Facebook", c: "Poster 12" });
  assert.deepStrictEqual(counts(hit, WINDOWS).campaigns, { "facebook · poster 12": 1 });
});

test("junk never becomes a map key of its own", () => {
  assert.strictEqual(cleanPath("/Blog/Index.html"), "/blog/");
  assert.strictEqual(cleanPath("/damtenebi//tbilisi/"), "/damtenebi/tbilisi/");
  assert.strictEqual(cleanPath("/ჩამოტვირთვა/"), "(other)");
  assert.strictEqual(cleanPath("/a".repeat(80)), "(other)");
  assert.strictEqual(cleanPath("no-leading-slash"), null);

  assert.strictEqual(normalizeHit("a string"), null);
  assert.strictEqual(normalizeHit({ t: "view" }), null);
  assert.strictEqual(normalizeHit({ t: "sale", p: "/" }), null);

  const hit = normalizeHit({ t: "view", p: "/", e: 1, r: "<script>", s: "__proto__", tz: "constructor" });
  assert.strictEqual(hit.ref, "");
  assert.strictEqual(hit.source, "");
  assert.strictEqual(countryOf(hit.tz), "unknown");
  assert.strictEqual(countryOf("__proto__"), "unknown");
});

test("sources: utm first, then the referrer, then the in-app browser", () => {
  const src = (hit, ua = WINDOWS) => sourceOf({ source: "", ref: "", ...hit }, ua);

  assert.strictEqual(src({ ref: "gemini.google.com" }), "gemini"); // not Google search
  assert.strictEqual(src({ ref: "mail.google.com" }), "email");
  assert.strictEqual(src({ ref: "google.com.ge" }), "google");
  assert.strictEqual(src({ ref: "com.google.android.googlequicksearchbox" }), "google");
  assert.strictEqual(src({ ref: "l.facebook.com" }), "facebook");
  assert.strictEqual(src({ ref: "chatgpt.com" }), "chatgpt");
  assert.strictEqual(src({ ref: "myauto.ge" }), "referral");

  assert.strictEqual(src({ source: "fb", ref: "google.com" }), "facebook");
  assert.strictEqual(src({ source: "newsletter" }), "newsletter");

  assert.strictEqual(src({}, FB_IAB), "facebook");
  assert.strictEqual(src({}, IPHONE), "direct");
});

test("devices, including a Tesla's browser", () => {
  assert.deepStrictEqual(deviceOf(IPHONE), { os: "ios", device: "mobile" });
  assert.deepStrictEqual(deviceOf(ANDROID), { os: "android", device: "mobile" });
  assert.deepStrictEqual(deviceOf(ANDROID_TABLET), { os: "android", device: "tablet" });
  assert.deepStrictEqual(deviceOf(WINDOWS), { os: "windows", device: "desktop" });
  assert.deepStrictEqual(deviceOf(TESLA), { os: "linux", device: "car" });
});

test("countries come from the time zone, old zone names included", () => {
  assert.strictEqual(countryOf("Asia/Tbilisi"), "GE");
  assert.strictEqual(countryOf("Europe/Istanbul"), "TR");
  assert.strictEqual(countryOf("Asia/Yerevan"), "AM");
  // Chrome still reports these pre-rename names on some systems.
  assert.strictEqual(countryOf("Europe/Kiev"), "UA");
  assert.strictEqual(countryOf("Asia/Calcutta"), "IN");
  assert.strictEqual(countryOf("Mars/Olympus_Mons"), "unknown");
  assert.strictEqual(countryOf(undefined), "unknown");
});

test("crawlers are bots, in-app browsers and cars are not", () => {
  assert.ok(BOTS.test(GOOGLEBOT));
  assert.ok(BOTS.test("facebookexternalhit/1.1 (+http://www.facebook.com/externalhit_uatext.php)"));
  assert.ok(!BOTS.test(IPHONE));
  assert.ok(!BOTS.test(FB_IAB));
  assert.ok(!BOTS.test(TESLA));
});

test("a Tbilisi day starts at 20:00 UTC the evening before", () => {
  assert.strictEqual(tbilisiDay(Date.UTC(2026, 8, 14, 19, 59)), "2026-09-14");
  assert.strictEqual(tbilisiDay(Date.UTC(2026, 8, 14, 20, 0)), "2026-09-15");
});
