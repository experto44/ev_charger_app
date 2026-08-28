// Signing in by pairing the car with the phone app.
//
// The car shows a 6-digit code and waits. The driver types it into GeoCharge on
// their phone — where they are already signed in as the account that owns the
// subscription — and the car swaps the code for a session. No password is ever
// typed in a car, which matters because most of these accounts were created
// with Google on the phone and have no password to type.
//
// Server side: functions/tesla-pairing.js.

import { callFn, loginWithToken } from './auth.js';
import { t } from './i18n.js';
import { track } from './analytics.js';

const DEVICE_KEY = 'gc_device_id';
// Set the moment a pairing succeeds and cleared on sign-out (auth.js). It is
// what separates "this car was paired from the phone" — where disconnecting in
// the app must throw the car out — from a classic email/Google session, which
// has no link document and must be left alone.
const PAIRED_KEY = 'gc_paired';
const POLL_MS = 3500;

/** True when this session was created by pairing with the phone. */
export function isPairedSession() {
  return localStorage.getItem(PAIRED_KEY) === '1';
}

/**
 * This car's id, kept for the life of the browser profile. It is what the
 * account is linked to, so clearing the Tesla browser's data means pairing
 * again — and it is also what lets the SAME car re-pair without the phone
 * having to disconnect anything.
 */
export function deviceId() {
  let id = localStorage.getItem(DEVICE_KEY);
  if (!id) {
    id = (crypto.randomUUID?.() ?? String(Math.random()).slice(2) + Date.now())
      .replace(/-/g, '');
    localStorage.setItem(DEVICE_KEY, id);
  }
  return id;
}

const hex = (buf) => [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, '0')).join('');

async function sha256Hex(text) {
  return hex(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text)));
}

const MAX_AUTO_RENEWS = 6; // ~30 min of waiting, then the driver taps for more

const state = {
  code: null,
  secret: null,
  expiresAt: 0,
  poll: null,
  tick: null,
  running: false,
  renews: 0,
};

const $ = (id) => document.getElementById(id);

function showError(key) {
  const el = $('pair-error');
  el.textContent = t(key);
  el.classList.remove('is-hidden');
}

function clearError() {
  $('pair-error').classList.add('is-hidden');
}

function paintCode(code) {
  // Grouped 3+3: read aloud from the driver's seat and typed on a phone.
  $('pair-code').textContent = `${code.slice(0, 3)} ${code.slice(3)}`;
}

function paintTimer() {
  const left = Math.max(0, state.expiresAt - Date.now());
  if (left === 0) {
    stopPolling();
    $('pair-timer').textContent = t('pairExpired');
    $('pair-refresh').classList.remove('is-hidden');
    // A dead code on a car screen is a dead end, and the driver may be halfway
    // through typing it. Fetch the next one straight away and let them carry on
    // — but not forever: a screen nobody is looking at stops asking.
    if (state.renews < MAX_AUTO_RENEWS) {
      state.renews++;
      newPairing();
    }
    return;
  }
  const m = Math.floor(left / 60000);
  const s = Math.floor((left % 60000) / 1000);
  $('pair-timer').textContent = `${t('pairValid')} ${m}:${String(s).padStart(2, '0')}`;
}

function stopPolling() {
  clearInterval(state.poll);
  clearInterval(state.tick);
  state.poll = state.tick = null;
}

async function poll() {
  if (!state.code) return;
  try {
    const res = await callFn('redeemTeslaPairing', {
      code: state.code,
      secret: state.secret,
      deviceId: deviceId(),
    });
    if (!res?.token) return; // still waiting on the phone
    stopPolling();
    track('tesla_pair_success', {});
    localStorage.setItem(PAIRED_KEY, '1');
    await loginWithToken(res.token);
  } catch (e) {
    // 'not-found' after approval means the code was already spent (a duplicate
    // poll won the race) — anything else is worth showing.
    if (e.code === 'functions/not-found') {
      // Either the code really lapsed or another poll of ours already spent it.
      // If it was spent, sign-in is seconds away and this code is moot; if it
      // lapsed, the driver needs a fresh one without hunting for a button.
      stopPolling();
      $('pair-timer').textContent = t('pairExpired');
      $('pair-refresh').classList.remove('is-hidden');
      setTimeout(() => {
        if ($('login-screen').classList.contains('is-open')) newPairing();
      }, 1500);
    }
    // Anything else (a server hiccup while minting the token) is transient:
    // keep polling, the code is not spent until a token exists.
  }
}

/** Ask for a fresh code and start waiting for the phone. */
export async function newPairing() {
  if (state.running) return;
  state.running = true;
  stopPolling();
  clearError();
  $('pair-refresh').classList.add('is-hidden');
  $('pair-code').textContent = '· · ·';
  $('pair-timer').textContent = '';

  try {
    state.secret = hex(crypto.getRandomValues(new Uint8Array(32)));
    const res = await callFn('createTeslaPairing', {
      deviceId: deviceId(),
      secretHash: await sha256Hex(state.secret),
    });
    state.code = res.code;
    // Count down from a duration, not from the server's absolute timestamp: a
    // car whose clock is off by minutes would otherwise kill a perfectly live
    // code (and stop polling) while the driver is still typing it.
    state.expiresAt = Date.now() + (res.ttlMs ?? Math.max(0, res.expiresAt - Date.now()));
    paintCode(res.code);
    paintTimer();
    state.tick = setInterval(paintTimer, 1000);
    state.poll = setInterval(poll, POLL_MS);
    track('tesla_pair_code', {});
  } catch (e) {
    $('pair-code').textContent = '— — —';
    showError(e.code === 'functions/resource-exhausted' ? 'pairTooMany' : 'pairFailed');
    $('pair-refresh').classList.remove('is-hidden');
  } finally {
    state.running = false;
  }
}

export function stopPairing() {
  stopPolling();
  state.code = state.secret = null;
}

export function initPairing() {
  $('pair-refresh')?.addEventListener('click', () => {
    state.renews = 0;
    newPairing();
  });
  // A code left running while the car sleeps is a dead code; re-issue on return.
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState !== 'visible') return;
    if (!$('login-screen').classList.contains('is-open')) return;
    if (Date.now() > state.expiresAt) {
      state.renews = 0; // they are back at the screen: start the budget over
      newPairing();
    }
  });
}
