"use strict";

// A fixed-window counter, one Firestore document per key.
//
// tesla-pairing.js predates this module and carries its own copy against its
// own collection; it is deployed and working, and moving a live login path for
// tidiness is not worth the risk. New callers use this one.

const admin = require("firebase-admin");

const COLLECTION = "rateWindows";
const WINDOW_MS = 3600000;

/**
 * Returns false once `key` has used up `limit` within the current hour. One
 * hot key costs a single read and a single write.
 *
 * @param {string} key   caller identity, prefixed by what is being limited
 * @param {number} limit calls allowed per hour
 */
async function underLimit(key, limit) {
  const db = admin.firestore();
  const ref = db.collection(COLLECTION).doc(key);
  return db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const now = Date.now();
    const win = snap.exists ? snap.data() : null;
    if (win && now - win.startedAt < WINDOW_MS) {
      if (win.count >= limit) return false;
      tx.update(ref, { count: win.count + 1 });
      return true;
    }
    tx.set(ref, { startedAt: now, count: 1 });
    return true;
  });
}

module.exports = { underLimit };
