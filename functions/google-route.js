"use strict";

// Reading a route the driver shared out of the Google Maps app.
//
// The phone sends the link it was given ("share directions" →
// https://maps.app.goo.gl/…) and gets back the stops, so the car can drive it.
// See docs/google_maps_share_links.md for the format and how it was worked out.
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

// One driver sharing routes is doing it a handful of times a day. This is here
// to stop a loop, not to ration a feature.
const IMPORTS_PER_HOUR = 60;

// Every host we will fetch. The client picks the URL, so without this the
// function is an open proxy into anything the runtime can reach.
const SHORT_HOSTS = new Set(["maps.app.goo.gl", "goo.gl"]);
const LONG_HOST = /^(?:www\.)?google\.[a-z.]{2,6}$|^maps\.google\.[a-z.]{2,6}$/;

const COORD = /^(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?)$/;

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
  return LONG_HOST.test(u.hostname) && u.pathname.startsWith("/maps");
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

/**
 * Pull the stops out of an expanded directions URL.
 *
 * Two sources, both needed. The path carries the stops in road order, as either
 * "lat,lng" or a place name. The data blob carries one coordinate block per
 * NAMED stop, in the same order — so walking the path and consuming a block per
 * name lines the two up.
 */
function parseDirections(u) {
  const m = u.pathname.match(/\/maps\/dir\/(.+?)(?:\/data=|\/@|$)/);
  if (!m) throw new HttpsError("invalid-argument", "That link is not a route, just a place.");

  // Google writes spaces as '+' in these segments, and decodeURIComponent
  // leaves them alone — in a path a plus is a literal plus.
  const segments = m[1]
    .split("/")
    .filter(Boolean)
    .map((seg) => {
      try {
        return decodeURIComponent(seg).replace(/\+/g, " ").trim();
      } catch (_) {
        return seg.replace(/\+/g, " ").trim();
      }
    });
  if (segments.length < 2) {
    throw new HttpsError("invalid-argument", "That route has no destination.");
  }

  const data = (u.pathname.match(/\/data=([^/?]+)/) || [])[1] || "";
  // Anchored on the coordinate pair rather than the !1m5!1m4 around it, so a
  // change in Google's field counts does not break the parse. 3d is latitude.
  const coords = [...data.matchAll(/!8m2!3d(-?\d+(?:\.\d+)?)!4d(-?\d+(?:\.\d+)?)/g)].map((c) => ({
    lat: Number(c[1]),
    lng: Number(c[2]),
  }));

  let next = 0;
  const stops = segments.map((seg) => {
    const c = seg.match(COORD);
    if (c) return { lat: Number(c[1]), lng: Number(c[2]), name: null };
    const pt = coords[next++];
    return pt ? { lat: pt.lat, lng: pt.lng, name: seg } : { lat: null, lng: null, name: seg };
  });

  // 0 driving, 1 bicycling, 2 walking, 3 transit. Anything else is a route this
  // car cannot drive.
  const mode = (data.match(/!3e(\d)/) || [])[1] ?? "0";

  // Route options group. 2b1 = avoid tolls, confirmed against a real shared
  // link and an A/B on maps.google.com. The 3b/4b positions are the usual
  // guess for highways and ferries and are NOT confirmed, so they are reported
  // but the app offers its own toggles rather than trusting these.
  const opts = (data.match(/!2m\d+((?:!\d+b[01])+)/) || [])[1] || "";

  return {
    stops,
    mode,
    avoidTolls: opts.includes("!2b1"),
    avoidHighways: opts.includes("!3b1"),
    avoidFerries: opts.includes("!4b1"),
  };
}

const placed = (s) => Number.isFinite(s.lat) && Number.isFinite(s.lng);

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
  const parsed = parseDirections(full);

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
  const middle = stops.slice(1, -1);
  const waypoints = middle.filter(placed);
  const dropped = middle.filter((s) => !placed(s)).map((s) => s.name);

  logger.info("google route imported", {
    uid,
    stops: waypoints.length,
    dropped: dropped.length,
    avoidTolls: parsed.avoidTolls,
  });

  return {
    // Informational only: the car always starts from its own live GPS.
    origin: placed(stops[0]) ? stops[0] : null,
    waypoints,
    destination,
    dropped,
    avoidTolls: parsed.avoidTolls,
    avoidHighways: parsed.avoidHighways,
    avoidFerries: parsed.avoidFerries,
  };
});
