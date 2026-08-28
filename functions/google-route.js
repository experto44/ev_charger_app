"use strict";

// Reading a route — or a single place — the driver shared out of Google Maps.
//
// The phone sends the link it was given ("share directions" →
// https://maps.app.goo.gl/…) and gets back the stops, so the car can drive it.
// See docs/google_maps_share_links.md for the format and how it was worked out.
//
// A shared PLACE arrives through the same door and comes back as a trip with a
// destination and no stops: "I found the hotel on my phone, send it to the
// car." Google's share button produces the same short link for both, so which
// one it is can only be told from what it expands to — parseTarget's job.
//
// The same short link expands to one of two entirely different URLs depending
// on which Google Maps app made it. Android gives the modern
// google.com/maps/dir/<stops>/data=<blob>; iOS gives the old
// maps.google.com/?saddr=…&daddr=…&geocode=… with nothing but a slash for a
// path. Both describe the same trip, so both are read here.
//
// Why this is a Cloud Function and not code in the app: the `data=` blob in a
// Maps URL is undocumented and Google can change it whenever they like. Here a
// fix is a deploy; in the app it is an App Store review. The car cannot do it
// either — expanding the short link is a cross-origin redirect the browser will
// not let JavaScript read.
//
// What comes back is stops, never a road: Google does not share the computed
// polyline, so the route is recomputed by the Directions API at drive time.
// That is also what their terms require.

const { onCall, HttpsError } = require("firebase-functions/v2/https");
const logger = require("firebase-functions/logger");

const { underLimit } = require("./rate-limit");
const { parseTarget, placeName } = require("./google-route-parse");

// One driver sharing routes is doing it a handful of times a day. This is here
// to stop a loop, not to ration a feature.
const IMPORTS_PER_HOUR = 60;

// Every host we will fetch. The client picks the URL, so without this the
// function is an open proxy into anything the runtime can reach.
const SHORT_HOSTS = new Set(["maps.app.goo.gl", "goo.gl"]);
const LONG_HOST = /^(?:www\.)?google\.[a-z.]{2,6}$|^maps\.google\.[a-z.]{2,6}$/;

// A phone's user agent. The short-link service answers a desktop one too, but
// this is the request Google actually expects for these links.
const UA =
  "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) " +
  "Chrome/120.0.0.0 Mobile Safari/537.36";

function parseUrl(raw) {
  let u;
  try {
    u = new URL(String(raw || "").trim());
  } catch (_) {
    throw new HttpsError("invalid-argument", "That is not a link.");
  }
  if (u.protocol !== "https:") {
    throw new HttpsError("invalid-argument", "Only https links.");
  }
  return u;
}

function isShort(u) {
  return SHORT_HOSTS.has(u.hostname);
}

function isMaps(u) {
  if (!LONG_HOST.test(u.hostname)) return false;
  // The path test alone rejects every route shared off an iPhone: those land on
  // maps.google.com with the whole trip in the query and "/" for a path. A
  // shared place can land the same way, with the point in `q` or `ll`.
  return (
    u.pathname.startsWith("/maps") ||
    u.searchParams.has("daddr") ||
    u.searchParams.has("q") ||
    u.searchParams.has("ll")
  );
}

/**
 * Follow the short link. One hop only, and the destination is checked against
 * the same allow-list as the input: a redirect is a URL chosen by someone else.
 */
async function expand(u) {
  if (!isShort(u)) return u;

  let res;
  try {
    res = await fetch(u.toString(), {
      redirect: "manual",
      headers: { "user-agent": UA },
      signal: AbortSignal.timeout(10000),
    });
  } catch (err) {
    logger.warn("short link fetch failed", { host: u.hostname, err: String(err) });
    throw new HttpsError("unavailable", "Could not open that link. Try again.");
  }

  const loc = res.headers.get("location");
  if (!loc) {
    // Google answered, but not with a redirect. Either the link is dead or the
    // service has started doing something else — worth a log line, because the
    // second case means this function needs revisiting.
    logger.warn("short link did not redirect", { status: res.status, host: u.hostname });
    throw new HttpsError("not-found", "That link no longer works.");
  }

  const target = parseUrl(loc);
  if (!isMaps(target)) {
    logger.warn("short link left Google Maps", { host: target.hostname });
    throw new HttpsError("invalid-argument", "That link is not a Google Maps route.");
  }
  return target;
}

const placed = (s) => Number.isFinite(s.lat) && Number.isFinite(s.lng);

/**
 * Last resort for a place whose URL carries no coordinates.
 *
 * Some shared place links are nothing but an id — `/maps/place//data=!4m2!3m1!
 * !1s0x40440…` — which names a place Google knows and we do not. Rather than
 * refuse the driver's hotel, fetch the page they were given and take the
 * position out of it. Three sources, in order of how stable they are: the
 * static-map image Google puts in its own og:image tag, the coordinate block
 * in the embedded state, and the camera position.
 *
 * No API key and no Geocoding call: this is the same public page the link
 * opens. Returns null rather than throwing — the caller already has an error
 * worth reporting if this cannot help.
 */
async function placeFromPage(u) {
  let html;
  try {
    const res = await fetch(u.toString(), {
      headers: { "user-agent": UA, "accept-language": "en" },
      redirect: "follow",
      signal: AbortSignal.timeout(10000),
    });
    if (!res.ok) return null;
    // These pages are megabytes of script; the position is near the top.
    html = (await res.text()).slice(0, 500000);
  } catch (err) {
    logger.warn("place page fetch failed", { err: String(err) });
    return null;
  }

  const m =
    html.match(/staticmap[^"']*?center=(-?\d+(?:\.\d+)?)(?:%2C|,)(-?\d+(?:\.\d+)?)/) ||
    html.match(/!3d(-?\d+(?:\.\d+)?)!4d(-?\d+(?:\.\d+)?)/) ||
    html.match(/\/@(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?)/);
  if (!m) return null;
  const lat = Number(m[1]);
  const lng = Number(m[2]);
  if (!Number.isFinite(lat) || !Number.isFinite(lng)) return null;
  return { lat, lng, name: nameFromPage(html) };
}

/**
 * The place's name as the page states it. Google writes it into both an
 * itemprop and an og:title; the og:title is the one that survives their
 * markup changes better, so it is the fallback rather than the first choice
 * only because the itemprop is the more specific of the two.
 */
function nameFromPage(html) {
  const m =
    html.match(/<meta content="([^"]{1,120})" itemprop="name"/) ||
    html.match(/<meta property="og:title" content="([^"]{1,120})"/);
  if (!m) return null;
  const name = m[1].replace(/&amp;/g, "&").replace(/&#39;/g, "'").trim();
  // Google titles a place page "<Name> · <address>" (and, signed out, sometimes
  // just "Google Maps"). Only the name goes on a card in a car.
  const head = name.split(" · ")[0].trim();
  return !head || head === "Google Maps" ? null : head;
}

// ── The callable ─────────────────────────────────────────────────────────────
exports.importGoogleRoute = onCall(async (request) => {
  if (!request.auth) throw new HttpsError("unauthenticated", "Sign in required.");
  const uid = request.auth.uid;

  if (!(await underLimit(`gmaps_${uid}`, IMPORTS_PER_HOUR))) {
    throw new HttpsError("resource-exhausted", "Too many links. Try again later.");
  }

  const input = parseUrl(request.data?.url);
  if (!isShort(input) && !isMaps(input)) {
    throw new HttpsError("invalid-argument", "That is not a Google Maps link.");
  }

  const full = await expand(input);
  let parsed;
  try {
    parsed = parseTarget(full);
  } catch (err) {
    // A place the URL names but does not place. The page itself knows where it
    // is; anything else is a link we genuinely cannot read.
    if (err?.details?.reason !== "no-coords") throw err;
    const found = await placeFromPage(full);
    if (!found) throw err;
    parsed = {
      kind: "place",
      stop: { lat: found.lat, lng: found.lng, name: placeName(full) ?? found.name },
    };
    logger.info("google place located from the page", { uid });
  }

  // ── A single place ─────────────────────────────────────────────────────────
  // Answered in the same shape as a route so nothing downstream has to learn a
  // second one: the app already sends "a destination and its stops" to the car,
  // and this is that with the stops left out. `kind` is there for a client that
  // wants to word its own screen differently; today's app ignores it.
  if (parsed.kind === "place") {
    logger.info("google place imported", { uid, named: Boolean(parsed.stop.name) });
    return {
      kind: "place",
      origin: null,
      waypoints: [],
      destination: parsed.stop,
      dropped: [],
      avoidTolls: false,
      avoidHighways: false,
      avoidFerries: false,
    };
  }

  if (parsed.mode !== "0") {
    // A machine-readable reason alongside the message: the app has to tell
    // "not a driving route" apart from "not a route link" to say the right
    // thing, and matching on English prose would break the first time either
    // sentence is reworded.
    throw new HttpsError("invalid-argument", "That route is not for driving.", {
      reason: "not-driving",
    });
  }

  const stops = parsed.stops;
  const destination = stops[stops.length - 1];
  if (!placed(destination)) {
    // Without a destination there is no trip. This is the case that needs
    // geocoding to do better, which needs a server-side Maps key we do not have.
    throw new HttpsError("invalid-argument", "Could not read the destination.");
  }

  // A middle stop we could not place is dropped rather than fatal: the trip is
  // still drivable, and the caller is told what went missing so it can say so.
  // A link that names no origin starts its stops at the first waypoint, so the
  // slice has to know which it is looking at.
  const middle = stops.slice(parsed.hasOrigin ? 1 : 0, -1);
  const waypoints = middle.filter(placed);
  const dropped = middle.filter((s) => !placed(s)).map((s) => s.name);

  logger.info("google route imported", {
    uid,
    stops: waypoints.length,
    dropped: dropped.length,
    avoidTolls: parsed.avoidTolls,
  });

  return {
    kind: "route",
    // Informational only: the car always starts from its own live GPS.
    origin: parsed.hasOrigin && placed(stops[0]) ? stops[0] : null,
    waypoints,
    destination,
    dropped,
    avoidTolls: parsed.avoidTolls,
    avoidHighways: parsed.avoidHighways,
    avoidFerries: parsed.avoidFerries,
  };
});
