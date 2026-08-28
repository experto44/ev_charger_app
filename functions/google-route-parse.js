"use strict";

// Turning an expanded Google Maps URL into a list of stops.
//
// Kept apart from google-route.js because this half is pure: a URL in, a route
// out, no network and no Firestore. That is what makes it testable, and it is
// the half that has to change every time Google reshapes a link.
//
// Three shapes are read. See docs/google_maps_share_links.md.

const { HttpsError } = require("firebase-functions/v2/https");

const COORD = /^(-?\d+(?:\.\d+)?),\s*(-?\d+(?:\.\d+)?)$/;

// Travel modes, mapped onto the numbers the modern `!3e` blob uses so every
// parser answers in one vocabulary. `dirflg` letters first, then the words the
// documented ?api=1 form spells out.
const LEGACY_MODES = { d: "0", b: "1", w: "2", r: "3" };
const API_MODES = { driving: "0", bicycling: "1", walking: "2", transit: "3" };

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
    // This form always writes the origin first; the segment count check above
    // is what guarantees there is a destination after it.
    hasOrigin: true,
    mode,
    avoidTolls: opts.includes("!2b1"),
    avoidHighways: opts.includes("!3b1"),
    avoidFerries: opts.includes("!4b1"),
  };
}

// ── The old URL form, which is what an iPhone shares ─────────────────────────

/**
 * Decode the `geocode=` parameter: one `;`-separated entry per stop, in the
 * same order as the addresses, base64url over a small protobuf.
 *
 * Field 2 is latitude and field 3 longitude, both fixed32 in millionths.
 * Fields 5 and 6 repeat the place's ftid and are skipped. Confirmed against
 * three links shared off an iPhone: the coordinates come out identical to the
 * ones the Android form of the same route carries in its `data=` blob.
 *
 * An entry that will not decode becomes null rather than throwing. One
 * unreadable middle stop must not lose the driver the whole trip.
 */
function geocodePoints(raw) {
  return String(raw || "")
    .split(";")
    .filter(Boolean)
    .map((entry) => {
      const buf = Buffer.from(entry.trim().replace(/-/g, "+").replace(/_/g, "/"), "base64");
      let lat = null;
      let lng = null;
      let i = 0;
      while (i < buf.length) {
        const tag = buf[i++];
        const field = tag >> 3;
        const wire = tag & 7;
        if (wire === 5) {
          if (i + 4 > buf.length) break;
          const v = buf.readUInt32LE(i);
          i += 4;
          if (field === 2) lat = v / 1e6;
          else if (field === 3) lng = v / 1e6;
        } else if (wire === 1) {
          i += 8; // the ftid halves
        } else if (wire === 0) {
          while (i < buf.length && buf[i++] & 0x80); // varint
        } else {
          break; // a length-delimited field we have never seen; stop guessing
        }
      }
      return lat === null || lng === null ? null : { lat, lng };
    });
}

/**
 * The name in an old-form link is the full postal string:
 * "SARPI | Georgian-Turkish border, E70, Sarpi". The car shows it on a card the
 * driver reads at a glance, so keep the head of it.
 *
 * A head of one or two characters is a house number rather than a place, so
 * that keeps the whole string instead.
 */
function shortName(name) {
  if (!name) return name;
  const head = name.split("|")[0].split(",")[0].trim();
  return head.length >= 3 ? head : name.trim();
}

/**
 * Pull the stops out of `?saddr=…&daddr=…&geocode=…`.
 *
 * Stops are the origin followed by the `daddr` value split on " to:", and the
 * `geocode` list runs in that same order with one entry per stop — including
 * the origin, even when the origin is already written as coordinates. So when
 * the two lists are the same length they line up by index; when they are not,
 * fall back to letting coordinate segments answer for themselves and giving
 * each named one the next unconsumed entry.
 */
function parseLegacy(u) {
  const q = u.searchParams;
  const daddr = (q.get("daddr") || "").trim();
  if (!daddr) throw new HttpsError("invalid-argument", "That link is not a route, just a place.");

  const saddr = (q.get("saddr") || "").trim();
  const names = [];
  if (saddr) names.push(saddr);
  for (const seg of daddr.split(/\s+to:/)) {
    const s = seg.trim();
    if (s) names.push(s);
  }
  if (!names.length) {
    throw new HttpsError("invalid-argument", "That route has no destination.");
  }

  const points = geocodePoints(q.get("geocode"));
  const aligned = points.length === names.length;
  let next = 0;
  const stops = names.map((name, idx) => {
    const c = name.match(COORD);
    if (c) return { lat: Number(c[1]), lng: Number(c[2]), name: null };
    const pt = aligned ? points[idx] : points[next++];
    return pt
      ? { lat: pt.lat, lng: pt.lng, name: shortName(name) }
      : { lat: null, lng: null, name: shortName(name) };
  });

  // The mode is the first letter and the avoidances follow it: "d" is a plain
  // drive, "dt" is a drive with tolls switched off. `t` is confirmed against a
  // Tbilisi → Istanbul link shared with tolls off; `h` and `f` are the
  // conventional letters for highways and ferries and are not confirmed, which
  // matches how the modern form's flags are treated.
  const dirflg = (q.get("dirflg") || "d").toLowerCase();
  const mode = LEGACY_MODES[dirflg[0]] ?? "0";
  const flags = LEGACY_MODES[dirflg[0]] ? dirflg.slice(1) : dirflg;

  return {
    stops,
    hasOrigin: Boolean(saddr),
    mode,
    avoidTolls: flags.includes("t"),
    avoidHighways: flags.includes("h"),
    avoidFerries: flags.includes("f"),
  };
}

/**
 * `/maps/dir/?api=1&origin=…&destination=…&waypoints=A|B` — the one form Google
 * documents. Nothing shares links in it, but a hand-made one is a fair thing to
 * paste, and it is a dozen lines. There is no coordinate blob, so a stop
 * written as a name has nowhere to get its position from and is reported as
 * dropped rather than guessed at.
 */
function parseApiForm(u) {
  const q = u.searchParams;
  const names = [];
  const origin = (q.get("origin") || "").trim();
  if (origin) names.push(origin);
  for (const seg of (q.get("waypoints") || "").split("|")) {
    const s = seg.trim();
    if (s) names.push(s);
  }
  const destination = (q.get("destination") || "").trim();
  if (!destination) throw new HttpsError("invalid-argument", "That route has no destination.");
  names.push(destination);

  const stops = names.map((name) => {
    const c = name.match(COORD);
    return c
      ? { lat: Number(c[1]), lng: Number(c[2]), name: null }
      : { lat: null, lng: null, name: shortName(name) };
  });

  const travel = (q.get("travelmode") || "driving").toLowerCase();
  const mode = API_MODES[travel] ?? "0";
  const avoid = (q.get("avoid") || "").toLowerCase();

  return {
    stops,
    hasOrigin: Boolean(origin),
    mode,
    avoidTolls: avoid.includes("tolls"),
    avoidHighways: avoid.includes("highways"),
    avoidFerries: avoid.includes("ferries"),
  };
}

// ── A single place, rather than a route ──────────────────────────────────────
// "I found the hotel on my phone, send it to the car." Google Maps' own share
// button on a place produces the same maps.app.goo.gl link shape as a shared
// route, so the only thing that tells the two apart is what it expands to.

/** Decode one path segment: Google writes spaces as '+' in these. */
function segment(raw) {
  try {
    return decodeURIComponent(raw).replace(/\+/g, " ").trim();
  } catch (_) {
    return String(raw).replace(/\+/g, " ").trim();
  }
}

const coordOf = (v) => {
  const c = String(v || "").trim().match(COORD);
  return c ? { lat: Number(c[1]), lng: Number(c[2]) } : null;
};

/**
 * The place's real coordinates, in order of how much they can be trusted.
 *
 * The `data=` blob is the place itself: `!8m2!3d<lat>!4d<lng>` is the same
 * block a shared route carries per stop. `@lat,lng,17z` is only where the
 * CAMERA was, which for a shared place is on it — close enough to drive to,
 * but never preferred over the real thing.
 */
function placePoint(u) {
  const data = (u.pathname.match(/\/data=([^/?]+)/) || [])[1] || u.search || "";
  const exact = data.match(/!8m2!3d(-?\d+(?:\.\d+)?)!4d(-?\d+(?:\.\d+)?)/) ||
    data.match(/!3d(-?\d+(?:\.\d+)?)!4d(-?\d+(?:\.\d+)?)/);
  if (exact) return { lat: Number(exact[1]), lng: Number(exact[2]) };

  // /maps/place/41.7,44.8 — a dropped pin has coordinates for a name.
  const named = (u.pathname.match(/\/maps\/(?:place|search)\/([^/@]+)/) || [])[1];
  const fromName = named ? coordOf(segment(named)) : null;
  if (fromName) return fromName;

  const q = u.searchParams;
  for (const key of ["q", "query", "ll", "center", "sll", "daddr"]) {
    const c = coordOf(q.get(key));
    if (c) return c;
  }

  const at = u.pathname.match(/\/@(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?)/);
  if (at) return { lat: Number(at[1]), lng: Number(at[2]) };
  return null;
}

/** The place's name, where the link carries one worth showing on a car screen. */
function placeName(u) {
  const seg = (u.pathname.match(/\/maps\/(?:place|search)\/([^/@]+)/) || [])[1];
  const fromPath = seg ? segment(seg) : "";
  if (fromPath && !COORD.test(fromPath)) return shortName(fromPath);

  const q = u.searchParams.get("q") || u.searchParams.get("query") || "";
  const decoded = q.trim();
  if (decoded && !COORD.test(decoded)) return shortName(decoded);
  return null;
}

/**
 * Read a shared place. Throws when the link names somewhere we cannot put on a
 * map — a `cid=` link or a bare search phrase carries no coordinates at all,
 * and guessing one would send a driver to the wrong hotel.
 */
function parsePlace(u) {
  const point = placePoint(u);
  if (!point) {
    throw new HttpsError("invalid-argument", "Could not read that location.", {
      reason: "no-coords",
    });
  }
  return { kind: "place", stop: { ...point, name: placeName(u) } };
}

/**
 * Pick the parser by the shape of the URL rather than by where the link came
 * from: the app cannot tell us which phone shared it, and a link forwarded
 * between phones would make that a lie anyway.
 */
function parseRoute(u) {
  if (/\/maps\/dir\/.+/.test(u.pathname)) return parseDirections(u);
  if (u.searchParams.has("daddr")) return parseLegacy(u);
  if (u.searchParams.get("api") === "1" && u.searchParams.has("destination")) {
    return parseApiForm(u);
  }
  throw new HttpsError("invalid-argument", "That link is not a route, just a place.");
}

/**
 * A route where the link describes one, a single place where it describes that.
 * Both end up in the car's inbox as somewhere to drive to; the difference is
 * only how many points came with it.
 *
 * Order matters: a directions link also carries `@lat,lng` and would parse as
 * a place, so every route shape is tried first and the place is the fallback.
 */
function parseTarget(u) {
  if (/\/maps\/dir\/.+/.test(u.pathname)) return { kind: "route", ...parseDirections(u) };
  if (u.searchParams.has("daddr")) return { kind: "route", ...parseLegacy(u) };
  if (u.searchParams.get("api") === "1" && u.searchParams.has("destination")) {
    return { kind: "route", ...parseApiForm(u) };
  }
  return parsePlace(u);
}

module.exports = {
  parseRoute,
  parseTarget,
  parsePlace,
  placeName,
  parseDirections,
  parseLegacy,
  parseApiForm,
  geocodePoints,
  shortName,
};
