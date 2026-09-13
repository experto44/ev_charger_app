"""Put Tbilisi City Hall's free chargers into assets/data/chargers.json.

These are the only stations in the feed with no operator behind them. City Hall
has no API and no way to tell us whether a post is working right now, so the
rows are written once, carry `live: false`, and every screen that shows them has
to say the status is unknown rather than guess. Run this after editing
tools/cityhall_chargers.json (the official list, with coordinates resolved from
the parcel codes by tools/resolve_cadastral.py).

The updater workflow rebuilds the feed from the bundled asset every cycle and
only replaces the providers it actually fetched, so rows written here survive
untouched -- which is exactly what a static provider needs.

Usage:  python tools/build_cityhall.py
"""
import io
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "cityhall_chargers.json")
FEED = os.path.join(HERE, os.pardir, "assets", "data", "chargers.json")

# Must match kCityHallProvider in lib/app_constants.dart, PROVIDER_KA in
# tools/build-pages.mjs and the map in tesla/js/format.js.
PROVIDER = "Tbilisi City Hall"


def main():
    with io.open(SRC, encoding="utf-8") as f:
        src = json.load(f)
    with io.open(FEED, encoding="utf-8-sig") as f:
        feed = json.load(f)

    rows = []
    for c in src["chargers"]:
        # The parcel code is the only stable id City Hall gives us: the row
        # numbers in their spreadsheet shift every time they send a new one.
        sid = "meria_" + c["cadastral"].replace(".", "")
        rows.append({
            "id": sid,
            # Straight from a spreadsheet, so it carries stray double spaces
            # that HTML collapses and a Flutter Text widget does not.
            "name": " ".join(c["address"].split()),
            "lat": c["lat"],
            "lng": c["lng"],
            # No rating is published. An invented "22 kW" would be a claim about
            # how fast the car charges, so the type stands on its own.
            "power": "",
            "type": "AC",
            "price": "უფასო",
            # Nothing is live here, so this is not a claim that a plug is free.
            # `live: false` is what makes the app show a count instead.
            "available_spots": "0 available",
            "total_spots": 1,
            "city": "Tbilisi",
            "provider": PROVIDER,
            "connectors": [c["connector"]],
            "ports": [],
            "live": False,
            "cadastral": c["cadastral"],
        })

    kept = [s for s in feed if s.get("provider") != PROVIDER]
    out = kept + rows
    # Same shape the file already has (2-space indent, CRLF, no trailing
    # newline), so a rerun shows up as the rows that changed and not as 16k
    # reindented lines.
    with io.open(FEED, "w", encoding="utf-8", newline="\r\n") as f:
        json.dump(out, f, ensure_ascii=False, indent=2)
    print("chargers.json: %d rows (%d were already there, %d City Hall)"
          % (len(out), len(kept), len(rows)))


if __name__ == "__main__":
    main()
