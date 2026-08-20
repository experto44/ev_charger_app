#!/usr/bin/env python3
"""Prove every client still reads AMPECO the same way.

The live status of a mart EV / MOVEO / Electrify / EV Power charger is parsed
THREE times from the same API shape:

  * Python, in `fetch_ampeco` in .github/workflows/update_gist.yml, for the feed
    everyone sees on the map;
  * Dart, in LiveStatusService, for the direct read behind the mobile app's
    refresh button;
  * JavaScript, in tesla/js/live.js, for the same button in the Tesla web app.

The duplication is unavoidable (none of the three can run the others' code) but
it is also the one place these codebases can silently drift apart. Drift does not
look like a crash. It looks like the map saying a charger is free while the panel
for that same charger says it is taken, which is worse for a driver than either
answer being slightly stale.

All three are fed the identical fixture and must agree. This script checks the
Python and JavaScript halves; the Dart half is `flutter test`:

    python tools/check_ampeco_parsers.py
    flutter test test/live_status_test.dart

Run this after touching any of the parsers, especially the "status=unavailable
means the sibling plug is busy, not broken" rule, which is the subtle one.

Requires PyYAML, and node on PATH for the JavaScript half (skipped if absent).
No network access and no secrets: the HTTP layer is stubbed.
"""
import io
import json
import os
import re
import shutil
import subprocess
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

    fails += check_js()

    if fails:
        print("\nPARSERS DISAGREE:")
        for f in fails:
            print("  -", f)
        print("\nFix whichever side is wrong, then re-run all three.")
        return 1

    print("\npipeline and tesla/js/live.js agree with "
          "test/live_status_test.dart on every field")
    return 0


def check_js():
    """Run tesla/js/live.js over the same fixture, via node."""
    if not shutil.which("node"):
        print("\nnode not on PATH — skipping the JavaScript half")
        return []
    script = """
import { readFileSync } from 'node:fs';
import { applyAmpeco } from './tesla/js/live.js';
const fx = JSON.parse(readFileSync(process.argv[1], 'utf8'));
const base = { id: 'martev_220', provider: 'mart EV', available: 0, total: 0, ports: [] };
const r = applyAmpeco(base, fx, '220');
const other = applyAmpeco(base, fx, '999');
console.log(JSON.stringify({
  available: r.available,
  total: r.total,
  ports: r.ports.map((p) => [p.type, p.status]),
  since: r.ports.find((p) => p.status === 'busy')?.since ?? null,
  otherTotal: other.total,
  otherAvailable: other.available,
  unknownId: applyAmpeco(base, fx, '12345'),
}));
"""
    out = subprocess.run(
        ["node", "--input-type=module", "-e", script, FIXTURE],
        cwd=ROOT, capture_output=True, text=True)
    if out.returncode != 0:
        return [f"node run failed: {out.stderr.strip()[:300]}"]
    got = json.loads(out.stdout)
    print("\ntesla/js/live.js reading for martev_220:")
    print("  available/total:", f"{got['available']}/{got['total']}")
    print("  ports          :", got["ports"])

    bad = []
    if got["total"] != EXPECTED_TOTAL or got["available"] != EXPECTED_AVAIL:
        bad.append(f"js counts {got['available']}/{got['total']} "
                   f"!= {EXPECTED_AVAIL}/{EXPECTED_TOTAL}")
    if [tuple(p) for p in got["ports"]] != EXPECTED_PORTS:
        bad.append(f"js ports {got['ports']} != {EXPECTED_PORTS}")
    if not str(got["since"] or "").startswith(EXPECTED_SINCE):
        bad.append(f"js session start wrong: {got['since']}")
    if got["otherTotal"] != 1 or got["otherAvailable"] != 1:
        bad.append("js linked location wrong")
    if got["unknownId"] is not None:
        bad.append("js returned a reading for a station not in the response")
    return bad


if __name__ == "__main__":
    sys.exit(main())
