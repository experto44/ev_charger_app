"use strict";

const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { defineSecret } = require("firebase-functions/params");
const { setGlobalOptions } = require("firebase-functions/v2");
const logger = require("firebase-functions/logger");
const admin = require("firebase-admin");
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
    const user = await admin.auth().getUser(uid);

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
      link = await admin.auth().generateEmailVerificationLink(user.email);
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
