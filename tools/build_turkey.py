#!/usr/bin/env python3
"""Build the Turkish charger dataset (chargers_tr.json) for GeoCharge.

Source of truth is EPDK, the Turkish energy regulator: every publicly usable
charging station in Turkey must be licensed and listed there, so the registry
is both authoritative and far more complete than Open Charge Map (≈5x the
station count). We take EPDK as the backbone and top it up with the OCM rows
that have no EPDK match, so nothing a driver can actually use goes missing.

Output rows use the same production schema as the Georgian gist, so the app
parses them with the existing Station.fromJson.

Notes on the EPDK endpoint
--------------------------
  GET https://apigateway.epdk.gov.tr/sarjIstasyonlari   (JSON body, no auth)

It sits behind an Apinizer gateway with a per-IP quota: a burst of calls trips
`ERR-227 QUOTA limit` (HTTP 429) for a long window. So this script issues ONE
unfiltered query per run, retries patiently on 429, and never fans out into
per-brand calls unless the single query comes back empty.

Prices
------
EPDK does not publish tariffs, so per-station prices come from tools/tr_tariffs.json,
a brand-level table (Turkish operators publish one national tariff per socket
class). A brand with no verified entry gets NO price rather than a guess.
"""

import json
import os
import re
import sys
import time
import unicodedata
from datetime import datetime, timezone

import requests

HERE = os.path.dirname(os.path.abspath(__file__))

EPDK_URL = "https://apigateway.epdk.gov.tr/sarjIstasyonlari"
OCM_URL = "https://api.openchargemap.io/v3/poi/"
OCM_KEY = "a374a367-c145-4ac1-82d5-91fb9ce52b36"
OCM_HEADERS = {
    "User-Agent": "ev_charger_app/1.0 (Flutter; +https://geocharge.ge)",
    "X-API-Key": OCM_KEY,
}

# Two stations closer than this are treated as the same place when merging OCM
# rows into the EPDK backbone.
DEDUPE_METERS = 150


# ── brand normalisation ───────────────────────────────────────────────────────
# EPDK's `marka` is free text straight off the trademark registration: "zes",
# "VOLTRUN", "eşarj", "SHARZ.NET" all appear as typed. We fold it to a bare
# lowercase ASCII key for table lookups, and keep a curated display name for the
# brands we know so the app shows "Eşarj", not "eşarj".
_TR_FOLD = str.maketrans({
    "ı": "i", "İ": "i", "ş": "s", "Ş": "s", "ğ": "g", "Ğ": "g",
    "ü": "u", "Ü": "u", "ö": "o", "Ö": "o", "ç": "c", "Ç": "c",
})


def brand_key(raw):
    """Normalised lookup key for a brand: lowercase, Turkish letters folded,
    everything that isn't a letter or digit removed."""
    if not raw:
        return ""
    s = str(raw).translate(_TR_FOLD).lower()
    s = unicodedata.normalize("NFKD", s)
    s = "".join(c for c in s if not unicodedata.combining(c))
    return re.sub(r"[^a-z0-9]", "", s)


def load_tariffs():
    with open(os.path.join(HERE, "tr_tariffs.json"), encoding="utf-8") as f:
        data = json.load(f)
    table = {}
    for key, entry in data["brands"].items():
        table[key] = entry
        for alias in entry.get("aliases", []):
            table[brand_key(alias)] = entry
    return data, table


# ── live tariff refresh ───────────────────────────────────────────────────────
# Operators publish their tariff on their own site, but most of those sites are
# SPAs and several block non-Turkish/datacentre IPs outright (zes.net refuses
# the connection from CI). The dated public index below tracks all of them in
# one parseable table, so we refresh from it and keep the committed table as the
# fallback: a broken scrape degrades to yesterday's prices, never to none.
DOVIZ_URL = "https://www.doviz.com/ev-sarj-fiyatlari"
DOVIZ_HEADERS = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                               "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126"}

_ROW_RE = re.compile(r"<tr>.*?</tr>", re.S)
_NAME_RE = re.compile(r'<span class="ml-8">([^<]+)</span>')
_CELL_RE = re.compile(r"<td[^>]*>(.*?)</td>", re.S)
_POPOVER_RE = re.compile(r'<span class="popover.*?</span></span>', re.S)
_TAG_RE = re.compile(r"<[^>]+>")
_MONEY_RE = re.compile(r"₺\s*([0-9.]+,[0-9]{2})")


def sane_price(value):
    """A per-kWh tariff is a single-digit-to-low-double-digit lira figure. The
    index renders a handful of operators in kuruş ("₺1.099,00" for 10.99 ₺), so
    rescale those and drop anything that still doesn't look like a price."""
    if 3 <= value <= 40:
        return round(value, 2)
    if 300 <= value <= 4000:
        return round(value / 100, 2)
    return None


def _prices(cell):
    out = []
    for raw in _MONEY_RE.findall(_TAG_RE.sub(" ", _POPOVER_RE.sub(" ", cell))):
        v = sane_price(float(raw.replace(".", "").replace(",", ".")))
        if v is not None:
            out.append(v)
    return [min(out), max(out)] if out else None


def refresh_tariffs(tariffs):
    """Update the in-memory tariff table from the live index, matching rows to
    our brands by normalised name and alias. Silently keeps the committed
    values for anything it can't match or parse."""
    try:
        html = requests.get(DOVIZ_URL, headers=DOVIZ_HEADERS, timeout=60).text
    except Exception as exc:
        print("tariff refresh skipped:", exc)
        return 0

    updated = 0
    for row in _ROW_RE.findall(html):
        m = _NAME_RE.search(row)
        if not m:
            continue
        cells = _CELL_RE.findall(row)
        if len(cells) < 4:
            continue
        # Index column order is: operator | DC | AC | date.
        dc, ac = _prices(cells[1]), _prices(cells[2])
        if not dc and not ac:
            continue
        date = _TAG_RE.sub("", cells[3]).strip()          # dd.mm.yyyy
        key = brand_key(re.sub(r"\([^)]*\)", " ", m.group(1)))
        entry = tariffs.get(key)
        if entry is None:
            continue                                       # brand we don't map
        if ac:
            entry["ac"] = ac
        if dc:
            entry["dc"] = dc
        if re.fullmatch(r"\d{2}\.\d{2}\.\d{4}", date):
            entry["checked"] = "-".join(reversed(date.split(".")))
        updated += 1
    print(f"tariff refresh: {updated} brand(s) updated from {DOVIZ_URL}")
    return updated


def display_name(raw, tariffs):
    """Human-facing provider name for a raw EPDK brand string."""
    entry = tariffs.get(brand_key(raw))
    if entry:
        return entry["name"]
    name = str(raw or "").strip()
    if not name:
        return "Unknown"
    # Some operators register the full company name as the brand
    # ("PİRİM GIDA VE MEŞRUBAT SAN. ve TİC. LTD. ŞTİ."). Drop the legal-form
    # tail and title-case SHOUTED names; leave MixedCase brands alone.
    name = re.sub(
        r"\s+(A\.?Ş\.?|ANONİM ŞİRKETİ|LTD\.?\s*ŞTİ\.?|LİMİTED ŞİRKETİ|"
        r"SAN\.?\s*(VE)?\s*TİC\.?.*|TİC\.?\s*.*)$",
        "", name, flags=re.IGNORECASE).strip(" .,-")
    if name.isupper() or name.islower():
        name = tr_title(name)
    return name or "Unknown"


def tr_title(s, turkish=False):
    """Title-case that survives Turkish orthography: str.title() turns "İ" into
    "i̇" (i + combining dot) and lowercases "I" wrongly, which mangles brands
    like "PİRİM" and "EN YAKIT".

    Brand names are a mixed bag — plenty are English — so by default the
    Turkish I rules apply only to words that carry a Turkish letter, keeping
    "MINUS ENERGY" from becoming "Mınus". Pass turkish=True where the input is
    known to be Turkish (province names), so "AYDIN" comes out "Aydın".
    """
    out = []
    for word in re.split(r"(\s+)", s):
        if not word.strip():
            out.append(word)
            continue
        if turkish or re.search(r"[şŞğĞüÜöÖçÇİı]", word):
            head = "İ" if word[0] == "i" else word[0].upper()
            tail = word[1:].replace("I", "ı").replace("İ", "i").lower()
            out.append(head + tail)
        else:
            out.append(word[:1].upper() + word[1:].lower())
    return "".join(out)


def price_note(entry, is_dc):
    """Provenance line shown under the price in the app. Empty when there is no
    price to explain — we never annotate a blank."""
    if not price_label(entry, is_dc):
        return ""
    checked = entry.get("checked", "")
    when = ".".join(reversed(checked.split("-"))) if checked else ""
    tail = f" · checked {when}" if when else ""
    return f"{entry['name']} published tariff{tail}"


def price_label(entry, is_dc):
    """"12,99 ₺/kWh" or "12,99 - 16,49 ₺/kWh" for the socket class in use.
    Empty when the brand has no verified tariff for that class."""
    if not entry:
        return ""
    span = entry.get("dc" if is_dc else "ac")
    if not span:
        return ""
    lo, hi = float(span[0]), float(span[1])
    fmt = lambda v: f"{v:.2f}".replace(".", ",")
    return (f"{fmt(lo)} ₺/kWh" if abs(hi - lo) < 0.005
            else f"{fmt(lo)} - {fmt(hi)} ₺/kWh")


# ── EPDK ──────────────────────────────────────────────────────────────────────
def fetch_epdk(max_wait_minutes=90):
    """One unfiltered query, retried through the gateway's quota window.

    Returns the list of station dicts (raw EPDK field names). Raises on a
    definitive failure so the caller can keep yesterday's file instead of
    publishing an empty dataset.
    """
    deadline = time.time() + max_wait_minutes * 60
    attempt = 0
    while True:
        attempt += 1
        res = requests.get(
            EPDK_URL,
            headers={"Content-Type": "application/json"},
            # GET-with-body, as the API documents. An EMPTY body answers 200
            # with numRows 0 — the query needs at least one real criterion —
            # and `hizmetSekli` is the one that enumerates the whole registry.
            # It also happens to be the filter we want: HALKA_ACIK is "open to
            # the public", so private sites never enter the dataset.
            data=json.dumps({"hizmetSekli": "HALKA_ACIK"}).encode(),
            timeout=300,
        )
        if res.status_code == 200:
            payload = res.json()
            rows = normalise_epdk_rows(payload)
            print(f"EPDK: {len(rows)} rows (attempt {attempt})")
            if rows:
                # One line of shape diagnostics in every run's log: EPDK's field
                # spelling is the thing most likely to drift under us, and a
                # silent rename would quietly empty half the dataset.
                sample = rows[0]
                print("EPDK sample keys:", sorted(sample.keys()))
                sockets = first(sample, "soketler", "soketListesi", "sockets")
                print("EPDK sample socket:",
                      json.dumps((sockets or [{}])[0], ensure_ascii=False)[:300]
                      if isinstance(sockets, list) else repr(sockets)[:300])
                return rows
            raise RuntimeError(f"EPDK returned no rows: {str(payload)[:400]}")

        quota_blocked = res.status_code == 429 or "QUOTA" in res.text.upper()
        if not quota_blocked:
            raise RuntimeError(f"EPDK HTTP {res.status_code}: {res.text[:300]}")
        if time.time() > deadline:
            raise RuntimeError("EPDK quota window never opened")
        print(f"EPDK quota blocked (attempt {attempt}); waiting 5 min")
        time.sleep(300)


def normalise_epdk_rows(payload):
    """The gateway answers
    {statusCode, columnNames: [...], numRows: N, result: null, data: [...]}.
    The rows live under `data`; `result` is null in every response seen so far
    but is checked too in case that flips. Rows have been seen both as dicts
    and as positional arrays, so handle both and always hand back dicts."""
    if isinstance(payload, list):
        return [r for r in payload if isinstance(r, dict)]
    cols = payload.get("columnNames") or []
    rows = payload.get("data") or payload.get("result") or []
    out = []
    for row in rows:
        if isinstance(row, dict):
            out.append(row)
        elif isinstance(row, (list, tuple)) and cols:
            out.append(dict(zip(cols, row)))
    return out


def first(row, *names):
    """EPDK's column spelling drifts between the legacy and gateway services
    (`marka` vs `markaAdi`, `enlem` vs `latitude`), so read by candidate list."""
    for n in names:
        if n in row and row[n] not in (None, ""):
            return row[n]
        # case-insensitive fallback
        for k, v in row.items():
            if k.lower() == n.lower() and v not in (None, ""):
                return v
    return None


def to_float(v):
    if v is None:
        return None
    try:
        return float(str(v).strip().replace(",", "."))
    except ValueError:
        return None


CONNECTOR_BY_SOCKET_TYPE = {
    "DC_CCS": "CCS2",
    "DC_CHADEMO": "CHAdeMO",
    "DC_GBT": "GB/T",
    "AC_TYPE2": "Type 2",
    "AC_TYPE1": "Type 1",
}
CONNECTOR_ORDER = ["CCS2", "GB/T", "CHAdeMO", "Type 2", "NACS", "CCS1", "Type 1"]


def sort_connectors(conns):
    return sorted(conns, key=lambda c: (CONNECTOR_ORDER.index(c)
                                        if c in CONNECTOR_ORDER
                                        else len(CONNECTOR_ORDER), c))


def parse_sockets(raw):
    """(connector labels, socket count, max kW, any DC) from EPDK's `soketler`."""
    conns, count, max_kw, any_dc = set(), 0, 0.0, False
    if isinstance(raw, str):
        try:
            raw = json.loads(raw)
        except (ValueError, TypeError):
            raw = []
    for s in (raw or []):
        if not isinstance(s, dict):
            continue
        count += 1
        turu = str(first(s, "soketTuru", "SOKET_TURU", "soketTipiKodu") or "").upper()
        tipi = str(first(s, "soketTipi", "SOKET_TIPI") or "").upper()
        label = CONNECTOR_BY_SOCKET_TYPE.get(turu)
        if label:
            conns.add(label)
        elif turu.startswith("AC"):
            conns.add("Type 2")
        if tipi == "DC" or turu.startswith("DC"):
            any_dc = True
        kw = to_float(first(s, "soketGucu", "SOKET_GUCU", "guc"))
        if kw and kw > max_kw:
            max_kw = kw
    return sort_connectors(conns), count, max_kw, any_dc


# Address tails read "... Silivri / İSTANBUL"; the province is what we show as
# the city label, falling back to the district when there's no province.
_PROVINCE_RE = re.compile(r"/\s*([^/,]+)\s*$")


def parse_city(address):
    if not address:
        return ""
    m = _PROVINCE_RE.search(str(address).strip())
    city = (m.group(1) if m else str(address).split(",")[-1]).strip()
    city = re.sub(r"\s+", " ", city)
    if city.isupper():
        # tr_title, not str.title(): the latter turns "İZMİR" into "İzmi̇r",
        # with a stray combining dot after the i. Provinces are always Turkish,
        # so the dotted/dotless I rules apply unconditionally here — otherwise
        # "AYDIN" comes out "Aydin" and splits one province into two labels.
        city = tr_title(city, turkish=True)
    return city[:40]


def map_epdk(rows, tariffs):
    """EPDK rows → production station schema. Public stations only."""
    out, skipped = [], 0
    for r in rows:
        service = str(first(r, "hizmetSekli", "HIZMET_SEKLI") or "").upper()
        # HALKA_ACIK = open to the public; OZEL = private site we must not show.
        if service and "HALKA" not in service:
            continue
        lat = to_float(first(r, "enlem", "LATITUDE", "latitude"))
        lng = to_float(first(r, "boylam", "LONGITUDE", "longitude"))
        if lat is None or lng is None or (lat == 0 and lng == 0):
            skipped += 1
            continue

        raw_brand = first(r, "marka", "markaAdi", "MARKA_TESCIL_BELGESI") or ""
        provider = display_name(raw_brand, tariffs)
        entry = tariffs.get(brand_key(raw_brand))

        conns, count, max_kw, any_dc = parse_sockets(
            first(r, "soketler", "soketListesi", "sockets"))
        # A few rows publish no socket list; keep the station (it exists and is
        # licensed) with an unknown rating rather than dropping it.
        kw = int(round(max_kw)) if max_kw else 0
        if not conns:
            conns = ["CCS2", "Type 2"] if any_dc else ["Type 2"]

        station_no = str(first(r, "sarjIstasyonuNo", "ISTASYON_NO") or "").strip()
        name = str(first(r, "sarjIstasyonuAdi", "AD") or "").strip() or provider
        address = first(r, "adres", "ADRES") or ""

        out.append({
            # "ŞRJ/2140" → "epdk_srj_2140" (fold first: a bare ASCII filter
            # would eat the Ş and leave a stray underscore).
            "id": f"epdk_{brand_key(station_no)}" if station_no
                  else f"epdk_{round(lat, 5)}_{round(lng, 5)}",
            "name": name,
            "lat": lat,
            "lng": lng,
            "power": f"{kw} kW" if kw else "—",
            "type": "Fast DC" if any_dc else "AC",
            "price": price_label(entry, any_dc),
            "price_note": price_note(entry, any_dc),
            "available_spots": f"{count} available",
            "total_spots": count,
            "city": parse_city(address),
            "provider": provider,
            "country": "Turkey",
            "connectors": conns,
            "live": False,          # EPDK publishes no real-time availability
            "last_updated": "",     # stamped at the end of the run
        })
    if skipped:
        print(f"EPDK: skipped {skipped} row(s) without coordinates")
    return out


# ── OCM top-up ────────────────────────────────────────────────────────────────
def fetch_ocm():
    """Every OCM charge point in Turkey, with the real operator name resolved
    from OCM's reference data (the app's own OCM path groups them all under
    'International' — here we can do better)."""
    ref = requests.get(f"{OCM_URL.replace('/poi/', '/referencedata/')}?output=json",
                       headers=OCM_HEADERS, timeout=120).json()
    operators = {o["ID"]: o["Title"] for o in ref.get("Operators", [])}

    rows, after_id = [], 0
    while len(rows) < 20000:
        res = requests.get(OCM_URL, headers=OCM_HEADERS, timeout=120, params={
            "countrycode": "TR", "maxresults": 1000, "compact": "true",
            "verbose": "false", "output": "json", "sortby": "id_asc",
            **({"greaterthanid": after_id} if after_id else {}),
        })
        res.raise_for_status()
        page = res.json()
        if not isinstance(page, list) or not page:
            break
        rows.extend(page)
        ids = [p.get("ID", 0) for p in page]
        if len(page) < 1000 or max(ids) <= after_id:
            break
        after_id = max(ids)
    print(f"OCM: {len(rows)} Turkish POIs")
    return rows, operators


# A Turkish per-kWh price: a number next to ₺/TL/TRY, or the words "kWh"/"kW".
_TR_PRICE_RE = re.compile(r"\d[\d.,]*\s*(₺|TL|TRY)|(₺|TL|TRY)\s*\d",
                          re.IGNORECASE)

OCM_CONNECTOR_TITLES = {
    "ccs2": "CCS2", "ccs1": "CCS1", "chademo": "CHAdeMO",
    "type2": "Type 2", "type1": "Type 1", "gbt": "GB/T", "nacs": "NACS",
}


def ocm_connector(title):
    t = (title or "").lower()
    if "ccs" in t and "type 1" in t:
        return "CCS1"
    if "ccs" in t or "combo" in t:
        return "CCS2"
    if "chademo" in t:
        return "CHAdeMO"
    if "gb" in t:
        return "GB/T"
    if "tesla" in t or "nacs" in t:
        return "NACS"
    if "type 2" in t or "mennekes" in t or "62196-2" in t:
        return "Type 2"
    if "type 1" in t or "j1772" in t:
        return "Type 1"
    return None


def map_ocm(rows, operators, tariffs):
    out = []
    for p in rows:
        ai = p.get("AddressInfo") or {}
        lat, lng = ai.get("Latitude"), ai.get("Longitude")
        if lat is None or lng is None:
            continue
        # A handful of OCM rows carry 0/0 placeholders, which would drop pins
        # into the Gulf of Guinea. Same guard the EPDK mapper uses.
        if float(lat) == 0 and float(lng) == 0:
            continue
        raw_brand = operators.get(p.get("OperatorID"), "")
        # OCM suffixes country to operator titles ("Eşarj (TR)"); strip it so the
        # brand matches the EPDK spelling and the tariff table.
        raw_brand = re.sub(r"\s*\([^)]*\)\s*$", "", raw_brand).strip()
        entry = tariffs.get(brand_key(raw_brand))
        # OCM often has no operator at all. An empty provider hides the chip in
        # the app, which beats labelling the station "Unknown".
        provider = display_name(raw_brand, tariffs) if raw_brand else ""

        conns, max_kw, any_dc, points = set(), 0.0, False, 0
        for c in (p.get("Connections") or []):
            if not isinstance(c, dict):
                continue
            label = ocm_connector(((c.get("ConnectionType") or {}) or {}).get("Title"))
            if label:
                conns.add(label)
            kw = to_float(c.get("PowerKW")) or 0
            max_kw = max(max_kw, kw)
            if c.get("CurrentTypeID") == 30 or kw >= 43:
                any_dc = True
            points += int(c.get("Quantity") or 0)
        total = p.get("NumberOfPoints") or points or len(p.get("Connections") or [])
        kw = int(round(max_kw)) if max_kw else 0

        # OCM's UsageCost is free text a contributor typed, and Turkish rows
        # carry leftovers from other countries ("0.00 jaarabonnement"). Only
        # accept it when it actually reads like a Turkish per-kWh price;
        # otherwise fall back to the operator's published tariff.
        cost = p.get("UsageCost")
        cost = cost.strip() if isinstance(cost, str) else ""
        usable_cost = bool(_TR_PRICE_RE.search(cost))
        price = cost if usable_cost else price_label(entry, any_dc)

        out.append({
            "id": f"ocm_{p.get('ID')}",
            "name": (ai.get("Title") or "Charging Station").strip(),
            "lat": float(lat),
            "lng": float(lng),
            "power": f"{kw} kW" if kw else "—",
            "type": "Fast DC" if any_dc else "AC",
            "price": price,
            # A usable cost straight from OCM is per-station and needs no
            # provenance line; a brand tariff we filled in does.
            "price_note": "" if usable_cost else price_note(entry, any_dc),
            "available_spots": f"{total} available",
            "total_spots": total,
            "city": (ai.get("Town") or ai.get("StateOrProvince") or "").strip(),
            "provider": provider,
            "country": "Turkey",
            "connectors": sort_connectors(conns) or (["CCS2", "CHAdeMO"] if any_dc
                                                     else ["Type 2"]),
            "live": False,
            "last_updated": "",
        })
    return out


# ── merge ─────────────────────────────────────────────────────────────────────
def merge(epdk, ocm):
    """EPDK wins; an OCM row is kept only when no EPDK station sits within
    DEDUPE_METERS. Uses a coarse lat/lng grid so this stays O(n)."""
    # ~0.0015° ≈ 165 m at Turkish latitudes: one cell per dedupe radius.
    cell = 0.0015
    grid = {}
    for s in epdk:
        key = (int(s["lat"] / cell), int(s["lng"] / cell))
        grid.setdefault(key, []).append(s)

    def near(lat, lng):
        cy, cx = int(lat / cell), int(lng / cell)
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                for s in grid.get((cy + dy, cx + dx), ()):
                    # equirectangular metres — plenty at this scale
                    dlat = (s["lat"] - lat) * 111_320
                    dlng = (s["lng"] - lng) * 111_320 * 0.75  # cos(41°) ≈ 0.75
                    if dlat * dlat + dlng * dlng <= DEDUPE_METERS ** 2:
                        return True
        return False

    extra = [s for s in ocm if not near(s["lat"], s["lng"])]
    print(f"OCM top-up: {len(extra)} station(s) not present in EPDK")
    return epdk + extra


def main():
    tariff_data, tariffs = load_tariffs()
    refresh_tariffs(tariffs)

    epdk_rows = fetch_epdk()
    stations = map_epdk(epdk_rows, tariffs)
    print(f"EPDK: {len(stations)} public station(s) mapped")

    try:
        ocm_rows, operators = fetch_ocm()
        stations = merge(stations, map_ocm(ocm_rows, operators, tariffs))
    except Exception as exc:                      # OCM is a bonus, never a blocker
        print("OCM top-up skipped:", exc)

    # Provider test rigs, same rule the Georgian pipeline uses.
    test_re = re.compile(r"\btest\b", re.IGNORECASE)
    before = len(stations)
    stations = [s for s in stations if not test_re.search(s["name"])]
    if before != len(stations):
        print(f"Dropped {before - len(stations)} test station(s)")

    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    for s in stations:
        s["last_updated"] = stamp

    priced = sum(1 for s in stations if s["price"])
    providers = len({s["provider"] for s in stations})
    print(f"✅ {len(stations)} stations, {providers} providers, "
          f"{priced} with a published tariff ({tariff_data['updated']})")

    out_path = os.path.join(HERE, "..", "build", "chargers_tr.json")
    if len(sys.argv) > 1:
        out_path = sys.argv[1]
    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(stations, f, ensure_ascii=False, separators=(",", ":"))
    print("wrote", os.path.abspath(out_path))


if __name__ == "__main__":
    main()
