# Google Maps share links — what a shared route actually contains

Reverse-engineered 2026-08-28 from three links shared out of the Google Maps
Android app, for the "send a route from the phone to the car" feature
(`tesla.geocharge.ge`). Nothing here is documented by Google; the `data=`
parameter is an undocumented protobuf and can change without notice. Treat this
file as a record of what was observed, not as a contract.

## The short link

`https://maps.app.goo.gl/<id>` answers a plain `302` with the full URL in
`Location`. One hop, no page download, no JavaScript:

```bash
curl -sI "https://maps.app.goo.gl/vNumakc9EVDb1RZy5" | grep -i location
```

In Node, `fetch(url, { redirect: 'manual' })` and read the `location` header.
**Untested from a Cloud Functions IP** — verify before relying on it in
production, and fail loudly rather than silently if the header is missing.

## The expanded URL

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

The prototype that produced the table above lives in `functions/` once the
import endpoint is built. It belongs server-side, not in the app: when Google
changes this format the fix must not wait on an App Store review.
