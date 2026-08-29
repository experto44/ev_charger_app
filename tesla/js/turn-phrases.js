// Turn-by-turn wording, in our own words.
//
// Google handed us a ready Georgian sentence per step (the Maps API is loaded
// with language=ka). OpenRouteService does not: it returns a maneuver code, the
// road name, and an English sentence. So the Georgian is ours to write — which
// is no loss, since Google's was machine-translated and read like it.
//
// Deliberately pure: no imports, no DOM, `lang` comes in as an argument. That
// is what lets every phrase be exercised from the console in one call.

// ── The one schema-dependent thing in this file ──────────────────────────────
// OpenRouteService numbers its maneuvers. Verified against live responses on
// 2026-08-29 rather than taken from the docs: for five Georgian routes, the
// turn angle was measured from the geometry either side of each maneuver and
// matched against the code. 0 came out at a median -84 degrees over 24
// samples and 1 at +84 over 20, so left and right are the right way round;
// 12/13 (-32 / +37) and 6 (-4, straight) hold too.
//
// The measurement only works if you remember that a step's maneuver happens at
// its START. Attributing the turn to the step that ENDS there inverts the whole
// table, which is exactly the mistake this comment exists to prevent.
//
// ORS puts the exit number on 7 and never emits 8 in practice, so a roundabout
// is one maneuver here, not an enter/exit pair.
export const ORS_TYPE = {
  0: 'left',
  1: 'right',
  2: 'sharpLeft',
  3: 'sharpRight',
  4: 'slightLeft',
  5: 'slightRight',
  6: 'straight',
  7: 'roundabout',
  8: 'roundabout',   // never seen in a live response; mapped in case it appears
  9: 'uturn',
  10: 'arrive',
  11: 'depart',
  12: 'keepLeft',
  13: 'keepRight',
};

// Which arrow glyph drive.js should draw. Kept here beside the wording so a new
// maneuver is one edit, not two files.
export const TURN_ARROW = {
  left: 'left',
  right: 'right',
  sharpLeft: 'left',
  sharpRight: 'right',
  slightLeft: 'left',
  slightRight: 'right',
  keepLeft: 'left',
  keepRight: 'right',
  uturn: 'uturn',
  straight: 'up',
  depart: 'up',
  // Measured at a median -5 degrees: entering a roundabout is geometrically
  // straight ahead. The exit number in the text is what the driver acts on.
  roundabout: 'up',
  arrive: 'flag',
};

// Georgian is informal throughout this app ("გახსენი", "მიუთითე"), so the
// instructions are too. `{road}` is dropped when the step has no name.
const KA = {
  left:            'მოუხვიე მარცხნივ',
  right:           'მოუხვიე მარჯვნივ',
  sharpLeft:       'მკვეთრად მოუხვიე მარცხნივ',
  sharpRight:      'მკვეთრად მოუხვიე მარჯვნივ',
  slightLeft:      'ოდნავ მარცხნივ',
  slightRight:     'ოდნავ მარჯვნივ',
  straight:        'გააგრძელე პირდაპირ',
  keepLeft:        'დარჩი მარცხენა ზოლში',
  keepRight:       'დარჩი მარჯვენა ზოლში',
  uturn:           'მოტრიალდი',
  depart:          'დაიწყე მოძრაობა',
  roundabout:      'შედი წრიულ მოძრაობაში',
  arrive:          'ჩახვედი დანიშნულების ადგილას',
};

const EN = {
  left:            'Turn left',
  right:           'Turn right',
  sharpLeft:       'Sharp left',
  sharpRight:      'Sharp right',
  slightLeft:      'Slight left',
  slightRight:     'Slight right',
  straight:        'Continue straight',
  keepLeft:        'Keep left',
  keepRight:       'Keep right',
  uturn:           'Make a U-turn',
  depart:          'Start driving',
  roundabout:      'Enter the roundabout',
  arrive:          'You have arrived',
};

// Roundabouts read better counted than described: "გადი მეორე გასასვლელით".
const KA_ORDINAL = ['', 'პირველი', 'მეორე', 'მესამე', 'მეოთხე', 'მეხუთე',
                    'მეექვსე', 'მეშვიდე', 'მერვე', 'მეცხრე', 'მეათე'];
const EN_ORDINAL = ['', 'first', 'second', 'third', 'fourth', 'fifth',
                    'sixth', 'seventh', 'eighth', 'ninth', 'tenth'];

function roundaboutExit(exit, ka) {
  const n = Number(exit);
  if (!Number.isInteger(n) || n < 1) return null; // no exit number to give
  if (ka) {
    const word = KA_ORDINAL[n] || `${n}-ე`;
    return `გადი ${word} გასასვლელით`;
  }
  const word = EN_ORDINAL[n] || `${n}th`;
  return `Take the ${word} exit`;
}

// Maneuvers that read wrong with a road appended.
const NO_ROAD_NAME = new Set(['arrive', 'uturn']);

// "რუსთაველის გამზირი" is the name; what you turn onto is "რუსთაველის
// გამზირზე". Only the last word of the phrase declines, and -ზე attaches to the
// stem: a nominative -ი is dropped first ("გამზირი" → "გამზირზე"), while a name
// already ending in a vowel just takes the suffix ("ქუჩა" → "ქუჩაზე"). Latin
// letters and digits take a hyphen the way Georgian writes them ("E60-ზე").
const MKHEDRULI = /[ა-ჿ]/;

function toLocative(name) {
  const words = name.split(/\s+/);
  let last = words[words.length - 1];
  if (!last) return name;

  const tail = last[last.length - 1];
  if (tail === 'ი' && last.length > 1) {
    last = last.slice(0, -1) + 'ზე';
  } else if (MKHEDRULI.test(tail)) {
    last += 'ზე';
  } else {
    last += '-ზე';
  }
  words[words.length - 1] = last;
  return words.join(' ');
}

// ORS writes "-" for a road it has no name for; so does a motorway link.
function cleanRoad(name) {
  const s = String(name ?? '').trim();
  if (!s || s === '-' || s === 'unknown') return '';
  return s;
}

/**
 * One line of guidance, ready to show and to speak.
 *
 * @param {{type?: number, key?: string, name?: string, exit?: number}} step
 *        `type` is the ORS maneuver code; `key` overrides it when the caller
 *        already knows the maneuver by name (the Google path does).
 * @param {string} lang 'ka' or anything else for English
 * @returns {{text: string, arrow: string}}
 */
export function turnPhrase(step, lang) {
  const ka = lang === 'ka';
  const key = step?.key || ORS_TYPE[step?.type];
  const arrow = TURN_ARROW[key] || 'up';

  // A roundabout is only worth announcing by its exit number; without one,
  // fall through to the plain "there is a roundabout here".
  const exitPhrase = key === 'roundabout' ? roundaboutExit(step?.exit, ka) : null;

  // An unrecognised maneuver still has to say something useful, and "keep
  // going" is the only safe thing to say when we do not know the turn.
  const base = exitPhrase || (ka ? KA : EN)[key] || (ka ? KA.straight : EN.straight);

  // The road name is the road you come out ONTO, which only makes sense for a
  // turn. "მოტრიალდი, რუსთაველის გამზირი" and "ჩახვედი, რუსთაველის გამზირი"
  // are both wrong, so these maneuvers stay bare.
  // A roundabout without an exit number reads as "there is a roundabout", which
  // no road name belongs on either.
  const bare = NO_ROAD_NAME.has(key) || (key === 'roundabout' && !exitPhrase);
  const road = bare ? '' : cleanRoad(step?.name);
  if (!road) return { text: base, arrow };
  return { text: `${base}, ${ka ? toLocative(road) : road}`, arrow };
}
