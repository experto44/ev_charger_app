"""Dev scraper for the MOVEO charging network (ge.moveo.cp).

MOVEO runs on the AMPECO charge-point platform — the same white-label backend as
mart EV (`_dev_martev.py`). The public mobile API needs no auth, only the app
identity headers. Two endpoints:

  GET /api/v1/app/pins            -> [{id, geo:"lat,lng", av:{ava,unk,una}}]
  GET /api/v1/app/locations/{id}  -> {locations:[{name,address,location,zones:[
                                       {evses:[{maxPower,currentType,isAvailable,
                                       tariffId,connectors:[{name,icon}]}]}]}],
                                      tariffs:[...], currencies:[...]}

Output: stations in the app's production schema (see assets/data/chargers.json),
grouped under the "MOVEO" provider with stable ids "moveo_{locationId}".

Run:  python _dev_moveo.py            # prints "MOVEO: N stations" + samples
      python _dev_moveo.py --json     # prints the full station JSON array
"""
import io
import json
import sys

import requests

# UTF-8 stdout so Georgian names/signs print on Windows consoles.
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8")

BASE = "https://cp.moveo.ge/api/v1"
HEADERS = {
    "Accept": "application/json",
    "Accept-Language": "ka",
    "App-Version": "3.177.0",
    "x-mobile-app-bundle-id": "ge.moveo.cp",
}
TIMEOUT = 30

PROVIDER = "MOVEO"
ID_PREFIX = "moveo_"

# Georgian city tokens -> English, to match the app's existing data style. The
# address city is in Georgian (e.g. "თბილისი 0186"); we map the common ones and
# fall back to the raw Georgian token for anything not listed.
CITY_MAP = {
    "თბილისი": "Tbilisi",
    "ბათუმი": "Batumi",
    "ქუთაისი": "Kutaisi",
    "რუსთავი": "Rustavi",
    "გორი": "Gori",
    "თელავი": "Telavi",
    "ზუგდიდი": "Zugdidi",
    "ფოთი": "Poti",
    "ოზურგეთი": "Ozurgeti",
    "ახალციხე": "Akhaltsikhe",
    "მცხეთა": "Mtskheta",
    "ყვარელი": "Kvareli",
    "სიღნაღი": "Sighnaghi",
    "ბაკურიანი": "Bakuriani",
    "გუდაური": "Gudauri",
    "ბორჯომი": "Borjomi",
    "მარნეული": "Marneuli",
    "კასპი": "Kaspi",
    "ხაშური": "Khashuri",
    "ზესტაფონი": "Zestaponi",
    "სამტრედია": "Samtredia",
    "სენაკი": "Senaki",
}


def norm_conn(raw):
    """Map an AMPECO connector icon/name onto the app's canonical chip label.

    Substring-based (not exact lookup): MOVEO's "gb-t-dc" icon and "GB/T DC"
    name both have to resolve to GB/T, which an exact map would miss.
    """
    if not raw:
        return None
    k = str(raw).lower().replace(" ", "").replace("-", "").replace("_", "").replace("/", "")
    if "chademo" in k:
        return "CHAdeMO"
    if "ccs1" in k or "combo1" in k:
        return "CCS1"
    if "ccs" in k or "combo" in k:          # ccs2 / combo2 / bare ccs
        return "CCS2"
    if "gb" in k:                           # gbt / gb_t / gbtdc
        return "GB/T"
    if "nacs" in k or "tesla" in k:
        return "NACS"
    if "type1" in k or "j1772" in k:
        return "Type 1"
    if "type2" in k or "mennekes" in k or "iec62196t2" in k:
        return "Type 2"
    return None


# App's canonical connector display order (mirrors kConnectorOrder in Dart).
CONN_ORDER = ["CCS2", "GB/T", "CHAdeMO", "Type 2", "NACS", "CCS1", "Type 1"]


def sort_conns(conns):
    return sorted(conns, key=lambda c: (CONN_ORDER.index(c) if c in CONN_ORDER else len(CONN_ORDER), c))


def fmt_amt(v):
    """Format a price amount, trimming trailing zeros (0.80 -> '0.8')."""
    try:
        f = float(v)
    except Exception:
        return None
    return f"{f:.2f}".rstrip("0").rstrip(".")


def tariff_price(tid, tariffs, currencies):
    """Build a "<amount> <sign>/kWh" price string from a tariff id."""
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


# Georgian city roots (nominative stems) -> English, for matching declined forms
# like the genitive "ქარელის" that appear in highway crossroad names.
CITY_ROOTS = {
    "ქარელ": "Kareli", "თბილის": "Tbilisi", "ბათუმ": "Batumi", "ქუთაის": "Kutaisi",
    "რუსთავ": "Rustavi", "გორ": "Gori", "თელავ": "Telavi", "ზუგდიდ": "Zugdidi",
    "გუდაურ": "Gudauri", "ბაკურიან": "Bakuriani", "ბორჯომ": "Borjomi",
}


def _clean_city(seg):
    """Strip postal codes / '#N' tokens from an address segment -> city name."""
    tokens = [w for w in seg.split() if not any(ch.isdigit() for ch in w) and not w.startswith("#")]
    name = " ".join(tokens).strip()
    if name in CITY_MAP:
        return CITY_MAP[name]
    for tok in tokens:
        for root, en in CITY_ROOTS.items():
            if tok.startswith(root):
                return en
    return name


def derive_city(addr):
    """Pull a city name out of an AMPECO address string.

    MOVEO addresses vary in shape:
      "ჯანაშიას ქუჩა #8 | ზუგდიდი 2100 | საქართველო"   (street | city+postal | country)
      "ა. თვალჭრელიძის ქ. #2 | თბილისი 0182"             (street | city+postal)
      "E60 ქარელის გზაჯვარედინი"                          (highway, no city/postal)
    The city always travels with the 4-digit postal code, so key off that; fall
    back to the pre-country segment, then to the only segment we have.
    """
    parts = [p.strip() for p in (addr or "").replace("|", ",").split(",") if p.strip()]
    if not parts:
        return ""
    # Segment that carries a 4-digit postal code is the city segment.
    for p in parts:
        if any(len(w) == 4 and w.isdigit() for w in p.split()):
            return _clean_city(p)
    # No postal code: take the segment before the country word, else the last.
    country = {"საქართველო", "Georgia", "georgia"}
    named = [p for p in parts if p not in country]
    return _clean_city(named[-1]) if named else ""


def fetch_moveo():
    r = requests.get(f"{BASE}/app/pins", headers=HEADERS, timeout=TIMEOUT)
    r.raise_for_status()
    pins = r.json().get("pins", [])

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
            if e.get("isAvailable"):
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
            "name": loc.get("name") or "MOVEO charger",
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
    data = fetch_moveo()
    if "--json" in sys.argv:
        print(json.dumps(data, ensure_ascii=False, indent=2))
    else:
        print(f"MOVEO: {len(data)} stations, "
              f"{sum(s['total_spots'] for s in data)} ports")
        print("\n--- samples ---")
        for s in data[:6]:
            print(json.dumps(s, ensure_ascii=False))
