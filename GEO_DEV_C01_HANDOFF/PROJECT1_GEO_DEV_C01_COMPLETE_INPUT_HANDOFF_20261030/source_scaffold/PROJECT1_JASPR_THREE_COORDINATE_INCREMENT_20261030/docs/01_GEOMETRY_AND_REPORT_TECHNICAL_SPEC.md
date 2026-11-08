# PROJECT1 — Geometry and Report Technical Specification (Jaspr proposal)

**Date:** 2026-10-30. **Authority:** working technical proposal, not Owner-adopted FRG / GM-12 contract, scientific release, or permission to implement in the production repository. **Source inputs:** `ODR3_DECISION_DELTA_20261030.md` SHA-256 `f37294da6de8cd93da6d180b712498a7efe4e95ae4c8d352fb4829aa76f8e9f3`; `GM_12_COMPETITOR_ABSENCE_STATES.md` SHA-256 `cbed0aecfa16c248fa4d59e79c267c86e6760fad0e43fc1be36643f20a883ce8`.

## 1. The two genuinely different data layers

| Layer | Selected display technology | Provenance | Status |
|---|---|---|---|
| Map background (roads, street labels, etc.) | Leaflet embedded in Jaspr; OpenStreetMap Carto raster tiles for an interactive *demo only* | © OpenStreetMap contributors; browser fetches visible tiles | **Map display only; no competitor source adopted** |
| Rental candidate markers | Teammate's stable rental IDs / location evidence (future adapter). This prototype contains *clearly fictional* examples. | Rental module, not OSM inferred facts | **Real adapter unbuilt** |
| Competitor records | Proposed separately versioned licensed OSM/Overture/other source dataset, once approved | Dataset snapshot ID, licence and rights, venue IDs, method and dates | **Deferred; no dataset loaded** |
| Geographic circles | Project1 deterministic haversine and explicit centre/accuracy/radius contract | ODR-3 policy and geometry version | **Synthetic demonstration only; numeric R undecided** |
| Report R09 | One claim/state block and a separate accessible provenance block | GM-12 S1–S7; ODR-V21A digit boundary and R12 metadata | **Synthetic report proposal only** |

**Crucial:** OpenStreetMap background map tiles do **not** constitute a licensed or complete competitor catalogue. Seeing cafés as labels on the basemap does **not** mean Project1 queried, verified or counted them. The demo never inspects map tiles for businesses.

## 2. Platform boundary

- **Frontend:** Jaspr **client-mode Dart** for this isolated demonstration. Leaflet 1.9.4 is a map *rendering library*, not Project1's geographic reasoning engine.
- **Geometry:** pure Dart functions, independent of Leaflet. `haversineMetres` uses mean Earth radius `6,371,000 m`. `withinCircle` uses an *explicit* tolerance parameter. `validateRadius` rejects radii outside `0 < R <= 5000 m`; no silent clamp.
- **Real backend:** the project's current .NET / ASP.NET Core direction should be confirmed by architecture authority; this package adds **no backend**, Spring Boot, Java, FastAPI, database or login.
- **Report:** a future approved report assembler will own R01–R12; the Jaspr page renders prepared claim states, not decisions or scientific calculations.
- **Rental selection:** teammate-owned. Jaspr report consumes future rental IDs and coordinate/provenance contract; does not add a competing rental catalogue.

## 3. ODR-3 adoption matrix

| ID | Decision currently supported | What Jaspr demo does | What remains open |
|---|---|---|---|
| ODR-3a | `NOT_DECIDABLE` numerical study radius | Preview buttons 400/500/800/1200 m visibly labelled experimental | Real centre + licensed dataset + method/Owner decision + entrepreneur-value comparison |
| ODR-3b | `RECOMMENDED` display radius equals study radius | Uses same numeric value when a synthetic preview circle is drawn | Owner contractual adoption |
| ODR-3c | `AREA_ONLY` ineligible; `LISTING_PIN` ineligible by default; `PREMISES`/`BUILDING` conditional | `classifyCentre` enforces conservative position rule | Teammate R-4 numeric accuracy, R-8 provenance, building entrance-offset bound, Owner grant |
| ODR-3d | descriptive recorded nearby venue observations only | No ranking, demand, suitability, catchment, walk time or market comparison | Owner contract adoption and report authority sign-off |

## 4. Geometry defect dispositions

- **D-1 (silent 5 km clamp):** the existing reused Python function would silently clamp a 6 km request to 5 km. This demonstrator rejects unsupported values explicitly; do not claim the existing Python component was fixed. A later integrated implementation must carry the same explicit refusal contract and test it.
- **F-2 (floating-point boundary):** edge location may be excluded due to ~3.6e-12 m numerical error. Demo shows the **candidate** `tolerance_m = 0.5 m` only as an *unadopted experiment*. Owner must adopt and publish a tolerance policy with the study radius and positional accuracy. A numerical epsilon does not resolve rental position uncertainty.
- **F-3 (forbidden copy conflict):** the frozen GM-12 prohibits a phrase that also appears inside negated canonical S4/S5 text. The demonstrator avoids the lexical phrase and retains the substantive meaning. Do not claim GM-12 itself has been amended.
- **F-4 (dates conflict):** S1–S5 prohibit digits within the status block, while canonical S4/S5 include dates. The demo separates source/date provenance entirely from status prose. Formal amendment and widget-level accessibility tests remain pending.

## 5. Report semantics (R01, R09, R12)

- **R01 area:** administrative locality/identity supplied by the rental module; separate from the circular search footprint.
- **R09:** per-rental source-state component; one of GM-12 `S1..S7`, selected using rights/query issued/source answered/coverage/completeness; **never infer S6 or zero from an empty array**.
- **R12:** versioned provenance: `queried_at`, `retrieved_at`, `source_as_of` (nullable), dataset snapshot/release, licence, rights, claim validity/limits. Source dates are outside digit-restricted R09 absence body under Owner-preferred Option B.
- **One report:** shared café findings emitted once; rental-specific geographic outcomes linked by stable candidate ID. No cross-rental numeric comparison unless `E1 ∧ E2 ∧ E3` is established and same licensed/dated/comparable data. Unknown coverage cannot become comparable merely because two areas are marked UNKNOWN.
- **Historical reports:** immutable issued snapshots, separate current-display rights check; rights withdrawal may hide protected records now without rewriting the issued report (display/retention policy pending).

## 6. Technical inputs for future integration

```json
{
  "assessment_id": "from authorised assessment service",
  "rental_id": "from teammate catalogue",
  "location": {"position_class":"PREMISES|BUILDING|LISTING_PIN|AREA_ONLY", "latitude":null, "longitude":null, "accuracy_m":null, "position_source":null, "coordinate_version":null, "entrance_offset_bound_m":null},
  "footprint": {"study_radius_m":null, "display_radius_m":null, "boundary_tolerance_m":null, "distance_method":"SPHERICAL_HAVERSINE_R6371000", "footprint_version":null},
  "venue_snapshot": {"snapshot_id":null, "source":null, "source_release":null, "queried_at":null, "retrieved_at":null, "source_as_of":null, "coverage_class":"UNKNOWN", "rights_state":"UNVERIFIED", "completeness_statement":null},
  "report": {"competitor_state":"S1", "claim_class":"UNAVAILABLE", "candidate_venue_links":[]}
}
```

The JSON above is a **proposed interface example**, not an approved JSON Schema or a representation of current teammate data.

## 7. Test obligations / release gates

| ID | Minimal observable contract | Status |
|---|---|---|
| GEO-D1 | Explicit refusal beyond 5000 m; no map/result mismatch | Dart test provided, **not executed** |
| GEO-F2 | Boundary tolerance is explicit and edge case stable | Dart test provided, **not executed** |
| GEO-POS | AREA_ONLY and unverified listing pin never draw precise circle | Dart test provided, **not executed** |
| GEO-GM12 | S1–S5 no digits in status body; S6 only with complete dated attestation; S7 only after source response | Dart tests provided, **not executed** |
| GEO-COMP | No cross-candidate count when source rights, geometry, coverage, freshness differ | Dart test provided, **not executed** |
| GEO-UI | Accessible state + qualifier inseparable, provenance visible, keyboard interactions, mobile layout | **Not executed** (H3F-01 remains) |
| GEO-TILE | Attribution visible; normal viewport loads only, never bulk preload or scrape OSM tile server | JS static source inspect only; **no browser run** |
| GEO-INT | Selected rental IDs link correctly to assessment and report; ownership/permissions | **Blocked until teammate handover / approved integration work order** |

## 8. Remaining technical gaps outside this proposal

1. Rental teammate `R-1 / R-4 / R-7 / R-8` contract and linked assessment identity not received.
2. Numerical `ODR-3a` and exact tolerance not adopted; `ODR-3b/c/d` recommended but not signed.
3. GM-12 `F-3/F-4`, Option B report text/provenance boundary and accessibility widget test not formally adopted/closed.
4. ODR-4 source/query/storage/display/redistribution permissions postponed. Open-source scraper **does not imply** terms permit its target.
5. H-F real venue identities, coordinates, temporal/coverage QA, dedup, taxonomy and sources postponed; no real venue list or recorded counts.
6. Report R01–R12 and 136-field contract, A10/HR, independent H3 and SGD-25 scientific release remain separate gates.
7. Project1 account/auth and assessment integration not done; real Jaspr app contract/build authorization unresolved.
8. Dart/Jaspr toolchain absent in this review sandbox: the source has **not** compiled or passed Dart tests here.

**Immediate proposed milestone:** accept this as a code-and-spec *candidate* for an authorised Jaspr geometry/report UI increment, not as a gate PASS or deployed feature.
