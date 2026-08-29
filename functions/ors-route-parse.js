"use strict";

// Turning an OpenRouteService GeoJSON answer into the plain road shape the EV
// core already runs on: { pts, totalDistKm, legEndsKm }, the same three fields
// the Google path produced.
//
// Kept apart from ors-route.js so it can be tested without network or secrets,
// the way google-route-parse.js is. Every failure returns null rather than
// throwing or half-filling the shape, because the caller turns null into a
// Google fallback — a surprise from upstream must degrade, never corrupt a plan.

/**
 * Flattens the per-leg step lists into one, keeping each step's maneuver code,
 * road name, roundabout exit and the geometry index where it ends — which is
 * everything drive mode needs to draw an arrow, say a sentence and know how far
 * the turn still is. The wording itself stays on the client, in
 * tesla/js/turn-phrases.js, next to the rest of the app's Georgian.
 *
 * Steps are best-effort: the trip planner does not use them, so a response
 * without usable ones still yields a road. Only drive mode cares, and it falls
 * back to Google when they are missing.
 */
function stepsFrom(segments, pointCount) {
  const steps = [];
  for (const seg of segments) {
    for (const st of (Array.isArray(seg.steps) ? seg.steps : [])) {
      const wp = st && st.way_points;
      if (!Array.isArray(wp) || wp.length < 2) return [];
      const endIdx = wp[1];
      if (!Number.isInteger(endIdx) || endIdx < 0 || endIdx >= pointCount) return [];
      steps.push({
        type: Number.isInteger(st.type) ? st.type : null,
        name: typeof st.name === "string" ? st.name : "",
        exit: Number.isInteger(st.exit_number) ? st.exit_number : null,
        endIdx,
      });
    }
  }
  return steps;
}

/**
 * @param {unknown} body parsed ORS GeoJSON
 * @returns {{pts: {lat:number,lng:number}[], totalDistKm: number,
 *            legEndsKm: number[], steps: object[], totalDurS: number}|null}
 */
function roadFrom(body) {
  const f = body && Array.isArray(body.features) ? body.features[0] : null;
  const coords = f && f.geometry && f.geometry.coordinates;
  const props = (f && f.properties) || {};
  const summary = props.summary || {};
  if (!Array.isArray(coords) || coords.length < 2) return null;

  const pts = [];
  for (const c of coords) {
    if (!Array.isArray(c) || c.length < 2) return null;
    const [lng, lat] = c;                       // GeoJSON is lng,lat
    if (!Number.isFinite(lat) || !Number.isFinite(lng)) return null;
    pts.push({ lat, lng });
  }

  // One ORS "segment" per leg between consecutive waypoints, exactly like a
  // Google leg — legEndsKm is the cumulative distance at each waypoint
  // boundary, which is what lets the planner interleave charging stops with
  // the driver's own stops without re-sorting them.
  const segments = Array.isArray(props.segments) ? props.segments : [];
  let totalDistKm = 0;
  const legEndsKm = [];
  for (const seg of segments) {
    if (!seg || !Number.isFinite(seg.distance)) return null;
    totalDistKm += seg.distance / 1000;
    legEndsKm.push(totalDistKm);
  }

  // No segments (some ORS responses only carry a summary): one leg, and the
  // planner still gets a usable end marker.
  if (!legEndsKm.length) {
    if (!Number.isFinite(summary.distance)) return null;
    totalDistKm = summary.distance / 1000;
    legEndsKm.push(totalDistKm);
  }

  if (!(totalDistKm > 0)) return null;

  const totalDurS = Number.isFinite(summary.duration) ? summary.duration : 0;

  return {
    pts,
    totalDistKm,
    legEndsKm,
    totalDurS,
    steps: stepsFrom(segments, pts.length),
  };
}

module.exports = { roadFrom };
