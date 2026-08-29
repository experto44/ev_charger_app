"use strict";

// Publishes the GeoCharge app poster campaign to Instagram, one poster a week,
// Thursday evening.
//
// Facebook takes a future `scheduled_publish_time` and does the waiting itself,
// so its side of this campaign is queued from a laptop by
// tools/poster-queue.mjs. The Instagram Graph API publishes when the call is
// made and has no scheduling at all, so something has to be awake on Thursday
// at 19:00. That is all this is.
//
// The captions are NOT authored here. They come from poster-content.json,
// exported by `node tools/poster-queue.mjs --export`, so both platforms read
// the copy from the same place.
//
// Unlike instagram.js, this campaign is finite: nine posters, in order, once
// each. When the last one has gone out the function keeps firing and keeps
// doing nothing, which is the quiet behaviour we want.

const { onSchedule } = require("firebase-functions/v2/scheduler");
const { defineSecret } = require("firebase-functions/params");
const logger = require("firebase-functions/logger");
const { getFirestore, FieldValue } = require("firebase-admin/firestore");

const CONTENT = require("./poster-content.json");

// Same page token the blog publisher uses: it carries instagram_basic and
// instagram_content_publish and is scoped to the GeoCharge page.
const FB_PAGE_TOKEN = defineSecret("FB_PAGE_TOKEN");

const IG_USER_ID = "17841448313966233";
const API = "https://graph.facebook.com/v26.0";
const STATE = "social/instagram-posters";

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

// A photo container is normally FINISHED at once, but the API is explicitly
// asynchronous and publishing an unfinished container fails, so the status is
// polled rather than assumed.
async function waitReady(id, token, tries = 6) {
  for (let i = 0; i < tries; i++) {
    const r = await graph(id, { fields: "status_code", access_token: token });
    if (r.status_code === "FINISHED") return;
    if (r.status_code === "ERROR" || r.status_code === "EXPIRED") {
      throw new Error(`container ${id} is ${r.status_code}`);
    }
    await new Promise((r2) => setTimeout(r2, 3000));
  }
  throw new Error(`container ${id} not FINISHED after ${tries} checks`);
}

async function publishNext() {
  const db = getFirestore();
  const ref = db.doc(STATE);
  const snap = await ref.get();
  const posted = (snap.exists && snap.data().posted) || [];
  const done = new Set(posted.map((p) => p.slug));

  const poster = CONTENT.posters.find((p) => !done.has(p.slug));
  if (!poster) {
    logger.info("instagram posters: campaign finished, nothing to publish");
    return;
  }

  const token = FB_PAGE_TOKEN.value();
  const container = await graph(
    `${IG_USER_ID}/media`,
    { image_url: poster.image, caption: poster.caption, access_token: token },
    "POST"
  );
  await waitReady(container.id, token);

  const published = await graph(
    `${IG_USER_ID}/media_publish`,
    { creation_id: container.id, access_token: token },
    "POST"
  );

  await ref.set(
    {
      posted: [
        ...posted,
        {
          slug: poster.slug,
          at: Math.floor(Date.now() / 1000),
          mediaId: published.id,
        },
      ],
      lastRun: FieldValue.serverTimestamp(),
    },
    { merge: true }
  );

  logger.info(`instagram posters: published ${poster.slug}`, {
    mediaId: published.id,
    left: CONTENT.posters.length - posted.length - 1,
  });
}

// retryCount stays 0 for the same reason as the blog publisher: a retry after a
// partial failure could publish the same poster twice, which is worse than
// missing a week. A miss shows up in the logs and the next Thursday carries on.
exports.instagramPosterThursday = onSchedule(
  {
    schedule: "0 19 * * 4",
    timeZone: "Asia/Tbilisi",
    secrets: [FB_PAGE_TOKEN],
    retryCount: 0,
  },
  publishNext
);
