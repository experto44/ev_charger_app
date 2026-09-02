// Spoken guidance, from recorded clips.
//
// The car said nothing on the road, and the reason was in drive.js: guidance is
// Georgian, the browser's speech synthesiser has no Georgian voice (a Tesla is
// Chromium on Linux with no TTS voices installed at all), and an English voice
// reading Georgian is worse than silence — so it stayed silent. Correct, and
// useless.
//
// So the voice is not synthesised at all. Every phrase a driver needs is one of
// about twenty short recordings, and an instruction is two of them played back
// to back: "ორას მეტრში" + "მოუხვიე მარჯვნივ". Street names are never spoken —
// they are on the banner, and no recording could cover them.
//
// Clips live in assets/voice/<lang>/<voice>/<id>.mp3, where <voice> is `f` or
// `m` — the driver picks which, from the speaker button in drive mode. Any clip
// that is missing simply does not play, and the phrase falls back to the
// browser's own synthesiser. Adding files is all it takes to make a language or
// a voice speak; no code changes, no release.

import { getLang } from './i18n.js';

const BASE = 'assets/voice';

// Which recorded voice the driver chose. Both languages have a woman and a man;
// 'f' is the default because that is what most car navigation sounds like, and
// the choice sticks across trips.
const SEX_KEY = 'gc_drive_voice_sex';
let sex = localStorage.getItem(SEX_KEY) === 'm' ? 'm' : 'f';

/** 'f' | 'm' — the voice currently speaking. */
export function voiceSex() {
  return sex;
}

/** Switch voices. Anything queued in the old one is dropped mid-sentence. */
export function setVoiceSex(next) {
  const want = next === 'm' ? 'm' : 'f';
  if (want === sex) return sex;
  stop();
  sex = want;
  try { localStorage.setItem(SEX_KEY, sex); } catch (_) {/* private mode */}
  return sex;
}

// What a clip is called, and what it says. The wording matches turn-phrases.js
// exactly — the banner and the voice must not disagree — and this table is also
// the recording script (see assets/voice/README.md).
export const CLIPS = {
  ka: {
    in500: 'ხუთას მეტრში',
    in300: 'სამას მეტრში',
    in200: 'ორას მეტრში',
    in100: 'ას მეტრში',
    in50: 'ორმოცდაათ მეტრში',
    left: 'მოუხვიე მარცხნივ',
    right: 'მოუხვიე მარჯვნივ',
    straight: 'გააგრძელე პირდაპირ',
    keepLeft: 'დარჩი მარცხენა ზოლში',
    keepRight: 'დარჩი მარჯვენა ზოლში',
    uturn: 'მოტრიალდი',
    roundabout: 'შედი წრიულ მოძრაობაში',
    depart: 'დაიწყე მოძრაობა',
    arrive: 'ჩახვედი დანიშნულების ადგილას',
    reroute: 'მარშრუტი გადაითვალა',
  },
  en: {
    in500: 'In five hundred metres',
    in300: 'In three hundred metres',
    in200: 'In two hundred metres',
    in100: 'In one hundred metres',
    in50: 'In fifty metres',
    left: 'Turn left',
    right: 'Turn right',
    straight: 'Continue straight',
    keepLeft: 'Keep left',
    keepRight: 'Keep right',
    uturn: 'Make a U-turn',
    roundabout: 'Enter the roundabout',
    depart: 'Start driving',
    arrive: 'You have arrived',
    reroute: 'Route recalculated',
  },
};

// Maneuvers that share a recording. A sharp left is still "turn left" out loud;
// the banner carries the exact wording for anyone reading it.
const KIND_CLIP = {
  left: 'left',
  sharpLeft: 'left',
  slightLeft: 'left',
  right: 'right',
  sharpRight: 'right',
  slightRight: 'right',
  keepLeft: 'keepLeft',
  keepRight: 'keepRight',
  straight: 'straight',
  uturn: 'uturn',
  roundabout: 'roundabout',
  depart: 'depart',
  arrive: 'arrive',
};

/** Which distance recording fits this many metres, or null to say nothing. */
export function distanceClip(m) {
  if (m >= 400) return 'in500';
  if (m >= 250) return 'in300';
  if (m >= 150) return 'in200';
  if (m >= 75) return 'in100';
  if (m >= 30) return 'in50';
  return null; // close enough that only the maneuver matters
}

/** The clip for a maneuver kind (turn-phrases.js vocabulary). */
export function maneuverClip(kind) {
  return KIND_CLIP[kind] || null;
}

// ── Playback ─────────────────────────────────────────────────────────────────
const cache = new Map();   // "ka/left" -> HTMLAudioElement | null (known missing)
let queue = [];
let playing = false;
let unlocked = false;

function url(lang, id) {
  return `${BASE}/${lang}/${sex}/${id}.mp3`;
}

/**
 * Load a clip once and remember whether it exists. A missing file is cached as
 * null, so a language with no recordings costs one failed request per clip and
 * nothing after that.
 */
function load(lang, id) {
  const key = `${lang}/${sex}/${id}`;
  if (cache.has(key)) return Promise.resolve(cache.get(key));
  return new Promise((resolve) => {
    const a = new Audio();
    a.preload = 'auto';
    a.src = url(lang, id);
    const ok = () => { cache.set(key, a); resolve(a); };
    const bad = () => { cache.set(key, null); resolve(null); };
    a.addEventListener('canplaythrough', ok, { once: true });
    a.addEventListener('error', bad, { once: true });
    // A car on a bad connection must not hold the queue open forever.
    setTimeout(() => { if (!cache.has(key)) bad(); }, 8000);
  });
}

/** Are the recordings for this language actually there? */
export async function hasVoice(lang = getLang()) {
  const probe = await load(lang, 'right');
  return !!probe;
}

/**
 * Warm the whole bank up. Called when navigation starts, so the first
 * instruction does not wait on a download.
 */
export async function preload(lang = getLang()) {
  // One probe first: a language with no recordings should cost a single 404,
  // not one per clip every time navigation starts.
  if (!(await load(lang, 'right'))) return;
  const set = CLIPS[lang] || {};
  for (const id of Object.keys(set)) load(lang, id);
}

/**
 * Browsers refuse to play audio until the user has interacted with the page.
 * Starting navigation is a tap, so that is where this is called from: one
 * muted play/pause is enough to hand us the right to speak later.
 */
export function unlock() {
  if (unlocked) return;
  unlocked = true;
  const a = new Audio(url(getLang(), 'right'));
  a.muted = true;
  const p = a.play();
  if (p && p.catch) p.catch(() => {/* nothing to unlock, or nothing to play */});
  setTimeout(() => { try { a.pause(); } catch (_) {} }, 50);
}

function next() {
  if (!queue.length) { playing = false; return; }
  playing = true;
  const a = queue.shift();
  a.currentTime = 0;
  a.onended = next;
  const p = a.play();
  if (p && p.catch) p.catch(() => next());
}

/** Drop anything still queued (arriving, rerouting, leaving drive mode). */
export function stop() {
  for (const a of queue) { try { a.pause(); } catch (_) {} }
  queue = [];
  playing = false;
}

/**
 * Say a phrase as a sequence of clips, e.g. ['in200', 'right'].
 *
 * @returns {Promise<boolean>} false when nothing could be played, so the caller
 *          can fall back to the browser's own synthesiser.
 */
export async function say(ids, lang = getLang()) {
  const wanted = ids.filter(Boolean);
  if (!wanted.length) return false;
  const clips = await Promise.all(wanted.map((id) => load(lang, id)));
  if (clips.some((c) => !c)) return false; // half a sentence is worse than none
  stop();
  queue = clips;
  next();
  return true;
}
