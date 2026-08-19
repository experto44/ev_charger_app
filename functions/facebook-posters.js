"use strict";

// Keeps the Facebook half of the poster campaign topped up.
//
// The Pages API takes a future `scheduled_publish_time`, which is why the
// campaign can sit in the page's planner at all, but it refuses anything much
// past a month out: measured against this page on 2026-08-19, 27 days ahead was
// accepted and 31 was refused. Nine weekly slots span 57 days, so a single run
// from a laptop can only queue the first five. Rather than leaving a reminder
// for a human, this function walks up behind the horizon every week and queues
// each poster as soon as its slot comes inside the window.
//
// Instagram does not need this. Its publisher fires at post time, so there is
// no horizon to walk. See instagram-posters.js.
//
// The plan is NOT authored here. Slot times, captions and images come from
// poster-content.json, exported by `node tools/poster-queue.mjs --export`, so
// the laptop and this function schedule from one plan and cannot disagree about
// what goes out when.

const { onSchedule } = require("firebase-functions/v2/scheduler");
const { defineSecret } = require("firebase-functions/params");
const logger = require("firebase-functions/logger");
const admin = require("firebase-admin");

const CONTENT = require("./poster-content.json");

const FB_PAGE_TOKEN = defineSecret("FB_PAGE_TOKEN");

// Not a secret: it is the public page id, and keeping it here makes the wiring
// obvious the same way IG_USER_ID does in the Instagram publisher.
const FB_PAGE_ID = "1227753007083449";

const API = "https://graph.facebook.com/v26.0";
const STATE = "social/facebook-posters";

// Deliberately short of the measured ceiling. A slot that is 28 days out today
// is 21 days out at the next run, so nothing is lost by being conservative,
// while a value close to the real limit risks a rejection on a bad day.
const HORIZON_DAYS = 25;

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

async function topUp() {
  const db = admin.firestore();
  const ref = db.doc(STATE);
  const snap = await ref.get();
  const queued = (snap.exists && snap.data().queued) || [];

  // Everything queued from the laptop plus everything queued by earlier runs.
  const done = new Set([...(CONTENT.facebookQueued || []), ...queued.map((q) => q.slug)]);

  const now = Math.floor(Date.now() / 1000);
  const limit = now + HORIZON_DAYS * 86400;
  const due = CONTENT.posters.filter(
    (p) => !done.has(p.slug) && p.at > now + 900 && p.at <= limit
  );

  if (!due.length) {
    const left = CONTENT.posters.filter((p) => !done.has(p.slug)).length;
    logger.info(`facebook posters: nothing due, ${left} still ahead of the horizon`);
    return;
  }

  const token = FB_PAGE_TOKEN.value();
  const added = [...queued];
  for (const p of due) {
    // /photos rather than /feed: the poster is the post, and a photo post keeps
    // the full 1080x1350 in the feed instead of a link card crop.
    const r = await graph(
      `${FB_PAGE_ID}/photos`,
      {
        url: p.image,
        caption: p.fb,
        published: "false",
        scheduled_publish_time: String(p.at),
        access_token: token,
      },
      "POST"
    );
    added.push({ slug: p.slug, at: p.at, id: r.id });
    // Written after every post so a mid-batch failure cannot make the next run
    // queue the same poster twice.
    await ref.set(
      { queued: added, lastRun: admin.firestore.FieldValue.serverTimestamp() },
      { merge: true }
    );
    logger.info(`facebook posters: scheduled ${p.slug}`, { id: r.id, at: p.at });
  }
}

// Monday morning, so a poster enters the queue days before its Thursday and any
// failure is visible with a week of slack. retryCount 0 for the same reason as
// the publishers: a retry after a partial failure could double book a slot.
exports.facebookPosterTopUp = onSchedule(
  {
    schedule: "0 9 * * 1",
    timeZone: "Asia/Tbilisi",
    secrets: [FB_PAGE_TOKEN],
    retryCount: 0,
  },
  topUp
);
