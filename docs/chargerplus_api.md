# Charger Plus — EV Charger API (reverse-engineered)

Source: **Charger Plus** Android app, package `com.chargerplus.app`.

| Build | Backend | Notes |
|-------|---------|-------|
| **3.0.6 (build 18)** — *current, live on Play Store* (pulled from device via adb) | own stack: `api.chargerpl.us` + `restapi.chargerpl.us` + **`wss://ws.chargerpl.us`** | Flutter, Google Maps. **This is what we integrate.** |
| 2.0.1 (build 213) — *old APKPure XAPK* | Sitronics Electro (`ezs.sitronics.com`) | A short-lived white-label detour, **abandoned**. See appendix. |

> **Purpose:** integrate Charger Plus's **public** Georgian stations (locations, connector types,
> live status) into our app. The live map is public over a WebSocket — no account needed.

---

## 1. Architecture (v3.0.6)

| Host | Role | Auth |
|------|------|------|
| **`wss://ws.chargerpl.us/`** | **Live map + station data** (custom JSON-over-WebSocket) | none for the public snapshot; account Bearer for richer detail |
| `api.chargerpl.us` (Node/Express) | Login (email OTP + Google/Apple), account, payments | Bearer |
| `restapi.chargerpl.us` (Laravel) | Payment `/bog/*` web-views; `/v1/stations` exists but is a **separate auth realm** (rejects the api token) | — |

The map is driven entirely by the WebSocket. `restapi.chargerpl.us/v1/stations` is **not** usable
(its 401 is a different token realm), and there is **no** public REST station list.

---

## 2. Live map — WebSocket `wss://ws.chargerpl.us/` (PUBLIC, tested ✅)

Custom protocol, JSON frames (records may be `\x1e`-separated). Connect with a normal WS upgrade
(no auth) and the server **pushes one snapshot, then closes**:

```jsonc
{
  "action": "connection",
  "status": "ERR", "message": "Unauthorized",   // = no *account* session; snapshot still sent
  "data": [
    { "id": 105, "status": "Online",             // Online | Offline
      "latitude": "41.001987", "longitude": "41.009346",
      "power": 7000,                             // watts
      "pool_id": null,
      "connectors": [ { "status": "Available" } ] }   // Available|Charging|Faulted|NoError (no type)
    // …
  ]
}
```
**Captured live (2026-07-02): 57 stations, 56 in Georgia** (1 test point in Saudi Arabia — filter
by bbox). Power tiers: 120 kW ×39 (DC), 22 kW ×11, 7 kW ×5, 14 kW ×1. 1–2 connectors each.

This snapshot is all the scraper needs: **location + power + live per-connector status**.
Dependency-free client (raw `socket`+`ssl`) is in `update_gist.yml → fetch_chargerplus()`.

### Authenticated actions (account Bearer as a WS connect header — optional)
Send `Authorization: Bearer <token>` in the WS upgrade → `status:"OK","Connected"` and the socket
stays open for these actions (`{"action": "...", ...}`):

| Action | Returns |
|--------|---------|
| `getStationPools` | Sites/pools: `{id, name, type:"fast"/"slow", max_power_kw, station_list:[ids]}` — **real site names** (e.g. "Kakheti Hwy 147", "Rikoti", "Zugdidi"). |
| `getStationDetails` (`station_id` top-level) | Supplementary: `{work_time, address_description, photos, size}`. |
| `getStationList` | The account's `{all, favorite}` lists. |
| `stationInfo` / `subscribe` | Subscribes to live changes; the server then streams `updateStations` frames = **full station cores** `{id, station_number, address, type, connectors:[{connector_number, connector_type, status}]}` as stations change. Connector types seen: `GB/T(DC)`, `CCS/2`, `Type 2`. |

> There is **no on-demand bulk "full catalog"** action — `getStations`/`getMaps` returned empty for
> every parameter shape tried. Full cores (address + connector types) only arrive via the
> `updateStations` live-change stream, so they can't be dumped in one call. We therefore **derive**
> connector types from power (below), validated against the cores we did capture (#9711, #9738 →
> both GB/T(DC)+CCS/2 on 120 kW DC). `getStationPools` site names are bundled into the scraper.

### Getting an account token (`api.chargerpl.us`, email OTP)
```
POST /v1/auth/signin/client  {"email":"you@x.com"}              → 206, emails a 5-digit code
POST /v1/auth/signin/client  {"email":"you@x.com","code":"NNNNN"} → 200 {"data":{"token":"<JWT>"}}
```
Also `/v1/oauth/signin/google`, `/v1/oauth/signin/apple`. The JWT is long-lived. Only needed to
refresh the bundled `getStationPools` site-name map — **not** needed at scrape time.

---

## 3. Data model / enums

- Station `status`: `Online`, `Offline`.
- Connector `status` (snapshot): `Available`, `Charging`, `Faulted`, `NoError` (idle/OK).
- Connector `connector_type` (station cores): `GB/T(DC)`, `GB/T(AC)`, `CCS/2`, `Type 2`.
- Pool/station `type`: `fast` (DC) / `slow` (AC). We map `power ≥ 50 kW → Fast DC`, else `AC`.
- Charger Plus runs a homogeneous fleet: **DC sites = GB/T(DC) + CCS/2**, **AC sites = Type 2**
  (matches the app's own map filter chips `showGbtDC / showCcs2 / showGbtAC`).

---

## 4. Integration (shipped)

`fetch_chargerplus()` was added to `.github/workflows/update_gist.yml` (registered in the provider
merge loop as `"Charger Plus"`). It:
1. Opens `wss://ws.chargerpl.us/` with a stdlib-only WS client (no extra pip deps), reads the
   public snapshot, filters to Georgia.
2. Emits our standard station schema: live `available_spots`, `power`, `type` (Fast DC/AC),
   `connectors`/`ports` derived per §3, and real site names for the pooled highway stations
   (bundled `POOL_NAMES`; generic `Charger Plus #<id>` for standalone Tbilisi sites).

Verified output: **56 Georgian stations** — 39 Fast DC (CCS2 + GB/T), 17 AC (Type 2), live
availability, 17 with real site names. Snapshot saved to `docs/chargerplus_ge_stations_sample.json`.

Future refinement (optional): run the authed `updateStations` stream over a long window to bundle
real per-station addresses + exact connector types, replacing the power-based derivation.

---

## Appendix — old 2.0.1 (Sitronics) build (historical, not used)

The 2.0.1 APKPure build was a Sitronics Electro white-label:
`GET https://ezs.sitronics.com/api/bff/v1/MapData/compressed`, header
`MobileAppId: 44444444-4f16-4838-afca-e6357128a912`. On production that tenant served the amperion
Russia+Armenia network (0 Georgian stations); Georgian data existed only on the Sitronics stage
server, offline. **The current 3.0.6 app dropped Sitronics entirely** and returned to the native
`chargerpl.us` stack above, so this path is not used.
