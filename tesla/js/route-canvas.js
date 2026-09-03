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
    },

    /** @param {{lat:number,lng:number}[]} path */
    setRoute(path) {
      world = (path || []).map((p) => worldPoint(p.lat, p.lng));
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

      // Only what can be on screen is drawn — a Tbilisi to Batumi route is tens
      // of thousands of points — and "on screen" is measured from the CAMERA,
      // not from the car. It used to be measured from the car, so panning away
      // to look at the destination ran off the end of the drawn stretch and the
      // line simply stopped halfway.
      //
      // The test is a circle around the camera rather than the screen rectangle,
      // because the map may be turned to any angle; the radius is the screen's
      // own half-diagonal with a margin, in world units.
      const reach = (Math.hypot(w, h) / 2 + 200) / scale;
      const reach2 = reach * reach;

      ctx.beginPath();
      let pen = false;       // is the path currently at the previous point?
      let prevX = 0;
      let prevY = 0;
      let prevNear = false;
      for (let i = 0; i < world.length; i++) {
        const p = world[i];
        const wx = p.x - c.x;
        const wy = p.y - c.y;
        const near = wx * wx + wy * wy <= reach2;
        const dx = wx * scale;
        const dy = wy * scale;
        const x = halfW + dx * cos - dy * sin;
        const y = halfH + dx * sin + dy * cos;
        // A segment is drawn when either of its ends could be seen, so the line
        // still crosses the screen when both of its points are off the edges of
        // a long straight.
        if (i > 0 && (near || prevNear)) {
          if (!pen) ctx.moveTo(prevX, prevY);
          ctx.lineTo(x, y);
          pen = true;
        } else {
          pen = false;
        }
        prevX = x;
        prevY = y;
        prevNear = near;
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
