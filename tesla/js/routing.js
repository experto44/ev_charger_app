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
  for (const leg of route.legs) totalDistKm += leg.distance.value / 1000;

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
  return {
    polyline: pts,
    totalDistanceKm: totalDistKm,
    batteryAtArrivalPct: Math.min(100, Math.max(0, (remainAtDestKm / effectiveKm) * 100)),
    stops,
    effectiveRangeKm: effectiveKm,
    reachable,
  };
}
