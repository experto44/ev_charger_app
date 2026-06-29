"""Dev scraper for the mart EV charging network (io.martev.app).

mart EV runs on the AMPECO charge-point platform — same backend as MOVEO
(`_dev_moveo.py`). Public mobile API, no auth, only app-identity headers.

  GET /api/v1/app/pins            -> [{id, geo, av:{ava,unk,una}}]
  GET /api/v1/app/locations/{id}  -> {locations:[{name,address,location,zones:[
                                       {evses:[...]}]}], tariffs, currencies}

Output: stations in the app's production schema, provider "mart EV", ids
"martev_{locationId}".

Run:  python _dev_martev.py                 # prints "mart EV: N stations" + samples
      LIMIT=20 python _dev_martev.py         # cap locations (dev)
      python _dev_martev.py --json           # full station JSON array
"""
import io
import json
import os
import sys

import requests

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8")

BASE = "https://cp.martev.io/api/v1"
HEADERS = {
    "Accept": "application/json",
    "Accept-Language": "ka",
    "App-Version": "3.130.0",
    "x-mobile-app-bundle-id": "io.martev.app",
}
TIMEOUT = 30
LIMIT = int(os.environ.get("LIMIT", "0"))  # 0 = no cap

PROVIDER = "mart EV"
ID_PREFIX = "martev_"


# ── Connector normalization (canonical app chip labels) ───────────────────────
CONN_ORDER = ["CCS2", "GB/T", "CHAdeMO", "Type 2", "NACS", "CCS1", "Type 1"]


def norm_conn(raw):
    if not raw:
        return None
    k = str(raw).lower().replace(" ", "").replace("-", "").replace("_", "").replace("/", "")
    if "chademo" in k:
        return "CHAdeMO"
    if "ccs1" in k or "combo1" in k:
        return "CCS1"
    if "ccs" in k or "combo" in k:
        return "CCS2"
    if "gb" in k:
        return "GB/T"
    if "nacs" in k or "tesla" in k:
        return "NACS"
    if "type1" in k or "j1772" in k:
        return "Type 1"
    if "type2" in k or "mennekes" in k or "iec62196t2" in k:
        return "Type 2"
    return None


def sort_conns(conns):
    return sorted(conns, key=lambda c: (CONN_ORDER.index(c) if c in CONN_ORDER else len(CONN_ORDER), c))


# ── Pricing ───────────────────────────────────────────────────────────────────
def fmt_amt(v):
    try:
        f = float(v)
    except Exception:
        return None
    return f"{f:.2f}".rstrip("0").rstrip(".")


def tariff_price(tid, tariffs, currencies):
    t = tariffs.get(str(tid))
    if not isinstance(t, dict):
        return ""
    ppk = t.get("priceForEnergy")
    if ppk is None:
        ppk = t.get("priceForEnergyAtDay")
    if ppk is None:
        ppk = t.get("priceForEnergyAtNight")
    amount = fmt_amt(ppk) if ppk is not None else None
    cur = currencies.get(t.get("currencyCode")) or {}
    sign = cur.get("sign") or cur.get("prefix") or "₾"
    if amount:
        return f"{amount} {sign}/kWh"
    return ""


# ── City derivation ───────────────────────────────────────────────────────────
# mart EV addresses are "<street>, <City>[ postal], Georgia" (Latin, with the
# apostrophe spelling "T'bilisi"). City = the segment before the country, postal
# code stripped, apostrophe spelling normalized.
def derive_city(addr):
    parts = [p.strip() for p in (addr or "").split(",") if p.strip()]
    if not parts:
        return ""
    cand = parts[-2] if len(parts) >= 3 else (parts[0] if parts else "")
    tokens = [w for w in cand.split() if not any(ch.isdigit() for ch in w)]
    name = " ".join(tokens).strip()
    return "Tbilisi" if name == "T'bilisi" else name


# ── Availability (see _dev_moveo.py evse_free for the full rationale) ──────────
def evse_free(e):
    """Free unless the platform says unavailable for a reason other than a busy
    sibling. Trust `isAvailable`, and additionally count a `status=unavailable`
    connector as free: on a shared DC cabinet AMPECO marks the idle sibling
    unavailable while the other charges, which is what made "1 car charging"
    read "0 of 2". Verified that `status=unavailable` never appears without a
    concurrent charging session, so it never masks a genuinely broken unit
    (those report `out of order`, which stays excluded).
    """
    if e.get("isAvailable"):
        return True
    s = (e.get("status") or "").strip().lower().replace(" ", "").replace("_", "").replace("-", "")
    return s == "unavailable"


def fetch_martev():
    r = requests.get(f"{BASE}/app/pins", headers=HEADERS, timeout=TIMEOUT)
    r.raise_for_status()
    pins = r.json().get("pins", [])
    if LIMIT:
        pins = pins[:LIMIT]

    stations = []
    for pin in pins:
        lid = pin.get("id")
        if lid is None:
            continue
        try:
            d = requests.get(f"{BASE}/app/locations/{lid}", headers=HEADERS, timeout=TIMEOUT)
            d.raise_for_status()
            payload = d.json()
        except Exception as e:
            print(f"error: location {lid}: {e}", file=sys.stderr)
            continue

        locs = payload.get("locations") or []
        if not locs:
            continue
        loc = locs[0]
        tariffs = {str(t["id"]): t for t in payload.get("tariffs", []) if "id" in t}
        currencies = {c["code"]: c for c in payload.get("currencies", []) if "code" in c}

        evses = [e for z in loc.get("zones", []) for e in z.get("evses", [])]
        if not evses:
            continue

        conns = set()
        max_w = 0.0
        any_dc = False
        available = 0
        price = ""
        for e in evses:
            if e.get("currentType") == "dc":
                any_dc = True
            mw = e.get("maxPower") or 0
            if mw > max_w:
                max_w = mw
            if evse_free(e):
                available += 1
            for c in e.get("connectors", []):
                n = norm_conn(c.get("icon") or c.get("name"))
                if n:
                    conns.add(n)
            if not price and e.get("tariffId") is not None:
                price = tariff_price(e["tariffId"], tariffs, currencies)

        kw = round(max_w / 1000) if max_w else 0
        geo = (loc.get("location") or pin.get("geo") or "").split(",")
        try:
            lat, lng = float(geo[0]), float(geo[1])
        except (ValueError, IndexError):
            continue

        stations.append({
            "id": f"{ID_PREFIX}{lid}",
            "name": loc.get("name") or "mart EV charger",
            "lat": lat,
            "lng": lng,
            "power": f"{kw} kW" if kw else "—",
            "type": "Fast DC" if any_dc else "AC",
            "price": price,
            "available_spots": f"{available} available",
            "total_spots": len(evses),
            "city": derive_city(loc.get("address")),
            "provider": PROVIDER,
            "connectors": sort_conns(conns),
            "last_updated": "Just now",
        })
    return stations


if __name__ == "__main__":
    data = fetch_martev()
    if "--json" in sys.argv:
        print(json.dumps(data, ensure_ascii=False, indent=2))
    else:
        print(f"mart EV: {len(data)} stations, {sum(s['total_spots'] for s in data)} ports")
        for s in data[:6]:
            print(json.dumps(s, ensure_ascii=False))
