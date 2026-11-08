# GEOH-04 — Jaspr-neutral input/output data contract (R01 / R09 / R12)

**Status:** `PROPOSED_FOR_OWNER_ADOPTION`. Nothing here is adopted, signed, built or tested against a running app.
**Custodian:** `HC-01` (`GEOH-01` §1). **Date:** 2026-10-30.
**Scope:** the typed shape a developer implements. It fixes **names, types, allowed values, required-ness, error states and forbidden outputs** — not implementation, not a framework, not a UI kit.

**Why this document is framework-neutral.** The directive asks for a contract that can be handed to a Jaspr team *or any other team*. Every rule below is expressible in Dart, TypeScript, Kotlin or a JSON Schema. Where the current Dart proposal (`lib/geometry_contract.dart`, `c09430de…`) already expresses a rule, this document reproduces it; where it does not, §9 states the delta as a numbered change, not a rewrite. **No Dart is fixed here and no teammate schema is assumed.**

---

## 1. Six objects, and the one rule that binds them

| Object | Carries | Answers | Source of truth for the rule |
|---|---|---|---|
| `RentalLocationFixture` | one rental's identity and position claim | "what is the centre, and may it be drawn?" | ODR-3c; R-4/R-8 (teammate, pending) |
| `AdministrativeAreaResolution` | per-tier identity, parentage, geometry state | "which area is this, and at which tier?" | `FRG-01`, `GEOH-03` §2–§6 |
| `BoundaryLayer` | one polygon or one circle layer + its gates | "may this geometry be displayed at all?" | `GEOH-03` §7 (BL-1…BL-4) |
| `StudyFootprint` | radius, centre class, tolerance, method | "what question was asked, geometrically?" | `GEOH-03` §9 (GM-GEO-01…23) |
| `CompetitorEvidenceState` | one GM-12 state per candidate + qualifier | "what may be said about competitors here?" | `GM-12`; `FRG-02` C-R1; `GEOH-03` §10–§11 |
| `ReportGeoProvenance` | R12 audit row | "when, from what, under which rights?" | `GEOH-03` §11; ODR-3 R12 |

> **DC-01 — One object, one question.** Each object may be produced by exactly one stage: position (`RentalLocationFixture`) → area (`AdministrativeAreaResolution`) → displayable geometry (`BoundaryLayer`) → the geometric question (`StudyFootprint`) → the state (`CompetitorEvidenceState`) → the audit row (`ReportGeoProvenance`). A later stage may **refuse** an earlier stage's output; it may never **repair** it. A repaired input looks identical to a good one and destroys the audit trail that the whole package exists to preserve.

### 1.1 The dependency direction is acyclic and fail-closed

```text
RentalLocationFixture ─┬─► AdministrativeAreaResolution ─► BoundaryLayer
                       └─► StudyFootprint
                                    │
                                    ▼
                          CompetitorEvidenceState ─► ReportGeoProvenance
```

Every arrow is a **hard** dependency: if the source object is refused, every object downstream is `WITHHELD` with a propagated reason code. There is no arrow from `AdministrativeAreaResolution` to `StudyFootprint` — **area is never derived from geometry and geometry is never derived from area** (`GEOH-03` G-1, G-2, G-3).

---

## 2. `RentalLocationFixture`

### 2.1 Fields

| Field | Type | Required | Allowed values / constraint | Invariant |
|---|---|---|---|---|
| `rental_id` | opaque string | **yes** | non-empty; no display text; stable across revisions | **DC-02** — never derived from `label`; never reused after deletion |
| `label` | string | **yes** | any display text, **may contain numerals** | **DC-03** — a label is B-side content: it may never be interpolated into an S1–S5 body (`GEOH-03` §11.6) |
| `locality_name` | string or `null` | yes (nullable) | free text | **DC-04** — this is a *name hint*, not an area identity; R01 identity comes from `AdministrativeAreaResolution` |
| `centre_class` | enum | **yes** | `PREMISES` \| `BUILDING` \| `LISTING_PIN` \| `AREA_ONLY` | **DC-05** — recorded on the fixture, never inferred at render time (GM-GEO-04) |
| `latitude` | decimal or `null` | conditional | −90 ≤ φ ≤ 90 | **DC-06** — required for `PREMISES`/`BUILDING`, forbidden for `AREA_ONLY`/`LISTING_PIN` |
| `longitude` | decimal or `null` | conditional | −180 ≤ λ ≤ 180 | as DC-06 |
| `accuracy_m` | decimal ≥ 0 or `null` | conditional | metres, **no maximum asserted** | **DC-07** — presence is required; a maximum is an Owner decision and is currently unset (`GEOH-03` §9.2) |
| `position_source` | enum or `null` | conditional | closed set (§2.2) | **DC-08** — an unrecognised value is refused, not coerced |
| `coordinate_version` | string or `null` | conditional | revision token | **DC-09** — a coordinate with no revision cannot be re-checked after a correction |
| `entrance_offset_bound_m` | decimal ≥ 0 or `null` | required iff `BUILDING` | bound on centre→entrance offset | **DC-10** — `BUILDING` without a bound is refused (GM-GEO-06) |
| `synthetic` | boolean | **yes, no default** | `true` \| `false` | **DC-11** — absence is invalid, not `false` |

### 2.2 `position_source` is a closed vocabulary

| Value | Meaning | Acceptable for a circle? |
|---|---|---|
| `FIELD_MEASURED` | position taken at the premises | yes |
| `LANDLORD_ATTESTED` | supplied by the party offering the premises | yes |
| `TENANCY_DOCUMENT` | read from a signed instrument | yes |
| `AGENT_LISTING_PIN` | a marketplace pin | **no** — treated as `LISTING_PIN` |
| `UNRECOGNISED` | any value outside this set | **no** — refused with `E_PROVENANCE_UNRECOGNISED` |

> **DC-12 — the *closedness* is the contract; the words are a proposal.** The four accepted values must be ratified by the rental team under `R-8`. Until then a developer implements the enum **and** the refusal branch, so that an unknown token fails closed instead of becoming a free string. This is the single most important delta from the current Dart, where `positionSource` is `String?` (§9 row Δ-1).

### 2.3 Position eligibility — total function

```text
eligibility(f):
    if f.centre_class == AREA_ONLY:      → REFUSE, E_AREA_ONLY
    if f.centre_class == LISTING_PIN:    → REFUSE, E_LISTING_PIN
    if f.position_source == null:        → REFUSE, E_NO_PROVENANCE
    if f.position_source not in ACCEPTED:→ REFUSE, E_PROVENANCE_UNRECOGNISED
    if f.latitude == null or f.longitude == null: → REFUSE, E_NO_COORD
    if out of range:                     → REFUSE, E_COORD_OUT_OF_RANGE
    if f.accuracy_m == null:             → REFUSE, E_NO_ACCURACY
    if f.accuracy_m < 0:                 → REFUSE, E_ACCURACY_NEGATIVE
    if f.centre_class == BUILDING and f.entrance_offset_bound_m == null:
                                         → REFUSE, E_BUILDING_NO_OFFSET_BOUND
    if f.coordinate_version == null:      → REFUSE, E_NO_COORD_VERSION
    otherwise                            → ELIGIBLE
```

**DC-13 — Refusal is per-object, not per-page.** A refused rental **stays visible** in the list with its reason code; the *footprint* is withheld. Deleting the row would hide that the candidate exists, which is a different (and worse) misstatement than saying "position not established".

**DC-14 — `ELIGIBLE` is not `VERIFIED`.** Eligibility says the fixture has enough recorded attributes to compute with. It does **not** say the accuracy is sufficient for the intended decision; that threshold is unset (`GEOH-03` §9.2) and eligibility must not be displayed as a quality claim.

---

## 3. `AdministrativeAreaResolution`

### 3.1 Shape

```text
AdministrativeAreaResolution {
  jurisdiction_code    : string            # e.g. the state / federal-territory code
  area_id              : string | null     # R01 identity
  area_catalogue_version: string | null
  tiers                : Map<TierName, TierResolution>
  hierarchy_defined    : Map<TierName, bool>
  resolved_at          : timestamp
  source_ref           : string | null
}

TierResolution {
  tier_name        : STATE_FT | DISTRICT | MUKIM | LOCALITY
  identity         : string | null
  display_state    : VERIFIED | PARTIAL | NAMED | UNRESOLVED | NOT_APPLICABLE
  parent_ref       : string | null      # from a catalogue field only
  geometry_ref     : string | null
  geometry_state   : ABSENT | UNVALIDATED | VALIDATED_LICENSED
  source_ref       : string | null
}
```

### 3.2 Rules

| ID | Rule |
|---|---|
| **DC-15** | `NOT_APPLICABLE` is permitted **only** when `hierarchy_defined[tier] == false` for the jurisdiction. It is never a synonym for `UNRESOLVED` (`GEOH-03` G-4). |
| **DC-16** | `identity != null` is required for `VERIFIED`, `PARTIAL` and `NAMED`. `UNRESOLVED` requires `identity == null` **and** a non-null reason. |
| **DC-17** | `display_state == VERIFIED` iff identity **and** `geometry_state == VALIDATED_LICENSED`; `PARTIAL` iff identity **and** `geometry_state == UNVALIDATED`; `NAMED` iff identity **and** `geometry_state == ABSENT`. The three are a conjunction, not a ladder of confidence in the *name*. |
| **DC-18** | `parent_ref` may be populated **only** from a field present in the source catalogue. It is never inferred from a name, a centroid, a radius or a sibling (`GEOH-03` G-10, six forbidden inferences). |
| **DC-19** | A tier with `hierarchy_defined == true` and `identity == null` renders `UNRESOLVED`, **never "none"** and never an empty string. |
| **DC-20** | `area_id` is required for an R01 area label. If `area_id == null` the report must print the locality as unresolved and **must not** print a locality name as though it were an area identity (`FRG-01` Case D). |

### 3.3 Jurisdiction facts the developer must not re-derive

| Jurisdiction | `DISTRICT` defined? | `MUKIM` defined? | Consequence |
|---|---|---|---|
| Kuala Lumpur (14) | **no** — one row, `00` placeholder | yes, 7 mukim + 112 sections | `DISTRICT = NOT_APPLICABLE`; `00` is never a code (`GEOH-03` G-5) |
| Sabah (12) | yes, 28 | **no** | `MUKIM = NOT_APPLICABLE` |
| Sarawak (13) | yes, 42 | **no** | `MUKIM = NOT_APPLICABLE` |
| Selangor (10) | yes | yes — but the layer mixes **228 rows** (54 mukim + 57 bandar + 117 pekan) | a `bandar`/`pekan` row is **not** a mukim (`G-27`) |

---

## 4. `BoundaryLayer`

| Field | Type | Required | Constraint |
|---|---|---|---|
| `layer_id` | string | yes | unique per (tier, catalogue version) |
| `layer_kind` | enum | yes | `ADMIN_POLYGON` \| `STUDY_CIRCLE` |
| `tier` | enum or `null` | yes for polygons | `STATE_FT`/`DISTRICT`/`MUKIM`; `null` for circles |
| `geometry_ref` | string or `null` | yes if `geometry_state != ABSENT` | |
| `geometry_state` | enum | yes | `ABSENT` \| `UNVALIDATED` \| `VALIDATED_LICENSED` |
| `licence_id` | string or `null` | yes if `VALIDATED_LICENSED` | |
| `rights_state` | enum | yes | `VERIFIED` \| `UNVERIFIED` \| `BLOCKED` |
| `catalogue_version` | string or `null` | yes if identity present | |
| `source_ref` | string or `null` | yes | |
| `feature_count` | integer or `null` | yes if `VALIDATED_LICENSED` | |
| `parent_field_present` | boolean | yes | whether the source carries a parent linkage field at all |
| `synthetic` | boolean | yes, no default | synthetic GeoJSON for UI development |

| ID | Rule |
|---|---|
| **DC-21** | A real polygon may be displayed **iff** `geometry_state == VALIDATED_LICENSED` **and** `rights_state == VERIFIED` **and** `parent_field_present == true` **and** `feature_count` matches the catalogue. Any missing gate ⇒ `E_LAYER_NOT_VALIDATED` and the layer is not rendered (BL-1…BL-4). |
| **DC-22** | A `STUDY_CIRCLE` layer carries **no tier**. A polygon never substitutes for a footprint and a circle never validates an area (`GM-GEO-22`). |
| **DC-23** | `synthetic == true` ⇒ the layer renders with a visible synthetic watermark and is rejected by every export and evidence path (`E_SYNTHETIC_IN_EVIDENCE_PATH`). |
| **DC-24** | Attribution from `source_ref` travels with the layer into every surface that draws it, including exports (`GEOH-03` G-13). |

---

## 5. `StudyFootprint`

| Field | Type | Required | Constraint |
|---|---|---|---|
| `footprint_id` | string | yes | |
| `rental_id` | string | yes | exactly one centre per footprint (GM-GEO-04) |
| `centre_class` | enum | yes | copied from the fixture, not inferred |
| `study_radius_m` | decimal | yes | `0 < R ≤ 5000`, else refuse |
| `display_radius_m` | decimal | **yes** | **must equal `study_radius_m`** |
| `boundary_tolerance_m` | decimal ≥ 0 or `null` | yes (nullable) | `null` ⇒ membership not evaluated |
| `tolerance_policy` | enum | yes | `ADOPTED` \| `UNSET_PENDING_OWNER_ADOPTION` |
| `distance_method` | const string | yes | `SPHERICAL_HAVERSINE_R6371000` |
| `footprint_version` | string | yes | changes on any constant change (GM-GEO-02) |
| `computed_at` | timestamp | yes | |

| ID | Rule |
|---|---|
| **DC-25** | `display_radius_m` is **required**. Absent ⇒ `E_DISPLAY_RADIUS_ABSENT`; ≠ `study_radius_m` ⇒ `E_DISPLAY_STUDY_MISMATCH` (GM-GEO-16). |
| **DC-26** | `boundary_tolerance_m == null` is legal **only** when `membership_state == NOT_EVALUATED` and **no venue membership is emitted**. If any `withinCircle` call is made with a null tolerance ⇒ `E_TOLERANCE_UNSET` (GM-GEO-12). This is the only permitted coexistence of a null tolerance and a live object; it prevents the 0.5 m example from becoming a silent default (§9 Δ-4). |
| **DC-27** | `tolerance_policy == ADOPTED` requires a non-null `boundary_tolerance_m`. `tolerance_policy == UNSET_PENDING_OWNER_ADOPTION` may not accompany an emitted membership. |
| **DC-28** | The footprint passed to a comparison must match on `distance_method`, `study_radius_m`, `boundary_tolerance_m` **and** `footprint_version` (GM-GEO-18). Tolerance equality is part of geometry equality, not a cosmetic detail. |
| **DC-29** | Rounding is applied to the **displayed** number only, and rounds away from the boundary (GM-GEO-08, GM-GEO-09). A displayed number is never re-used as an input. |
| **DC-30** | Requesting `R` outside `(0, 5000]` throws; it is never clamped. The error names the requested value and the supported maximum (GM-GEO-15). |

---

## 6. `CompetitorEvidenceState`

### 6.1 Shape — state and qualifier are one object

```text
CompetitorEvidenceState {
  rental_id        : string
  state            : S1 | S2 | S3 | S4 | S5 | S6 | S7
  state_basis      : enum            # which predicate decided, see 6.2
  body             : string          # the state sentence, no digit for S1–S5
  qualifier        : string          # the coverage/limits sentence
  record_count     : integer | null  # present iff S6 or S7
  snapshot_ref     : string | null
  provenance_ref   : string | null   # pointer to ReportGeoProvenance
  evaluated_at     : timestamp
}

CrossCandidateCount {                # emitted only when 6.3 holds
  rental_ids       : [string, string, ...]
  union_count      : integer
  dedup_rule       : "name_fold_plus_30m"
  snapshot_ref     : string
  window           : (timestamp, timestamp)
}
```

| ID | Rule |
|---|---|
| **DC-31** | `state == S6 or S7` ⇔ `record_count != null`; every other state ⇒ `record_count == null`. A count on S1–S5 is `E_COUNT_ON_ABSENCE_STATE`. |
| **DC-32** | `body` for S1–S5 contains **no digit**. Tested by `\d`, not by inspection (`G-16-*`). |
| **DC-33** | `body` and `qualifier` are **one object** and must be rendered by one widget. A surface that can render `body` without `qualifier` fails the contract (R-21; §9 Δ-13). |
| **DC-34** | `state` is derived by the ordered function in §6.2 — the **order is normative**. Argument order in code must not be the only statement of precedence. |
| **DC-35** | `state == S6` requires `coverage == COMPLETE` **and** a written completeness statement **and** `record_count == 0`. `state == S7` requires `record_count ≥ 1`. |
| **DC-36** | A **null** `record_count` in the source snapshot is **not** `0`. It derives no state at all; it raises `E_COUNT_UNKNOWN` and the candidate renders `WITHHELD`. |
| **DC-37** | An **empty list** is not evidence of absence. `len(items) == 0` may reach S4/S5/S6; it may never reach S6 without the written statement (`GM-12`; `G-14`, `G-15`). |

### 6.2 Derivation order (normative)

```text
derive(snapshot):
  1. snapshot == null or not display_rights_established   → S1  (basis: NO_DISPLAYABLE_SOURCE)
  2. not area_resolved                                    → S3  (basis: ZONE_UNRESOLVED)
  3. query_failed or not source_answered                  → S2  (basis: QUERY_UNANSWERED)
  4. record_count is null                                 → WITHHELD (E_COUNT_UNKNOWN)
  5. record_count > 0                                     → S7  (basis: RECORDS_RETURNED)
  6. coverage == PARTIAL                                  → S5  (basis: COVERAGE_PARTIAL)
  7. coverage == COMPLETE and written_completeness_statement → S6 (basis: ATTESTED_ZERO)
  8. otherwise                                            → S4  (basis: COVERAGE_UNKNOWN)
```

**DC-38 — Why S3 precedes S2.** If the area is unresolved, a failed query is a *consequence*, not a separate fact; reporting S2 would blame the source for a failure of the zone lookup. The order is the substantive claim, and it is a rule, not an artefact of `if`-statement sequence.

### 6.3 Cross-candidate count gate

```text
mayEmitCrossCandidateCount(a, b):
    return  a.footprint.distance_method    == b.footprint.distance_method
        and a.footprint.study_radius_m     == b.footprint.study_radius_m
        and a.footprint.boundary_tolerance_m == b.footprint.boundary_tolerance_m
        and a.footprint.footprint_version  == b.footprint.footprint_version
        and a.snapshot.snapshot_id         == b.snapshot.snapshot_id
        and a.snapshot.source_release      == b.snapshot.source_release
        and a.snapshot.display_rights_established
        and b.snapshot.display_rights_established
        and a.snapshot.has_written_completeness_statement      # E-2*
        and b.snapshot.has_written_completeness_statement      # E-2*
        and sameWindow(a.snapshot, b.snapshot)                 # E-3*
```

| ID | Rule |
|---|---|
| **DC-39** | Any false term ⇒ no `CrossCandidateCount`. Per-candidate S7 lists are **still** rendered; only the cross-candidate number is refused (C-R1). |
| **DC-40** | When emitted, `union_count` is the size of the **de-duplicated union**, never the sum of per-rental counts (`GM-GEO-20`). |
| **DC-41** | `dedup_rule` is a **named disclosed string**. No de-duplication across sources; `canonical_competitor_id` is source-scoped (`GM-GEO-21`). |
| **DC-42** | Equal `UNKNOWN` coverage labels on both sides do **not** satisfy E-2*. Fixture `CMP-2` is exactly this case and is refused (`G-23-CMP-2`). |

---

## 7. `ReportGeoProvenance` (R12)

| Field | Type | Required | Note |
|---|---|---|---|
| `assessment_id` | string | yes | |
| `report_version` | string | yes | |
| `issued_at` | timestamp | yes | |
| `footprint_ref` | string | yes | → `StudyFootprint.footprint_id` |
| `snapshot_ref` | string or `null` | yes | `null` ⇒ `NO_COMPETITOR_SNAPSHOT` |
| `snapshot_id` | string or `null` | yes | |
| `source` | string or `null` | yes | |
| `source_release` | string or `null` | yes | |
| `queried_at` | timestamp or `null` | yes | when the query was issued |
| `retrieved_at` | timestamp or `null` | yes | when bytes were obtained — **PROPOSED_BLOCK_SEMANTICS** |
| `source_as_of` | timestamp or `null` | yes | `SOURCE_VINTAGE`; genuinely nullable |
| `coverage_class` | enum | yes | `UNKNOWN` \| `PARTIAL` \| `COMPLETE` |
| `rights_state` | enum | yes | `VERIFIED` \| `UNVERIFIED` \| `BLOCKED` |
| `licence_id` | string or `null` | yes | |
| `completeness_statement` | string or `null` | yes | required for any S6 |
| `tolerance_policy` | enum | yes | mirrors the footprint |
| `distance_method` | const string | yes | |
| `footprint_version` | string | yes | |
| `display_rights_check_at` | timestamp | yes | separate from issue time |

| ID | Rule |
|---|---|
| **DC-43** | `queried_at`, `retrieved_at`, `source_as_of` are **three distinct fields**, each independently nullable and each separately labelled. Collapsing them into one "date" loses the distinction between *when we asked* and *what the source knew* (`G-32`). |
| **DC-44** | Under the recommended **Option B**, **no** date or provenance numeral appears inside an S1–S5 body; the audit row is a separate accessible region (`G-31`). |
| **DC-45** | Under **Option A**, exactly **one** timestamp span is exempt, introduced by `queried` in S4/S5/S6 and by `at` in S2 (the N1-a defect: S2 says `at`, not `queried`). Block-boundary validation per `D38` must not report whole-clause false `E_DIGIT`. |
| **DC-46** | **`ADOPTED_OPTION = None`.** Both options are proposals. A developer may implement **either**, but must expose the choice as a configuration value with no default, and must fail closed if neither is selected. |

---

## 8. R01 / R09 / R12 mapping, and what may be printed

### 8.1 Mapping

| Report slot | Object | Rule |
|---|---|---|
| **R01** — area | `AdministrativeAreaResolution` (`area_id` + `area_catalogue_version` + label) | the *area* is not the *footprint*; a circle is never printed as an administrative area (`GEOH-03` §1) |
| **R09** — competitor state | `CompetitorEvidenceState` | one state per candidate; never inferred from an empty array |
| **R12** — provenance | `ReportGeoProvenance` | separate accessible region; nullable `source_as_of` |

### 8.2 Allowed outputs

| Output | Preconditions | Forbidden |
|---|---|---|
| Per-candidate S1–S5 block + qualifier | eligibility decision made; no digit in body | any count, any rate, any "none"/"no competitors" phrasing |
| Per-candidate S7 list | `record_count ≥ 1`; source displayable | ranking, suitability, saturation, walking time |
| `CrossCandidateCount` | **all** of DC-39 | sum, average, share, index, score, density |
| Area label | `area_id != null` | a name printed as though it were a coded identity |
| Boundary polygon | DC-21 gates | a polygon standing in for a search footprint |
| Any of the above with `synthetic == true` | synthetic watermark present | any export or evidence path |

### 8.3 Absolute prohibitions (`GEOH-03` §12 restated as machine rules)

| ID | Never emitted |
|---|---|
| **DC-47** | a competitor **count** for a candidate in S1–S5 |
| **DC-48** | a **rate, ratio, density, saturation, index or score** across candidates (C-R2) |
| **DC-49** | a **demand**, **suitability**, **ranking**, **walking-time** or **market-size** claim (ODR-3d) |
| **DC-50** | a **distance to a venue** presented as a **walking route** |
| **DC-51** | any number derived from **map tile labels** |
| **DC-52** | a **zero** for an unknown; `null`, `UNKNOWN`, `UNRESOLVED` and `WITHHELD` are not zeros |
| **DC-53** | a **date or digit** inside an S1–S5 body under Option B |
| **DC-54** | **any** field from `lib/geometry_contract.dart`'s free-string `positionSource` used without enum mapping |

---

## 9. Field-level delta against the current Dart proposal

`lib/geometry_contract.dart` (`c09430de…`) is a **proposal by the developer**, not an adopted contract, and it is read here as evidence of what a first implementation will do by default. Fourteen deltas:

| # | Current Dart | Proposed | Why it matters |
|---|---|---|---|
| **Δ-1** | `positionSource: String?` | closed enum + refusal branch | a free string cannot express R-8 provenance classes and cannot be validated |
| **Δ-2** | `CentreDecision(bool canDraw, String explanation)` | `(bool, reason_code, explanation)` | prose is untestable; `G-06-*` asserts codes, not sentences |
| **Δ-3** | no display radius at all | `display_radius_m` + `E_DISPLAY_STUDY_MISMATCH` | the *drawn* circle is currently unvalidated against the *queried* one |
| **Δ-4** | `experimentalBoundaryToleranceMetres = 0.5` as a compiled constant | `null` + `tolerance_policy` | a constant in a library is how a number enters a contract without an Owner decision |
| **Δ-5** | `withinCircle(..., {required double toleranceMetres})` | `double? toleranceMetres` + `E_TOLERANCE_UNSET` | non-nullable `double` makes "unset" unrepresentable, so callers pass the constant |
| **Δ-6** | `accuracyMetres! < 0` folds three causes into one message | separate codes | "coordinates, provenance and accuracy" cannot be reported to the user precisely |
| **Δ-7** | `validateRadius` applied to study only | study **and** display | `maximumDemonstratorRadiusMetres` is a *demonstrator* cap; the name must survive into the error |
| **Δ-8** | `competitorState` precedence implicit in `if` order | declared `state_basis` + normative table | §6.2 order is a substantive claim that must be reviewable |
| **Δ-9** | `recordCount: int` (required) | `int?` + `E_COUNT_UNKNOWN` | a snapshot whose count is unknown is currently forced to a number |
| **Δ-10** | `displayRightsEstablished: bool` only | `rights_state` + `licence_id` | R12 needs the licence identity, not just a boolean |
| **Δ-11** | `absenceBody()` returns `String` | `{body, qualifier, state, count?}` object | text without its qualifier is renderable and therefore shippable (`DC-33`) |
| **Δ-12** | `mayDisplayCrossCandidateCounts` has `sameMethodAndRadius` | explicit tolerance + footprint-version terms | two runs at the same `R` with different tolerances are different geometric questions |
| **Δ-13** | `locality: String` on `RentalCentre` | `locality_name` hint + coded area identity | a free-text locality can be printed as an area identity it does not have |
| **Δ-14** | `synthetic` defaults to `true` | required, no default | the default is *safe* (fail-to-demo), but a default on a truth-bearing flag is still a default; make it explicit |

> **Δ-14 is deliberately labelled non-urgent.** Unlike Δ-4, the `synthetic` default fails **closed**. It is listed for completeness so that the delta table is not read as an all-or-nothing rewrite.

---

## 10. Error-state table

Codes marked **implemented** are the exact strings raised by `harness/geoh_contract_check.py` and observed in `logs/geoh_contract_check.log`. Contract codes (`E_*`) are the developer-facing names; the harness token is the observed value. The mapping is recorded so a developer test can assert either without ambiguity.

| Contract code | Harness token | Raised when | Status |
|---|---|---|---|
| `E_RADIUS_NOT_NUMERIC` | `REFUSE_NOT_NUMERIC` | radius is not numeric | implemented |
| `E_RADIUS_NOT_FINITE` | `REFUSE_NOT_FINITE` | NaN / ±∞ | implemented |
| `E_RADIUS_NON_POSITIVE` | `REFUSE_NON_POSITIVE` | `R ≤ 0` | implemented |
| `E_MAX_RADIUS` | `REFUSE_MAX_RADIUS` | `R > 5000` | implemented |
| `E_AREA_ONLY` | `REFUSE_AREA_ONLY` | centre class `AREA_ONLY` | implemented |
| `E_LISTING_PIN` | `REFUSE_LISTING_PIN` | centre class `LISTING_PIN` | implemented |
| `E_NO_COORD` | `REFUSE_NO_COORDS` | lat or lon absent | implemented |
| `E_NO_PROVENANCE` | `REFUSE_NO_PROVENANCE` | `position_source` absent | implemented |
| `E_NO_ACCURACY` | `REFUSE_NO_ACCURACY` | `accuracy_m` absent | implemented |
| `E_BUILDING_NO_OFFSET_BOUND` | `REFUSE_BUILDING_NO_OFFSET_BOUND` | `BUILDING` without bound | implemented |
| `E_TOLERANCE_UNSET` | `REFUSE_TOLERANCE_UNSET` | tolerance null at a membership call | implemented |
| `E_TOLERANCE_NEGATIVE` | `REFUSE_TOLERANCE_NEGATIVE` | tolerance < 0 | implemented |
| `E_DISPLAY_RADIUS_ABSENT` | `REFUSE_DISPLAY_RADIUS_ABSENT` | display radius missing | implemented |
| `E_DISPLAY_STUDY_MISMATCH` | `REFUSE_DISPLAY_STUDY_MISMATCH` | display ≠ study | implemented |
| `E_COUNT_INVALID` | `INVALID_RECORD_COUNT` | `record_count < 0` | implemented |
| `E_PROVENANCE_UNRECOGNISED` | — | token outside the closed enum | **specified, not implemented** (Δ-1) |
| `E_COORD_OUT_OF_RANGE` | — | φ∉[−90,90] or λ∉[−180,180] | **specified** |
| `E_ACCURACY_NEGATIVE` | — | `accuracy_m < 0` | **specified** |
| `E_NO_COORD_VERSION` | — | coordinate revision absent | **specified** |
| `E_CENTRE_CLASS_UNKNOWN` | — | adapter saw a centre type outside the four | **specified** (§12) |
| `E_COORD_VERSION_CONFLICT` | — | two coordinates, two revisions | **specified** (§12) |
| `E_COUNT_UNKNOWN` | — | snapshot count null (Δ-9) | **specified** |
| `E_COUNT_ON_ABSENCE_STATE` | — | count supplied for S1–S5 | **specified** |
| `E_LAYER_NOT_VALIDATED` | — | BL-1…BL-4 gate unmet | **specified** |
| `E_SYNTHETIC_IN_EVIDENCE_PATH` | — | synthetic object reached an export | **specified** (Δ-13/G-3) |
| `E_NUMERAL_IN_ABSENCE_BODY` | — | `\d` found in S1–S5 body | **implemented as a check, not a throw** (`G-16-*`) |
| `E_BANNED_PHRASE` | — | §4.1 phrase found | **implemented as a check** (`G-17-*`) |
| `E_OPTION_UNSET` | — | neither Option A nor B configured | **specified** (DC-46) |
| `E_SNAPSHOT_WINDOW_MISMATCH` | — | E-3* fails at emission | **implemented as a refusal path** (`G-23-CMP-3`) |

**DC-55 — A refusal path that is only specified is not implemented.** §10 is the honest ledger: **15** codes run today, **1** is a refusal path rather than a throw, **2** are checks rather than throws, and **11** are specified but unenforced. No row may be marked "done" on the strength of this table.

---

## 11. Synthetic fixtures, and why they can never be evidence

`fixtures/GEOH_SYNTHETIC_FIXTURES.json` (`fixture_id = GEOH-SYN-20261030`) implements every object above:

| Block | Count | Exercises |
|---|---|---|
| `rentals` | 3 | eligibility for `PREMISES` and `BUILDING` |
| `centre_class_cases` | 7 | all four centre classes and the missing-attribute branches |
| `radius_requests` | 9 | accept 400/500/800/1200/5000; refuse 5000.5, 6000, 0, −800 |
| `boundary_cases` | 5 | exact boundary, 3.6×10⁻¹² m float noise, tolerance absorption, genuine 5 m excess |
| `synthetic_venues_from_SYN_A` | 10 | distance arithmetic only |
| `expected_counts_strict` | 5 | 400→2, 500→3, 800→7, 800τ0.5→7, 1200→9 |
| `venue_snapshots` | 9 | S1, S2 (two ways), S3, S4, S5, S6, S7 |
| `comparison_cases` | 5 | E-1/E-2*/E-3* refusals, incl. equal-label `CMP-2` |
| `admin_resolutions` | 11 | all five display states, KL, Sabah, bandar row, district median, out-of-pilot |
| `display_radius_cases` | 3 | equality, absence, mismatch |
| `geo_provenance` | 1 | `tolerance_policy = UNSET_PENDING_OWNER_ADOPTION`, `boundary_tolerance_m = null` |

| ID | Rule |
|---|---|
| **DC-56** | `contains_real_rental_data`, `contains_real_competitor_records`, `reportable_as_evidence` are all `false` and are asserted (`G-01`…`G-03`). |
| **DC-57** | The three coordinates are plausible Kuala Lumpur positions and are **not** claims that a rental, entrance or café exists there. `PREMISES` and 1 m accuracy on `SYN-A` are **test-only assumptions** (`G-04`). |
| **DC-58** | None of the 10 synthetic venues is a real business and none is counted in any reportable output. |
| **DC-59** | Copying any fixture value into a production surface without flipping `synthetic` to `false` **and** supplying real, licensed, versioned provenance is `E_SYNTHETIC_IN_EVIDENCE_PATH`. |

---

## 12. The adapter boundary (teammate-independent)

The teammate's rental schema is **unpublished** (`GEOH-01` §3, `R-1`/`R-4`/`R-7`/`R-8`). This contract therefore defines only the **shape it consumes**, plus an adapter seam:

```text
adapter: TeammateRentalRecord → RentalLocationFixture | Unmappable(reason)

unmappable cases (never repaired):
   unknown centre type                    → E_CENTRE_CLASS_UNKNOWN
   coordinate present, accuracy absent     → E_NO_ACCURACY
   accuracy present, provenance absent     → E_NO_PROVENANCE
   two coordinates, two versions           → E_COORD_VERSION_CONFLICT
   field absent                            → null, not 0, not ""
```

| ID | Rule |
|---|---|
| **DC-60** | The adapter is the **only** component that may read teammate fields. Nothing downstream may branch on a teammate field name. |
| **DC-61** | An unmappable record is still **listed**, with its reason, and its footprint is withheld (DC-13). |
| **DC-62** | Absent ⇒ `null`. The adapter may never synthesise `0`, `""`, `false` or a `UNKNOWN` enum member to fill a hole. |
| **DC-63** | If the teammate publishes a schema with different names, only the adapter changes. A downstream change means this contract was violated, not that the schema moved. |
| **DC-64** | `RentalLocationFixture` may be populated from fixtures today. It may **not** be populated from scraped listings, and never from a map tile. |

---

## 13. Readiness statement

| Claim | True today? |
|---|---|
| the contract is complete enough to implement against | **yes** — subject to §9 deltas |
| the contract is adopted by the Owner | **no** — `PROPOSED_FOR_OWNER_ADOPTION` |
| any part of it compiles or runs in Jaspr | **no** — no Dart toolchain in this environment (`GEOH-01` §3) |
| it depends on the teammate's schema | **no** — adapter seam, DC-60…DC-64 |
| a real rental has been mapped through it | **no** |
| a licensed competitor source exists | **no** — ODR-4 and H-F postponed |
| an S1–S7 state has been emitted on real data | **no** — every state in this package is synthetic |

**Nothing in this document advances a gate. `GEOH-05` maps each rule here to a developer test; the tests are unexecuted.**
