// The route line, drawn by us, on our own canvas over the map.
//
// Google's Polyline is not part of the map's picture. On a vector map the
// ground is WebGL and the overlays are a separate layer that the API re-projects
// on its own schedule — slower than the ground moves — so with the camera being
// written every frame the line swam over the road. It did it north-up as well
// as heading-up, so it was never about rotation.
//
// A WebGLOverlayView, which would put the line inside the map's own frame, is
// worse: measured on 2026-09-03 its drawing is wiped by the base map whenever
// the map animates (clearing the whole framebuffer from onDraw changed nothing
// on a moving map, and the line appeared only when the map stood still).
//
// So the line is drawn here instead, in plain 2D canvas, from the SAME camera
// values that were just handed to the map, in the same animation frame. The two
// cannot disagree, because there is only one number for each of them.

const rad = (d) => (d * Math.PI) / 180;

/** Web Mercator: lat/lng to world pixels at zoom 0 (256 px world). */
function worldPoint(lat, lng) {
  const s = Math.min(Math.max(Math.sin(rad(lat)), -0.9999), 0.9999);
  return {
    x: 256 * (0.5 + lng / 360),
    y: 256 * (0.5 - Math.log((1 + s) / (1 - s)) / (4 * Math.PI)),
  };
}

export function createRouteCanvas(opts = {}) {
  const color = opts.color || '#2bd594';
  const casing = opts.casing || '#0a3b2b';
  const widthPx = opts.widthPx || 7;
  const casingPx = opts.casingPx || 12;

  const canvas = document.createElement('canvas');
  canvas.className = 'route-canvas';
  const ctx = canvas.getContext('2d');

  let host = null;
  let world = [];      // the route in world pixels, computed once per route
  let cum = [];        // metres along the route, one per point
  let along = 0;       // how far along the car is, for deciding what to draw
  let dpr = 1;
  let w = 0;
  let h = 0;
  // The car rides on this canvas too. It has to: the canvas covers the map, so
  // a marker left to Google would be under the route line — and drawn here it
  // is placed by the same numbers in the same frame as the road it is on.
  let car = null;      // { lat, lng, heading }
  let carImg = null;   // an Image of the car, pointing straight up
  let carSize = 48;

  function resize() {
    if (!host) return;
    const r = host.getBoundingClientRect();
    dpr = Math.min(2, window.devicePixelRatio || 1);
    w = Math.round(r.width);
    h = Math.round(r.height);
    canvas.width = Math.round(w * dpr);
    canvas.height = Math.round(h * dpr);
    canvas.style.width = `${w}px`;
    canvas.style.height = `${h}px`;
  }

  const api = {
    attach(container) {
      if (host === container) return;
      host = container;
      if (canvas.parentElement !== container) container.appendChild(canvas);
      resize();
      addEventListener('resize', resize);
    },

    detach() {
      removeEventListener('resize', resize);
      canvas.remove();
      host = null;
      world = [];
      cum = [];
    },

    /**
     * @param {{lat:number,lng:number}[]} path
     * @param {number[]} cumM  distance along the route at each point
     */
    setRoute(path, cumM) {
      world = (path || []).map((p) => worldPoint(p.lat, p.lng));
      cum = cumM || [];
    },

    /** Where the car is along the route; only the road near it is drawn. */
    setAlong(m) {
      along = m;
    },

    /** The car silhouette, drawn pointing north; rotated here as it drives. */
    setCarImage(svg, size = 48) {
      carSize = size;
      const img = new Image();
      img.onload = () => { carImg = img; };
      img.src = 'data:image/svg+xml;charset=UTF-8,' + encodeURIComponent(svg);
    },

    setCar(next) {
      car = next;
    },

    /**
     * Draw the route for this camera. Called from the same frame that moved the
     * map, which is the whole point of this file.
     *
     * @param {{center:{lat,lng}, zoom:number, heading:number}} cam
     */
    draw(cam) {
      if (!host || !ctx) return;
      if (canvas.width !== Math.round(w * dpr) || w === 0) resize();
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      ctx.clearRect(0, 0, w, h);
      if (world.length < 2 || !cam) return;

      const scale = Math.pow(2, cam.zoom);
      const c = worldPoint(cam.center.lat, cam.center.lng);
      const th = rad(-(cam.heading || 0));
      const cos = Math.cos(th);
      const sin = Math.sin(th);
      const halfW = w / 2;
      const halfH = h / 2;

      // Only the stretch of road that can be on screen. A Tbilisi to Batumi
      // route is tens of thousands of points and projecting all of them every
      // frame would cost more than it shows: the visible half-diagonal, plus a
      // margin, is all that can matter.
      const mPerPx = (156543.03392 * Math.cos(rad(cam.center.lat))) / scale;
      const reach = (Math.hypot(w, h) / 2) * mPerPx + 400;
      let from = 0;
      let to = world.length - 1;
      if (cum.length === world.length) {
        while (from < to && cum[from] < along - reach) from++;
        while (to > from && cum[to] > along + reach) to--;
        from = Math.max(0, from - 1);
        to = Math.min(world.length - 1, to + 1);
      }
      if (to - from < 1) return;

      ctx.beginPath();
      for (let i = from; i <= to; i++) {
        const p = world[i];
        const dx = (p.x - c.x) * scale;
        const dy = (p.y - c.y) * scale;
        const x = halfW + dx * cos - dy * sin;
        const y = halfH + dx * sin + dy * cos;
        if (i === from) ctx.moveTo(x, y);
        else ctx.lineTo(x, y);
      }
      ctx.lineJoin = 'round';
      ctx.lineCap = 'round';
      ctx.strokeStyle = casing;
      ctx.lineWidth = casingPx;
      ctx.stroke();
      ctx.strokeStyle = color;
      ctx.lineWidth = widthPx;
      ctx.stroke();

      if (car && carImg) {
        const p = worldPoint(car.lat, car.lng);
        const dx = (p.x - c.x) * scale;
        const dy = (p.y - c.y) * scale;
        const x = halfW + dx * cos - dy * sin;
        const y = halfH + dx * sin + dy * cos;
        ctx.save();
        ctx.translate(x, y);
        ctx.rotate(rad((car.heading || 0) - (cam.heading || 0)));
        ctx.drawImage(carImg, -carSize / 2, -carSize / 2, carSize, carSize);
        ctx.restore();
      }
    },
  };
  return api;
}
