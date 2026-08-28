// The camera that follows a moving car outside navigation.
//
// The app opens on the whole of Georgia, which is the right first screen: the
// driver is looking for chargers, not for themselves. The moment the car pulls
// away, though, a country-wide map is useless — so the first fixes that show
// real movement zoom the camera down to the car and keep it there, whether or
// not navigation is running.
//
// Two rules make it bearable rather than bossy:
//   • The location permission is NEVER asked for here. This module starts only
//     once the browser reports geolocation as already granted (the locate
//     button or a drive is what asks), so a first-ever visit is not met with a
//     permission prompt it did not provoke.
//   • Dragging the map — or opening a charger, or searching for somewhere —
//     hands control back to the driver until the car has stopped and started
//     again. Looking at something while every fix yanks the map away is the
//     thing that makes follow-cameras hated.
//
// Drive mode has its own watch and its own camera (drive.js), so this one steps
// aside for the whole of a navigation session.

import { getMap, setUserLocation, setUserStyle } from './map.js';

// Street level, one step wider than drive mode's 17: there is no turn banner
// here, so a little more road ahead is worth having.
const FOLLOW_ZOOM = 16;

// Speed thresholds in m/s. 2.5 m/s is 9 km/h — above walking pace and above
// the wander a parked car's GPS produces; 0.8 m/s is the "we have stopped"
// line. The gap between the two is deliberate: one threshold would flap.
const MOVING_MS = 2.5;
const STOPPED_MS = 0.8;

// Fixes needed to change our mind either way. Moving is confirmed fast (two
// fixes, ~2 s) because that is the moment the driver wants the close-up;
// stopping is confirmed slowly, so a red light does not end the follow.
const MOVING_FIXES = 2;
const STOPPED_FIXES = 8;

const state = {
  watchId: null,
  prev: null,        // { pos, at } — for deriving speed where the GPS gives none
  moving: false,
  movingCount: 0,
  stoppedCount: 0,
  // The driver took the map over — a drag, a search result, a charger they
  // opened. We stop moving the camera under them until the car stops and pulls
  // away again.
  handedOver: false,
  dragListener: null,
  paused: false,     // drive mode is running
};

const rad = (d) => (d * Math.PI) / 180;

function metresBetween(a, b) {
  const R = 6371000;
  const dLat = rad(b.lat - a.lat);
  const dLng = rad(b.lng - a.lng);
  const s =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(rad(a.lat)) * Math.cos(rad(b.lat)) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(s));
}

/**
 * Speed in m/s for this fix. The GPS value is preferred where the device
 * publishes one; otherwise it comes from the distance since the last fix. A
 * gap longer than 30 s says nothing about the present, so it counts as unknown.
 */
function speedOf(coords, pos, at) {
  if (Number.isFinite(coords.speed) && coords.speed >= 0) return coords.speed;
  const p = state.prev;
  if (!p) return null;
  const dt = (at - p.at) / 1000;
  if (dt <= 0 || dt > 30) return null;
  return metresBetween(p.pos, pos) / dt;
}

function onFix(p) {
  if (state.paused) return;
  const pos = { lat: p.coords.latitude, lng: p.coords.longitude };
  const at = Date.now();
  const speed = speedOf(p.coords, pos, at);
  const heading = Number.isFinite(p.coords.heading) ? p.coords.heading : null;

  // The dot (or the car) stays current whatever the camera is doing.
  setUserLocation(pos, heading);

  if (speed == null) {
    state.prev = { pos, at };
    return;
  }

  if (speed >= MOVING_MS) {
    state.stoppedCount = 0;
    state.movingCount++;
    if (!state.moving && state.movingCount >= MOVING_FIXES) {
      state.moving = true;
      // Pulling away is a fresh start: whatever the driver was looking at
      // before they parked, the car is what matters now.
      state.handedOver = false;
      setUserStyle('car');
      const map = getMap();
      map?.panTo(pos);
      map?.setZoom(FOLLOW_ZOOM);
    } else if (state.moving && !state.handedOver) {
      getMap()?.panTo(pos);
    }
  } else if (speed <= STOPPED_MS) {
    state.movingCount = 0;
    state.stoppedCount++;
    if (state.moving && state.stoppedCount >= STOPPED_FIXES) {
      state.moving = false;
      setUserStyle('dot'); // parked: back to the browsing marker
    }
  } else if (state.moving && !state.handedOver) {
    // Between the two thresholds — crawling in traffic. Still driving.
    state.movingCount = 0;
    state.stoppedCount = 0;
    getMap()?.panTo(pos);
  }

  state.prev = { pos, at };
}

/**
 * Start watching the live position, if we may. Idempotent, and silent when the
 * permission has not been granted — the caller must not care.
 */
export function startFollowWatch() {
  if (state.watchId != null || !navigator.geolocation) return;
  state.watchId = navigator.geolocation.watchPosition(
    onFix,
    () => {/* a lost fix is normal in a tunnel; the next one resumes */},
    { enableHighAccuracy: true, maximumAge: 5000, timeout: 20000 },
  );
  // `dragstart` is the driver's finger only — moving the camera in code never
  // raises it, which is what makes it a clean signal.
  if (!state.dragListener) {
    state.dragListener = getMap()?.addListener('dragstart', () => {
      state.handedOver = true;
    }) ?? null;
  }
}

function stopFollowWatch() {
  if (state.watchId == null) return;
  navigator.geolocation.clearWatch(state.watchId);
  state.watchId = null;
  state.prev = null;
  state.moving = false;
  state.movingCount = state.stoppedCount = 0;
}

/**
 * Wire the auto-follow up. Starts watching straight away if the permission is
 * already granted, and picks it up the moment it is granted later (the locate
 * button, or the first drive) without anything having to tell it.
 */
export function initFollow() {
  // Anything that puts the camera somewhere deliberately (map.js's panTo) is
  // the driver looking at something. Leave it alone until the car moves again.
  document.addEventListener('gc:camera-moved', () => {
    state.handedOver = true;
  });

  document.addEventListener('gc:drive-start', () => {
    // Drive mode runs its own watch and owns the camera. Two watches would
    // fight over the marker and the map.
    state.paused = true;
    stopFollowWatch();
  });
  document.addEventListener('gc:drive-end', () => {
    state.paused = false;
    // Navigation ended where the car is; carry on following it from there.
    startFollowWatch();
  });

  if (!navigator.permissions?.query) return; // Safari-shaped browsers: locate button only
  navigator.permissions
    .query({ name: 'geolocation' })
    .then((status) => {
      if (status.state === 'granted') startFollowWatch();
      status.onchange = () => {
        if (status.state === 'granted') startFollowWatch();
        else stopFollowWatch();
      };
    })
    .catch(() => {/* the query itself is optional */});
}

/**
 * The driver asked to see themselves (the locate button), which is the one
 * deliberate camera move that should NOT stop the follow: it is the same place
 * the follow would put it.
 */
export function resumeFollow() {
  state.handedOver = false;
}

/** Debug handle. */
export function followState() {
  return state;
}
