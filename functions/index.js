"use strict";

const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { defineSecret } = require("firebase-functions/params");
const { setGlobalOptions } = require("firebase-functions/v2");
const logger = require("firebase-functions/logger");
const admin = require("firebase-admin");
const { getFirestore, FieldValue, Timestamp } = require("firebase-admin/firestore");
const { getAuth } = require("firebase-admin/auth");
const nodemailer = require("nodemailer");

const { buildVerificationEmail } = require("./email_template");

admin.initializeApp();

// Keep functions cheap and predictable.
setGlobalOptions({ region: "us-central1", maxInstances: 5 });

// ── Config ───────────────────────────────────────────────────────────────────
// SMTP credentials are stored as Firebase secrets (never in source):
//   firebase functions:secrets:set ZOHO_USER   → e.g. noreply@geocharge.ge
//   firebase functions:secrets:set ZOHO_PASS   → Zoho app-specific password
// Host/port are plain params (safe to commit) — override at deploy if needed.
const ZOHO_USER = defineSecret("ZOHO_USER");
const ZOHO_PASS = defineSecret("ZOHO_PASS");

// SMTP host/port are not secret — set for the account's Zoho region.
// EU accounts: smtp.zoho.eu · US accounts: smtp.zoho.com (both port 465, SSL).
const ZOHO_HOST = "smtp.zoho.eu";
const ZOHO_PORT = 465;

// Display name shown in the recipient's inbox.
const FROM_NAME = "GeoCharge";

// The generated verification link defaults to the Firebase host
// (geocharge-f6714.firebaseapp.com). We rewrite it to our own domain, which
// serves the identical Firebase auth action handler (/__/auth/action) and is an
// authorized domain — so the link reads as geocharge.ge and works the same. Done
// in code (not the flaky Console "Action URL" setting) so it's version-controlled.
const LINK_DOMAIN = "geocharge.ge";

let _transporter = null;
function transporter() {
  if (_transporter) return _transporter;
  _transporter = nodemailer.createTransport({
    host: ZOHO_HOST,
    port: ZOHO_PORT,
    secure: true, // 465 = implicit TLS
    auth: {
      user: ZOHO_USER.value(),
      pass: ZOHO_PASS.value(),
    },
  });
  return _transporter;
}

// ── sendVerificationEmail ─────────────────────────────────────────────────────
// Callable from the app after registration and on "resend". Generates a Firebase
// email-verification link and delivers it inside a branded HTML email from
// noreply@geocharge.ge via Zoho SMTP — replacing Firebase's default (spam-prone)
// verification email.
exports.sendVerificationEmail = onCall(
  { secrets: [ZOHO_USER, ZOHO_PASS] },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in required.");
    }

    const uid = request.auth.uid;
    const user = await getAuth().getUser(uid);

    if (!user.email) {
      throw new HttpsError("failed-precondition", "Account has no email address.");
    }
    if (user.emailVerified) {
      // Nothing to do — client can proceed straight into the app.
      return { alreadyVerified: true };
    }

    // Firebase mints the one-time verification action link for this address.
    let link;
    try {
      link = await getAuth().generateEmailVerificationLink(user.email);
      // Swap only the host → geocharge.ge, preserving oobCode/apiKey/lang.
      const u = new URL(link);
      u.hostname = LINK_DOMAIN;
      link = u.toString();
    } catch (err) {
      logger.error("generateEmailVerificationLink failed", err);
      throw new HttpsError("internal", "Could not create verification link.");
    }

    const { subject, html, text } = buildVerificationEmail(link);

    try {
      await transporter().sendMail({
        from: `"${FROM_NAME}" <${ZOHO_USER.value()}>`,
        to: user.email,
        subject,
        html,
        text,
      });
    } catch (err) {
      logger.error("Zoho SMTP sendMail failed", err);
      throw new HttpsError("internal", "Could not send the verification email.");
    }

    logger.info(`Verification email sent to ${user.email} (uid=${uid})`);
    return { sent: true };
  }
);

// ── expireManualPremium ───────────────────────────────────────────────────────
// Manual (bank-transfer) premium grants are written by the admin panel as
//   users/{uid}.isPremium    = true
//   users/{uid}.premiumUntil = <expiry timestamp>
//   users/{uid}.premiumSource= "manual"
// The mobile app has no concept of an expiry date — it just reads `isPremium`
// from Firestore on every launch (PurchaseService.syncPremiumFromFirestore).
// So the expiry has to be enforced server-side: this job flips `isPremium` back
// to false once `premiumUntil` has passed, and the ad-supported version returns
// on the user's next app open. Deliberately server-side so NO app update is
// needed for manual subscriptions to expire.
//
// Runs hourly. The query filters on `premiumUntil` alone (a single-field range —
// no composite index required) and the remaining conditions are checked in
// memory; only already-expired documents are ever returned, so a quiet hour
// costs a single empty read.
exports.expireManualPremium = onSchedule(
  {
    schedule: "every 60 minutes",
    timeZone: "Asia/Tbilisi",
    retryCount: 1,
  },
  async () => {
    const db = getFirestore();
    const now = Timestamp.now();

    const snap = await db
      .collection("users")
      .where("premiumUntil", "<=", now)
      .get();

    // Only manual grants that are still marked premium need downgrading. A
    // store subscription (premiumSource != "manual") is owned by Apple/Google
    // and must never be touched here.
    const stale = snap.docs.filter((d) => {
      const u = d.data();
      return u.isPremium === true && u.premiumSource === "manual";
    });

    if (stale.length === 0) {
      logger.info("expireManualPremium: nothing to expire");
      return;
    }

    // Firestore caps a batch at 500 writes; chunk so a large sweep can't fail.
    for (let i = 0; i < stale.length; i += 400) {
      const batch = db.batch();
      for (const doc of stale.slice(i, i + 400)) {
        batch.set(
          doc.ref,
          {
            isPremium: false,
            premiumExpiredAt: FieldValue.serverTimestamp(),
          },
          { merge: true }
        );
      }
      await batch.commit();
    }

    logger.info(
      `expireManualPremium: downgraded ${stale.length} account(s) → free`,
      { uids: stale.map((d) => d.id) }
    );
  }
);

// Instagram publishing runs on its own schedule — see instagram.js for why it
// is a function at all while Facebook is a local script.
Object.assign(exports, require("./instagram"));

// The app poster campaign has its own weekly slot and its own state, so it
// lives beside the blog publisher rather than inside it.
Object.assign(exports, require("./instagram-posters"));

// Facebook cannot be handed the whole campaign at once, so its queue is topped
// up week by week as the scheduling horizon moves. See facebook-posters.js.
Object.assign(exports, require("./facebook-posters"));

// Signing in to the Tesla web app by pairing it with the phone (6-digit code →
// custom token). See tesla-pairing.js.
Object.assign(exports, require("./tesla-pairing"));

// Reading a route shared out of the Google Maps app, so the phone can hand it
// to the car. Server-side because the URL format is undocumented and a fix must
// not wait on an App Store review. See google-route.js.
Object.assign(exports, require("./google-route"));

// How much of Google Maps Platform's free tier is left, read from Cloud
// Monitoring for the admin panel's usage gauge. See maps-usage.js — and note
// that it reads a DIFFERENT Cloud project to the one it runs in.
Object.assign(exports, require("./maps-usage"));
