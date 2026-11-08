# GEOH-03 — Administrative, district/mukim and geometry contract

**Directive:** `PROJECT1-ODR3-RESEARCH-FIRST-GEO-CONTRACT-20261030` (R3, R4, R5, plus the R2 reconciliation)
**Custodian:** `HC-01`
**Status:** `PROPOSED_FOR_OWNER_ADOPTION`
**Controlling inputs:** `FRG-01` (`7a0d7f91…`), `FRG-02` (`ca5842f4…`), `GM_12` (`cbed0aec…`), `FRG-06` V3 (`d23e753d…`). Hashes in `GEOH-01` §2.
**Standing:** nothing here amends a frozen document. §12 separates every proposal from the rule it would change.

---

## 1. Two layers that must never be confused

This document specifies **two independent geographic objects**. Almost every error in the preceding packages comes from letting one borrow the other's authority.

| | **Administrative identity** | **Search footprint** |
|---|---|---|
| What it is | which named area a rental belongs to | which circle was queried for nearby records |
| Answers | *"where is this rental, administratively?"* | *"what did the source return near this point?"* |
| Geometry | a polygon, if and only if licensed | a circle of radius `R`, always |
| Depends on | a name catalogue + (optionally) a boundary licence | a certified centre + `R` + a tolerance |
| Output section | `R01` (per candidate), `R12` (audit) | `R09` (per candidate), `R12` (audit) |
| Failure mode | drawing a boundary the project may not publish | counting records from a circle that does not match the query |

**Rule G-1 — non-substitution.** A boundary polygon may never be used to decide circle membership, and a circle may never be drawn clipped to, or labelled as, an administrative boundary. They are different objects with different provenance, and a reader who sees them superimposed is entitled to assume the project claims one implies the other. It does not.

**Rule G-2 — independence of failure.** The administrative layer may be `named` while the footprint is undefined (`AREA_ONLY`), and the footprint may be well-defined while every administrative tier is `unresolved`. Neither resolves the other. This is the runtime form of `FRG-01` §3's assertion *"no tier state is inferred from another tier"*.

**Rule G-3 — the footprint is not a trade area.** `FRG-02` §2.1: a circle is *"a device for collecting records, never for scoring a location"*. No administrative statement may be derived from it, and no customer-catchment claim may be derived from either.

---

## 2. The hierarchy is a graph per jurisdiction, not a ladder

`FRG-01` §0 is explicit: the directive's assumption that there is *"a district or mukim"* fails because the tiers differ by jurisdiction. The contract models that as a **tier graph**, with `tier_defined` as a per-jurisdiction boolean rather than an implicit assumption.

### 2.1 Tiers

| Tier | Code | Present in | Notes |
|---|---|---|---|
| `STATE` | `NEGERI` | all | also carries federal territories (`W.P.`) |
| `DIVISION` | `BAHAGIAN` | **Sabah (5), Sarawak (12)** only | an intervening tier between state and district |
| `DISTRICT` | `DAERAH` | all except **W.P. Kuala Lumpur** | KL has one row with `KOD_DAERAH='00'` |
| `MUKIM` | `MUKIM` | Peninsular states; **not** Sabah, Sarawak | KL has 7 |
| `SECTION` | `SEKSYEN` | W.P. Kuala Lumpur | 112, the finest recorded type there |

**`BANDAR` and `PEKAN` are not tiers.** They are **classes inside the "Mukim" layer** that overlap mukim rather than nesting inside it (`FRG-01` §2 Case F). A consumer that counts every row of that layer as a mukim overstates Selangor's mukim by **4×** (54 mukim + 57 bandar + 117 pekan = 228 rows; `FRG-01` §1, §2 Case F).

### 2.2 Per-jurisdiction facts the contract depends on

| Jurisdiction | District tier | Mukim tier | Intervening tier | Contract consequence |
|---|---|---|---|---|
| **W.P. Kuala Lumpur** (`KOD_NEGERI=14`) | **absent** — one row, `KOD_DAERAH='00'`, a placeholder for absence | present (7: Ampang, Batu, Cheras, Hulu Kelang, Kuala Lumpur, Petaling, Setapak) | — | `district → notApplicable`; `00` is **never** rendered as a district code |
| **Sabah** (`12`) | present (28) | **absent** | `BAHAGIAN` (5) | `mukim → notApplicable`; selector is `state → division → district` |
| **Sarawak** (`13`) | present (42) | **absent** | `BAHAGIAN` (12) | as Sabah |
| **Selangor** | present (9) | present, but the layer is class-contaminated (54 / 57 / 117) | — | every mukim row must pass a class filter before it is called a mukim |
| **Outside the pilot** | unknown | unknown | unknown | all tiers `unresolved`; the listing stays **visible and unfiltered** |

**Rule G-4 — `notApplicable` is a fact about the jurisdiction; `unresolved` is a fact about the data.** `FRG-01` Rule E-R1. They must not be collapsed in either direction, in code or in copy.

**Rule G-5 — a placeholder is not a code.** `KOD_DAERAH='00'` for KL is *"a placeholder for absence, not a district code"* (`FRG-01` §2 Case C). Copying it into a district field reproduces the publisher's schema error at the source.

**Rule G-6 — a city name is not a district.** `Petaling Jaya` is a city spanning more than one of Selangor's nine districts, so a listing whose district column reads `Petaling Jaya` is `DISTRICT_UNRESOLVED` (`FRG-01` §2 Case B). District-name coverage in the supplied Selangor rows is **176 / 1,971 = 8.9 %** — so Case B is the normal case, not the exception.

---

## 3. Identity and geometry are separate axes

`FRG-01` §1.1 states this and it is the single most useful idea in the frozen corpus. Adopted unchanged:

| Axis | Symbol | Satisfied when | Today |
|---|---|---|---|
| **Site** | `S` | the listing carries its own coordinates, the coordinate system is stated, and coordinate-shift semantics are documented | `S_PARTIAL` — 5,973/6,334 rows carry coordinates; **4,209 record a shift**; **336 substitute a district median**; `COORD_SHIFT_SEMANTICS_NOT_DOCUMENTED` |
| **Identity** | `I` | `(area_id, catalogue_version)` resolves for that tier | `I_YES` for a minority of listings (8.9 % district-name coverage in Selangor); `I_NO` otherwise |
| **Geometry** | `G` | a `licence_id` is established **and** the polygon is validated for display | **`G_NO` for every tier in every jurisdiction** |

**Rule G-7 — "verified" is a conjunction.** A surface may not render `Boundary verified` unless `G_YES` holds. A name plus a code is `named`, never `verified` (`FRG-01` Rule A-R1).

**Rule G-8 — name reuse is not boundary use.** *"A district label is not an administrative boundary and must never be presented as one"* (`FRG-01` §4). The rights ask for a name list is materially weaker than the ask for a polygon, and the two must never be tracked as one decision.

---

## 4. The five display states, with machine predicates

`FRG-01` §3 fixes five states and says there is no sixth. The contract restates them as total, disjoint predicates so that a renderer can be checked rather than interpreted.

| State | Meaning | Predicate (evaluated per tier) | Drawn | Badge |
|---|---|---|---|---|
| `verified` | identity **and** licensed, validated geometry | `tier_defined ∧ identity ≠ null ∧ geometry_state = VALIDATED_LICENSED` | **yes** | `VERIFIED` |
| `partial` | geometry exists but is **not** validated for display | `tier_defined ∧ identity ≠ null ∧ geometry_state = UNVALIDATED` | **yes**, distinct outline | `PARTIAL / UNVERIFIED` |
| `named` | identity established, geometry absent | `tier_defined ∧ identity ≠ null ∧ geometry_state ∈ {ABSENT}` | no | `NAME ONLY` |
| `unresolved` | the tier exists but no area could be resolved for this listing | `tier_defined ∧ identity = null` | no | `NOT RESOLVED` |
| `notApplicable` | the jurisdiction has no such tier | `¬tier_defined` | no | `TIER NOT APPLICABLE` |

Evaluated left to right, so the predicates are total and mutually exclusive. All five are exercised in `fixtures/GEOH_SYNTHETIC_FIXTURES.json` (`ADM-A2`, `ADM-P`, `ADM-A1`, `ADM-D`, `ADM-E-KL`, `ADM-E-SABAH`) and asserted at `G-24`, `G-25`, `G-26` in `logs/geoh_contract_check.log`.

**Rule G-9 — non-colour channel.** `GM_05` R-10: boundary absence is stated *"in words **and** by a non-colour channel (an icon and an outline style), so it survives greyscale and colour-vision deficiency."* A design distinguishing `NAME ONLY` from `VERIFIED` by colour alone fails.

---

## 5. Parentage — what may never be inferred

The contract needs a parent link from mukim → district and district → state. **No authority supplies one.** `FRG-01` §4 records that ADM3 *"carries no parent district or state field"* and `shapeISO` is populated for **0 of 1,859** rows.

**Rule G-10 — six inferences that are forbidden.** A parent may not be derived from:

1. the child's **name** (`Petaling` is both a Selangor district and a KL mukim — a name collision, not a parentage proof);
2. **adjacency** or geometric containment;
3. a **sibling's** parent;
4. a **city name** in the listing text;
5. an **uncertified rental coordinate** (a point-in-polygon result computed from a `S_PARTIAL` coordinate is not a parent link);
6. a **postcode**, centroid, radius, hull, or a neighbouring listing.

Where no authority-supplied parent exists, the child renders `Parent district: not verified` (`FRG-01` §2 Case C) and the parent tier renders `unresolved` — never a guess. This is the same refusal `O-4`/`SCI_GEO_04` make for statistics, applied to structure.

---

## 6. The case matrix, as a resolution function

`FRG-01` §2 defines seven cases (A1, A2, B, C, D, E, F, G) plus an out-of-pilot branch. The contract keeps every one and keeps the order, because the order is what prevents a later case from overwriting an earlier one.

```text
resolve(listing, tier):
    if listing.uses_district_median:            -> G  (no marker, no zone claim)        [first: it poisons every later step]
    if jurisdiction not in pilot:               -> OUTSIDE (all tiers unresolved; listing retained)
    if not tier_defined(jurisdiction, tier):    -> notApplicable                        [before any value lookup]
    if listing_value blank:                     -> unresolved
    if value not in catalogue:                  -> named + LISTING_LOCALITY_LABEL
    if row.class not in mukim-class:            -> named + CLASS label (BANDAR/PEKAN)
    if catalogue match and geometry ABSENT:     -> named
    if catalogue match and geometry UNVALIDATED -> partial
    if catalogue match and geometry licensed+validated -> verified
    if geometry source errors:                  -> named + sourceErrors              [fail closed]
    if two sources disagree:                    -> ZoneConflict, no automatic preference
```

**Case G goes first, and that is the substantive change from `FRG-01`'s prose order.** A listing that carries a substituted district median has no site axis at all; evaluating a tier before disqualifying the site lets a name resolution look like a location. `GM_14` §6: *"may a district median stand in for a missing point? **no** — 336 rows would otherwise display a fabricated location."*

| Case | Trigger | Contract output | Test |
|---|---|---|---|
| **A1** | district + mukim identity, no geometry | both `named`; `NAME ONLY`; **no polygon, outline or shade** | `ADM-A1-IDENTITY-ONLY` |
| **A2** | identity + licensed validated geometry | both `verified`; polygon carries `licence_id`, vintage, source, retrieval date, **simplification level** | `ADM-A2-GEOMETRY-LICENSED-SYNTHETIC` — **synthetic only** |
| **B** | district resolved, mukim not stated | district `named`; mukim `unresolved` (`MUKIM_NOT_STATED`) | `ADM-B-MUKIM-NOT-STATED` |
| **C** | mukim resolved, parent not verified | mukim `named`; district `unresolved`; `Parent district: not verified` | `ADM-C-PARENT-NOT-VERIFIED` |
| **D** | neither resolvable | both `unresolved`; locality shown as `LISTING_LOCALITY_LABEL` in band 1 only | `ADM-D-NEITHER` |
| **E** | KL / Sabah / Sarawak / outside pilot | `notApplicable` at the tier the jurisdiction lacks; `unresolved ×4` outside pilot | `ADM-E-KL-NO-DISTRICT-TIER`, `ADM-E-SABAH-NO-MUKIM-TIER`, `ADM-OUTSIDE-PILOT` |
| **F** | a `BANDAR`/`PEKAN` row in the mukim layer | `named` with the **class** in the label: `Bandar Petaling Jaya (40) — town area within Petaling district`; `counts_as_mukim = false` | `ADM-F-BANDAR-ROW` |
| **G** | district-median substitute | no marker; *"listing location not carried; analysis uses a district-level substitute"*; no mukim claim | `ADM-G-DISTRICT-MEDIAN` |

**Rule G-11 — the locality label never becomes an area.** A listing-supplied locality renders as `LISTING_LOCALITY_LABEL` in the first band, never as a resolved area in the second. `GM_05` R-01: *"A name without a code is a label, not a zone."*

---

## 7. `BoundaryLayer` — what gates a real polygon

Real polygon display is gated on four independent conditions. All four must hold; today none does for any tier.

| # | Gate | Requirement | Status today |
|---|---|---|---|
| **BL-1** | **Lineage** | the geometry carries a `licence_id` and a `licence_evidence_uri` on the record | `G_04`'s 25-field record carries the URI; `permitted_uses = []`; `MAP_DISPLAY = "NOT GRANTED"` |
| **BL-2** | **Source rights** | `redistribution_status` and `derivative_works` both permitted, not merely collection | no publisher found with both; ADM2/ADM3 `LICENCE_CHAIN_UNVERIFIED — BLOCKED`; MyGDI `SOURCE_NOT_ACCESSIBLE` (DNS failure 2026-10-27) |
| **BL-3** | **Parent linkage** | the feature set carries a parent district/state relation from an authority | absent (0/1,859 `shapeISO`); Rule G-10 forbids manufacturing it |
| **BL-4** | **Feature counts** | the delivered feature count matches the catalogue count for that vintage | not established for any layer |

**Rule G-12 — synthetic GeoJSON is permitted for UI development and nothing else.** A synthetic boundary must carry a visible watermark (`SYNTHETIC FIXTURE — NOT A REAL BOUNDARY`), must never populate a real-listing view, and must never be exported in a report. Provenance for a synthetic layer is `synthetic: true`, `licence_id: null`, `rights_state: UNVERIFIED`.

**Rule G-13 — attribution travels.** `GM_05` R-11: *"The rights status of a source appears wherever its data appears, including in an exported report."* A layer that loses its `licence_id` is no longer the layer that was licensed.

---

## 8. Jurisdiction specifics worth writing down

| Fact | Source | Why the contract needs it |
|---|---|---|
| KL has **7 mukim** and **112 sections**; no district tier | `FRG-01` §2 Case E | the level selector must start at mukim for KL, not at district |
| A KL mukim row is parented to `KOD_DAERAH='00'` | `GM_01` §2.2 via `FRG-01` §2 Case C | copying it as a district is the upstream twin of `WGC_05`'s `area_level: "DISTRICT"` for a federal territory defect |
| Selangor's "Mukim" layer is **228 rows**: 54 mukim, 57 bandar, 117 pekan | `FRG-01` §1 | 76.3 % of rows offered as "mukim" are towns |
| `Bandar Petaling Jaya` (40) sits inside `Petaling` mukim (03); intersection is **0.0000037 %** of the bandar's area | `GM_11` §4.3 via `FRG-01` §2 Case F | bandar/pekan **overlap** mukim; they do not nest, so neither sums nor comparisons are defined across the layer |
| 1,857 / 1,859 ADM3 names are all-capitals; 948 are prefixed `MUKIM ` | `G_02` §3.3 | an entrepreneur cannot match a mukim name to a place they know; respondent-facing use is rejected for V1 |
| OpenDOSM publishes 160–166 **districts**, not mukim | `G_02` §1.1 | applying a district figure to a mukim is the ecological inference `SCI_GEO_04` §9 and `CLM-D` both prohibit |

**Rule G-14 — mukim is a navigation level, not a claim unit.** `FRG-01` §7's layered verdict is adopted as proposal: navigation `PERMIT` (class filter, `named` only, no statistic); report claim unit `DEFER`; respondent-facing question `REJECT for V1`. It is `ODR-3-mukim-navigation` in `GEOH-02` and remains `CONDITIONAL` on `O-1`/`O-1a`.

---

## 9. Geometry requirements (R5)

These are the developer-facing rules. Every one is a contract term, not an implementation note. Each names the defect it prevents.

### 9.1 Earth model and distance method

| ID | Requirement | Prevents |
|---|---|---|
| **GM-GEO-01** | Distances use a **spherical haversine with mean Earth radius `R⊕ = 6 371 000.0 m`**, named as a constant and recorded in provenance as `distance_method = "SPHERICAL_HAVERSINE_R6371000"`. | two implementations disagreeing by metres on the same pair (F-2) |
| **GM-GEO-02** | No per-call Earth-radius override. Changing the constant is a **footprint version change** and invalidates comparisons. | a silent method change that looks like a data change |
| **GM-GEO-03** | `asin` argument clamped to `[0, 1]`; no `atan2`-vs-`asin` mix within one report. | NaN or domain errors at antipodal/duplicate points |

Verified: `haversine` recomputed independently reproduces the developer's three published distances to ≤ 0.2 m (`G-05`), so both sides already agree on `R⊕`.

### 9.2 Centre selection

| ID | Requirement | Prevents |
|---|---|---|
| **GM-GEO-04** | Exactly **one** centre per footprint; its class is recorded on the footprint, not inferred at render time. | a circle drawn from one centre and described as another |
| **GM-GEO-05** | Centre classes `AREA_ONLY` and `LISTING_PIN` are **ineligible** — refused, not degraded. | a pin that is not the premises standing in for it (S-03: one venue crosses the boundary at 760 m) |
| **GM-GEO-06** | `PREMISES` requires a coordinate **and** a provenance **and** a numeric positional accuracy. `BUILDING` additionally requires a documented `entrance_offset_bound_m`. | a precise-looking circle from an unrecorded position (R-4, R-8) |
| **GM-GEO-07** | Missing coordinate, provenance or accuracy causes **refusal of the footprint**, never a default and never a zero. The rental row itself remains visible. | absence becoming a value |

**A threshold this contract deliberately does not set.** `GM-GEO-06` requires `accuracy_m` to be **present and numeric**; it sets **no maximum**. Proposing a maximum (e.g. "reject above 25 m") would be inventing a threshold that no source supports. The maximum is an Owner decision, recorded nowhere today, and is called out as a gap rather than silently chosen.

### 9.3 Precision, uncertainty and rounding

| ID | Requirement | Prevents |
|---|---|---|
| **GM-GEO-08** | Membership is decided on the **unrounded double**. Display rounding is applied **after** the decision and never re-fed into it. | a venue flipping sides because a display rounded 799.6 to 800 |
| **GM-GEO-09** | Displayed distances round **away from the boundary** (down when inside, up when outside), so a rounded number never contradicts the rendered membership. | "800 m — outside" appearing next to an included venue |
| **GM-GEO-10** | The footprint record carries `accuracy_m` and the tolerance it was evaluated with; the report displays both beside `R`. | a precision claim with no interval |

### 9.4 Boundary inclusion and tolerance

| ID | Requirement | Prevents |
|---|---|---|
| **GM-GEO-11** | The boundary is **inclusive**: a venue is inside iff `measured ≤ R + tolerance`. | an off-by-one convention at exactly `R` |
| **GM-GEO-12** | `tolerance` is a **required argument with no default**. An absent tolerance is an error (`E_TOLERANCE_UNSET`). | a hidden epsilon masquerading as a policy |
| **GM-GEO-13** | The tolerance must be **published with `R`** in the footprint metadata. A result computed with an unpublished tolerance is not reportable. | a result that cannot be reproduced by a second implementation |
| **GM-GEO-14** | The **value** of the tolerance is unset (`null`) until the Owner adopts one. `0.5 m` remains a labelled example, not a policy. | a number entering the contract through a code comment |

Measured, not asserted: at exactly `800.0 m` with `tolerance = 0` the venue is **included**; at `800.0000000000036 m` (3.6 × 10⁻¹² m of float noise) it is **excluded**; with `tolerance = 0.5` it is **included** again; and a genuine `805.0 m` stays **excluded** under both (`G-09-1`…`G-09-5`).

### 9.5 Radius bounds and display/study consistency

| ID | Requirement | Prevents |
|---|---|---|
| **GM-GEO-15** | A request above the supported maximum is **refused by exception/error**, never clamped. | the 6 km circle drawn over a 5 km query (D-1) |
| **GM-GEO-16** | `display_radius_m` must equal `study_radius_m`. An absent display radius is an error (`E_DISPLAY_RADIUS_ABSENT`); a mismatched one is `E_DISPLAY_STUDY_MISMATCH`. | a drawn circle that describes a query nobody ran (S-09) |
| **GM-GEO-17** | A radius of zero or below, or a non-finite value, is refused (`E_RADIUS_NON_POSITIVE`, `E_RADIUS_NOT_FINITE`). | a division-shaped failure downstream |

Measured: 400 / 500 / 800 / 1200 / 5000 accepted; 5000.5 and 6000 refused; 0 and −800 refused; and no clamp is observable at 6000 (`G-07-*`, `G-08`). Note the honest gap: `P19` validates the **study** radius only, so `GM-GEO-16` is currently **unenforced** — see `GEOH-T-10`.

### 9.6 Multiple rentals, de-duplication and layer semantics

| ID | Requirement | Prevents |
|---|---|---|
| **GM-GEO-18** | Each selected rental gets its **own** footprint; parameters (`R`, tolerance, method, footprint version) must be identical across a comparison. | a comparison between two different geometric questions |
| **GM-GEO-19** | Within one rental, count each `canonical_competitor_id` once, using a **named, disclosed** de-duplication rule (`name_fold_plus_30m`). | a node and a way describing one venue counted twice (D-1) |
| **GM-GEO-20** | Across rentals, print the **union size**, never the sum of per-rental counts. | 17 printed where the union is 11 (S-02) |
| **GM-GEO-21** | **Never sum or merge across sources.** `canonical_competitor_id` is source-scoped; no cross-source de-duplication rule exists. | an invented merge rule at render time (D-3) |
| **GM-GEO-22** | A polygon layer and a circle layer are **separate layers** with separate provenance. Neither clips, substitutes for, or validates the other. | Rule G-1 violated by a renderer convenience |
| **GM-GEO-23** | Every optional field is nullable, and `null ≠ 0 ≠ false`. A null tolerance, radius, coordinate or `licence_id` is an **error or a refusal**, never a default. | absence read as a value |

---

## 10. `E-2` and `E-3` as contract terms

`GEOH-02` §3 gives the reconciliation and the erratum. Restated here as the machine rule the developer implements:

```text
mayEmitCrossCandidateCount(a, b):
    return  a.footprint.method      == b.footprint.method
        and a.footprint.study_radius_m == b.footprint.study_radius_m
        and a.footprint.tolerance_m  == b.footprint.tolerance_m
        and a.snapshot.snapshot_id   == b.snapshot.snapshot_id          # one versioned snapshot
        and a.snapshot.source_release== b.snapshot.source_release
        and a.snapshot.display_rights_established and b...               # both displayable
        and a.snapshot.has_written_completeness_statement                # E-2*
        and b.snapshot.has_written_completeness_statement                # E-2*
        and sameWindow(a.snapshot.retrieved_at, b.snapshot.retrieved_at) # E-3*
```

Five fixtures exercise it (`CMP-1`…`CMP-5`, checks `G-23-*`). `CMP-2` is the case the frozen `E-2` text cannot distinguish: **both footprints are labelled `UNKNOWN`, the geometry and window are identical, and the count is still refused** — because equal labels are not equal observation.

> **`GEOH-E1` erratum, restated.** `E-3` needs **one shared window** for comparability. A **second** observation date is required only for temporal-change analysis. My earlier delta (`ODR3_DECISION_DELTA_20261030` §8, P-6) said otherwise and is corrected here.

**Descriptive per-rental lists are unaffected.** `E-2*`/`E-3*` gate the *cross-rental count* only. Each rental still renders its own list or its own GM-12 state. That is the whole point of keeping `S7` as a per-candidate state and `C-R1` as a separate cross-candidate refusal.

---

## 11. The GM-12 corrections

Three conflicts were found in the frozen `GM_12` (`cbed0aec…`). All three are **measured**, not argued, and none is repaired in the frozen file.

### 11.1 What is actually broken

| # | Conflict | Frozen text | Measured |
|---|---|---|---|
| **F-3 / N1-b** | §4.1 bans `no competitors`; §4's S4/S5 copy contains it | *"This is an empty result, not evidence that **no competitors** exist."* | `banned_hits()` returns `['no competitors']` on the frozen S4 text — `G-20` |
| **F-4 / N1** | §2 bans any digit in S1–S5; §4's S4/S5 mandate `Source: <name>, queried <date>` | both sentences are in force for the same block | the rendered S4 text contains digits from `queried 2026-10-20` — `G-21` |
| **N1-a** | V2.1's Option A exempted only text *"immediately after the literal word `queried`"*, but **S2** introduces its timestamp with `at` | `… did not answer OSM at 2026-10-20 09:31.` | under the predecessor's Option A this remains `E_DIGIT`; its 26 cases did not cover S2 |
| **N1-c** | §2's unit is *"anywhere in the block"*, and the block boundary is undefined | a real rental label (`No. 12, Jalan Contoh`) contains a house number | under **both** options, every S1–S5 block for a real rental is numeral-unlawful |

`N1-a` is the predecessor correcting itself, not a new contract question. `N1-c` is genuinely open (`ODR-3-blockboundary`).

### 11.2 Option A — one provenance timestamp, and it is the only digit-bearing span

> **S1–S5 contain no digit anywhere in the block, with one exception:** the single provenance timestamp, written as one ISO-8601 token (`YYYY-MM-DD`, optionally with `Thh:mm`), introduced by the literal word `queried` in S4/S5/S6 and by **`at` in S2**. The exception covers that one token and nothing else: not a count, not a radius, not a badge, not a trailing label, not a tooltip, not a second date, and not a clock time appended to the date.

S2 becomes `… did not answer <source>, queried <time>.`; the frozen `… at <time>.` is kept as an equally lawful alternative.

### 11.3 Option B — the provenance component carries no timestamp at all

> **S1–S5 contain no digit anywhere in the block** — not in a heading, not in a badge, not in a trailing label, not in a tooltip, **and not in the provenance line**, which names the source and carries no timestamp. The retrieval date and the dataset's own vintage are recorded once, per source and per query, in the report's evidence snapshot audit row (`R12`), which each block names in words. A `0` next to `Competitor records` remains the exact rendering this correction exists to prevent.

### 11.4 The proposed copy (Option B), with all four defects repaired

These are the strings asserted digit-free and phrase-free at `G-16`/`G-17`.

| State | Heading | Body |
|---|---|---|
| **S1** | `Competitor data unavailable` | `No competitor source is licensed for display in this product. Nothing here indicates how many businesses trade nearby.` |
| **S2** | `Competitor data unavailable` | `The competitor source did not answer. No count is available. This is a retrieval failure, not a finding about the area.` |
| **S3** | `Competitors not queried` | `Competitor records are listed against a resolved area. This premises has no resolved area, so no query was issued.` |
| **S4** | `No competitor records returned` | `Coverage: UNKNOWN — the source makes no statement about completeness for this area. This is an empty result, not a finding about the area.` |
| **S5** | `No competitor records returned` | `Coverage: PARTIAL — <the source's own stated limitation>. This is an empty result, not a finding about the area.` |
| **S6** | `Competitor records: 0` | `Coverage: COMPLETE — <the completeness statement, with its area scope and date>. Within the stated scope, this count is a fact about the dataset and about the area.` |
| **S7** | `Competitor records: <n> returned · <m> shown` | `<n> is a count of records, not of businesses: <k> merged duplicates, <e> excluded by category, <b> beyond the display radius.` |

Source name and dates appear **only** in the adjacent provenance region (`GEOH-04` `ReportGeoProvenance`), never inside S1–S5.

### 11.5 The qualifier repair, and why the shorter fix is refused

| Candidate | Keeps the denial? | Carries a banned span? | Verdict |
|---|---|---|---|
| `…not evidence that no competitors exist.` (frozen) | yes | **yes** | fails F-3 |
| `This is an empty result, not a finding about the area.` | **yes** | no | **proposed** |
| `This is an empty result.` | **no** | no | rejected — it drops the denial and with it the reason the qualifier exists |

### 11.6 `N1-c` — the block boundary

Three lawful readings, none adopted:

1. **the block starts at the component; the rental label is outside it** ← *proposed*, smallest change, needs no new position in §2;
2. the label is inside the block, and addresses get their own exemption;
3. blocks are rendered without a rental label, and identity lives in a heading §2 governs.

Until one is recorded, **no real rental's S1–S5 block can be shown lawful under either option**, because a real label usually carries a house number.

### 11.7 Recommendation, and the status that must not be lost

**This package recommends Option B**, on two criteria that bear on safety: it does not weaken the prohibition that exists to stop a competitor count appearing, and it removes a validation special case instead of institutionalising one. Under Option A a validator applied to a whole `§R09` clause strips one token out of N and reports the other N−1 as unlawful (hazard `D38`) — Option B is indifferent to the unit because it carries no digit at all.

**`ADOPTED_OPTION = None`.** Both options are `PROPOSED_NOT_ADOPTED`. No `GM_12` byte was changed by this package.

### 11.8 What neither option changes

S1, S3, S6 and S7 text is untouched in substance; S6 and S7 legitimately carry a numeral and stay outside §2's prohibition, which is about S1–S5 only. The seven state identifiers are unchanged. The distinction between the seven **per-candidate** states and the **cross-rental** `C-R1` refusal is preserved: a per-candidate `S4` says *this footprint's query returned nothing*; `C-R1` says *two footprints may not be compared*. They are different objects and must never be collapsed into one enum.

---

## 12. Proposals versus controlling rules

Every proposal in this document, and the frozen rule it would change. Nothing is applied until the Owner records it.

| Topic | Controlling frozen rule | This package proposes | If adopted, what changes |
|---|---|---|---|
| Boundary tolerance as a number | `FRG-02` §2.1 (*"`R` is an Owner parameter"*), `P1` F-2 (*"publish a boundary tolerance"*) | **no number**; explicit-and-published as a requirement | nothing numeric; a metadata field becomes mandatory |
| Silent clamp | none — `geo_proto.py` L180–181 clamps and its tests expect it | explicit refusal | the Python component must change behaviour, or callers must pre-validate |
| Digit rule and dates | `GM_12` §2 + §4 (self-contradictory) | Option A or Option B (§11.2–11.3) | the S4/S5 provenance line, or the §2 sentence |
| Banned phrase and qualifier | `GM_12` §4.1 + §4 | the replacement sentence (§11.5) | S4/S5 qualifier text |
| `E-2` meaning | `FRG-02` §3 row `E-2` (two tests in one row) | `E-2*` (§10) | cross-rental counts require documented completeness |
| `E-3` meaning | `FRG-02` §3 row `E-3` | `E-3*` + erratum `GEOH-E1` (§10) | one shared window, not two dates |
| Provenance date semantics | `GM_12` §4 (`queried <date>`, unqualified) | `RETRIEVAL_TIME`, with `as_of` for vintage | a label definition |
| R12 audit row fields | `FRG-06` V3 §2.3.2 (R12 described, not fielded) | eight named fields | new fields, explicitly flagged as new |
| R01's "area" | `FRG-06` V3 §2.3.2 L102 (undefined) | the rental's administrative area | removes R01's footprint dependency |
| Case-G ordering | `FRG-01` §3 (median branch is listed second) | median branch first | resolution order only; no state changes |
| mukim as navigation | `FRG-01` §7 (layered verdict, not adopted) | adopt the navigation row | a feature gate, not a claim |
| `notApplicable ≠ unresolved` | `FRG-01` Rule E-R1 (already stated) | unchanged — **restated as an assertion** | nothing; it is already the rule |
| Parent inference | `FRG-01` §2 Case C (forbids three routes) | forbids **six** (§5) | three additional refusals |
| Five display states | `FRG-01` §3 | unchanged — converted to total predicates | nothing semantic |
| Boundary gate | `FRG-01` §4 (four requirements, none met) | unchanged — restated as `BL-1`…`BL-4` | nothing |
| `GM-12` state derivation | `GM_12` §2.1 (*"coverage, not length"*) | unchanged — asserted at `G-15` | nothing |
| Cross-rental count gate | `FRG-02` C-R1 | unchanged in effect; `E-2*` tightens it | a stricter predicate |

---

## 13. What this document does not authorise

It does not ingest a boundary, render a real polygon, populate an area catalogue, adopt a radius, adopt a tolerance value, adopt an option, amend `GM_12`, decide `ODR-V21A-04/-07/-08/-09`, or resolve `O-1`/`O-1a`. It does not close `G-D7`, `M-D5`, `M-D9`, `O-4` or any gate in `GEOH-02` §6. It does not claim that any case other than `A1`, `B`, `C`, `D`, `E`-as-named, `F` and `G` is renderable today.

A synthetic boundary, a synthetic coordinate and a synthetic venue remain synthetic after this document is adopted. Adopting a rule does not create a fact.
