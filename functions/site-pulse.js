"use strict";

// Visitor statistics for geocharge.ge, for the admin panel's Site tab.
//
// site/assets/pulse.js sends one small JSON body per page view and one per
// click on a store link. Each is folded into one document per Tbilisi day:
//
//   siteStats/2026-09-15 {
//     day, views, visits, visitors, newVisitors, updatedAt,
//     clicks     { play, appstore },
//     pages      { "/damtenebi/": n },                 every page view
//     entries    { "/damtenebi/": n },                 where each visit started
//     clickPages { "/damtenebi/": { play, appstore } },
//     sources    { google, facebook, direct, … },    referrers { "google.com": n },
//     campaigns  { "facebook · poster": n },           countries { GE: n },
//     devices    { mobile, desktop, tablet, car },    os { android, ios, … },
//   }
//
// Why our own counter and not Google Analytics: GA4 needs a cookie banner, ad
// blockers drop a large share of its hits, and the panel could only read it
// through a service-account grant made inside Analytics. This stores totals and
// nothing else: no IP, no cookie, no identifier. The country comes from the
// device's time zone (tz-country.json, built from the IANA zone.tab).
//
// One document per day, incremented in place, so the panel reads at most 90 of
// them however busy the site gets. The price is Firestore's soft limit of about
// one sustained write per second per document, far above this site's traffic.
// A burst past it slows the beacons first; a write that still fails is logged
// and that single hit is lost, which is the right trade for statistics.

const { onRequest } = require("firebase-functions/v2/https");
const logger = require("firebase-functions/logger");
const { getFirestore, FieldValue } = require("firebase-admin/firestore");

const { BOTS, tbilisiDay, normalizeHit, counts } = require("./site-pulse-count");

// Only the site itself. A script can still forge the header, but a page on
// another domain cannot, and that is the abuse worth closing.
const ORIGINS = /^https:\/\/(www\.)?geocharge\.ge$/;

// A real beacon is well under 400 bytes.
const MAX_BODY = 2048;

function readBody(req) {
  const raw = req.rawBody
    ? req.rawBody.toString("utf8")
    : typeof req.body === "string" ? req.body : "";
  if (!raw) return req.body && typeof req.body === "object" ? req.body : null;
  if (raw.length > MAX_BODY) return null;
  try {
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

/** { a: 1, b: { c: 1 } } → the same shape with every number an increment. */
function increments(obj) {
  const out = {};
  for (const [key, value] of Object.entries(obj)) {
    out[key] = typeof value === "number" ? FieldValue.increment(value) : increments(value);
  }
  return out;
}

exports.sitePulse = onRequest({ timeoutSeconds: 10, memory: "256MiB" }, async (req, res) => {
  // Every request gets the same empty answer: the page never reads it, and a
  // prober learns nothing about what was counted.
  res.set("Cache-Control", "no-store");
  const done = () => res.status(204).end();

  if (req.method !== "POST" || !ORIGINS.test(req.get("origin") || "")) return done();
  const ua = String(req.get("user-agent") || "").slice(0, 512);
  if (!ua || BOTS.test(ua)) return done();

  const hit = normalizeHit(readBody(req));
  if (!hit) return done();

  // Written before answering: Cloud Run takes the CPU away once the response
  // is sent, so a write left running after it may never finish.
  const day = tbilisiDay(Date.now());
  try {
    await getFirestore()
      .collection("siteStats")
      .doc(day)
      .set(
        { day, ...increments(counts(hit, ua)), updatedAt: FieldValue.serverTimestamp() },
        { merge: true },
      );
  } catch (err) {
    logger.warn("sitePulse: write failed", { day, message: String(err?.message ?? err) });
  }
  done();
});
