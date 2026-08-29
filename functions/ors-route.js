"use strict";

// Road geometry from OpenRouteService, so the car app stops buying it from
// Google Directions — the most expensive Maps SKU we use and the one already
// pressed against its daily free-tier ceiling.
//
// Why this is a function and not a fetch from the browser: an ORS key cannot be
// restricted to a domain the way our Google browser key is, so a key shipped in
// tesla/js/ would be readable by anyone who opens the site and our 2,000
// routes/day could be spent by strangers. Here the key stays in Secret Manager,
// the caller has to be a signed-in GeoCharge user, and the quota is ours.
//
//   firebase functions:secrets:set ORS_API_KEY
//
// Until that secret exists this function fails cleanly and the car app falls
// back to Google, so deploying it early changes nothing for drivers.
//
// Measured before writing this (2026-08-29): ORS/OSRM road geometry matches
// Google to within ~1 km everywhere the car app operates — all of Georgia and
// all of Turkey, including Tbilisi → İstanbul at 1620 km. It is NOT accurate in
// Azerbaijan, which the car app never covers.

const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { defineSecret } = require("firebase-functions/params");
const logger = require("firebase-functions/logger");
const { underLimit } = require("./rate-limit");
const { roadFrom } = require("./ors-route-parse");

const ORS_API_KEY = defineSecret("ORS_API_KEY");

// Secret Manager will not store an empty value, and a function that declares a
// secret cannot deploy until that secret exists — so this was first deployed
// holding the sentinel below. It means "no key yet": the function fails fast and
// the car app falls back to Google, instead of spending a round trip to collect
// a 401. Replacing it is one command:
//
//   firebase functions:secrets:set ORS_API_KEY
//   firebase deploy --only functions:orsRoute
const UNSET = "unset";

// api.openrouteservice.org is being retired in favour of api.heigit.org, and
// the announcement gave no cut-off date. Rather than bet on one, try the
// documented host and fall back to its replacement on a transport-level or
// 404/410 failure — an expired host fails over instead of taking routing down.
const ORS_HOSTS = [
  "https://api.openrouteservice.org",
  "https://api.heigit.org",
];
const ORS_PATH = "/v2/directions/driving-car/geojson";

// Georgia + Turkey with room to spare. The car app never plans outside this,
// and refusing the rest keeps our free quota from becoming a public world
// router. Out-of-box requests fall back to Google on the client.
const BBOX = { minLat: 34, maxLat: 45, minLng: 24, maxLng: 48 };

const MAX_WAYPOINTS = 6;   // the planner allows 5 stops
const PER_HOUR = 150;      // per signed-in user; planning is debounced client-side
const TIMEOUT_MS = 12000;

function badPoint(p) {
  return (
    !p ||
    typeof p.lat !== "number" || typeof p.lng !== "number" ||
    !Number.isFinite(p.lat) || !Number.isFinite(p.lng) ||
    p.lat < BBOX.minLat || p.lat > BBOX.maxLat ||
    p.lng < BBOX.minLng || p.lng > BBOX.maxLng
  );
}

async function askOrs(host, coordinates, key) {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), TIMEOUT_MS);
  try {
    return await fetch(host + ORS_PATH, {
      method: "POST",
      signal: ctrl.signal,
      headers: {
        Authorization: key,
        "Content-Type": "application/json",
        Accept: "application/geo+json",
      },
      body: JSON.stringify({ coordinates }),
    });
  } finally {
    clearTimeout(timer);
  }
}

exports.orsRoute = onCall(
  { secrets: [ORS_API_KEY], region: "us-central1" },
  async (req) => {
    const uid = req.auth && req.auth.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign in first.");
    }

    const waypoints = req.data && req.data.waypoints;
    if (!Array.isArray(waypoints) ||
        waypoints.length < 2 || waypoints.length > MAX_WAYPOINTS ||
        waypoints.some(badPoint)) {
      throw new HttpsError("invalid-argument", "Bad waypoints.");
    }

    if (!(await underLimit(`ors:${uid}`, PER_HOUR))) {
      throw new HttpsError("resource-exhausted", "Too many routes this hour.");
    }

    const key = ORS_API_KEY.value();
    if (!key || key === UNSET) {
      // No real key yet — say so plainly; the client falls back to Google.
      throw new HttpsError("failed-precondition", "ORS key not configured.");
    }

    const coordinates = waypoints.map((p) => [p.lng, p.lat]);

    let lastStatus = 0;
    for (const host of ORS_HOSTS) {
      let res;
      try {
        res = await askOrs(host, coordinates, key);
      } catch (e) {
        logger.warn("ORS unreachable", { host, err: String(e) });
        continue; // try the other host
      }
      lastStatus = res.status;

      // A retired host answers 404/410; anything else is a real answer from a
      // live host and there is no point asking the other one.
      if (res.status === 404 || res.status === 410) {
        logger.warn("ORS host retired", { host, status: res.status });
        continue;
      }
      if (!res.ok) {
        const text = await res.text().catch(() => "");
        logger.error("ORS error", { host, status: res.status, body: text.slice(0, 300) });
        break;
      }

      const road = roadFrom(await res.json().catch(() => null));
      if (!road) {
        logger.error("ORS response not usable", { host });
        break;
      }
      return road;
    }

    throw new HttpsError("unavailable", `ORS failed (${lastStatus}).`);
  },
);
