// Access gate: login → 24h account trial → premium required.
//
// Screens (mutually exclusive):
//   #login-screen    — no user signed in
//   #paywall-screen  — signed in, trial expired, not premium
//   the app itself   — signed in AND (premium OR trial active)

import { ensureTrial, logout, watchAuth, watchDeviceLink, watchPremium, TRIAL_MS } from './auth.js';
import { track } from './analytics.js';
import { t } from './i18n.js';
import { PAIRING_ENABLED } from './config.js';
import { deviceId, isPairedSession, newPairing, stopPairing } from './pair.js';
import { showToast } from './ui.js';

const state = {
  user: null,
  premium: false,
  trialEndsAt: null, // epoch ms
  stopPremium: null,
  stopDevice: null,
  expiryTimer: null,
  countdownTimer: null,
};

let onGranted = null;
let granted = false;

function show(screen) {
  const login = document.getElementById('login-screen');
  const wasLogin = login.classList.contains('is-open');
  login.classList.toggle('is-open', screen === 'login');
  document.getElementById('paywall-screen').classList.toggle('is-open', screen === 'paywall');

  // A pairing code is only worth having while it is on screen.
  if (!PAIRING_ENABLED) return;
  if (screen === 'login' && !wasLogin) newPairing();
  if (screen !== 'login' && wasLogin) stopPairing();
}

function trialActive() {
  return state.trialEndsAt !== null && Date.now() < state.trialEndsAt;
}

function evaluate() {
  clearTimeout(state.expiryTimer);
  clearInterval(state.countdownTimer);

  if (!state.user) {
    show('login');
    return;
  }
  if (state.premium) {
    show(null);
    grantOnce();
    setBadge(t('premiumBadge'), false);
    return;
  }
  if (trialActive()) {
    show(null);
    grantOnce();
    startCountdown();
    // Flip to the paywall the moment the trial runs out mid-session.
    state.expiryTimer = setTimeout(evaluate, state.trialEndsAt - Date.now() + 1000);
    return;
  }
  document.getElementById('access-badge').classList.add('is-hidden');
  if (!state.paywallSeen) {
    state.paywallSeen = true; // once per session
    track('paywall_view');
  }
  show('paywall');
}

function grantOnce() {
  if (!granted) {
    granted = true;
    onGranted?.();
  }
}

function setBadge(text, isTrial) {
  const el = document.getElementById('access-badge');
  el.textContent = text;
  el.classList.toggle('badge--trial', isTrial);
  el.classList.remove('is-hidden');
}

function startCountdown() {
  const paint = () => {
    const left = Math.max(0, state.trialEndsAt - Date.now());
    const h = String(Math.floor(left / 3600000)).padStart(2, '0');
    const m = String(Math.floor((left % 3600000) / 60000)).padStart(2, '0');
    setBadge(`${t('trialBadge')} ${h}:${m}`, true);
  };
  paint();
  state.countdownTimer = setInterval(paint, 30000);
}

/**
 * Start the gate. `whenGranted` runs exactly once, the first time access is
 * allowed — the app boots behind it. Later downgrades (trial expiry) overlay
 * the paywall on top of the running app rather than tearing it down.
 */
export function startGate(whenGranted) {
  onGranted = whenGranted;

  watchAuth(async (user) => {
    state.stopPremium?.();
    state.stopDevice?.();
    state.stopDevice = null;
    state.user = user;
    state.premium = false;
    state.trialEndsAt = null;

    if (!user) {
      document.getElementById('access-badge').classList.add('is-hidden');
      evaluate();
      return;
    }

    document.getElementById('user-email').textContent = user.email ?? '';

    // One account drives one car: if the phone pairs a different Tesla (or
    // disconnects this one), this session ends here rather than quietly
    // sharing a subscription between two cars.
    state.stopDevice = watchDeviceLink(user.uid, deviceId(), isPairedSession(), (why) => {
      showToast(t(why === 'unlinked' ? 'pairDisconnected' : 'pairRevoked'), 8000);
      track('tesla_pair_revoked', { why });
      logout();
    });

    // Premium is realtime: buying on the phone unlocks this screen live.
    state.stopPremium = watchPremium(user.uid, (premium) => {
      if (premium && !state.premium && state.paywallSeen) track('premium_unlock');
      state.premium = premium;
      evaluate();
    });

    try {
      state.trialEndsAt = await ensureTrial(user.uid);
    } catch (e) {
      // Trial doc unreadable/uncreatable (offline, rules) — premium listener
      // still decides; without either the paywall shows, which is the safe side.
      state.trialEndsAt = null;
    }
    evaluate();
  });
}
