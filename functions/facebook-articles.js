"use strict";

// Keeps the Facebook half of the blog rotation topped up.
//
// Same reason facebook-posters.js exists: the Pages API takes a future
// `scheduled_publish_time` but refuses anything much past a month out (measured
// on this page 2026-08-19: 27 days ahead accepted, 31 refused). A laptop run can
// therefore only fill the slots inside that window, and on 2026-08-31 that was
// three of the eight guides that had never been posted. The rest sat in
// marketing/fb-queue.md waiting for a human to run the script again. This
// function walks up behind the horizon every week instead.
//
// The difference from the poster campaign is what the plan looks like. Posters
// are a finite series with fixed dates, so poster-content.json carries the slot
// times and this side only has to notice when one comes into range. The blog is
// a rotation with no end: which guide goes into a free slot depends on what has
// already gone out and on the month, so the ranking lives here, in the same
// tiers `plan()` uses in tools/fb-queue.mjs. Keep the two in step.
//
// Copy is NOT authored here. Hooks, images, ORDER and SEASON come from
// social-content.json, exported by `node tools/fb-queue.mjs --export`, which is
// the same file the Instagram publisher reads.

const { onSchedule } = require("firebase-functions/v2/scheduler");
const { defineSecret } = require("firebase-functions/params");
const logger = require("firebase-functions/logger");
const { getFirestore, FieldValue } = require("firebase-admin/firestore");

const CONTENT = require("./social-content.json");

const FB_PAGE_TOKEN = defineSecret("FB_PAGE_TOKEN");

// Public page id, kept in source for the same reason as in facebook-posters.js.
const FB_PAGE_ID = "1227753007083449";

const API = "https://graph.facebook.com/v26.0";
const STATE = "social/facebook-articles";

// Short of the measured ceiling on purpose: a slot 25 days out today is 18 days
// out at the next run, so nothing is lost by being conservative, while a value
// close to the real limit risks a rejection on a bad day.
const HORIZON_DAYS = 25;

// Asia/Tbilisi is UTC+4 all year with no DST, so a fixed offset is correct and
// stays correct. Hours are Tbilisi wall clock, and they match SLOTS in
// tools/fb-queue.mjs. Thursday is deliberately left alone: that is the poster
// campaign's evening.
const TZ = 4;
const SLOTS = [
  { dow: 2, h: 19, m: 0 }, // Tuesday evening
  { dow: 6, h: 12, m: 0 }, // Saturday midday
];

async function graph(path, params, method = "GET") {
  const body = new URLSearchParams(params);
  const url = `${API}/${path}`;
  const res =
    method === "GET"
      ? await fetch(`${url}?${body}`)
      : await fetch(url, { method, body });
  const json = await res.json();
  if (json.error) {
    throw new Error(`${json.error.type} ${json.error.code}: ${json.error.message}`);
  }
  return json;
}

const tbilisiUnix = (d, h, m) =>
  Math.floor(Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate(), h - TZ, m) / 1000);

// Every slot between now and the horizon that nobody has taken yet.
function freeSlots(taken) {
  const out = [];
  const now = Math.floor(Date.now() / 1000);
  const limit = now + HORIZON_DAYS * 86400;
  const day = new Date();
  day.setUTCHours(0, 0, 0, 0);
  while (tbilisiUnix(day, 0, 0) <= limit) {
    for (const s of SLOTS) {
      if (day.getUTCDay() !== s.dow) continue;
      const t = tbilisiUnix(day, s.h, s.m);
      // Facebook refuses anything less than 10 minutes out, too.
      if (t > now + 900 && t <= limit && !taken.has(t)) out.push(t);
    }
    day.setUTCDate(day.getUTCDate() + 1);
  }
  return out.sort((a, b) => a - b);
}

// The tiers of plan() in tools/fb-queue.mjs: an in-season guide that has never
// run beats one that has never run, which beats the least recently used, which
// beats anything out of its season. Nothing repeats inside a single run.
function pick(history, month, chosen) {
  const last = {};
  for (const h of history) last[h.slug] = Math.max(last[h.slug] || 0, h.at);

  const rank = (a) => {
    if (chosen.includes(a.slug)) return [9, 0];
    const season = CONTENT.season[a.slug];
    if (season && !season.includes(month)) return [3, last[a.slug] || 0];
    if (last[a.slug]) return [2, last[a.slug]];
    return [season ? 0 : 1, CONTENT.order.indexOf(a.slug)];
  };

  return [...CONTENT.articles].sort((a, b) => {
    const [ta, sa] = rank(a);
    const [tb, sb] = rank(b);
    return ta - tb || sa - sb;
  })[0];
}

async function topUp() {
  const db = getFirestore();
  const ref = db.doc(STATE);
  const snap = await ref.get();
  const queued = (snap.exists && snap.data().queued) || [];

  // What the laptop has queued or published travels in the export; what earlier
  // runs of this function queued is in Firestore. Both are needed: the first
  // decides which guide is due, the second stops a slot being booked twice.
  const history = [...(CONTENT.facebookHistory || []), ...queued];
  const taken = new Set(history.map((h) => h.at));
  const slots = freeSlots(taken);

  if (!slots.length) {
    logger.info("facebook articles: no free slot inside the horizon");
    return;
  }

  const token = FB_PAGE_TOKEN.value();
  const added = [...queued];
  const chosen = [];
  for (const at of slots) {
    const month = new Date(at * 1000).getUTCMonth() + 1;
    const article = pick(history, month, chosen);
    if (!article) break;
    const seen = history.filter((h) => h.slug === article.slug).length;
    const hook = article.hooks[seen % article.hooks.length];

    const r = await graph(
      `${FB_PAGE_ID}/feed`,
      {
        message: `${hook}\n\n${article.url}`,
        link: article.url,
        published: "false",
        scheduled_publish_time: String(at),
        access_token: token,
      },
      "POST"
    );

    chosen.push(article.slug);
    history.push({ slug: article.slug, at });
    added.push({ slug: article.slug, at, id: r.id });
    // Written after every post so a mid-batch failure cannot make the next run
    // queue the same slot twice.
    await ref.set(
      { queued: added, lastRun: FieldValue.serverTimestamp() },
      { merge: true }
    );
    logger.info(`facebook articles: scheduled ${article.slug}`, { id: r.id, at });
  }
}

// Monday morning, an hour before the poster top-up, so a guide enters the queue
// with a week of slack and a failure is visible long before its slot. retryCount
// 0 for the same reason as the publishers: a retry after a partial failure could
// double book a slot.
exports.facebookArticleTopUp = onSchedule(
  {
    schedule: "0 8 * * 1",
    timeZone: "Asia/Tbilisi",
    secrets: [FB_PAGE_TOKEN],
    retryCount: 0,
  },
  topUp
);
