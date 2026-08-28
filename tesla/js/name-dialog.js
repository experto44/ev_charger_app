// "What shall we call it?" — the one modal that asks for a name.
//
// Shared by saved places (which also pick an icon) and saved routes (which do
// not), so the driver types a name into the same box wherever they are. It
// resolves a promise instead of taking callbacks: every caller wants exactly
// one answer and then wants to get on with saving.

const $ = (id) => document.getElementById(id);

/** Longest name the field accepts. Rows and chips ellipsise past that. */
export const MAX_NAME = 32;

// The dialog is a singleton in the page; this is whoever is currently waiting
// on it. Opening it a second time answers the first caller with null rather
// than leaving a promise hanging forever.
let pending = null;

function renderIcons(icons, selected, onPick) {
  const wrap = $('fav-icons');
  wrap.innerHTML = '';
  wrap.hidden = !icons;
  if (!icons) return;
  for (const icon of icons) {
    const b = document.createElement('button');
    b.className = `fav-icon${icon === selected ? ' is-on' : ''}`;
    b.type = 'button';
    b.textContent = icon;
    b.addEventListener('click', () => onPick(icon));
    wrap.appendChild(b);
  }
}

function settle(value) {
  const p = pending;
  pending = null;
  $('fav-dialog').classList.add('is-hidden');
  p?.resolve(value);
}

/**
 * Ask for a name.
 *
 * @param {object} o
 * @param {string} o.title       heading, already translated
 * @param {string} [o.subtitle]  the thing being named, shown above the field
 * @param {string} [o.value]     what the field starts with
 * @param {string} [o.placeholder]
 * @param {string[]} [o.icons]   offer an icon row; omit for a name-only dialog
 * @param {string} [o.icon]      the icon that starts selected
 * @param {(name:string)=>string} [o.guessIcon]
 *        Re-picks the icon as the driver types, until they pick one by hand.
 * @returns {Promise<{name:string, icon:string|null}|null>} null on cancel
 */
export function askName(o) {
  settle(null); // whatever was open loses

  const state = { icon: o.icon ?? null, touched: false };

  $('fav-dialog-title').textContent = o.title;
  const sub = $('fav-dialog-place');
  sub.textContent = o.subtitle ?? '';
  sub.hidden = !o.subtitle;

  const input = $('fav-name');
  input.value = o.value ?? '';
  input.placeholder = o.placeholder ?? '';

  const paint = () => renderIcons(o.icons, state.icon, (icon) => {
    state.icon = icon;
    state.touched = true; // the name must stop overriding a deliberate pick
    paint();
  });
  paint();

  $('fav-dialog').classList.remove('is-hidden');
  input.focus();
  input.select();

  return new Promise((resolve) => {
    pending = {
      resolve,
      read: () => {
        const name = input.value.trim().slice(0, MAX_NAME);
        return name ? { name, icon: state.icon } : null; // an unnamed thing is not worth saving
      },
      retype: () => {
        if (state.touched || !o.guessIcon) return;
        state.icon = o.guessIcon(input.value);
        paint();
      },
    };
  });
}

/** True while the dialog is waiting on an answer. */
export function isNameDialogOpen() {
  return pending !== null;
}

export function initNameDialog() {
  $('fav-cancel').addEventListener('click', () => settle(null));
  $('fav-save').addEventListener('click', () => {
    const answer = pending?.read();
    if (answer) settle(answer);
  });
  $('fav-name').addEventListener('input', () => pending?.retype());
  $('fav-name').addEventListener('keydown', (e) => {
    if (e.key === 'Enter') {
      const answer = pending?.read();
      if (answer) settle(answer);
    }
    if (e.key === 'Escape') settle(null);
  });
}
