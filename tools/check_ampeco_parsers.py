#!/usr/bin/env python3
"""Prove the app and the updater still read AMPECO the same way.

The live status of a mart EV / MOVEO / Electrify / EV Power charger is parsed
TWICE from the same API shape: once in Python, inside `fetch_ampeco` in
.github/workflows/update_gist.yml, for the feed everyone sees on the map; and
once in Dart, inside LiveStatusService, for the direct read behind the detail
sheet's refresh button.

That duplication is deliberate (the app cannot run the pipeline, the pipeline
cannot run Dart) but it is also the one place these two codebases can silently
drift apart. Drift does not look like a crash. It looks like the map saying a
charger is free while the sheet for that same charger says it is taken, which is
worse for a driver than either answer being slightly stale.

So both are fed the identical fixture and must agree:

    python tools/check_ampeco_parsers.py     # the Python half, here
    flutter test test/live_status_test.dart  # the Dart half

Run this after touching either parser, especially the "status=unavailable means
the sibling plug is busy, not broken" rule, which is the subtle one.

Requires PyYAML. No network access and no secrets: the HTTP layer is stubbed.
"""
import io
import json
import os
import re
import sys

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WF = os.path.join(ROOT, ".github", "workflows", "update_gist.yml")
FIXTURE = os.path.join(ROOT, "test", "fixtures", "ampeco_location.json")

# What test/live_status_test.dart asserts for this fixture. Keep the two in step.
EXPECTED_TOTAL = 3
EXPECTED_AVAIL = 1
EXPECTED_PORTS = [("CCS2", "busy"), ("GB/T", "free"), ("Type 2", "out")]
EXPECTED_SINCE = "2026-08-19T18:57"


def load_fetchers():
    """Pull fetch_ampeco out of the workflow and into this process."""
    doc = yaml.safe_load(io.open(WF, encoding="utf-8").read())
    steps = doc["jobs"]["update-gist"]["steps"]
    script = [s for s in steps if "Gist" in (s.get("name") or "")][-1]["run"]
    m = re.search(r"if python3 << 'PYEOF'\n(.*?)\nPYEOF\n", script, re.S)
    if not m:
        sys.exit("could not find the embedded Python in the workflow")
    py = m.group(1)
    # Everything from the merge onwards needs GIST_TOKEN and Firebase creds.
    py = py[: py.index("# ── Load station data from the committed asset file")]
    py = py.replace('token   = os.environ["GIST_TOKEN"]', 'token = "parser-check"')
    ns = {}
    exec(compile(py, "<workflow fetchers>", "exec"), ns)
    return ns


class _Resp:
    def __init__(self, payload):
        self._payload = payload

    def raise_for_status(self):
        pass

    def json(self):
        return self._payload


class _StubRequests:
    """Serves the fixture instead of the operator, so this runs offline."""

    def __init__(self, fixture):
        self.fixture = fixture

    def get(self, url, **_kw):
        if url.endswith("/app/pins"):
            return _Resp({"pins": [{"id": 220}]})
        if url.endswith("/app/locations/220"):
            return _Resp(self.fixture)
        raise AssertionError(f"unexpected request: {url}")


def main():
    fixture = json.load(io.open(FIXTURE, encoding="utf-8"))
    ns = load_fetchers()
    ns["requests"] = _StubRequests(fixture)

    rows = ns["fetch_ampeco"]("cp.example.test", "mart EV", "martev")
    by_id = {r["id"]: r for r in rows}
    if "martev_220" not in by_id:
        sys.exit(f"pipeline produced no row for martev_220 (got {list(by_id)})")
    row = by_id["martev_220"]

    print("pipeline reading for martev_220:")
    print("  available_spots:", row["available_spots"])
    print("  total_spots    :", row["total_spots"])
    print("  ports          :", json.dumps(row["ports"], ensure_ascii=False))

    fails = []
    if row["total_spots"] != EXPECTED_TOTAL:
        fails.append(f"total_spots {row['total_spots']} != {EXPECTED_TOTAL}")
    if row["available_spots"] != f"{EXPECTED_AVAIL} available":
        fails.append(
            f"available_spots {row['available_spots']!r} "
            f"!= '{EXPECTED_AVAIL} available'")
    ports = [(p["type"], p["status"]) for p in row["ports"]]
    if ports != EXPECTED_PORTS:
        fails.append(f"ports {ports} != {EXPECTED_PORTS}")
    busy = [p for p in row["ports"] if p["status"] == "busy"]
    if not busy or not str(busy[0].get("since", "")).startswith(EXPECTED_SINCE):
        fails.append(f"session start missing or wrong: {busy}")

    # A linked location in the same response is its own station, never folded in.
    other = by_id.get("martev_999")
    if not other:
        fails.append("linked location 999 produced no row of its own")
    elif other["total_spots"] != 1 or other["available_spots"] != "1 available":
        fails.append(
            f"linked location wrong: {other['available_spots']} "
            f"of {other['total_spots']}")

    if fails:
        print("\nPIPELINE AND APP DISAGREE:")
        for f in fails:
            print("  -", f)
        print("\nFix whichever side is wrong, then re-run both halves.")
        return 1

    print("\npipeline agrees with test/live_status_test.dart on every field")
    return 0


if __name__ == "__main__":
    sys.exit(main())
