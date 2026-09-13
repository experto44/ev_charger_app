# ZZZ / Keystone charger API

Reverse-engineered notes for the **ZZZ app** (`com.keystone.zzzapp`, iOS
`id6757087242`), a Georgian charging network that runs its own OCPP backend.
We integrate it as the provider **`ZZZ`** in `chargers.json`.

- **App**: React Native / Expo (Hermes bytecode), v1.0.3.
- **Backend**: `https://client.keystone.ge` (NestJS).
- **Swagger is public**: UI at `/api`, full OpenAPI at `/api-json` (146 routes).
- **Realtime**: socket.io on the same host (`/socket.io/`), handshake is open.
  We do NOT use it — the REST `status` field already carries live state and our
  gist pipeline polls every few minutes.

## Auth

The charge-point list is JWT-gated (no public app key, unlike E-Space). We use a
dedicated read-only **service account** and log in each cycle for a fresh token.

```
POST /auth/login   {"username": "<email or phone>", "password": "<pw>"}
  -> 200 {"accessToken": "<JWT>"}          # HS256, aud/iss "keystone_charger"
```

The JWT lives ~14 days, but the fetcher re-logs in every run anyway. Credentials
live in GitHub Actions secrets **`KEYSTONE_USERNAME`** / **`KEYSTONE_PASSWORD`**.
`POST /auth/register` (firstName, lastName, email, phoneNumber, password) returns
a token immediately with **no SMS step**, but account creation is a human action.

## Station list

```
GET /client/chargepoints        Authorization: Bearer <JWT>
  -> 200 [ ChargePoint, ... ]    # the WHOLE network, live
```

Reference-data routes that happen to be open (no token): `/client/connector-types`,
`/client/charge-point-connector-types`, `/client/app-control?queryVersion=&queryPlatform=`.

### ChargePoint shape (fields we read)

| field             | notes                                                        |
|-------------------|-------------------------------------------------------------|
| `id`              | stable int PK → our id `keystone_<id>`                       |
| `description`/`address` | Georgian; used as the station name / city derivation   |
| `latitude`/`longitude`  | **strings**, need `float()`                            |
| `maxPower`        | kW (station-level; connector `maxPower` is often `"0.00"`)   |
| `kilowattTariff`  | **tetri** integer: `80` → `0.80 ₾/kWh`                       |
| `parkingTariff`   | tetri/idle (not surfaced in the app)                         |
| `connectroTypes`  | `AC` / `DC` / `(AC/DC) Mixed` (note the backend's typo)      |
| `status`          | OCPP station status (see below)                              |
| `isAvailable`     | station reachable                                            |
| `connectors[]`    | `{connectorId, type, status, isAvailable, maxPower, occupied}` |

### Enums

- **Connector `type`** → our chip label:
  `Type1/Type2 (AC)`→Type 1/Type 2 · `CCS1/CCS2 (DC)`→CCS1/CCS2 ·
  `CHAdeMO (DC)` & `CHAdeMO 2.0 (DC)`→CHAdeMO · `GB/T AC/DC (AC/DC)`→GB/T ·
  `NACS (AC/DC)` & `Tesla Proprietary (AC/DC)`→NACS · `Pantograph (DC)`→Pantograph.
- **OCPP `status`** → our live state:
  `Available`→**free** · `Preparing/Charging/SuspendedEVSE/SuspendedEV/Finishing/Reserved/Occupied`→**busy**
  (also `occupied:true`) · `Faulted/Unavailable`→**out**.
- The feed publishes no session start time, so `since` (how long a plug has been
  busy) is carried forward from the previous gist snapshot, like E-Space.

Photos: `photoUrl` is a path under the backend, e.g.
`https://client.keystone.ge/upload/charge-points/<file>` (we don't ship these).

## Integration points in this repo

- Scraper: `fetch_keystone()` in `.github/workflows/update_gist.yml`, added to
  the provider merge list as `("ZZZ")`.
- App: `'ZZZ'` in `_kAllProviders` (`lib/main.dart`); logo `zzz` →
  `assets/providers/zzz.png` in `lib/provider_logos.dart`.
- Tesla web: same logo entry in `tesla/js/format.js` +
  `tesla/assets/providers/zzz.png`.
- Bundled offline snapshot of the current stations in `assets/data/chargers.json`.
- New-station broadcast: the current ids were pre-seeded into the gist's
  `known_stations.json` so onboarding is silent; genuinely new ZZZ stations
  announce normally afterwards.

As of integration: **3 DC fast chargers in Tbilisi**, all 180 kW, CCS2 + GB/T,
0.80 ₾/kWh. New chargers the operator adds appear automatically.
