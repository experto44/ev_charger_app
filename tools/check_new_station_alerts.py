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
wanted = {"load_known_ids", "_site_label", "notify_new_stations",
          "_load_georgia_ring", "in_georgia"}
consts = {"KNOWN_FILE", "MAX_NEW_PER_PROVIDER", "CONFIG_FILE", "BORDER_FILE",
          "GEORGIA_RING"}
keep = [n for n in tree.body
        if (isinstance(n, ast.FunctionDef) and n.name in wanted)
        or (isinstance(n, ast.Assign) and getattr(n.targets[0], "id", None) in consts)]
assert len(keep) == len(wanted) + len(consts), f"found {[getattr(n,'name',None) or n.targets[0].id for n in keep]}"

# GEORGIA_RING is built at import time from a path relative to the checkout,
# which is where the workflow runs from.
os.chdir(ROOT)
ns = {"json": json, "os": os, "requests": None, "headers": {}}
exec(compile(ast.Module(body=keep, type_ignores=[]), "<pipeline>", "exec"), ns)
notify = ns["notify_new_stations"]
label = ns["_site_label"]
in_georgia = ns["in_georgia"]

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
burst = [st(f"b{i}", lat=41.7 + i / 10.0) for i in range(9)]
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
two = [st("d1", lat=41.64, lng=41.64, name="A"),
       st("d2", lat=42.27, lng=42.70, name="B")]
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

# 11. Georgia only. The feed carries Armenian and Turkish stations, and the
#     bounding box people reach for first contains several of them.
check("Tbilisi is inside", in_georgia(41.716, 44.783))
check("Batumi is inside", in_georgia(41.651, 41.667))
check("Sadakhlo is inside", in_georgia(41.222, 44.821))
check("Kazbegi is inside", in_georgia(42.66, 44.64))
check("Bagratashen (AM) is outside", not in_georgia(41.232, 44.839))
check("Alaverdi (AM) is outside", not in_georgia(41.092, 44.686))
check("Ashotsk (AM) is outside", not in_georgia(41.031, 43.872))
check("Noyemberyan (AM) is outside", not in_georgia(41.207, 44.906))
check("Yerevan (AM) is outside", not in_georgia(40.18, 44.51))
check("Hopa (TR) is outside", not in_georgia(41.402, 41.427))
check("Vladikavkaz (RU) is outside", not in_georgia(43.03, 44.68))
check("a missing coordinate is outside", not in_georgia(None, None))

out, log = run({"seed"}, [st("seed"),
                          st("e1", provider="EcoCars", lat=41.092, lng=44.686,
                             name="Alaverdi", city="Alaverdi")], ALL)
check("an Armenian opening is not announced", "[dry-run]" not in log, log)
check("...but it is recorded", "e1" in out, out)
check("...and the log says why", "outside Georgia" in log, log)

mixed = [st("seed"),
         st("f1", provider="EcoCars", lat=41.092, lng=44.686, name="Alaverdi"),
         st("f2", provider="EcoCars", lat=41.651, lng=41.667, name="Batumi")]
out, log = run({"seed"}, mixed, ALL)
check("a Georgian opening in the same cycle still goes out",
      log.count("[dry-run]") == 2 and "Batumi" in log, log)

print()
if FAIL:
    print(f"{len(FAIL)} FAILED: {FAIL}")
    sys.exit(1)
print("all checks passed")
