# PROJECT1 — Jaspr Geometry + R09 Report: proposed bounded work order

**For:** Master / Jaspr UI engineer, with FRG / report reviewer. **Not authorisation to edit the production repo.**

## Goal

Integrate the already researched geographic *presentation* with the future R01–R12 entrepreneur report without duplicating the teammate's rental selection, without generating fabricated competitors, and without redoing geographic research.

## Existing evidence to reuse

- ODR3_DECISION_DELTA_20261030 — four ODR-3 decisions, twenty synthetic executions, D-1/F-2 and F-3/F-4 disclosures.
- GM_12_COMPETITOR_ABSENCE_STATES — seven states, R-19/R-20/R-21, S1–S5 digit-free rule, UI-01 unresolved.
- Existing Flutter `MAP_PROTOTYPE_01` source — research reference only, **not** a Jaspr component or integrated app.
- Teammate rental selection — Owner-reported existing, contract not handed over; do **not** rebuild it.

## Exact proposed work, after bounded authorisation

1. Confirm the Jaspr runtime/version and keep existing public website separate from the private entrepreneur assessment surface.
2. Add a Jaspr `GeographicContextPanel` and `ReportR09Section` using **prepared, versioned claim data**; use a distinct accessible provenance panel. Preserve report candidate identity, report status and source limitations.
3. Render an OSM basemap via Leaflet with attribution, a rental marker only when the rental service says the location class and provenance permit it; draw no reportable circle when ODR-3a is unset.
4. Add pure Dart geography methods for the **approved** haversine, R constraint and explicitly adopted boundary policy; never silently clamp.
5. Keep the competitor layer S1 until a valid authorised venue snapshot is supplied; never infer business counts from OSM map labels or a map tile.
6. Include a read-only rental selection adapter **interface proposal**, not actual tenant-account code, until the teammate's contract and identity checks arrive.
7. Reuse future one-time venue data snapshots only after ODR-4 and H-F are resolved; query the local snapshot per candidate, no Maps call per assessment.
8. Prepare and test keyboard/semantic linkage, mobile layout, absence/status safeguards and report R01/R09/R12 interplay. All real integration changes require their own signed build and test permissions.

## Stop conditions

No authorised Jaspr build scope; no approved report/geometry contract; attempt to use a scraped venue source without permissions; any inferred centre, fabricated date, hardcoded actual competitor count, property ranking or report suitability verdict.

## Expected handback

`GEO-JASPR-01` reviewed source pin and build output; `GEO-JASPR-02` screenshot/accessibility evidence; `GEO-JASPR-03` geometry unit and boundary controls; `GEO-JASPR-04` rental adapter contract; `GEO-JASPR-05` R09/R12 report sample and no-data negative controls; `GEO-JASPR-06` remaining gates/decisions. All status words must distinguish executed, synthetic and blocked.
