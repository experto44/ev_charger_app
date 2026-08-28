// Who actually sits in a car with this open, and for how long.
//
// GA4 (js/analytics.js) counts events, but it cannot answer the two questions
// the admin panel is for: WHICH account was in a car today, and how long they
// used it. It has no uid and cannot be queried from the panel. So one document
// per visit is written here instead, and admin.geocharge.ge reads them:
//
//   teslaSessions/{id}  { uid, email, startedAt, lastSeenAt, seconds, drives … }
//
// Only signed-in visits are recorded — which is every visit that gets past the
// gate, since the app is behind a login. A driver who opens the page and never
// signs in is a GA4 pageview and nothing more, deliberately: an unauthenticated
// write path would be a hole in the rules for the sake of a number nobody acts
// on.
//
// `seconds` counts ACTIVE time only — the clock stops while the tab is hidden.
// A car left parked overnight with the browser open would otherwise report a
// nine-hour session, which is not usage, it is a screensaver.

import { currentEmail, saveSession, serverNow, watchAuth } from './auth.js';
import { deviceId } from './pair.js';

// How often accumulated time reaches Firestore. Two minutes is close enough for
// a session-length column and cheap: half an hour of driving is 15 writes.
const FLUSH_MS = 120000;

// The local clock tick. Short enough that a tab hidden mid-minute does not
// carry a minute of phantom use with it.
const TICK_MS = 15000;

const state = {
  id: null,
  uid: null,
  activeMs: 0,
  countingSince: 0, // 0 when the clock is stopped (tab hidden)
  drives: 0,
  dirty: false,
  tick: null,
  flush: null,
};

const newId = () =>
  (crypto.randomUUID?.() ?? String(Math.random()).slice(2) + Date.now()).replace(/-/g, '');

/** Fold the time since the last tick into the total. */
function accumulate() {
  if (!state.countingSince) return;
  const now = Date.now();
  const delta = now - state.countingSince;
  state.countingSince = now;
  // A jump of more than a few minutes is the machine having been suspended,
  // not the driver having stared at the screen: the car sleeps without always
  // firing visibilitychange first.
  if (delta > 0 && delta < 5 * TICK_MS) {
    state.activeMs += delta;
    state.dirty = true;
  }
}

function write(extra = {}) {
  if (!state.id || !state.uid) return;
  state.dirty = false;
  saveSession(state.id, {
    uid: state.uid,
    lastSeenAt: serverNow(),
    seconds: Math.round(state.activeMs / 1000),
    drives: state.drives,
    ...extra,
  }).catch(() => {/* usage data is never worth a message to the driver */});
}

function flush() {
  accumulate();
  if (state.dirty) write();
}

function startSession(uid) {
  if (state.id) return;
  state.id = newId();
  state.uid = uid;
  state.activeMs = 0;
  state.drives = 0;
  state.countingSince = document.visibilityState === 'hidden' ? 0 : Date.now();

  saveSession(state.id, {
    uid,
    email: currentEmail(),
    device: deviceId(),
    lang: document.documentElement.lang || '',
    // Server time on both ends: a Tesla's browser clock cannot be trusted to
    // put a session on the right day, and the day is what the panel groups by.
    startedAt: serverNow(),
    lastSeenAt: serverNow(),
    seconds: 0,
    drives: 0,
  }).catch(() => {});

  state.tick = setInterval(accumulate, TICK_MS);
  state.flush = setInterval(flush, FLUSH_MS);
}

function endSession() {
  flush();
  clearInterval(state.tick);
  clearInterval(state.flush);
  state.tick = state.flush = null;
  state.id = null;
  state.uid = null;
  state.countingSince = 0;
}

/**
 * Start recording this visit. Called once the gate lets the driver in, so a
 * session means "someone actually used the app", not "someone loaded the page".
 */
export function initUsage() {
  watchAuth((user) => {
    if (!user) {
      endSession();
      return;
    }
    if (state.uid && state.uid !== user.uid) endSession(); // signed in as someone else
    startSession(user.uid);
  });

  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'hidden') {
      accumulate();
      state.countingSince = 0;
      write(); // the last thing we may get a chance to say
    } else if (!state.countingSince) {
      state.countingSince = Date.now();
    }
  });

  // Best effort on the way out: the SDK may not get the write away before the
  // page dies, which is exactly why the periodic flush exists as well.
  window.addEventListener('pagehide', flush);

  // How many of those sessions turned into an actual drive — the difference
  // between looking at the map and using the car.
  document.addEventListener('gc:drive-start', () => {
    state.drives++;
    state.dirty = true;
    flush();
  });
}

/** Debug handle. */
export function usageState() {
  return state;
}
