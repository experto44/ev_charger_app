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
  signInWithPopup,
  signInWithRedirect,
  signOut,
} from 'https://www.gstatic.com/firebasejs/10.12.2/firebase-auth.js';
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

/** Realtime premium flag from users/{uid} — fires on every change. */
export function watchPremium(uid, cb) {
  return onSnapshot(
    doc(db, 'users', uid),
    (snap) => cb(snap.exists() && snap.data().isPremium === true),
    () => cb(false), // permission/network error → treat as not premium
  );
}
