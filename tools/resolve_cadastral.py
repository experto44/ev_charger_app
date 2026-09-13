"""Georgian cadastral code -> WGS84 point, using NAPR's own public GeoServer.

Why this file exists: Tbilisi City Hall hands out its charger list with parcel
codes instead of coordinates, so the codes have to be turned into pins once,
by hand, before the rows go into assets/data/chargers.json. Keeping the
resolver in the repo means the next batch can be placed the same way instead of
being eyeballed on a map.

The obvious source, maps.napr.gov.ge, is behind a WAF that answers every
scripted request with an "Access Denied" page (a real browser gets an error
page too), so this goes to the GeoServer that the government's own municipal
map reads, nv.napr.gov.ge, which is open. That server allows only GetMap and
GetCapabilities: WFS and GetFeatureInfo are 403 and POST is 405. So a parcel
cannot be asked for as data -- it has to be DRAWN and then measured:

  * CQL_FILTER is honoured, so CADCODE='...' renders that parcel alone;
  * the layer's own style stops drawing above 1:13056, so an inline SLD_BODY
    (which has no scale rule) is what lets one request cover the whole city;
  * render, find the painted pixels, re-render tight around them, repeat.

Four passes take the box from city-wide to a few metres, in about a second.
The answer is the parcel's centre, not the charging post itself -- for an
address that says "მიმდებარედ" it is the neighbouring parcel -- so pins still
want a look on a satellite view before they ship.

Usage:  python tools/resolve_cadastral.py 01.14.05.007.721 [more codes...]
"""
import json
import sys
import urllib.parse
import urllib.request

BASE = "https://nv.napr.gov.ge/geoserver/wms"
LAYER = "cite:LR_PARCELS"
CODE_FIELD = "CADCODE"

# Tbilisi, generously boxed. Widen for a code outside the capital.
TBILISI = (44.60, 41.58, 45.05, 41.90)

# A style with no scale rule, so the parcels layer also draws when zoomed out.
SLD = (
    '<?xml version="1.0" encoding="UTF-8"?>'
    '<StyledLayerDescriptor version="1.0.0"'
    ' xmlns="http://www.opengis.net/sld" xmlns:ogc="http://www.opengis.net/ogc">'
    "<NamedLayer><Name>" + LAYER + "</Name><UserStyle><FeatureTypeStyle><Rule>"
    '<PolygonSymbolizer><Fill>'
    '<CssParameter name="fill">#FF0000</CssParameter>'
    "</Fill></PolygonSymbolizer>"
    "</Rule></FeatureTypeStyle></UserStyle></NamedLayer>"
    "</StyledLayerDescriptor>"
)

_UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
       "(KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36")


def _render(box, code, size):
    """PNG bytes of just this parcel, drawn over `box` (lon0, lat0, lon1, lat1)."""
    q = urllib.parse.urlencode({
        "service": "WMS", "version": "1.1.1", "request": "GetMap",
        "layers": LAYER, "styles": "", "srs": "EPSG:4326",
        "bbox": ",".join("%.8f" % b for b in box),
        "width": size, "height": size, "format": "image/png",
        "transparent": "true", "exceptions": "application/vnd.ogc.se_xml",
        "cql_filter": "%s='%s'" % (CODE_FIELD, code),
        "SLD_BODY": SLD,
    })
    req = urllib.request.Request(BASE + "?" + q, headers={"User-Agent": _UA})
    with urllib.request.urlopen(req, timeout=120) as r:
        ctype = r.headers.get("Content-Type", "")
        body = r.read()
    if "image" not in ctype:
        raise RuntimeError(body[:300].decode("utf-8", "replace"))
    return body


def _painted_box(png, box):
    """Geographic box of the drawn pixels, or None when nothing was drawn."""
    from PIL import Image
    import io

    im = Image.open(io.BytesIO(png)).convert("RGBA")
    w, h = im.size
    px = im.load()
    xs, ys = [], []
    for y in range(h):
        for x in range(w):
            if px[x, y][3] > 0:
                xs.append(x)
                ys.append(y)
    if not xs:
        return None
    lon0, lat0, lon1, lat1 = box
    dx = (lon1 - lon0) / w
    dy = (lat1 - lat0) / h
    return (lon0 + min(xs) * dx, lat1 - (max(ys) + 1) * dy,
            lon0 + (max(xs) + 1) * dx, lat1 - min(ys) * dy)


def resolve(code, start=TBILISI, rounds=4, size=800):
    """(lat, lng) of the parcel's centre, or None when the code draws nothing."""
    box = start
    for i in range(rounds):
        got = _painted_box(_render(box, code, size), box)
        if got is None:
            # Nothing at all on the first pass means the code is not in `start`.
            return None if i == 0 else _centre(box)
        lon0, lat0, lon1, lat1 = got
        if (lon1 - lon0) < 2e-5 and (lat1 - lat0) < 2e-5:
            return _centre(got)
        pad_x = max((lon1 - lon0) * 0.2, 1e-6)
        pad_y = max((lat1 - lat0) * 0.2, 1e-6)
        box = (lon0 - pad_x, lat0 - pad_y, lon1 + pad_x, lat1 + pad_y)
    return _centre(box)


def _centre(box):
    return ((box[1] + box[3]) / 2.0, (box[0] + box[2]) / 2.0)


if __name__ == "__main__":
    codes = sys.argv[1:]
    if not codes:
        print(__doc__)
        raise SystemExit(2)
    for c in codes:
        pt = resolve(c)
        print(json.dumps({"cadastral": c,
                          "lat": None if not pt else round(pt[0], 6),
                          "lng": None if not pt else round(pt[1], 6)},
                         ensure_ascii=False))
