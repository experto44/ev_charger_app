"use strict";

// Fixtures for the OpenRouteService road parser.
//
//   cd functions && node --test
//
// No network and no key: the point is that a malformed or surprising answer
// from ORS becomes null — which the caller turns into a Google fallback —
// rather than a half-built road that would send the EV planner looking for
// chargers along a route that does not exist.

const test = require("node:test");
const assert = require("node:assert");

const { roadFrom } = require("./ors-route-parse");

// A two-leg answer, shaped like ORS returns it: GeoJSON lng,lat coordinates
// and one `segment` per leg between consecutive waypoints.
const twoLeg = () => ({
  type: "FeatureCollection",
  features: [{
    type: "Feature",
    geometry: {
      type: "LineString",
      coordinates: [
        [44.8271, 41.7151],   // Tbilisi
        [43.9000, 41.9000],
        [42.6946, 42.2679],   // Kutaisi
        [41.6405, 41.6461],   // Batumi
      ],
    },
    properties: {
      summary: { distance: 357500, duration: 17100 },
      segments: [
        { distance: 220700, duration: 10980 },
        { distance: 136800, duration: 6120 },
      ],
    },
  }],
});

test("reads coordinates as lat/lng out of GeoJSON lng/lat", () => {
  const road = roadFrom(twoLeg());
  assert.ok(road);
  assert.equal(road.pts.length, 4);
  assert.deepEqual(road.pts[0], { lat: 41.7151, lng: 44.8271 });
  assert.deepEqual(road.pts[3], { lat: 41.6461, lng: 41.6405 });
});

test("legEndsKm is cumulative, one entry per leg", () => {
  const road = roadFrom(twoLeg());
  assert.equal(road.legEndsKm.length, 2);
  assert.ok(Math.abs(road.legEndsKm[0] - 220.7) < 1e-9);
  assert.ok(Math.abs(road.legEndsKm[1] - 357.5) < 1e-9);
  assert.ok(Math.abs(road.totalDistKm - 357.5) < 1e-9);
});

test("falls back to the summary when there are no segments", () => {
  const body = twoLeg();
  delete body.features[0].properties.segments;
  const road = roadFrom(body);
  assert.ok(road);
  assert.deepEqual(road.legEndsKm, [357.5]);
  assert.equal(road.totalDistKm, 357.5);
});

// ── Steps, which only drive mode reads ──────────────────────────────────────

const withSteps = () => {
  const b = twoLeg();
  b.features[0].properties.segments[0].steps = [
    { type: 11, name: "რუსთაველის გამზირი", way_points: [0, 1] },
    { type: 1,  name: "-",                  way_points: [1, 2] },
  ];
  b.features[0].properties.segments[1].steps = [
    { type: 8,  name: "E60", exit_number: 2, way_points: [2, 3] },
    { type: 10, name: "",                    way_points: [3, 3] },
  ];
  return b;
};

test("flattens steps across legs and keeps where each one ends", () => {
  const road = roadFrom(withSteps());
  assert.equal(road.steps.length, 4);
  assert.deepEqual(road.steps.map((s) => s.endIdx), [1, 2, 3, 3]);
  assert.deepEqual(road.steps.map((s) => s.type), [11, 1, 8, 10]);
  assert.equal(road.steps[0].name, "რუსთაველის გამზირი");
  assert.equal(road.steps[2].exit, 2);
  assert.equal(road.steps[1].exit, null);
});

test("carries the total duration from the summary", () => {
  assert.equal(roadFrom(withSteps()).totalDurS, 17100);
  const noSummary = withSteps();
  delete noSummary.features[0].properties.summary;
  assert.equal(roadFrom(noSummary).totalDurS, 0);
});

test("a road with no steps is still a road", () => {
  const road = roadFrom(twoLeg());
  assert.ok(road);
  assert.deepEqual(road.steps, []);
  assert.ok(road.totalDistKm > 0);
});

// Drive mode indexes into pts with endIdx, so a step pointing past the end of
// the geometry would read undefined and mis-place every later turn. Drop the
// lot instead: no steps means drive mode uses Google, which is safe.
test("drops all steps when one points outside the geometry", () => {
  const b = withSteps();
  b.features[0].properties.segments[1].steps[0].way_points = [2, 999];
  const road = roadFrom(b);
  assert.ok(road);
  assert.deepEqual(road.steps, []);
});

test("drops all steps when a step has no way_points", () => {
  const b = withSteps();
  delete b.features[0].properties.segments[0].steps[1].way_points;
  assert.deepEqual(roadFrom(b).steps, []);
});

// ── Everything below must return null, so the caller falls back to Google ────

test("null for an empty or missing answer", () => {
  assert.equal(roadFrom(null), null);
  assert.equal(roadFrom(undefined), null);
  assert.equal(roadFrom({}), null);
  assert.equal(roadFrom({ features: [] }), null);
});

test("null when the geometry is too short to be a road", () => {
  const body = twoLeg();
  body.features[0].geometry.coordinates = [[44.8271, 41.7151]];
  assert.equal(roadFrom(body), null);
});

test("null on a non-numeric coordinate", () => {
  const body = twoLeg();
  body.features[0].geometry.coordinates[1] = [43.9, "north"];
  assert.equal(roadFrom(body), null);
});

test("null on a truncated coordinate pair", () => {
  const body = twoLeg();
  body.features[0].geometry.coordinates[2] = [42.6946];
  assert.equal(roadFrom(body), null);
});

test("null when a leg carries no distance", () => {
  const body = twoLeg();
  delete body.features[0].properties.segments[1].distance;
  assert.equal(roadFrom(body), null);
});

test("null when nothing states a distance at all", () => {
  const body = twoLeg();
  delete body.features[0].properties.segments;
  delete body.features[0].properties.summary;
  assert.equal(roadFrom(body), null);
});

test("null on a zero-length road", () => {
  const body = twoLeg();
  body.features[0].properties.segments = [{ distance: 0, duration: 0 }];
  assert.equal(roadFrom(body), null);
});

// An ORS error body is JSON too, and must not be mistaken for a road.
test("null for an ORS error payload", () => {
  assert.equal(
    roadFrom({ error: { code: 2010, message: "Could not find routable point" } }),
    null,
  );
});
