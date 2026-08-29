"use strict";

// How much of Google Maps Platform's free tier is left, in Firestore.
//
// The admin panel shows a gauge per API: what has been spent this month against
// what is free, and today's count against the daily cap. Those numbers can only
// come from Google, and they cannot be counted client-side — the phone app
// calls Directions and Places too, and counting our own calls would miss every
// one of them (and would need an app release to change). So this reads the real
// figures from Cloud Monitoring, which is the same source the Cloud console's
// own usage graphs are drawn from.
//
// Two projects are involved, which is the thing to remember here:
//   • the Firebase project this function runs in — geocharge-f6714
//   • the project the Maps KEYS belong to — ev-charger-app-497408
// So the function's runtime service account needs Monitoring Viewer ON THE
// SECOND ONE, granted by hand in the console (see docs below). Without it every
// run logs a 403 and writes nothing; the panel then shows the last good day and
// says the data is stale, rather than pretending usage is zero.
//
// Buckets are HOURLY on purpose. Cloud Monitoring aligns its windows to the end
// of the interval, so asking for daily buckets would give "the last 24 hours",
// not calendar days. Hours are aligned to the hour, and Georgia is a fixed
// UTC+4 with no daylight saving, so summing hours into local days is exact.

const { onSchedule } = require("firebase-functions/v2/scheduler");
const logger = require("firebase-functions/logger");
const { getFirestore, FieldValue } = require("firebase-admin/firestore");
const { GoogleAuth } = require("google-auth-library");

// The project the Maps API keys live in (NOT the Firebase project). Both the
// mobile key and the Tesla web key belong to it, so it is where all Maps usage
// and all the daily quota caps are.
const MAPS_PROJECT = "ev-charger-app-497408";

// Georgia is UTC+4 all year. A day here starts at 20:00 UTC the evening before.
const TBILISI_OFFSET_H = 4;

// How far back each run re-reads. A month plus a few days, so the panel always
// has a complete current month and the tail of the previous one, and so a run
// that failed yesterday heals itself rather than leaving a hole.
const WINDOW_DAYS = 35;

// The APIs worth watching, keyed by the short name the panel uses. The value is
// the "consumed API" service name Monitoring files usage under — always the
// backend form, which is what the metric carries even for the JS API.
const SERVICES = {
  maps: "maps-backend.googleapis.com",          // Maps JavaScript API — map loads
  directions: "directions-backend.googleapis.com",
  places: "places-backend.googleapis.com",
  geocoding: "geocoding-backend.googleapis.com",
};

const auth = new GoogleAuth({
  scopes: ["https://www.googleapis.com/auth/monitoring.read"],
});

/** Floor a moment to the top of its UTC hour. */
function hourFloor(ms) {
  return Math.floor(ms / 3600000) * 3600000;
}

/** The Tbilisi calendar day (YYYY-MM-DD) an instant falls in. */
function tbilisiDay(ms) {
  return new Date(ms + TBILISI_OFFSET_H * 3600000).toISOString().slice(0, 10);
}

/**
 * Hourly successful-request counts for one API, as a Map of bucket start (ms)
 * to count.
 *
 * `response_code_class="2xx"` on purpose: a request Google refused is not a
 * request Google bills, and a 4xx storm (a referrer-restricted key called from
 * the wrong page, say) would otherwise read as usage.
 */
async function hourlyCounts(service, startMs, endMs) {
  const client = await auth.getClient();
  const filter =
    'metric.type="serviceruntime.googleapis.com/api/request_count" ' +
    'AND resource.type="consumed_api" ' +
    `AND resource.label."service"="${service}" ` +
    'AND metric.label."response_code_class"="2xx"';

  const params = new URLSearchParams({
    filter,
    "interval.startTime": new Date(startMs).toISOString(),
    "interval.endTime": new Date(endMs).toISOString(),
    "aggregation.alignmentPeriod": "3600s",
    "aggregation.perSeriesAligner": "ALIGN_SUM",
    "aggregation.crossSeriesReducer": "REDUCE_SUM",
    "view": "FULL",
  });

  const url =
    `https://monitoring.googleapis.com/v3/projects/${MAPS_PROJECT}/timeSeries?${params}`;

  const out = new Map();
  let pageToken = "";
  // Paging is unlikely at one series of ~840 points, but a missing page would
  // silently under-report usage, which is the one thing this must not do.
  for (let page = 0; page < 10; page++) {
    const res = await client.request({
      url: pageToken ? `${url}&pageToken=${encodeURIComponent(pageToken)}` : url,
      method: "GET",
    });
    for (const series of res.data?.timeSeries ?? []) {
      for (const p of series.points ?? []) {
        const at = hourFloor(Date.parse(p.interval.startTime));
        const v = Number(p.value?.int64Value ?? p.value?.doubleValue ?? 0);
        out.set(at, (out.get(at) ?? 0) + v);
      }
    }
    pageToken = res.data?.nextPageToken ?? "";
    if (!pageToken) break;
  }
  return out;
}

/**
 * Read every watched API and write one document per Tbilisi day:
 *
 *   mapsUsage/2026-08-29  { day, maps, directions, places, geocoding, updatedAt }
 *
 * Only days whose numbers actually changed are written, so a quiet hour costs
 * one read per day and no writes at all.
 */
async function refresh() {
  const endMs = hourFloor(Date.now());
  // Start on a Tbilisi midnight rather than "35 × 24 h ago", so the oldest day
  // in the window is a whole day. A half-day written as a whole one would
  // quietly understate a month total whenever the window's edge fell inside it.
  const local = (ms) => ms + TBILISI_OFFSET_H * 3600000;
  const startMs =
    Math.ceil(local(endMs - WINDOW_DAYS * 86400000) / 86400000) * 86400000 -
    TBILISI_OFFSET_H * 3600000;

  const perDay = new Map(); // day → { maps: n, … }
  const failed = [];
  const read = [];          // the APIs this run actually got numbers for

  for (const [key, service] of Object.entries(SERVICES)) {
    let counts;
    try {
      counts = await hourlyCounts(service, startMs, endMs);
    } catch (err) {
      // One API failing must not lose the others. A 403 here is almost always
      // the missing IAM grant, so say which project it was.
      failed.push(key);
      logger.error(`maps usage: ${service} unreadable in ${MAPS_PROJECT}`, {
        status: err?.response?.status ?? null,
        message: String(err?.message ?? err),
      });
      continue;
    }
    read.push(key);
    for (const [at, n] of counts) {
      const day = tbilisiDay(at);
      const row = perDay.get(day) ?? {};
      row[key] = (row[key] ?? 0) + n;
      perDay.set(day, row);
    }
  }

  if (failed.length === Object.keys(SERVICES).length) {
    // Nothing was readable: leave yesterday's numbers alone rather than
    // stamping a fresh `updatedAt` on data we did not actually refresh.
    throw new Error(`maps usage: no API was readable in ${MAPS_PROJECT}`);
  }

  const db = getFirestore();
  const existing = await db
    .collection("mapsUsage")
    .where("day", ">=", tbilisiDay(startMs))
    .get();
  const before = new Map(existing.docs.map((d) => [d.id, d.data()]));

  let written = 0;
  const batch = db.batch();
  // Every day in the window, not only the ones with traffic: a day that saw no
  // calls at all still has to read as a zero rather than as a gap.
  for (let ms = startMs; ms < endMs; ms += 86400000) {
    const day = tbilisiDay(ms);
    perDay.set(day, perDay.get(day) ?? {});
  }

  for (const [day, row] of perDay) {
    const prev = before.get(day);
    // Only the APIs this run could read are compared — and only they are
    // written. An API that 403'd must not overwrite yesterday's real number
    // with a confident zero.
    const same = prev && read.every((k) => (prev[k] ?? 0) === (row[k] ?? 0));
    if (same) continue;
    batch.set(
      db.collection("mapsUsage").doc(day),
      {
        day,
        ...Object.fromEntries(read.map((k) => [k, row[k] ?? 0])),
        // Which APIs this row could not be refreshed from, so the panel can say
        // "Directions is stale" instead of showing a confident zero.
        stale: failed,
        updatedAt: FieldValue.serverTimestamp(),
      },
      { merge: true },
    );
    written++;
  }
  if (written) await batch.commit();

  logger.info(`maps usage refreshed: ${written} day(s) written`, {
    days: perDay.size,
    failed,
  });
}

// Hourly. Maps quotas reset daily (Pacific) and the free tier is monthly, so
// nothing here changes faster than that — an hourly gauge is already finer than
// any decision made from it.
exports.pullMapsUsage = onSchedule(
  {
    schedule: "every 60 minutes",
    timeZone: "Asia/Tbilisi",
    retryCount: 1,
  },
  refresh,
);
