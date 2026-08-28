# Google Maps share links — what a shared route actually contains

Reverse-engineered 2026-08-28 from three links shared out of the Google Maps
Android app, and 2026-08-29 from three more shared out of the iOS app, for the
"send a route from the phone to the car" feature (`tesla.geocharge.ge`). Nothing
here is documented by Google; the `data=` parameter is an undocumented protobuf
and can change without notice. Treat this file as a record of what was observed,
not as a contract.

**The two apps share different URLs.** Same short-link host, same trip, two
formats that have nothing in common:

| shared from | expands to |
| --- | --- |
| Android | `https://www.google.com/maps/dir/<stops>/data=<blob>` |
| iOS | `https://maps.google.com/?saddr=…&daddr=…&geocode=…&dirflg=d` |

Both are described below. The parser picks by the shape of the URL, not by any
claim about which phone sent it.

## The short link

`https://maps.app.goo.gl/<id>` answers a plain `302` with the full URL in
`Location`. One hop, no page download, no JavaScript:

```bash
curl -sI "https://maps.app.goo.gl/vNumakc9EVDb1RZy5" | grep -i location
```

In Node, `fetch(url, { redirect: 'manual' })` and read the `location` header.
**Untested from a Cloud Functions IP** — verify before relying on it in
production, and fail loudly rather than silently if the header is missing.

The `Location` a short link answers with is the same whatever user agent asks,
and dropping the `?g_st=` parameter changes nothing: an iOS link stays an iOS
link. Following further hops does not help either — `maps.google.com` bounces to
`www.google.com` carrying the same old query, and never reaches `/maps/dir/`.

## The expanded URL, Android

```
https://www.google.com/maps/dir/41.6721448,44.8673392/არგვეთა/სარფის+სასაზღვრო-გამშვები+პუნქტი
  /data=!4m16!4m15!1m1!4e1
        !1m5!1m4!1s0x405cbffb2163c16f:0xb5bd08f6f42ad6c!8m2!3d42.1329735!4d42.9844081
        !1m5!1m4!1s0x4067913d6549efcb:0xee656409b40b2536!8m2!3d41.5209672!4d41.5484345
        !3e0
```

Two independent sources of the same route, and both are needed:

**The path** — `/maps/dir/` followed by origin, then any stops, then the
destination, in road order. Each segment is either `lat,lng` or a place name.
Spaces are written as `+`, which `decodeURIComponent` does NOT convert (in a
path a plus is a literal plus), so replace them by hand.

**The `data=` blob** — one block per *named* stop, in the same order, carrying
the exact coordinates:

| token | meaning |
| --- | --- |
| `!1s0x…:0x…` | the place's feature id (ftid) |
| `!8m2!3d<lat>!4d<lng>` | **`3d` is latitude, `4d` is longitude** |
| `!3e0` | travel mode: 0 driving, 1 bicycling, 2 walking, 3 transit |
| `!2m1!2b1` | route options group: **`2b1` = avoid tolls** |
| `!1m1!4e1` | present in all three samples; origin is "my location" |

Anchor the coordinate regex on `!8m2!3d…!4d…` rather than on the surrounding
`!1m5!1m4`, so a change in Google's field counts does not break the parse.

### Matching names to coordinates

Walk the path segments in order. A `lat,lng` segment is its own answer and
consumes nothing. A named segment takes the next unconsumed `data` block. That
reproduces all three samples exactly, including the one with a mid-route stop.

A named segment with no block left (a link with no `data`, or a format change)
has to be geocoded from the name — handle it, do not assume it never happens.

### Route options

`2b1 = avoid tolls` is **confirmed twice**: it appears only in the link the user
made with tolls switched off, and forcing `!2m1!2b1` onto a Tbilisi → Istanbul
URL on maps.google.com changed the route from 20 h 3 min to 21 h 30 min.

`3b1` and `4b1` are the conventional guess for avoid-highways and avoid-ferries
and are **not confirmed** — forcing either onto the same URL produced the
unchanged default route plus alternatives, i.e. Google appeared to ignore them
in that URL form. Since Georgia has no toll roads, tolls is the flag that
matters (Turkey), and it is the one that is proven. Expose highways/ferries as
our own toggles rather than pretending to have read them.

## The expanded URL, iOS

```
https://maps.google.com/?geocode=FdPfewIdYaGsAg%3D%3D;FW0KgwIdMtiPAimPJAXyqb9cQDEiCBX1sCZ8_Q%3D%3D;FUePeQIdk_p5AinL70llPZFnQDE2JQu0CWRl7g%3D%3D
  &daddr=Argveta+to:SARPI+%7C+Georgian-Turkish+border,+E70,+Sarpi
  &saddr=41.6726588,44.8679366
  &dirflg=d
  &ftid=0x4067913d6549efcb:0xee656409b40b2536
```

This is the pre-2013 Maps URL, which the iOS app still emits. The path is a
bare `/` and the whole trip lives in the query, so a host check that insists on
a `/maps` path rejects every route shared off an iPhone. That was the bug fixed
on 2026-08-29.

| parameter | meaning |
| --- | --- |
| `saddr` | origin, written as `lat,lng` |
| `daddr` | the destinations, separated by ` to:` (written `+to:` in the raw URL) |
| `geocode` | `;`-separated, one entry per stop **including the origin** |
| `dirflg` | travel mode then avoidances |
| `ftid`, `lucs`, `g_ep`, `skid`, `g_st` | ignored |

Spaces are `+` here, and unlike the path segments of the modern form that is a
real space: a query string decoder converts it. `URLSearchParams` handles it.

### The `geocode` blob

base64url over a tiny protobuf, one per stop, in the same order as the
addresses:

| field | wire type | meaning |
| --- | --- | --- |
| 2 | fixed32 | latitude × 1e6 |
| 3 | fixed32 | longitude × 1e6 |
| 5 | fixed64 | the place's ftid, first half |
| 6 | fixed64 | second half |

Because the origin gets an entry too — even when `saddr` already spells out its
coordinates — the list lines up with the stops by index.

**Cross-check.** Tbilisi → Sarpi shared from both phones names the same
destination: `41.5209672, 41.5484345` out of the Android `data=` blob and
`41.520967, 41.548435` out of the iOS `geocode` blob.

### `dirflg`

Mode first: `d` drive, `w` walk, `b` bicycle, `r` transit. Letters after it are
avoidances. **`t` = avoid tolls is confirmed**: a Tbilisi → Istanbul route
shared with tolls switched off came through as `dirflg=dt`. `h` for highways
and `f` for ferries are the conventional letters and are **not confirmed** —
the same position the modern form's `3b1`/`4b1` are in.

### Names

`daddr` carries a full postal string where the modern form carries a short
label: `SARPI | Georgian-Turkish border, E70, Sarpi`. The car shows this on a
card read at a glance, so the parser keeps the head up to the first `|` or `,`,
unless that would leave fewer than three characters (a house number), giving
`SARPI`.

### Worked examples, iOS

| link | origin | stops | destination | flags |
| --- | --- | --- | --- | --- |
| Tbilisi → Sarpi | 41.6719, 44.8671 | — | სარფის სასაზღვრო-გამშვები პუნქტი (41.5210, 41.5484) | `d` |
| + one stop | 41.6727, 44.8679 | Argveta (42.1423, 42.9814) | SARPI (41.5210, 41.5484) | `d` |
| Tbilisi → Istanbul, no tolls | 41.6719, 44.8671 | — | Istanbul (41.0082, 28.9784) | `dt` |

The Argveta coordinates differ from the Android sample's by about a kilometre
because the two links were made by tapping the village in two places, not
because the two blobs disagree.

## What is NOT in the link

The computed route. Google shares the *stops*, never the polyline, so the road
between them has to be worked out again with the Directions API. For a normal
A→B with stops that reproduces the same roads; it is not a guarantee, and it
should not be described to users as "the exact route from your phone".

This is also the right outcome for us: `tesla/js/routes.js` already stores a
route as destination + stops and recomputes from live GPS on every start, so an
imported Google route drops into the existing model with no new shape. Storing
Directions output long-term would in any case be against Google's terms.

## Worked examples

| link | origin | stops | destination | flags |
| --- | --- | --- | --- | --- |
| Tbilisi → Sarpi | 41.6722, 44.8673 | — | სარფის სასაზღვრო-გამშვები პუნქტი (41.5210, 41.5484) | `3e0` |
| + one stop | 41.6721, 44.8673 | არგვეთა (42.1330, 42.9844) | same as above | `3e0` |
| Tbilisi → Istanbul, no tolls | 41.6719, 44.8673 | — | სტამბოლი (41.0082, 28.9784) | `3e0`, `2m1!2b1` |

The origin is always the phone's position at planning time. Drive mode starts
from the live GPS fix regardless, so the imported origin is informational only.

## Parser

`functions/google-route-parse.js` reads all three shapes: the Android
`/maps/dir/` path form, the iOS query form, and the documented `?api=1` form.
`functions/google-route.js` is the callable around it — allow-list, short-link
expansion, rate limit.

It belongs server-side, not in the app: when Google changes this format the fix
must not wait on an App Store review.

Every sample in this file is a fixture in `functions/google-route-parse.test.js`,
so a change made for one phone cannot quietly break the other:

```bash
cd functions && node --test
```

## A place, not a route

Google's share button produces the same `maps.app.goo.gl/…` short link for a
place as for a route, so which one it is can only be told from what the link
expands to. `parseTarget()` tries every route shape first and falls back to
`parsePlace()`, which reads a point out of, in order:

| Source | Example |
| --- | --- |
| the data blob | `/maps/place/Name/data=…!8m2!3d41.7092!4d44.7862` |
| a dropped pin | `/maps/place/41.71350,44.79700/…` |
| the query | `?q=41.71,44.79`, `?query=…`, `?ll=…`, `?center=…` |
| the camera | `/@41.7135,44.797,15z` — the map centre, so it is the last resort |

A link that names a place only by id (`/maps/place//data=!4m2!3m1!1s0x40440…`)
carries no coordinates at all. Rather than refuse the driver's hotel,
`google-route.js` then fetches that same public page once and takes the position
out of Google's own `og:image` static map (falling back to the `!3d…!4d…` block
and the camera position). No API key and no Geocoding call is involved.

The answer has the same shape as a route — a destination and no waypoints — so
the app needs no change to send one: it writes the same `users/{uid}/tesla/inbox`
document, and the car offers a place card with "navigate", "route here"
(the trip planner, chargers and all) and "save".
