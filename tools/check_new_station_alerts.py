#!/usr/bin/env python3
"""Prove the "new charger" broadcast cannot spam the whole user base.

A "this plug is free" push goes to the one person who asked for it. This one
goes to every subscriber at once and cannot be recalled, so the interesting
cases are not the happy path but the ways a data glitch could be mistaken for
a dozen chargers opening at the same moment.

The logic under test is lifted out of .github/workflows/update_gist.yml at run
time rather than copied, so this cannot quietly pass against a stale duplicate.

    python tools/check_new_station_alerts.py
"""
import io, ast, os, json, sys, contextlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
P = os.path.join(ROOT, ".github", "workflows", "update_gist.yml")
lines = io.open(P, encoding="utf-8").read().split("\n")
end = next(i for i, l in enumerate(lines) if l.strip() == "PYEOF")
body = lines[114:end]
pad = min(len(l) - len(l.lstrip()) for l in body if l.strip())
code = "\n".join(l[pad:] if len(l) >= pad else l for l in body)

# Keep only the definitions we care about, so importing does not run the
# pipeline (which would hit every provider's API).
tree = ast.parse(code)
wanted = {"load_known_ids", "_site_label", "notify_new_stations"}
consts = {"KNOWN_FILE", "MAX_NEW_PER_PROVIDER", "CONFIG_FILE"}
keep = [n for n in tree.body
        if (isinstance(n, ast.FunctionDef) and n.name in wanted)
        or (isinstance(n, ast.Assign) and getattr(n.targets[0], "id", None) in consts)]
assert len(keep) == len(wanted) + len(consts), f"found {[getattr(n,'name',None) or n.targets[0].id for n in keep]}"

ns = {"json": json, "os": os, "requests": None, "headers": {}}
exec(compile(ast.Module(body=keep, type_ignores=[]), "<pipeline>", "exec"), ns)
notify = ns["notify_new_stations"]
label = ns["_site_label"]

def st(sid, provider="mart EV", lat=41.7, lng=44.8, name="Site", city="Tbilisi",
       connectors=("CCS2",)):
    return {"id": sid, "provider": provider, "lat": lat, "lng": lng,
            "name": name, "city": city, "connectors": list(connectors)}

def run(known, stations, fresh, enabled=False):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        out = notify(known, stations, fresh, enabled)
    return out, buf.getvalue()

FAIL = []
def check(name, cond, detail=""):
    print(("  ok   " if cond else "  FAIL ") + name + ("" if cond else f"  <- {detail}"))
    if not cond:
        FAIL.append(name)

ALL = {"mart EV", "Tegeta", "EcoCars"}
print("new-charger broadcast logic")

# 1. First run must never announce.
feed = [st("a1"), st("a2")]
out, log = run(None, feed, ALL)
check("first run seeds and stays silent",
      out == {"a1", "a2"} and "[dry-run]" not in log, log)

# 2. A genuinely new station announces once, in both languages.
out, log = run({"a1"}, [st("a1"), st("a2", name="Vake")], ALL)
check("one new station -> one site, two languages",
      log.count("[dry-run]") == 2, log)
check("new id is recorded", out == {"a1", "a2"}, out)

# 3. Nothing new -> silence.
out, log = run({"a1", "a2"}, feed, ALL)
check("nothing new stays silent", "[dry-run]" not in log, log)

# 4. A provider that did not refresh cannot introduce anything.
out, log = run({"a1"}, [st("a1"), st("zz", provider="Tegeta")], {"mart EV"})
check("stale provider cannot announce", "[dry-run]" not in log, log)
check("stale provider is still recorded", "zz" in out, out)

# 5. A burst is recorded but not announced.
burst = [st(f"b{i}", lat=41.0 + i) for i in range(9)]
out, log = run(set(), burst, ALL)
check("burst is suppressed", "[dry-run]" not in log, log)
check("burst is still recorded", len(out) == 9, out)
check("burst is explained in the log", "without announcing" in log, log)

# 6. Co-located rows collapse to one push with merged connectors.
site = [st("c1", lat=41.72, lng=44.81, connectors=["CCS2"]),
        st("c2", lat=41.72, lng=44.81, connectors=["GB/T"])]
out, log = run(set(["seed"]), site + [st("seed")], ALL)
check("one site -> one push per language", log.count("[dry-run]") == 2, log)
check("connectors merge", "CCS2, GB/T" in log, log)

# 7. Two distinct sites -> two pushes per language.
two = [st("d1", lat=41.10, name="A"), st("d2", lat=42.90, name="B")]
out, log = run(set(["seed"]), two + [st("seed")], ALL)
check("two sites -> four dry-run lines", log.count("[dry-run]") == 4, log)

# 8. The reappearing-station trap: a partial feed drops a1, it comes back.
known = {"a1", "a2"}
out, _ = run(known, [st("a2")], ALL)          # a1 vanished this cycle
out2, log = run(out, [st("a1"), st("a2")], ALL)  # and is back
check("a station that vanished and returned is NOT announced",
      "[dry-run]" not in log, log)

# 8b. An empty feed must never reset the state (it would make the whole
#     country look new next cycle).
out, log = run({"a1", "a2"}, [], ALL)
check("empty feed leaves state untouched", out is None, out)
out, log = run(None, [], ALL)
check("empty feed does not seed either", out is None, out)

# 9. Labels.
check("city is prefixed", label({"name": "Gezi", "city": "Batumi"}) == "Batumi, Gezi")
check("city is not repeated",
      label({"name": "Batumi Mall", "city": "Batumi"}) == "Batumi Mall")
check("missing everything is empty", label({}) == "")

# 10. Both topics are addressed.
out, log = run({"a1"}, [st("a1"), st("a2")], ALL)
check("english topic used", "new_stations_en" in log, log)
check("georgian topic used", "new_stations_ka" in log, log)
check("provider named in copy", "mart EV" in log, log)

print()
if FAIL:
    print(f"{len(FAIL)} FAILED: {FAIL}")
    sys.exit(1)
print("all checks passed")
