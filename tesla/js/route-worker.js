// Runs the route-planning core off the UI thread.
//
// Planning Tbilisi → İstanbul means projecting ~14k chargers onto a ~39k-point
// polyline. Even after the spatial-grid rewrite that is most of a second on a
// laptop and several on a car's processor — long enough to freeze the page if
// it happens on the main thread. Here it does not: the map keeps panning and
// the drawer keeps scrolling while the plan is computed.
//
// routing.js falls back to calling the same module directly if a worker cannot
// be created, so there is only ever one implementation of the algorithm.

import { planFromRoute } from './route-core.js';

self.onmessage = (e) => {
  const { id, input } = e.data ?? {};
  try {
    self.postMessage({ id, result: planFromRoute(input) });
  } catch (err) {
    self.postMessage({ id, error: String(err?.message ?? err) });
  }
};
