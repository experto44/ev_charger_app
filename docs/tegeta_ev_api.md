# Tegeta Motors — EV Charger API (reverse-engineered)

Source: `Tegeta Motors` Android app, package `ge.tegetamotors.app`, version **2.3.3 (5)**
(extracted from `Tegeta+Motors_2.3.3_APKPure.xapk`).

The app is native Kotlin / Jetpack Compose. Networking is **Ktorfit/Ktor** (Retrofit-style
interface `feature.chargers.data.api.ChargerApiService`). Live connector status is delivered
through **Cloud Firestore**, not REST.

> **Purpose of this doc:** integrate Tegeta's public EV charging stations (locations, connector
> types, live status) into our own EV charger app. Only the *public catalog + live status* is
> needed for that; the customer-scoped endpoints (reservations, transactions, favourites, fines)
> are documented for completeness but require a logged-in Tegeta account.

---

## 1. Architecture overview

There are **two** data sources working together:

| Layer | Transport | Role |
|-------|-----------|------|
| **REST API** (`mobileapi.tegetamotors.ge`) | HTTPS / JSON | Static catalog: station locations, connector types, prices, filters, amenities. Also customer actions. |
| **Cloud Firestore** (`tegeta-app-prod`) | Firestore realtime listeners | **Live status** of each charge-point / connector (Available / Charging / …), plus live reservation & transaction progress. |

Flow the app uses:
1. `GET /api/v1/EVs/Common/LastUpdateDate` → decide whether the local catalog cache is stale.
2. `GET /api/v1/EVs/ChargeStations` → full station + connector catalog (rendered on the map).
3. Subscribe to Firestore charge-point documents → overlay live `status` onto each connector.

For **our integration** the important pieces are steps 1–3. Steps that need auth are optional.

---

## 2. REST API

### 2.1 Base URL & headers

```
Base URL:  https://mobileapi.tegetamotors.ge/
```

- **Auth:** OAuth. The session layer stores an access token
  (`getStoredAccessTokenAsBearerToken`) obtained from `https://account.tegetamotors.ge/`.
  Customer-scoped endpoints send `Authorization: Bearer <token>`.
  The **catalog endpoints** (`ChargeStations`, `Common/ConnectorFilters`,
  `Common/LastUpdateDate`) are used to draw the public map before login and do **not** appear to
  require a user token — verify with a live request during integration.
- Responses are JSON. Many endpoints wrap payloads in a base envelope
  (`{ "data": …, "errorCode": …, "errorMessage": … }`); catalog list endpoints return the
  object/array directly. Confirm per-endpoint against the live server.

### 2.2 Endpoint reference (EV / chargers)

Interface: `feature.chargers.data.api.ChargerApiService`.
Verb legend recovered from the minified annotations: `GET`, `POST`, `DELETE`.

| # | Method | Verb | Path | Params | Returns | Auth |
|---|--------|------|------|--------|---------|------|
| 1 | `getLastUpdateDate` | GET | `/api/v1/EVs/Common/LastUpdateDate` | — | `LastUpdateDateDTO` | public |
| 2 | `getChargerStations` | GET | `/api/v1/EVs/ChargeStations` | — (returns **all** stations) | `List<ChargerStationDTO>` | public |
| 3 | `getConnectorFilters` | GET | `/api/v1/EVs/Common/ConnectorFilters` | — | `ConnectorFiltersDTO` | public |
| 4 | `getCurrentActivity` | GET | `/api/v1/EVs/CurrentActivity` | — | `CurrentActivityDTO` | Bearer |
| 5 | `getChargingHistory` | GET | `/api/v1/EVs/ChargingHistory` | query: `dateFrom`, `dateTo`, `pageSize`, `pageNumber` | `ChargingHistoryDTO` | Bearer |
| 6 | `getFavourites` | GET | `/api/v1/EVs/Customers/FavoriteStations` | — | `FavouriteStationsDTO` | Bearer |
| 7 | `addFavourite` | POST | `/api/v1/EVs/Customers/FavoriteStations/{chargeStationId}` | path: `chargeStationId` | — | Bearer |
| 8 | `removeFavourite` | DELETE | `/api/v1/EVs/Customers/FavoriteStations/{chargeStationId}` | path: `chargeStationId` | — | Bearer |
| 9 | `getFineDetails` | GET | `/api/v1/EVs/Customers/Fines` | — | `FineDetailsDTO` | Bearer |
| 10 | `payDebts` | POST | `/api/v1/EVs/Customer/PayDebts` | body: `PayDebtBody` | — | Bearer |
| 11 | `startReservation` | POST | `/api/v1/EVs/Connectors/{connectorId}/Reserve` | path: `connectorId` | `ReservationDTO` | Bearer |
| 12 | `cancelReservation` | POST | `/api/v1/EVs/Reservations/{reservationId}/Cancel` | path: `reservationId` | — | Bearer |
| 13 | `startTransaction` | POST | `/api/v1/EVs/Connectors/{connectorId}/StartTransaction` | path: `connectorId`, body: `BillingTypeBody` | — | Bearer |
| 14 | `stopTransaction` | POST | `/api/v1/EVs/Transactions/{transactionId}/Stop` | path: `transactionId` | — | Bearer |

> Note: `addFavourite` and `removeFavourite` share the same path; the app distinguishes them by
> HTTP verb (POST vs DELETE).

### 2.3 Related non-EV endpoint (fuel stations, for reference)

The same server exposes fuel stations, which the app also plots on a map:
`GET api/v1/Fuels/stations`, `GET api/v1/Fuels/stations/{stationId}`,
`GET api/v1/Fuels/providers`, `GET api/v1/Fuels/lowestPrices`. Not part of the EV feature.

---

## 3. Data models (REST DTOs)

Recovered directly from the DEX field tables. `List` element types are inferred from usage where
the generic parameter isn't preserved in bytecode.

### 3.1 Station catalog

```
ChargerStationDTO
├─ id: Long
├─ nameTranslations: List<TranslationDTO>
├─ addressTranslations: List<TranslationDTO>
├─ city: BaseNameDTO
├─ latitude: Double
├─ longitude: Double
├─ isDeactivated: Boolean
├─ images: List<StationImageDTO>
├─ amenities: List<AmenityDTO>
└─ chargePoints: List<ChargePointDTO>

ChargePointDTO                 // a physical charger unit at a station
├─ id: String                  // chargePointId — the key used by Firestore live status
├─ type: BaseNameDTO           // e.g. AC / DC power class
├─ isDeactivated: Boolean
└─ connectors: List<ConnectorDTO>

ConnectorDTO                   // a single plug/socket on a charge point
├─ id: String                  // connectorId — used for Reserve / StartTransaction
├─ connectorName: String
├─ connectorOrderId: Int
├─ connectorType: ConnectorTypeDTO
├─ price: BigDecimal
├─ fineAmount: BigDecimal      // idle/overstay penalty
└─ freeReservationTime: Int    // minutes reservation is held free
        // NOTE: no live "status" here — status comes from Firestore (§4).

StationImageDTO { image: String (url), type: String, order: Int }
AmenityDTO      { id: Long, nameTranslations: List<TranslationDTO>, images: List<ImageDTO>, order: Int }
```

### 3.2 Connector types & filters

```
ConnectorTypeDTO
├─ id: Long
├─ typeTranslations: List<TranslationDTO>          // localized connector-type name
├─ nameTranslations: List<TranslationDTO>
├─ descriptionTranslations: List<TranslationDTO>
├─ images: List<ImageDTO>
└─ banners: List<…>

ConnectorFiltersDTO
├─ cities: List<BaseNameDTO>
└─ connectorTypesFilters: List<ConnectorTypesFilterDTO>

ConnectorTypesFilterDTO
├─ connectorType: ConnectorTypeDTO
└─ powerOutputType: BaseNameDTO                     // e.g. AC / DC, kW class
```

Known connector-type tokens present in the binary (OCPP-style):
`EV_CONNECTOR_TYPE_UNSPECIFIED_GB_T`, `EV_CONNECTOR_TYPE_UNSPECIFIED_WALL_OUTLET`,
plus CCS / CHAdeMO / Type2 families implied by the type translations. Read the real list from
`GET /api/v1/EVs/Common/ConnectorFilters` at runtime.

### 3.3 Shared / localization models

```
TranslationDTO { language: String, translation: String }   // e.g. {"language":"ka","translation":"..."}
BaseNameDTO    { id: Long, nameTranslations: List<TranslationDTO> }
ImageDTO       { image | imageUrl: String }
LastUpdateDateDTO { lastUpdateDate: String }               // ISO timestamp for cache invalidation
```

### 3.4 Customer / session models

```
CurrentActivityDTO   { connectorId: String, customerActivityType: String, debtAmount: BigDecimal, isCardRequired: Boolean }
ChargingHistoryDTO   { count: Int, pageNumber: Int, pageSize: Int, hasNextPage: Boolean, data: List<ChargingHistoryDataItem> }
ChargingHistoryDataItem { stationName: List<TranslationDTO>, stationAddress: List<TranslationDTO>,
                          connectorTypeName: List<TranslationDTO>, startTime: String, duration: Int,
                          price: BigDecimal, sum: BigDecimal, penalty: BigDecimal, totalExpense: BigDecimal }
ReservationDTO       { reservationId: Long, connectorId: Long }
FavouriteStationsDTO { idTag: String, chargeStationIds: List<Long> }
ChargeStationIdDTO   { chargeStationId: Int }
FineDetailsDTO       { type: String, amount: BigDecimal, date: String, nameTranslations: List<TranslationDTO> }

// Request bodies
BillingTypeBody { billingType: String, cardId: String, fixedAmount: BigDecimal }
PayDebtBody     { cardId: String }
```

`billingType` selects how a charging session is billed (e.g. charge to full vs a fixed amount —
`fixedAmount` is used with the fixed option).

---

## 4. Live status — Cloud Firestore

The realtime status shown on the map (Available / Charging / Reserved / …) is **not** in the REST
response. The app subscribes to Firestore (`chargersFirebaseManager`, method
`subscribeFireBaseManagerChargers`) and merges the live `status` into each connector.

### 4.1 Firebase project config (from `resources.arsc`)

| Field | Value |
|-------|-------|
| `project_id` | `tegeta-app-prod` |
| `storage_bucket` | `tegeta-app-prod.firebasestorage.app` |
| `gcm_defaultSenderId` / project number | `462018893485` |
| Android `app_id` | `462018893485:android:725e028a77085b0f98d824` |
| `google_api_key` | `AIzaSyAjyKySWY5iv0mxjxcFIKdrDA3_7Va9W8c` |

(These ship in every copy of the APK; they are client identifiers, not private secrets. Firestore
access is governed by the project's security rules — test whether anonymous/unauthenticated reads
of the charge-point collection are permitted.)

### 4.2 Firestore document shapes

Collection holds one document per **charge point**, keyed by `chargePointId` (the `ChargePointDTO.id`
from REST). Collection name is most likely `chargePoints` — confirm against the live project.

```
ChargerPointDocument
├─ chargePointId: String
└─ chargePointDetail: ChargerPointDetailDocument
        ├─ chargeStationId: Int
        ├─ status: String                       // charge-point level status
        └─ connectors: List<ChargerPointConnectorDocument>

ChargerPointConnectorDocument
├─ connectorId: String
├─ status: String                                // <-- LIVE connector status (drives the map pin)
├─ price: BigDecimal
├─ fineAmount: BigDecimal
├─ freeReservationTime: Int
├─ reservation: ReservationDocument              // present when connector is reserved
└─ transaction: TransactionDocument              // present while charging

ReservationDocument
├─ id: Long,  connectorId: Long,  transactionId: Long
├─ idTag: String
├─ status: String
├─ expiryDate: String,  timestamp: String,  expired: Boolean

TransactionDocument                              // live charging session progress
├─ id: Long,  idTag: String
├─ billingType: String
├─ currentPercent: Double                         // battery %
├─ currentWH: BigDecimal                          // energy delivered
├─ currentPrice: BigDecimal
├─ meterStart: Int,  meterStop: Int
├─ fixedAmount / fineAmount / maxFineAmount: BigDecimal
├─ freeParkingTime: Int
└─ finished: Boolean
```

### 4.3 Status values

`status` is a plain `String` (no enum in bytecode). Status tokens present in the binary
(OCPP 1.6 connector-status vocabulary):

```
Available   Preparing   Charging   Finishing   Reserved
Occupied    Unavailable Faulted    Connected   Disconnected
Pending     Active      Completed
```

Map these to your own availability model, e.g.:
- **Available** → free/usable
- **Preparing / Charging / Finishing / Occupied** → in use
- **Reserved** → reserved
- **Unavailable / Faulted / Offline** → not usable

---

## 5. Integration recipe (for our EV charger app)

To ingest Tegeta's public chargers:

1. **Catalog** — `GET https://mobileapi.tegetamotors.ge/api/v1/EVs/ChargeStations`.
   Parse `ChargerStationDTO[]`. For each station take `id`, `latitude`, `longitude`,
   localized name/address (`nameTranslations`/`addressTranslations`, pick `language == "ka"` or
   `"en"`), and iterate `chargePoints[].connectors[]` for connector type, price, and
   `connectorId`.
2. **Filters (optional)** — `GET /api/v1/EVs/Common/ConnectorFilters` for the canonical connector
   type + power-output taxonomy to normalize against ours.
3. **Cache invalidation** — poll `GET /api/v1/EVs/Common/LastUpdateDate` and only re-pull the
   catalog when `lastUpdateDate` changes.
4. **Live status** — connect to Firestore project `tegeta-app-prod`, listen to the charge-point
   collection, and join `ChargerPointConnectorDocument.status` onto each `connectorId` from step 1.
   If unauthenticated Firestore reads are blocked by security rules, live status won't be available
   without a session; the static catalog still works.

### First things to verify against the live server
- Whether `ChargeStations` / `ConnectorFilters` / `LastUpdateDate` respond **without** a Bearer
  token (expected: yes, they render the pre-login map).
- The exact Firestore collection name and whether its rules allow anonymous reads.
- The precise response envelope (raw array vs `{data, errorCode, errorMessage}`) per endpoint.

---

## 6. Appendix — how this was extracted

- Unpacked the XAPK → `ge.tegetamotors.app.apk` (base split) + config splits.
- Parsed the 5 `classes*.dex` directly (no decompiler available): custom Python readers over the
  DEX `string_ids`, `type_ids`, `field_ids`, `method_ids`, `class_defs`, and the annotation
  directories.
- Endpoint paths + verbs came from the (minified) Ktorfit method/parameter annotations on
  `ChargerApiService`; data models came from the class field tables; Firebase config came from
  `resources.arsc`.
- Everything here reflects app version **2.3.3** and should be re-validated against live traffic
  before relying on it.
