# Project1 — Proceed-now decision with three synthetic rental coordinates

**Status:** `SYNTHETIC_JASPR_INCREMENT_READY_FOR_LOCAL_COMPILATION`. **Not:** production implementation, real rental integration, adopted ODR-3a radius, accepted competitor evidence, H3/H0/BUILD/TEST approval.

## The corrected dependency decision

**Proceed immediately with the separate Jaspr prototype**. Three fixed coordinates are sufficient to test map rendering, three-point identification, selection highlighting, one experimental footprint, distance arithmetic, output states S1 and synthetic S3, report R01/R09/R12 structure, and front-end accessibility tests. Six additional **fake venue points** in `test/synthetic_venue_geometry_test.dart` exercise local spatial inclusion and overlap without importing real competitor records. They do **not** validate a real rental's identity, coordinate precision, licence, nearby businesses, or business conclusions.

The prior "wait for teammate" advice applied **only** to integrating live teammate rentals and certifying real candidate-specific reports, not to local synthetic development.

## Exactly three synthetic test coordinates

| Fixture ID | Latitude | Longitude | What it is |
|---|---:|---:|---|
| SYN-A | 3.1432 | 101.6892 | Arbitrary synthetic map centre A |
| SYN-B | 3.1502 | 101.6988 | Arbitrary synthetic map centre B |
| SYN-C | 3.1356 | 101.7022 | Arbitrary synthetic map centre C |

These points are plausible map positions in Kuala Lumpur but **are not claims that a specific rental, building entrance or café exists there**. Their “PREMISES” class and 1 m accuracy in the fixture are **test-only assumptions**, not certification or measured accuracy. The canonical source is `lib/synthetic_rentals.dart`.

### Independently calculated synthetic straight-line checks

| Pair | Haversine distance (Earth R=6,371,000 m) |
|---|---:|
| SYN-A–SYN-B | 1319.8 m |
| SYN-A–SYN-C | 1672.6 m |
| SYN-B–SYN-C | 1666.8 m |

These are point-to-point distances between **synthetic rentals**, not distances to competitors or walking routes.

## What to implement and test without teammate data

1. Verify installed Dart/Jaspr runtime and compile the previous scaffold plus three-point update using `dart pub get`, `dart test`, `jaspr serve` and `jaspr build`; log versions and exit codes. Previous package had NOT been compiled.
2. Run the six-venue synthetic inclusion/overlap tests separately; they are not production report data. Map shows all three clearly synthetic markers; selecting one highlights it and optionally draws a distinctly labelled experimental radius. The map must never imply these markers came from the teammate's catalogue.
3. Use pure Dart haversine, not Leaflet map pixels, for geometric membership. Never silently clamp `R`; reject invalid parameters. Exercise floating-point exact-boundary and test-only explicit tolerance.
4. Generate an **illustrative combined report** that shows selected synthetic rental references and explains each R09 as `S1` (no source) rather than making up venue counts. R01 locality label should be marked synthetic/unresolved; R12 provenance must explicitly say "NO_COMPETITOR_SNAPSHOT".
5. Render GM-12 S1–S5 bodies without count numerals; provenance dates in a separate accessible region. Do not claim the canonical F-3/F-4 conflicts are formally corrected by UI copy.
6. Validate three-point selection/identity, accessible label-to-qualifier linkage, responsive layout, keyboard navigation, report snapshot consistency, no competitor points, no live Maps/Places scraping.
7. Return compiled artefacts, test log and screenshots, with failures. If toolchain missing report `NOT_EXECUTED`, not `PASS`.

## What remains after this increment

- Actual teammate rental IDs, ownership and revisions; R-4 accuracy and R-8 provenance and coordinate eligibility. This is an **integration dependency**, not a synthetic-UI dependency.
- Adopt ODR-3a numeric study radius and geometric tolerance; 3b/3c/3d adoption and FRG authority; cannot convert experimental selection into a scientific claim.
- ODR-4 venue source permissions; H-F real data quality, dedup, taxonomy, coverage. Postponing these is compatible with a blank competitor layer, **not** with shipping counts.
- GM-12 canonical wording F-3/F-4 and widget-level `UI-01` must pass prior to report release. H3 formal acceptance and H0 academic scope are independent gates.
- Production integration approval is separate from permission to create an isolated synthetic prototype. If Owner wants a production modification, require a separate explicitly scoped work order.

## Technical caveat

OpenStreetMap **basemap tile display** is not the same as importing OpenStreetMap POIs. The OSMF tile usage policy requires attribution, normal on-screen viewport requests and no bulk offline tile downloading. The tile-source terms apply to the prototype even while ODR-4 competitor-source investigation is deferred.

## Four final boundaries

- No genuine rent amounts, scores, rankings, demand or competitor assertions.
- No new teammate rental-selection UI: these three selectable fixtures are a test-only control inside the standalone demonstrator, not BC-05 product functionality.
- No map tile labels are parsed or counted as competitors.
- No assumption that synthetic geometric successes close real-source, academic or production gates.
