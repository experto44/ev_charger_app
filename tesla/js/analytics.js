// Firebase Analytics (GA4) — funnel events for the Tesla web app.
// Never breaks the app: every call is fire-and-forget behind a try/catch
// (analytics can be blocked/unavailable in the car browser).

import { getApps } from 'https://www.gstatic.com/firebasejs/10.12.2/firebase-app.js';
import {
  getAnalytics,
  logEvent,
} from 'https://www.gstatic.com/firebasejs/10.12.2/firebase-analytics.js';

let analytics = null;

export function initAnalytics() {
  try {
    analytics = getAnalytics(getApps()[0]);
  } catch (_) {
    analytics = null;
  }
}

/** track('tesla_trial_start'), track('trip_planned', {stops: 2}) … */
export function track(event, params = {}) {
  if (!analytics) return;
  try {
    logEvent(analytics, event, params);
  } catch (_) {/* never surface analytics failures */}
}
