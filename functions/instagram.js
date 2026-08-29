"use strict";

// Publishes GeoCharge blog articles to Instagram on a schedule.
//
// Why this is a Cloud Function while Facebook is a local script: the Pages API
// accepts a future `scheduled_publish_time` and does the waiting itself, so
// Facebook posts can be queued a month ahead from a laptop. The Instagram Graph
// API has no equivalent — publishing happens when the call is made — so
// something has to be awake at 19:00 on Tuesday. That is all this is.
//
// Two further Instagram constraints shape the code:
//   · A post must carry an image. There is no text-only post.
//   · A link in a caption is not clickable. The article URL is printed anyway,
//     since it is readable and it matches the poster, but the bio is what a
//     reader will actually tap.
//
// The article copy is NOT authored here. It comes from social-content.json,
// exported by `node tools/fb-queue.mjs --export`, so Facebook and Instagram
// always read from the same hooks.

const { onSchedule } = require("firebase-functions/v2/scheduler");
const { defineSecret } = require("firebase-functions/params");
const logger = require("firebase-functions/logger");
const { getFirestore, FieldValue } = require("firebase-admin/firestore");

const CONTENT = require("./social-content.json");

// Same page token the Facebook scheduler uses. It carries instagram_basic and
// instagram_content_publish, is scoped to the GeoCharge page, and does not
// expire:  firebase functions:secrets:set FB_PAGE_TOKEN
const FB_PAGE_TOKEN = defineSecret("FB_PAGE_TOKEN");

// The Instagram professional account behind @geo.charge. Not a secret: it is
// derivable from the public page, and keeping it in source makes the wiring
// obvious. Get it from  GET /{page-id}?fields=instagram_business_account
const IG_USER_ID = "17841448313966233";

const API = "https://graph.facebook.com/v26.0";
const STATE = "social/instagram";

// Images are the 1080x1350 posters under site/assets/social, built by
// tools/build-article-posters.mjs and pointed at by the export. That is 4:5,
// the tallest ratio Instagram allows and the most screen a post can take on a
// phone. Which image is used is decided in the export, never here.
const TAGS = [
  "#GeoCharge",
  "#ელექტრომობილი",
  "#დამტენი",
  "#საქართველო",
  "#EV",
  "#ევმანქანა",
];

// The article URL goes in the caption even though Instagram will not make it
// clickable: it is readable, it is what the poster shows, and it is the only
// way a reader can get to the piece without hunting. The bio line is there
// because tapping is what most people will actually do.
const caption = (hook, url) =>
  [
    hook,
    "",
    `სრული სტატია: ${url.replace(/^https:\/\//, "").replace(/\/$/, "")}`,
    "ბმული ბიოშიც არის.",
    "",
    TAGS.join(" "),
  ].join("\n");

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

// Mirrors the selection in tools/fb-queue.mjs: an article that has never gone
// out wins, ties broken by the authored ORDER; after a full pass the least
// recently posted wins. Seasonal articles are held back outside their months,
// unless nothing else is left — the schedule should not go silent over a rule
// about winter.
function pick(posted, month) {
  const last = {};
  for (const p of posted) last[p.slug] = Math.max(last[p.slug] || 0, p.at);

  const rank = (a) => {
    const season = CONTENT.season[a.slug];
    if (season && !season.includes(month)) return [3, last[a.slug] || 0];
    if (last[a.slug]) return [2, last[a.slug]];
    return [season ? 0 : 1, CONTENT.order.indexOf(a.slug)];
  };

  const sorted = [...CONTENT.articles].sort((a, b) => {
    const [ta, sa] = rank(a);
    const [tb, sb] = rank(b);
    return ta - tb || sa - sb;
  });
  const article = sorted[0];
  const seen = posted.filter((p) => p.slug === article.slug).length;
  return { article, hook: article.hooks[seen % article.hooks.length] };
}

// A container is normally FINISHED immediately for a photo, but the API is
// explicitly asynchronous and publishing an unfinished container fails, so the
// status is polled rather than assumed.
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
  const token = FB_PAGE_TOKEN.value();
  const db = getFirestore();
  const ref = db.doc(STATE);
  const snap = await ref.get();
  const posted = (snap.exists && snap.data().posted) || [];

  const month = new Date().getUTCMonth() + 1;
  const { article, hook } = pick(posted, month);

  const container = await graph(
    `${IG_USER_ID}/media`,
    {
      image_url: article.image,
      caption: caption(hook, article.url),
      access_token: token,
    },
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
        { slug: article.slug, at: Math.floor(Date.now() / 1000), mediaId: published.id },
      ],
      lastRun: FieldValue.serverTimestamp(),
    },
    { merge: true }
  );

  logger.info(`instagram: published ${article.slug}`, {
    mediaId: published.id,
    url: article.url,
  });
}

// Instagram's rate limit is 50 published posts per 24 hours, so two a week is
// nowhere near it. retryCount stays 0 deliberately: a retry after a partial
// failure could publish the same article twice, which is worse than missing a
// slot. A miss is visible in the logs and the next slot carries on.
const options = {
  timeZone: "Asia/Tbilisi",
  secrets: [FB_PAGE_TOKEN],
  retryCount: 0,
};

exports.instagramTuesday = onSchedule(
  { ...options, schedule: "0 19 * * 2" },
  publishNext
);

exports.instagramSaturday = onSchedule(
  { ...options, schedule: "0 12 * * 6" },
  publishNext
);
