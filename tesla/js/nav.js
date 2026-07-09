// Navigation via Google Maps web (matches the mobile app's launchUrl).
// Tesla's own nav doesn't work in Georgia, so opening Google Maps directions
// in a new tab — with dir_action=navigate to auto-start — is the way to drive.

/**
 * Build a Google Maps directions URL.
 * @param {{lat:number,lng:number}} destination
 * @param {{lat:number,lng:number}} [origin]
 * @param {{lat:number,lng:number}[]} [waypoints]  ordered intermediate points
 * @param {boolean} [autoStart=true]  append dir_action=navigate
 */
export function buildDirUrl({ destination, origin, waypoints = [], autoStart = true }) {
  const p = new URLSearchParams({ api: '1', travelmode: 'driving' });
  if (origin) p.set('origin', `${origin.lat},${origin.lng}`);
  p.set('destination', `${destination.lat},${destination.lng}`);
  if (waypoints.length) {
    p.set('waypoints', waypoints.map((w) => `${w.lat},${w.lng}`).join('|'));
  }
  if (autoStart) p.set('dir_action', 'navigate');
  return `https://www.google.com/maps/dir/?${p.toString()}`;
}

/** Open turn-by-turn directions to a single point in a new tab. */
export function navigateTo(lat, lng) {
  window.open(buildDirUrl({ destination: { lat, lng } }), '_blank', 'noopener');
}

/** Open a full multi-stop route in a new tab. */
export function navigateRoute({ origin, destination, waypoints }) {
  window.open(buildDirUrl({ origin, destination, waypoints }), '_blank', 'noopener');
}
