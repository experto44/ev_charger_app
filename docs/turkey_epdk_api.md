# Turkey: EPDK charging-station registry

How GeoCharge gets Turkish chargers, why the source is EPDK rather than Open
Charge Map, and what is known about the endpoints. Written 2026-08-06.

## Why EPDK

Every publicly usable charging station in Turkey must hold a **şarj ağı
işletmeci lisansı** from EPDK (Enerji Piyasası Düzenleme Kurumu, the energy
regulator) and appear in its registry. That makes the registry both
authoritative and far more complete than the alternatives:

| Source | Turkish stations | Provider name | Tariff | Live status |
|---|---|---|---|---|
| Open Charge Map | 2,110 (measured 2026-08-06) | yes, via `OperatorID` | 236 of 2,110 | no |
| **EPDK registry** | **~9,600+ public locations** | yes (`marka`) | no | no |

For scale: the EPDK extract for **İstanbul alone** is 2,963 stations and 38,950
sockets, of which 2,029 stations are `HALKA_ACIK` (open to the public) and 904
are `OZEL` (private sites a driver cannot use — we filter those out).

Neither source publishes real-time availability, which is why every Turkish
station is emitted with `live: false`; see "Live status" below.

## Endpoints

### Station list (what we use)

```
GET https://apigateway.epdk.gov.tr/sarjIstasyonlari
Content-Type: application/json
body: {}
```

Yes, a GET with a JSON body — that is what the published Swagger describes
(`https://apigateway.epdk.gov.tr/sarjIstasyonlari?swagger`). Documented filters:

```json
{"lisansNo":"?","sarjIstasyonuNo":"?","markaAdi":"?",
 "yesilSarjIstasyonuMu":"?","sarjIstasyonuAdi":"?","hizmetSekli":"?"}
```

Passing empty strings acts as a literal filter and returns `numRows: 0`; send
`{}` to get everything. Response envelope:

```json
{"statusCode":200,"columnNames":[...],"numRows":N,"result":[...]}
```

`columnNames`:
`sarjIstasyonuNo, sarjIstasyonuAdi, yesilSarjIstasyonuMu, hizmetSekli,`
`sarjAgiIsletmecisiUnvan, sarjAgiIsletmecisiLisansNo, sarjIstasyonuIsletmecisi,`
`marka, olumluGorusVerenDagitimSirketiLisansNo,`
`olumluGorusVerenDagitimSirketiLisansUnvani, dagitimSirketiOlumluGorusBelgeNumarasi,`
`soketler, adres, enlem, boylam`

### ⚠ Quota

The gateway is Apinizer and enforces a **per-IP quota with a long window**. In
testing, the first call succeeded and every call afterwards returned:

```
HTTP 429  {"faultCode":"ERR-227","faultString":"Because of reaching QUOTA limit, message is BLOCKED!"}
```

…and stayed blocked for well over 35 minutes. No quota headers are exposed. So:

* issue **one** unfiltered call per run, never a per-brand fan-out;
* retry patiently rather than hammering (`build_turkey.py` waits up to 90 min);
* run the job **daily at most** — the registry changes over weeks.

### Operator licences

```
GET https://apigateway.epdk.gov.tr/sarjAgiIsletmeciLisansiSorgula
body: {"lisansNo":"?","lisansDurumu":["?"],"unvan":"?", ...}
```

Same gateway, same quota. Not currently used.

### Related, for reference

* **Public web form** (no quota, JSF/PrimeFaces, needs a ViewState POST and
  paginates province by province) —
  `https://lisans.epdk.gov.tr/epvys-web/faces/pages/lisans/elektrikSarjAgiIsletmeci/sarjIstasyonuOzetSorgula.xhtml`
  This is the fallback if the REST quota ever becomes unusable.
* **Legacy REST** (now 404, superseded by the gateway) —
  `https://lisansws.epdk.gov.tr/epvys-web/rest/sarjIstasyonlariRest/sarjIstasyonlariSorgulaPublic`
  and `.../sarjIstasyonuSoketleriSorgulaPublic`.
* **İstanbul open-data mirror** of that legacy service, last refreshed
  2025-05-13 — useful as a fixture for testing the mapper offline:
  <https://data.ibb.gov.tr/dataset/elektrikli-arac-sarj-istasyonlari-verisi>
  (stations, GeoJSON) and `…/elektrikli-arac-sarj-istasyonlari-soket-verileri`
  (sockets, CSV).
* **Şarj@TR**, EPDK's own consumer app, does show live availability and prices,
  but its backend (`sarjtr.epdk.gov.tr`) sits behind a WAF that 403s everything
  that isn't the app. We do not try to get around it.

## Field notes

* `hizmetSekli` — `HALKA_ACIK` (public) or `OZEL` (private). **Filter to public.**
* `marka` — the registered trademark, free text exactly as filed: `zes`,
  `VOLTRUN`, `eşarj`, `SHARZ.NET`, and occasionally a full company name. The
  builder folds it to an ASCII key and maps it to a display name.
* `soketler` — socket rows. Vocabulary observed in the İstanbul extract:
  `SOKET_TURU` ∈ {`AC_TYPE2` (23,765), `DC_CCS` (15,032), `DC_CHADEMO` (153)},
  `SOKET_TIPI` ∈ {`AC`, `DC`}, `SOKET_GUCU` in kW (commonest: 22, 180, 120, 11, 60).
* `adres` — free text ending `İlçe / İL`; the builder takes the province as the
  city label.
* One "station" is a **site**, not a plug: İstanbul averages ~13 sockets per
  registered station.

## Tariffs

EPDK does not publish prices, so `tools/tr_tariffs.json` holds a brand-level
table (Turkish operators publish one national tariff per socket class, so this
is accurate for the great majority of stations) and `build_turkey.py` refreshes
it on every run from the dated public index at
<https://www.doviz.com/ev-sarj-fiyatlari>, falling back to the committed values
if the fetch or parse fails.

Rules that keep this honest:

* an operator with several tariffs gets a **range** (`12,99 - 16,49 ₺/kWh`),
  never an invented single figure;
* a brand with no verified figure gets **no price at all**;
* the index renders a few operators in kuruş (`₺1.099,00` meaning 10.99 ₺), so
  every parsed value is sanity-checked and rescaled or dropped;
* each station carries `price_note` — e.g. `ZES published tariff · checked
  07.08.2026` — which the app shows under the price, so it never reads as a
  live per-station quote.

Cross-check source, operator-published and reachable without auth:
`https://cms.esarj.com/api/pricing/tariffs` (Eşarj; AC 9.90, DC 13.50 TRY/kWh
as of 2026-01-31). Most operator sites are SPAs and several (zes.net) refuse
connections from non-Turkish/datacentre IPs, which is why per-operator scraping
is not the primary path.

## Live status

Not available from any public Turkish source we found, so Turkish stations set
`live: false`. In the app that means a slate pin instead of green, the plug
count instead of "N plugs available", and no "charger freed up" alerts. If we
ever want real-time Turkish availability it has to come from the individual
operator apps (ZES, Eşarj, Trugo), one integration at a time.

## Pipeline

* `tools/build_turkey.py` → `chargers_tr.json` (EPDK backbone + OCM top-up for
  anything EPDK doesn't list, deduped at 150 m).
* `.github/workflows/update_turkey.yml` — daily at 02:20 UTC, PATCHes
  `chargers_tr.json` in its **own** gist
  (`8cb62fc7ad6d86e3172eec6aedd4dba6`), not the Georgian one. Two reasons:
  drivers who never look at Turkey never download it, and `update_gist.yml`
  re-sends every other file it finds in its gist on each 5-minute patch — since
  GitHub truncates file content over 1 MB when reading a gist, a shared gist
  would let that job write a truncated Turkish file back over the good one.
  **It must never push a commit to `main`**: that would reach Codemagic through
  the webhook and start a billed iOS build (see CLAUDE.md).
* `lib/turkey_service.dart` — lazily downloads that file the first time the user
  looks at Turkey, then serves it from a 3-day disk cache.
