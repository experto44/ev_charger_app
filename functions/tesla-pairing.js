"use strict";

// Signing in to tesla.geocharge.ge by pairing the car with the phone app.
//
// Why this exists: most accounts were created with Google on the phone, so they
// have no password at all, and Google's own sign-in is unreliable inside the
// Tesla browser (popups get blocked, and signInWithRedirect breaks in Chrome
// 115+ when the auth domain is a different site). The car therefore never asks
// for a credential — it shows a 6-digit code, the phone app (already signed in,
// already the account that owns the subscription) approves it, and the car
// swaps the code for a custom token.
//
// The flow, in four calls:
//   1. car   → createTeslaPairing({ deviceId, secretHash })   → { code }
//   2. phone → approveTeslaPairing({ code })                  → { approved } | { needsReplace }
//   3. car   → redeemTeslaPairing({ code, secret, deviceId }) → { token } | { status:'pending' }
//   4. phone → unlinkTeslaDevice()                            → disconnects the car
//
// One account = one car: the linked device lives at users/{uid}/flags/teslaDevice
// and redeeming OVERWRITES it. The car watches that document and signs itself
// out when the id stops being its own, so a shared account cannot drive two
// cars at once — enforcement is not left to the honour system.

const crypto = require("node:crypto");
const { onCall, HttpsError } = require("firebase-functions/v2/https");
const logger = require("firebase-functions/logger");
const { getFirestore } = require("firebase-admin/firestore");
const { getAuth } = require("firebase-admin/auth");

const CODE_TTL_MS = 5 * 60 * 1000; // a code on screen is worth 5 minutes
const PAIRINGS = "teslaPairings";
const RATE = "teslaPairingRates";

// Rate windows. The car's limit stops a loop hammering the function; the
// phone's limit is the one that matters — it stops someone typing random codes
// until they hit one that happens to be on a stranger's screen.
const CAR_CODES_PER_HOUR = 30; // the car re-issues every 5 min while it waits
const PHONE_TRIES_PER_HOUR = 10;

const db = () => getFirestore();
const now = () => Date.now();
const sha256 = (s) => crypto.createHash("sha256").update(String(s)).digest("hex");

/** Six digits, leading zeros allowed, from a real CSPRNG. */
function newCode() {
  return String(crypto.randomInt(0, 1000000)).padStart(6, "0");
}

function cleanDeviceId(v) {
  const s = String(v || "");
  if (!/^[A-Za-z0-9_-]{8,64}$/.test(s)) {
    throw new HttpsError("invalid-argument", "Bad device id.");
  }
  return s;
}

function cleanCode(v) {
  const s = String(v || "").replace(/\D/g, "");
  if (s.length !== 6) {
    throw new HttpsError("invalid-argument", "The code is six digits.");
  }
  return s;
}

/**
 * Fixed-window counter. Returns false when `key` has already used up `limit`
 * in the current hour. One document per key, so a hot key costs one read+write.
 */
async function underLimit(key, limit) {
  const ref = db().collection(RATE).doc(key);
  return db().runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const t = now();
    const win = snap.exists ? snap.data() : null;
    if (win && t - win.startedAt < 3600000) {
      if (win.count >= limit) return false;
      tx.update(ref, { count: win.count + 1 });
      return true;
    }
    tx.set(ref, { startedAt: t, count: 1 });
    return true;
  });
}

// ── 1. The car asks for a code ───────────────────────────────────────────────
// Unauthenticated by design: nobody is signed in yet, that is the whole point.
// The car also sends the hash of a secret it keeps to itself, so the code alone
// is useless on any other device.
exports.createTeslaPairing = onCall(async (request) => {
  const deviceId = cleanDeviceId(request.data?.deviceId);
  const secretHash = String(request.data?.secretHash || "");
  if (!/^[a-f0-9]{64}$/.test(secretHash)) {
    throw new HttpsError("invalid-argument", "Bad secret hash.");
  }

  if (!(await underLimit(`car_${deviceId}`, CAR_CODES_PER_HOUR))) {
    throw new HttpsError("resource-exhausted", "Too many codes. Wait a few minutes.");
  }

  // Collisions are rare (a million codes, a handful live at a time) but a
  // reused code would hand the wrong car a token, so never overwrite a live one.
  for (let i = 0; i < 8; i++) {
    const code = newCode();
    const ref = db().collection(PAIRINGS).doc(code);
    const created = await db().runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      if (snap.exists && snap.data().expiresAt > now() && snap.data().status !== "used") {
        return false;
      }
      tx.set(ref, {
        deviceId,
        secretHash,
        status: "pending",
        createdAt: now(),
        expiresAt: now() + CODE_TTL_MS,
      });
      return true;
    });
    // ttlMs as well as the absolute time: the car counts down with ttlMs, so a
    // browser clock that disagrees with the server cannot expire a live code.
    if (created) return { code, expiresAt: now() + CODE_TTL_MS, ttlMs: CODE_TTL_MS };
  }
  throw new HttpsError("internal", "Could not allocate a code.");
});

// ── 2. The phone approves it ─────────────────────────────────────────────────
// Signed in as the account that will end up driving the car. If that account is
// already linked to a DIFFERENT car we do not silently steal it: the app is told
// to ask, and only a second call with replace:true goes through.
exports.approveTeslaPairing = onCall(async (request) => {
  if (!request.auth) throw new HttpsError("unauthenticated", "Sign in required.");
  const uid = request.auth.uid;
  const code = cleanCode(request.data?.code);
  const replace = request.data?.replace === true;

  if (!(await underLimit(`phone_${uid}`, PHONE_TRIES_PER_HOUR))) {
    throw new HttpsError("resource-exhausted", "Too many attempts. Try again later.");
  }

  const ref = db().collection(PAIRINGS).doc(code);
  const snap = await ref.get();
  const p = snap.exists ? snap.data() : null;
  if (!p || p.expiresAt < now() || p.status === "used") {
    throw new HttpsError("not-found", "This code is wrong or has expired.");
  }

  const linkRef = db().doc(`users/${uid}/flags/teslaDevice`);
  const link = await linkRef.get();
  if (link.exists && link.data().deviceId !== p.deviceId && !replace) {
    return {
      needsReplace: true,
      pairedAt: link.data().pairedAt ?? null,
    };
  }

  await ref.update({ status: "approved", uid, approvedAt: now() });
  logger.info(`tesla pairing approved (uid=${uid}, device=${p.deviceId})`);
  return { approved: true };
});

// ── 3. The car collects its token ────────────────────────────────────────────
// Polled every few seconds while the code is on screen: 'pending' until the
// phone acts, then one custom token, once. Redeeming is also what LINKS the
// car — overwriting whatever car was linked before.
exports.redeemTeslaPairing = onCall(async (request) => {
  const code = cleanCode(request.data?.code);
  const deviceId = cleanDeviceId(request.data?.deviceId);
  const secret = String(request.data?.secret || "");

  const ref = db().collection(PAIRINGS).doc(code);
  const snap = await ref.get();
  const p = snap.exists ? snap.data() : null;

  if (!p || p.expiresAt < now() || p.status === "used") {
    throw new HttpsError("not-found", "This code is wrong or has expired.");
  }
  // The code is on a screen anyone can photograph; the secret never leaves the
  // car, so this is what proves the caller is the car that asked.
  if (p.deviceId !== deviceId || p.secretHash !== sha256(secret)) {
    throw new HttpsError("permission-denied", "This code belongs to another device.");
  }
  if (p.status !== "approved") return { status: "pending" }; // waiting on the phone

  // Mint the token BEFORE the code is spent. Signing needs the runtime service
  // account to hold Service Account Token Creator on itself; the first time this
  // ran in production it did not, and because the code had already been marked
  // used by then, the car's next poll read "expired" and the driver was stuck
  // with no way back. Nothing is consumed until there is a token in hand.
  let token;
  try {
    token = await getAuth().createCustomToken(p.uid);
  } catch (err) {
    logger.error("createCustomToken failed", err);
    throw new HttpsError("internal", "Could not finish sign-in. Try again.");
  }

  // Now spend it — once. A second car polling the same code loses here and gets
  // a plain not-found, having minted a token that is never returned to it.
  const won = await db().runTransaction(async (tx) => {
    const fresh = await tx.get(ref);
    if (!fresh.exists || fresh.data().status !== "approved") return false;
    tx.update(ref, { status: "used", usedAt: now() });
    return true;
  });
  if (!won) throw new HttpsError("not-found", "This code is wrong or has expired.");

  await db().doc(`users/${p.uid}/flags/teslaDevice`).set({
    deviceId,
    pairedAt: now(),
  });

  logger.info(`tesla pairing redeemed (uid=${p.uid}, device=${deviceId})`);
  return { token };
});

// ── 4. The phone disconnects the car ─────────────────────────────────────────
// Deleting the link is enough: the car is watching this document and signs
// itself out as soon as it disappears.
exports.unlinkTeslaDevice = onCall(async (request) => {
  if (!request.auth) throw new HttpsError("unauthenticated", "Sign in required.");
  await db().doc(`users/${request.auth.uid}/flags/teslaDevice`).delete();
  logger.info(`tesla device unlinked (uid=${request.auth.uid})`);
  return { unlinked: true };
});
