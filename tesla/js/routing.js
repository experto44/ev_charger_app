// EV route planning — a 1:1 JS port of lib/routing_service.dart (planRoute).
// Only the transport differs: the mobile app calls the Directions REST API,
// here we use google.maps.DirectionsService (the REST endpoint has no CORS).
// The interactive "options blocks" list of the mobile planner is not ported;
// this client shows the greedy recommended plan only.

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
export async function planRoute({ waypoints, currentBatteryPct, maxRangeKm, stations }) {
  if (waypoints.length < 2) return null;

  const effectiveKm = maxRangeKm * 0.9; // 90% usable
  const reserveKm = maxRangeKm * 0.1;   // 10% safety reserve

  const svc = new google.maps.DirectionsService();
  let route;
  try {
    const res = await svc.route({
      origin: waypoints[0],
      destination: waypoints[waypoints.length - 1],
      waypoints: waypoints.slice(1, -1).map((w) => ({ location: w, stopover: true })),
      travelMode: google.maps.TravelMode.DRIVING,
    });
    route = res.routes[0];
  } catch (e) {
    return null;
  }
  if (!route) return null;

  const pts = route.overview_path.map((p) => ({ lat: p.lat(), lng: p.lng() }));
  let totalDistKm = 0;
  const legEndsKm = []; // cumulative km at each waypoint boundary
  for (const leg of route.legs) {
    totalDistKm += leg.distance.value / 1000;
    legEndsKm.push(totalDistKm);
  }

  // Cumulative along-route distance for every polyline point.
  const cum = new Array(pts.length).fill(0);
  for (let i = 1; i < pts.length; i++) cum[i] = cum[i - 1] + haversineKm(pts[i - 1], pts[i]);
  const routeKm = pts.length ? cum[cum.length - 1] : totalDistKm;

  // Project every available station onto the route.
  const projected = [];
  for (const s of stations) {
    if (s.available === 0) continue;
    let bestDist = Infinity, bestAlong = 0;
    for (let i = 0; i < pts.length - 1; i++) {
      const [d, t] = projectToSegment({ lat: s.lat, lng: s.lng }, pts[i], pts[i + 1]);
      if (d < bestDist) {
        bestDist = d;
        bestAlong = cum[i] + t * (cum[i + 1] - cum[i]);
      }
    }
    projected.push({ station: s, detourKm: bestDist, alongKm: bestAlong });
  }

  // Greedy corridor planning (identical constants to the mobile app).
  const corridorKm = 8.0;
  const stops = [];
  let coveredKm = 0;
  let currentKm = (currentBatteryPct / 100) * effectiveKm;
  let guard = 0;
  let reachable = true;

  while (coveredKm + currentKm - reserveKm < routeKm && guard++ < 25) {
    const reachKm = coveredKm + currentKm - reserveKm;

    let cands = projected.filter(
      (p) => p.alongKm > coveredKm + 0.5 && p.alongKm <= reachKm && p.detourKm <= corridorKm,
    );
    if (!cands.length) {
      cands = projected.filter((p) => p.alongKm > coveredKm + 0.5 && p.alongKm <= reachKm);
      if (!cands.length) { reachable = false; break; } // can't reach any charger
    }

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

  // 2. Merge co-located chargers (≤200 m) into single blocks.
  const clusters = [];
  for (const p of onRoute) {
    if (clusters.length) {
      const anchor = clusters[clusters.length - 1][0].station;
      const m =
        haversineKm({ lat: anchor.lat, lng: anchor.lng }, { lat: p.station.lat, lng: p.station.lng }) * 1000;
      if (m <= 200) {
        clusters[clusters.length - 1].push(p);
        continue;
      }
    }
    clusters.push([p]);
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

  // 4. Sample ~one cluster per 50 km, always moving forward.
  const sampleStepKm = 50.0;
  const pickedIdx = new Set();
  let lastAlong = -1;
  for (let cp = sampleStepKm; cp < routeKm + sampleStepKm; cp += sampleStepKm) {
    let best = -1, bestDelta = Infinity;
    for (let i = 0; i < clusters.length; i++) {
      if (pickedIdx.has(i)) continue;
      const a = clusters[i][0].alongKm;
      if (a <= lastAlong) continue;
      const d = Math.abs(a - cp);
      if (d < bestDelta) { bestDelta = d; best = i; }
    }
    if (best === -1) continue;
    pickedIdx.add(best);
    lastAlong = clusters[best][0].alongKm;
  }
  for (const i of recommendedIdx) pickedIdx.add(i);

  const options = [...pickedIdx]
    .map((i) => toOption(clusters[i], recommendedIdx.has(i), pts, cum))
    .sort((a, b) => a.alongKm - b.alongKm);

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
    chargerCount: sts.reduce((n, s) => n + (s.total > 0 ? s.total : 1), 0),
    availableCount: sts.reduce((n, s) => n + s.available, 0),
    isDC: sts.some((s) => s.isDC),
    requiresUTurn,
    side: blockSide,
    recommended,
  };
}
