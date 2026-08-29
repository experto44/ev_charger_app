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
 * @param {unknown} body parsed ORS GeoJSON
 * @returns {{pts: {lat:number,lng:number}[], totalDistKm: number,
 *            legEndsKm: number[]}|null}
 */
function roadFrom(body) {
  const f = body && Array.isArray(body.features) ? body.features[0] : null;
  const coords = f && f.geometry && f.geometry.coordinates;
  const props = (f && f.properties) || {};
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
    const summary = props.summary || {};
    if (!Number.isFinite(summary.distance)) return null;
    totalDistKm = summary.distance / 1000;
    legEndsKm.push(totalDistKm);
  }

  if (!(totalDistKm > 0)) return null;
  return { pts, totalDistKm, legEndsKm };
}

module.exports = { roadFrom };
