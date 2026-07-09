// Formatting helpers that mirror the mobile app exactly.

import { getLang } from './i18n.js';

// ── Timezone: Tbilisi = UTC+4, no DST (matches _formatVerified in main.dart) ──
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/**
 * Parse a gist "YYYY-MM-DD HH:MM UTC" timestamp and render it in Tbilisi local
 * time as "09 Jul, 14:49". Non-matching input is returned verbatim.
 */
export function formatVerified(raw) {
  if (!raw) return '';
  const m = /^(\d{4})-(\d{2})-(\d{2})\s+(\d{2}):(\d{2})\s*UTC$/i.exec(raw.trim());
  if (!m) return raw;
  const utc = Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5]);
  const d = new Date(utc + 4 * 3600 * 1000); // +4h, read back as UTC fields
  const dd = String(d.getUTCDate()).padStart(2, '0');
  const mon = MONTHS[d.getUTCMonth()];
  const hh = String(d.getUTCHours()).padStart(2, '0');
  const mi = String(d.getUTCMinutes()).padStart(2, '0');
  return `${dd} ${mon}, ${hh}:${mi}`;
}

// ── Busy timer: bucketed "charging for" (matches chargingFor in app_strings) ──
/** minutes → "Just started" (<5), "Charging 25+ min" (5-min buckets), "Charging 1 h+" (≥60). */
export function chargingFor(minutes) {
  const ka = getLang() === 'ka';
  if (minutes >= 60) {
    const h = Math.floor(minutes / 60);
    return ka ? `იტენება ${h} სთ+` : `Charging ${h} h+`;
  }
  const b = Math.floor(minutes / 5) * 5;
  if (b <= 0) return ka ? 'ახლახ დაიწყო' : 'Just started';
  return ka ? `იტენება ${b}+ წთ` : `Charging ${b}+ min`;
}

/** Elapsed-minutes label for a busy port, or null if no/invalid `since`. */
export function busyForLabel(since) {
  if (!since) return null;
  const t = Date.parse(since);
  if (Number.isNaN(t)) return null;
  const mins = Math.floor((Date.now() - t) / 60000);
  if (mins < 0) return null;
  return chargingFor(mins);
}

// ── Provider logos (new feature — the app has none) ──────────────────────────
const PROVIDER_LOGOS = {
  'e-space': 'espace.svg',
  'mart ev': 'martev.svg',
  'moveo': 'moveo.png',
  'electrify georgia': 'electrify.png',
  'ev power ge': 'evpower.png',
  'da-tene': 'datene.png',
  'gadatene': 'gadatene-dark.svg',
  'ecocars': 'ecocars.png',
  'solar station': 'solarstation.png',
  'tegeta': 'tegeta.png',
  'charger plus': 'chargerplus.png',
};

/** Logo asset path for a provider name, or null (e.g. International/OCM). */
export function providerLogo(name) {
  const file = PROVIDER_LOGOS[(name || '').trim().toLowerCase()];
  return file ? `assets/providers/${file}` : null;
}
