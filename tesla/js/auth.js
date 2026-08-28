// Firebase Auth + Firestore access for the Tesla web app.
// Same project/accounts as the mobile app: premium bought on the phone lands
// in users/{uid}.isPremium (written by lib/services/purchase_service.dart)
// and unlocks here through a realtime listener.

import { initializeApp } from 'https://www.gstatic.com/firebasejs/10.12.2/firebase-app.js';
import {
  getAuth,
  GoogleAuthProvider,
  onAuthStateChanged,
  signInWithEmailAndPassword,
  signInWithCustomToken,
  signInWithPopup,
  signInWithRedirect,
  signOut,
} from 'https://www.gstatic.com/firebasejs/10.12.2/firebase-auth.js';
import {
  getFunctions,
  httpsCallable,
} from 'https://www.gstatic.com/firebasejs/10.12.2/firebase-functions.js';
import {
  doc,
  getDoc,
  getFirestore,
  onSnapshot,
  serverTimestamp,
  setDoc,
} from 'https://www.gstatic.com/firebasejs/10.12.2/firebase-firestore.js';

import { FIREBASE_CONFIG } from './config.js';
import { track } from './analytics.js';

const app = initializeApp(FIREBASE_CONFIG);
const auth = getAuth(app);
const db = getFirestore(app);
// Same region the functions are deployed to (setGlobalOptions in functions/index.js).
const fns = getFunctions(app, 'us-central1');

/** Call one of our callable Cloud Functions. */
export function callFn(name, data) {
  return httpsCallable(fns, name)(data).then((r) => r.data);
}

/** Finish pairing: swap the custom token minted by redeemTeslaPairing for a session. */
export function loginWithToken(token) {
  return signInWithCustomToken(auth, token);
}

export const TRIAL_MS = 24 * 60 * 60 * 1000;

export function watchAuth(cb) {
  return onAuthStateChanged(auth, cb);
}

export function loginEmail(email, password) {
  return signInWithEmailAndPassword(auth, email, password);
}

/** Popup first (works in desktop/Tesla Chromium); redirect as fallback. */
export async function loginGoogle() {
  const provider = new GoogleAuthProvider();
  try {
    return await signInWithPopup(auth, provider);
  } catch (e) {
    if (e.code === 'auth/popup-blocked' || e.code === 'auth/popup-closed-by-user') {
      return signInWithRedirect(auth, provider);
    }
    throw e;
  }
}

export function logout() {
  // Whatever put this session here, it is gone now: the next sign-in decides
  // for itself whether it is a paired one (see pair.js).
  localStorage.removeItem('gc_paired');
  return signOut(auth);
}

/**
 * Resolve the account's Tesla trial. Creates the create-once marker on first
 * visit (enforced by firestore.rules — it can never be rewritten).
 * Returns the trial end as epoch millis.
 */
export async function ensureTrial(uid) {
  const ref = doc(db, 'users', uid, 'flags', 'teslaTrial');
  const snap = await getDoc(ref);
  if (snap.exists()) {
    return snap.data().startedAt.toMillis() + TRIAL_MS;
  }
  await setDoc(ref, { startedAt: serverTimestamp() });
  track('tesla_trial_start');
  const created = await getDoc(ref);
  return created.data().startedAt.toMillis() + TRIAL_MS;
}

/**
 * Watch which car this account is linked to. One account may drive one car, so
 * a document naming a DIFFERENT device (someone paired another Tesla) ends this
 * session. For a car that signed in BY pairing, the document disappearing also
 * ends it — that is what "Disconnect" in the phone app has to mean. Classic
 * email/Google sessions never had a document and are left alone, which is why
 * `paired` is passed in rather than guessed.
 */
export function watchDeviceLink(uid, deviceId, paired, onRevoked) {
  return onSnapshot(
    doc(db, 'users', uid, 'flags', 'teslaDevice'),
    (snap) => {
      if (!snap.exists()) {
        if (paired) onRevoked('unlinked');        // disconnected from the phone
        return;
      }
      if (snap.data().deviceId !== deviceId) onRevoked('replaced');
    },
    () => {/* transient read error — keep driving */},
  );
}

// ── Car-side account state (users/{uid}/tesla/{doc}) ─────────────────────────
// Saved places today, saved routes next. One document per kind, holding an
// array: four favourites is not a collection worth paginating, and a single
// document means one listener, one write, and a shape that caches into
// localStorage as-is.

/** The signed-in account, or null. */
export function currentUid() {
  return auth.currentUser?.uid ?? null;
}

/** The signed-in account's email, where it has one. */
export function currentEmail() {
  return auth.currentUser?.email ?? '';
}

/**
 * The server's clock, for a document field. A Tesla's browser clock can be
 * minutes or days out, and a session filed under the wrong day is worse than
 * no session at all.
 */
export function serverNow() {
  return serverTimestamp();
}

/**
 * Create or merge one usage-session document (`teslaSessions/{id}`).
 *
 * A top-level collection rather than something under users/{uid}: the admin
 * panel wants "who was in a car today" across every account, which is one
 * query here and a collection-group scan there. The rules keep a driver to
 * writing rows that carry their own uid. See js/usage.js.
 */
export function saveSession(id, data) {
  return setDoc(doc(db, 'teslaSessions', id), data, { merge: true });
}

/** Live contents of users/{uid}/tesla/{name}; cb(null) when there is none. */
export function watchTeslaDoc(uid, name, cb) {
  return onSnapshot(
    doc(db, 'users', uid, 'tesla', name),
    (snap) => cb(snap.exists() ? snap.data() : null),
    () => {/* transient read error — the cached copy stays on screen */},
  );
}

/** Merge-write users/{uid}/tesla/{name}. */
export function saveTeslaDoc(uid, name, data) {
  return setDoc(doc(db, 'users', uid, 'tesla', name), data, { merge: true });
}

/** Realtime premium flag from users/{uid} — fires on every change. */
export function watchPremium(uid, cb) {
  return onSnapshot(
    doc(db, 'users', uid),
    (snap) => cb(snap.exists() && snap.data().isPremium === true),
    () => cb(false), // permission/network error → treat as not premium
  );
}
