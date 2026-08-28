"use strict";

// Regression fixtures for the Google Maps link parser.
//
//   cd functions && node --test
//
// No network and no dependencies: every URL here is one an expanded share link
// really produced, so the parser can be reshaped without a phone in hand.
//
// The two families must both keep working. Android shares the modern
// /maps/dir/ form; iOS shares the old query form. A fix for one silently
// breaking the other is exactly what these are here to catch.

const test = require("node:test");
const assert = require("node:assert");

const { parseRoute, parseTarget } = require("./google-route-parse");

const route = (url) => parseRoute(new URL(url));
const target = (url) => parseTarget(new URL(url));
const near = (actual, expected, what) =>
  assert.ok(Math.abs(actual - expected) < 1e-5, what + ": " + actual + " is not " + expected);

// ── iOS: the old query form ──────────────────────────────────────────────────
// Captured 2026-08-29 by expanding three maps.app.goo.gl links shared out of
// the iOS app. The tracking parameters (lucs, g_ep, skid, g_st) are dropped
// here for readability; nothing reads them.

const IOS_SARPI =
  "https://maps.google.com/?geocode=FbfcewIdR56sAg%3D%3D;FUePeQIdk_p5AinL70llPZFnQDE2JQu0CWRl7g%3D%3D" +
  "&daddr=%E1%83%A1%E1%83%90%E1%83%A0%E1%83%A4%E1%83%98%E1%83%A1+%E1%83%A1%E1%83%90%E1%83%A1%E1%83%90" +
  "%E1%83%96%E1%83%A6%E1%83%95%E1%83%A0%E1%83%9D-%E1%83%92%E1%83%90%E1%83%9B%E1%83%A8%E1%83%95%E1%83%94" +
  "%E1%83%91%E1%83%98+%E1%83%9E%E1%83%A3%E1%83%9C%E1%83%A5%E1%83%A2%E1%83%98,+E70,+Sarpi" +
  "&saddr=41.6718630,44.8671428&dirflg=d&ftid=0x4067913d6549efcb:0xee656409b40b2536";

const IOS_WITH_STOP =
  "https://maps.google.com/?geocode=FdPfewIdYaGsAg%3D%3D;FW0KgwIdMtiPAimPJAXyqb9cQDEiCBX1sCZ8_Q%3D%3D;" +
  "FUePeQIdk_p5AinL70llPZFnQDE2JQu0CWRl7g%3D%3D" +
  "&daddr=Argveta+to:SARPI+%7C+Georgian-Turkish+border,+E70,+Sarpi" +
  "&saddr=41.6726588,44.8679366&dirflg=d";

const IOS_NO_TOLLS =
  "https://maps.google.com/?geocode=FbTcewIdPZ6sAg%3D%3D;FW68cQIdtyy6ASlrCGgABKfKFDHQsAG8mP7M4Q%3D%3D" +
  "&daddr=Istanbul,+%C4%B0stanbul,+T%C3%BCrkiye&saddr=41.6718602,44.8671333&dirflg=dt";

test("iOS link: a plain drive to one destination", () => {
  const r = route(IOS_SARPI);
  assert.equal(r.mode, "0");
  assert.equal(r.hasOrigin, true);
  assert.equal(r.avoidTolls, false);
  assert.equal(r.stops.length, 2);

  // The origin is written as coordinates and answers for itself.
  near(r.stops[0].lat, 41.671863, "origin lat");
  near(r.stops[0].lng, 44.8671428, "origin lng");

  // The destination's position comes out of the geocode blob, and matches the
  // one the Android form of this same route carries in its data= blob
  // (41.5209672, 41.5484345) to six decimals.
  near(r.stops[1].lat, 41.520967, "destination lat");
  near(r.stops[1].lng, 41.548435, "destination lng");
  assert.equal(r.stops[1].name, "სარფის სასაზღვრო-გამშვები პუნქტი");
});

test("iOS link: a mid-route stop, written after a to: separator", () => {
  const r = route(IOS_WITH_STOP);
  assert.equal(r.stops.length, 3);
  assert.equal(r.hasOrigin, true);

  assert.equal(r.stops[1].name, "Argveta");
  near(r.stops[1].lat, 42.142317, "stop lat");
  near(r.stops[1].lng, 42.981426, "stop lng");

  // "SARPI | Georgian-Turkish border, E70, Sarpi" is too long for the card the
  // car shows, so only the head survives.
  assert.equal(r.stops[2].name, "SARPI");
  near(r.stops[2].lat, 41.520967, "destination lat");
});

test("iOS link: dirflg=dt is a drive with tolls switched off", () => {
  const r = route(IOS_NO_TOLLS);
  assert.equal(r.mode, "0");
  assert.equal(r.avoidTolls, true);
  assert.equal(r.avoidHighways, false);
  assert.equal(r.stops.at(-1).name, "Istanbul");
  near(r.stops.at(-1).lat, 41.008238, "destination lat");
  near(r.stops.at(-1).lng, 28.978359, "destination lng");
});

test("iOS link: dirflg letters that are not a drive", () => {
  assert.equal(route(IOS_SARPI.replace("dirflg=d", "dirflg=w")).mode, "2");
  assert.equal(route(IOS_SARPI.replace("dirflg=d", "dirflg=r")).mode, "3");
  assert.equal(route(IOS_SARPI.replace("dirflg=d", "dirflg=b")).mode, "1");
});

test("iOS link with no origin does not mistake the destination for one", () => {
  const r = route(
    "https://maps.google.com/?geocode=FW68cQIdtyy6ASlrCGgABKfKFDHQsAG8mP7M4Q%3D%3D" +
      "&daddr=Istanbul,+%C4%B0stanbul,+T%C3%BCrkiye&dirflg=d"
  );
  assert.equal(r.hasOrigin, false);
  assert.equal(r.stops.length, 1);
  near(r.stops[0].lat, 41.008238, "destination lat");
});

test("iOS link with no coordinates at all still names its stops", () => {
  const r = route("https://maps.google.com/?daddr=Batumi&saddr=Tbilisi&dirflg=d");
  assert.equal(r.stops.length, 2);
  assert.equal(r.stops[1].name, "Batumi");
  assert.equal(r.stops[1].lat, null); // the caller refuses this, it does not guess
});

// ── Android: the modern /maps/dir/ form ──────────────────────────────────────
// Verbatim from docs/google_maps_share_links.md, which recorded it from a real
// share. The variants below add tokens documented in that same file.

const ANDROID_WITH_STOP =
  "https://www.google.com/maps/dir/41.6721448,44.8673392/%E1%83%90%E1%83%A0%E1%83%92%E1%83%95%E1%83%94" +
  "%E1%83%97%E1%83%90/%E1%83%A1%E1%83%90%E1%83%A0%E1%83%A4%E1%83%98%E1%83%A1+%E1%83%A1%E1%83%90%E1%83%A1" +
  "%E1%83%90%E1%83%96%E1%83%A6%E1%83%95%E1%83%A0%E1%83%9D-%E1%83%92%E1%83%90%E1%83%9B%E1%83%A8%E1%83%95" +
  "%E1%83%94%E1%83%91%E1%83%98+%E1%83%9E%E1%83%A3%E1%83%9C%E1%83%A5%E1%83%A2%E1%83%98" +
  "/data=!4m16!4m15!1m1!4e1" +
  "!1m5!1m4!1s0x405cbffb2163c16f:0xb5bd08f6f42ad6c!8m2!3d42.1329735!4d42.9844081" +
  "!1m5!1m4!1s0x4067913d6549efcb:0xee656409b40b2536!8m2!3d41.5209672!4d41.5484345!3e0";

test("Android link: path names lined up with the data blob", () => {
  const r = route(ANDROID_WITH_STOP);
  assert.equal(r.mode, "0");
  assert.equal(r.hasOrigin, true);
  assert.equal(r.avoidTolls, false);
  assert.equal(r.stops.length, 3);

  near(r.stops[0].lat, 41.6721448, "origin lat");
  assert.equal(r.stops[0].name, null);

  assert.equal(r.stops[1].name, "არგვეთა");
  near(r.stops[1].lat, 42.1329735, "stop lat");
  near(r.stops[1].lng, 42.9844081, "stop lng");

  assert.equal(r.stops[2].name, "სარფის სასაზღვრო-გამშვები პუნქტი");
  near(r.stops[2].lat, 41.5209672, "destination lat");
  near(r.stops[2].lng, 41.5484345, "destination lng");
});

test("Android link: the confirmed avoid-tolls group", () => {
  assert.equal(route(ANDROID_WITH_STOP.replace("!3e0", "!2m1!2b1!3e0")).avoidTolls, true);
});

test("Android link: a walking route is reported as one", () => {
  assert.equal(route(ANDROID_WITH_STOP.replace("!3e0", "!3e2")).mode, "2");
});

// ── The documented ?api=1 form ───────────────────────────────────────────────

test("api=1 links are read when their stops carry coordinates", () => {
  const r = route(
    "https://www.google.com/maps/dir/?api=1&origin=41.7151,44.8271" +
      "&destination=41.6168,41.6367&waypoints=42.1329735,42.9844081|Argveta" +
      "&travelmode=driving&avoid=tolls"
  );
  assert.equal(r.hasOrigin, true);
  assert.equal(r.avoidTolls, true);
  assert.equal(r.stops.length, 4);
  near(r.stops[1].lat, 42.1329735, "waypoint lat");
  assert.equal(r.stops[2].name, "Argveta"); // named, and this form carries no coordinates
  assert.equal(r.stops[2].lat, null);
  near(r.stops[3].lng, 41.6367, "destination lng");
});

// ── Links that are not routes ────────────────────────────────────────────────

test("a place is refused, and says so", () => {
  for (const url of [
    "https://www.google.com/maps/place/Tbilisi/@41.7151,44.8271,12z",
    "https://maps.google.com/?q=Tbilisi&ftid=0x40440cd7e64f626b:0x91ef4e3aa42303fc",
    "https://www.google.com/maps/dir/",
  ]) {
    assert.throws(() => route(url), /not a route/, url);
  }
});

// ── A single place, shared instead of a route ────────────────────────────────
// Same short link, same door, different shape at the other end: the driver
// found a hotel on the phone and sent where it is, not how to get there.
// parseRoute still refuses these (above); parseTarget is what reads them.

test("a shared place gives its exact coordinates and its name", () => {
  const p = target(
    "https://www.google.com/maps/place/Rooms+Hotel+Tbilisi/@41.7092,44.7862,17z/" +
      "data=!3m1!4b1!4m9!3m8!1s0x40440cd7e64f626b:0x1f0!5m2!4m1!1i2" +
      "!8m2!3d41.7092123!4d44.7862456!16s%2Fg%2F1td_0abc"
  );
  assert.equal(p.kind, "place");
  assert.equal(p.stop.name, "Rooms Hotel Tbilisi");
  // The data blob, not the @ camera position two decimals coarser.
  near(p.stop.lat, 41.7092123, "place lat");
  near(p.stop.lng, 44.7862456, "place lng");
});

test("a dropped pin is a place with coordinates for a name", () => {
  const p = target("https://www.google.com/maps/place/41.71350,44.79700/@41.7135,44.797,15z");
  assert.equal(p.kind, "place");
  assert.equal(p.stop.name, null);
  near(p.stop.lat, 41.7135, "pin lat");
});

test("the old query forms of a place are read too", () => {
  for (const url of [
    "https://maps.google.com/?q=41.7135,44.7970",
    "https://www.google.com/maps/search/?api=1&query=41.7135,44.7970",
    "https://www.google.com/maps/@41.7135,44.797,14z",
  ]) {
    const p = target(url);
    assert.equal(p.kind, "place", url);
    near(p.stop.lng, 44.797, url);
  }
});

test("a place with no coordinates anywhere is refused rather than guessed", () => {
  assert.throws(
    () => target("https://www.google.com/maps/place/Hotel+Astoria/data=!4m2!3m1!1s0x40440"),
    /Could not read that location/
  );
});

test("routes still parse as routes, not as the @ position they also carry", () => {
  const r = target(IOS_SARPI);
  assert.equal(r.kind, "route");
  assert.equal(r.stops.length, 2);
});
