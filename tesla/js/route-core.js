// Pure route-planning core — no DOM, no google.maps, no network.
//
// Split out of routing.js so the expensive part can run inside a Web Worker
// (route-worker.js) and leave the UI thread free. routing.js still calls it
// directly when workers are unavailable, so there is exactly one implementation
// of the algorithm.
//
// Everything here is a 1:1 port of lib/routing_service.dart (planRoute).

// ── Geometry helpers (ported verbatim) ───────────────────────────────────────
const rad = (d) => (d * Math.PI) / 180;

function haversineKm(a, b) {
  const R = 6371.0;
  const dLat = rad(b.lat - a.lat);
  const dLng = rad(b.lng - a.lng);
  const x =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(rad(a.lat)) * Math.cos(rad(b.lat)) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(x));
}

/** [perpendicularDistanceKm, tFraction] of p onto segment a→b. */
function projectToSegment(p, a, b) {
  const latRef = rad(a.lat);
  const px = (q) => rad(q.lng - a.lng) * Math.cos(latRef) * 6371.0;
  const py = (q) => rad(q.lat - a.lat) * 6371.0;
  const bx = px(b), by = py(b);
  const qx = px(p), qy = py(p);
  const len2 = bx * bx + by * by;
  let t = len2 === 0 ? 0 : (qx * bx + qy * by) / len2;
  t = Math.min(1, Math.max(0, t));
  const cx = t * bx, cy = t * by;
  return [Math.hypot(qx - cx, qy - cy), t];
}

function bearing(a, b) {
  const lat1 = rad(a.lat), lat2 = rad(b.lat);
  const dLon = rad(b.lng - a.lng);
  const y = Math.sin(dLon) * Math.cos(lat2);
  const x = Math.cos(lat1) * Math.sin(lat2) - Math.sin(lat1) * Math.cos(lat2) * Math.cos(dLon);
  return ((Math.atan2(y, x) * 180) / Math.PI + 360) % 360;
}

function bearingAlong(pts, cum, alongKm) {
  if (pts.length < 2) return 0;
  let seg = pts.length - 2;
  for (let i = 0; i < cum.length - 1; i++) {
    if (alongKm <= cum[i + 1]) { seg = i; break; }
  }
  return bearing(pts[seg], pts[seg + 1]);
}

// ── Road side (E60/E70 carriageway heuristic, ported verbatim) ───────────────
export function parseSideFromName(name) {
  const n = name.trim().toLowerCase();
  if (n.endsWith('მარჯვენა')) return 'right';
  if (n.endsWith('მარცხენა')) return 'left';
  if (n.endsWith('right')) return 'right';
  if (n.endsWith('left')) return 'left';
  return 'unknown';
}

function preferredSide(b) {
  const deg = ((b % 360) + 360) % 360;
  return deg > 180 && deg < 360 ? 'right' : 'left';
}

// ── Planner ──────────────────────────────────────────────────────────────────
/**
 * @param waypoints  [{lat,lng}, ...] origin first, destination last
 * @param currentBatteryPct  0–100
 * @param maxRangeKm         driver's full-charge range
 * @param stations           live station list (data.js shape)
 * @returns {Promise<{polyline, totalDistanceKm, batteryAtArrivalPct, stops,
 *                    effectiveRangeKm, reachable} | null>}
 */

/**
 * Plans the charging stops for an already-resolved route.
 *
 * @param {{pts: {lat:number,lng:number}[], totalDistKm: number,
 *          legEndsKm: number[], currentBatteryPct: number,
 *          maxRangeKm: number, stations: object[]}} input
 */
export function planFromRoute({
  pts,
  totalDistKm,
  legEndsKm,
  currentBatteryPct,
  maxRangeKm,
  stations,
}) {
  const effectiveKm = maxRangeKm * 0.9; // 90% usable
  const reserveKm = maxRangeKm * 0.1;   // 10% safety reserve

  // Cumulative along-route distance for every polyline point.
  const cum = new Array(pts.length).fill(0);
  for (let i = 1; i < pts.length; i++) cum[i] = cum[i - 1] + haversineKm(pts[i - 1], pts[i]);
  const routeKm = pts.length ? cum[cum.length - 1] : totalDistKm;

  // A busy charger (0 free plugs) is still SHOWN — it may free up by arrival.
  // Only a charger that is fully out of order is dropped: every published plug
  // reads "out". Providers with no per-plug data are assumed present (busy).
  const operational = (s) => {
    if (s.available > 0) return true;
    if (s.ports && s.ports.length) return s.ports.some((p) => p.status !== 'out');
    return true;
  };

  // Project every operational station onto the route.
  //
  // Done naively this is O(stations x segments), and on a real trip that is
  // enormous: Tbilisi → İstanbul is ~38,800 polyline points against ~14,100
  // stations once Turkey is loaded — 549 MILLION segment projections on the
  // main thread, which froze the page for ~20s on a laptop and far longer in a
  // car. So segments go into a coarse lat/lng grid first and each station is
  // only measured against the segments in its own neighbourhood.
  //
  // The result is identical for every station that matters: the planner only
  // ever uses chargers within `corridorKm` (8 km), and the neighbourhood
  // searched here is much wider than that. Anything with no segment nearby is
  // dropped outright — it is hundreds of kilometres off-route and was never a
  // candidate.
  const CELL_DEG = 0.15;              // ~16 km lat, ~12 km lng at these latitudes
  const NEIGHBOURHOOD = 2;            // +-2 cells => everything within ~25 km
  const cellKey = (la, ln) =>
    `${Math.floor(la / CELL_DEG)},${Math.floor(ln / CELL_DEG)}`;

  const segGrid = new Map();
  const addSeg = (la, ln, i) => {
    const k = cellKey(la, ln);
    const bucket = segGrid.get(k);
    if (bucket) bucket.push(i);
    else segGrid.set(k, [i]);
  };
  for (let i = 0; i < pts.length - 1; i++) {
    // Register the segment in both endpoints' cells; segments are far shorter
    // than a cell, so they cannot skip over one.
    addSeg(pts[i].lat, pts[i].lng, i);
    const k1 = cellKey(pts[i + 1].lat, pts[i + 1].lng);
    if (k1 !== cellKey(pts[i].lat, pts[i].lng)) {
      addSeg(pts[i + 1].lat, pts[i + 1].lng, i);
    }
  }

  const projected = [];
  const seen = new Set();
  for (const s of stations) {
    if (!operational(s)) continue;
    const cy = Math.floor(s.lat / CELL_DEG);
    const cx = Math.floor(s.lng / CELL_DEG);
    let bestDist = Infinity, bestAlong = 0, tested = 0;
    seen.clear();
    for (let dy = -NEIGHBOURHOOD; dy <= NEIGHBOURHOOD; dy++) {
      for (let dx = -NEIGHBOURHOOD; dx <= NEIGHBOURHOOD; dx++) {
        const bucket = segGrid.get(`${cy + dy},${cx + dx}`);
        if (!bucket) continue;
        for (const i of bucket) {
          if (seen.has(i)) continue;   // a segment can sit in two cells
          seen.add(i);
          tested++;
          const [d, t] = projectToSegment({ lat: s.lat, lng: s.lng }, pts[i], pts[i + 1]);
          if (d < bestDist) {
            bestDist = d;
            bestAlong = cum[i] + t * (cum[i + 1] - cum[i]);
          }
        }
      }
    }
    if (!tested) continue;             // nowhere near the route
    projected.push({ station: s, detourKm: bestDist, alongKm: bestAlong });
  }

  // Greedy corridor planning (identical constants to the mobile app).
  const onRouteKm = 2.5;   // "directly on the road the driver passes"
  const corridorKm = 8.0;  // still counts as "on the route" within this
  const stops = [];
  let coveredKm = 0;
  let currentKm = (currentBatteryPct / 100) * effectiveKm;
  let guard = 0;
  let reachable = true;

  while (coveredKm + currentKm - reserveKm < routeKm && guard++ < 25) {
    const reachKm = coveredKm + currentKm - reserveKm;

    // Only currently-free chargers can be RECOMMENDED (a busy one still shows in
    // the list, just isn't pre-picked).
    //
    // DC before AC, always, and only then by how close the charger is to the
    // road. This loop only runs when the destination is out of reach on the
    // current charge, so every stop it picks is a stop on a genuinely long
    // trip — and there, an 11 kW AC socket is not a real option: arriving at
    // 11% it would need 8-10 hours, against minutes at a DC unit. A DC a few
    // kilometres off the road beats an AC one right on it. AC is still picked
    // when no DC is reachable at all, and AC chargers stay in the options list
    // either way, so the driver can always choose one deliberately.
    const usable = (p) =>
      p.station.available > 0 && p.alongKm > coveredKm + 0.5 && p.alongKm <= reachKm;
    const tiers = (only) => {
      const pool = only ? projected.filter(only) : projected;
      let t = pool.filter((p) => usable(p) && p.detourKm <= onRouteKm);
      if (!t.length) t = pool.filter((p) => usable(p) && p.detourKm <= corridorKm);
      if (!t.length) t = pool.filter(usable);
      return t;
    };
    let cands = tiers((p) => p.station.isDC);
    if (!cands.length) cands = tiers(null);
    if (!cands.length) { reachable = false; break; } // can't reach a free charger

    // Reward progress, penalise detour.
    cands.sort((a, b) => (b.alongKm - 3 * b.detourKm) - (a.alongKm - 3 * a.detourKm));
    const pick = cands[0];

    // Road-side awareness: swap to the same-side twin within 200 m, else U-turn.
    const preferred = preferredSide(bearingAlong(pts, cum, pick.alongKm));
    let chosen = pick;
    let requiresUTurn = false;
    const pickSide = parseSideFromName(pick.station.name);
    if (pickSide !== 'unknown' && pickSide !== preferred) {
      let alt = null, altM = Infinity;
      for (const p of projected) {
        if (parseSideFromName(p.station.name) !== preferred) continue;
        const m = haversineKm(
          { lat: pick.station.lat, lng: pick.station.lng },
          { lat: p.station.lat, lng: p.station.lng },
        ) * 1000;
        if (m <= 200 && m < altM) { altM = m; alt = p; }
      }
      if (alt) chosen = alt;
      else requiresUTurn = true;
    }

    const arriveKm = currentKm - (chosen.alongKm - coveredKm);
    const batPct = Math.min(100, Math.max(0, (arriveKm / effectiveKm) * 100));
    let chargeHours = null;
    if (!chosen.station.isDC) {
      const capKwh = maxRangeKm / 6; // rough kWh estimate
      const neededKwh = capKwh * ((effectiveKm - arriveKm) / effectiveKm);
      chargeHours = neededKwh / (chosen.station.kw === 0 ? 1 : chosen.station.kw);
    }
    stops.push({
      station: chosen.station,
      batteryOnArrivalPct: batPct,
      distanceFromStartKm: chosen.alongKm,
      chargeHours,
      side: parseSideFromName(chosen.station.name),
      requiresUTurn,
    });
    coveredKm = chosen.alongKm;
    currentKm = effectiveKm; // assume full recharge
  }

  const remainAtDestKm = currentKm - (routeKm - coveredKm);

  // ── Selectable charger "option" blocks (~one per 50 km) ─────────────────────
  // 1. Corridor chargers, ordered along the road.
  const onRoute = projected
    .filter((p) => p.detourKm <= corridorKm)
    .sort((a, b) => a.alongKm - b.alongKm);

  // 2. Merge chargers that are the SAME provider at the SAME place (≤200 m) into
  //    one block — e.g. E-Space's several units at Argveta collapse into a single
  //    "E-Space · N stations · 50–360 kW" block. Different providers are NEVER
  //    merged, so Terjola's EV Power GE and E-Space stay separate, each keeping
  //    its own correct Google Maps pin.
  //    Scanning every cluster for every station is O(n^2) and cost ~170 ms on a
  //    Tbilisi → İstanbul route (2,300 chargers, 2,000 clusters), so candidates
  //    are looked up in a provider + ~220 m grid instead. Only clusters that
  //    could possibly be within 200 m are ever compared, which gives exactly
  //    the same grouping.
  const clusters = [];
  const CLUSTER_DEG = 0.002;         // ~220 m, just over the 200 m merge radius
  const clusterGrid = new Map();     // "provider|cy,cx" -> clusters anchored there
  for (const p of onRoute) {
    const st = p.station;
    const prov = (st.provider || '').trim().toLowerCase();
    const cy = Math.floor(st.lat / CLUSTER_DEG);
    const cx = Math.floor(st.lng / CLUSTER_DEG);
    let target = null;
    search:
    for (let dy = -1; dy <= 1; dy++) {
      for (let dx = -1; dx <= 1; dx++) {
        const list = clusterGrid.get(`${prov}|${cy + dy},${cx + dx}`);
        if (!list) continue;
        for (const c of list) {
          const anchor = c[0].station;
          const m = haversineKm(
            { lat: anchor.lat, lng: anchor.lng },
            { lat: st.lat, lng: st.lng },
          ) * 1000;
          if (m <= 200) { target = c; break search; }
        }
      }
    }
    if (target) {
      target.push(p);
    } else {
      const c = [p];
      clusters.push(c);
      const k = `${prov}|${cy},${cx}`;
      const bucket = clusterGrid.get(k);
      if (bucket) bucket.push(c);
      else clusterGrid.set(k, [c]);
    }
  }

  // 3. Mark clusters holding a greedy-recommended charger (always shown/ticked);
  //    a recommended charger outside the corridor gets its own appended cluster.
  const sameStation = (a, b) => a.name === b.name && a.lat === b.lat && a.lng === b.lng;
  const recommendedIdx = new Set();
  for (const stop of stops) {
    let found = -1;
    for (let i = 0; i < clusters.length; i++) {
      if (clusters[i].some((e) => sameStation(e.station, stop.station))) { found = i; break; }
    }
    if (found === -1) {
      const proj =
        projected.find((p) => sameStation(p.station, stop.station)) ||
        { station: stop.station, detourKm: 0, alongKm: stop.distanceFromStartKm };
      clusters.push([proj]);
      recommendedIdx.add(clusters.length - 1);
    } else {
      recommendedIdx.add(found);
    }
  }

  // 4. Build every corridor block, ordered along the route. Recommended blocks
  //    stay flagged (pre-ticked) so a charging plan is still ready.
  const allOptions = clusters
    .map((cl, i) => toOption(cl, recommendedIdx.has(i), pts, cum))
    .sort((a, b) => a.alongKm - b.alongKm);

  // 5. Prefer on-road chargers in the LIST too: within each 50 km window, if any
  //    charger sits right on the road, drop the detour ones there. A window whose
  //    road has no charger still shows its detour options; recommended kept.
  const displayWindowKm = 50.0;
  const windows = new Map();
  for (const o of allOptions) {
    const k = Math.floor(o.alongKm / displayWindowKm);
    (windows.get(k) || windows.set(k, []).get(k)).push(o);
  }
  const options = [];
  for (const group of windows.values()) {
    const hasOnRoad = group.some((o) => o.detourKm <= onRouteKm);
    for (const o of group) {
      if (!hasOnRoad || o.detourKm <= onRouteKm || o.recommended) options.push(o);
    }
  }
  options.sort((a, b) => a.alongKm - b.alongKm);

  return {
    polyline: pts,
    totalDistanceKm: totalDistKm,
    batteryAtArrivalPct: Math.min(100, Math.max(0, (remainAtDestKm / effectiveKm) * 100)),
    stops,
    options,
    legEndsKm,
    effectiveRangeKm: effectiveKm,
    reachable,
  };
}

// ── Option-block helpers (ported from RouteChargerOption) ─────────────────────
function providerPowers(stationsArr) {
  const names = new Map();      // key → display name
  const byProvider = new Map(); // key → kW[]
  for (const s of stationsArr) {
    const p = (s.provider || '').trim();
    if (!p) continue;
    const key = p.toLowerCase();
    if (!names.has(key)) names.set(key, p);
    if (!byProvider.has(key)) byProvider.set(key, []);
    if (s.kw > 0) byProvider.get(key).push(s.kw);
  }
  const out = [];
  for (const key of names.keys()) {
    const kws = byProvider.get(key);
    let power = '';
    if (kws.length) {
      const mn = Math.min(...kws), mx = Math.max(...kws);
      power = mn === mx ? `${kws[0]} kW` : `${mn}–${mx} kW`;
    }
    out.push({ name: names.get(key), power });
  }
  return out;
}

function connectorTypes(stationsArr) {
  const seen = new Set();
  const out = [];
  for (const s of stationsArr) {
    for (const c of s.connectors) {
      const tt = (c || '').trim();
      if (!tt || seen.has(tt.toLowerCase())) continue;
      seen.add(tt.toLowerCase());
      out.push(tt);
    }
  }
  return out;
}

function toOption(cl, recommended, pts, cum) {
  const along = cl.reduce((a, e) => a + e.alongKm, 0) / cl.length;
  const detour = Math.min(...cl.map((e) => e.detourKm));
  const preferred = preferredSide(bearingAlong(pts, cum, along));
  let hasGoodSide = false;
  for (const e of cl) {
    const sd = parseSideFromName(e.station.name);
    if (sd === 'unknown' || sd === preferred) { hasGoodSide = true; break; }
  }
  const requiresUTurn = !hasGoodSide;
  const blockSide = requiresUTurn ? (preferred === 'right' ? 'left' : 'right') : preferred;
  const sts = cl.map((e) => e.station);
  const first = cl[0].station;
  return {
    location: { lat: first.lat, lng: first.lng },
    locationKey: `${first.lat.toFixed(5)},${first.lng.toFixed(5)}`,
    alongKm: along,
    detourKm: detour,
    title: (first.city || '').trim() || first.name,
    providerPowers: providerPowers(sts),
    connectorTypes: connectorTypes(sts),
    stationCount: sts.length, // merged charger units at this place
    chargerCount: sts.reduce((n, s) => n + (s.total > 0 ? s.total : 1), 0),
    availableCount: sts.reduce((n, s) => n + s.available, 0),
    isDC: sts.some((s) => s.isDC),
    requiresUTurn,
    side: blockSide,
    recommended,
  };
}
