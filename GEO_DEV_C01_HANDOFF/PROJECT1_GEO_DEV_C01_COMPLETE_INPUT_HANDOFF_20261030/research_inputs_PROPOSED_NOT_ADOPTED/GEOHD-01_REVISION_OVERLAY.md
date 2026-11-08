# GEOHD-01 — Targeted revision overlay, `GEOH-REV-01` … `GEOH-REV-08`

**Package:** `GEOH_INDEPENDENT_CHALLENGE_DELTA_20261030`
**Date:** 2026-10-30
**Directive:** `PROJECT1-GEOH-INDEPENDENT-CHALLENGE-DELTA-20261030`
**Governing input:** `inputs/GEOH_INDEPENDENT_CHALLENGE_AND_TARGETED_RETURN.md` (the independent challenge register), SHA-256 `9db48f4af954ce2c0a995d27a008df1a045db484182a5cf6815df5813749d005`, carried verbatim.
**Predecessor (frozen, unmodified):** `GEOH_ODR3_TO_JASPR_20261030`, `SHA256_MANIFEST.txt` re-verified **9/9 OK, exit 0** before and after this work.

| Field | Value |
|---|---|
| Status of every rule below | `PROPOSED_FOR_OWNER_ADOPTION` — nothing in this overlay is adopted |
| Signatures obtained | **0** |
| Owner decisions signed | **0** (including the fourteen in `GEOH-02` §4, which are **not** re-signed here) |
| Jaspr tests executed | **0** of `GEOH-T-01`…`T-41`; the eight tests added here (`T-42`…`T-49`) are `NOT_EXECUTED` as written |
| Readiness level reached | **L0 (documentary) only.** No L1 (Jaspr compiles), no L2 (real rental), no L3 (licensed evidence) |
| Geographic research re-run | **none.** No source was re-queried, no polygon fetched, no competitor dataset touched |
| Predecessor files modified | **none.** This is an overlay, not a revision of `GEOH-01`…`GEOH-05` |
| Machine evidence | `_verify/geoh_delta_check.py` → `_verify/logs/geoh_delta_check.log`: **62 checks, 62 `HOLDS`, 0 `VIOLATED`, exit 0** |

---

## 0. How to read this overlay

**Vocabulary.** Three verdicts are used and they must not be conflated.

| Token | Where | Meaning |
|---|---|---|
| `HOLDS` in `logs/geoh_contract_check.log` | predecessor | a documentary self-check assertion about the *contract text and fixtures* |
| `D-R-nn HOLDS` in `geoh_delta_check.log` | this package | the named **contradiction is present** in the pinned predecessor bytes. A `HOLDS` here is a **defect report**, not a pass |
| `D-C-nn HOLDS` in `geoh_delta_check.log` | this package | the **proposed replacement rule**, as implemented in `_verify/geoh_delta_check.py`, behaves as this document states. It ratifies nothing |

**AC-D1 — no rule below relaxes a refusal.** Every replacement either (a) refuses something the predecessor claimed it could render, (b) adds a refusal path, or (c) splits one overloaded concept into two. `D-C-23` and `D-C-24` test this: none of the 19 radius/centre/display cases changes verdict, and the `BANNED` phrase list and the S1–S5 digit rule are untouched.

**AC-D2 — the delta does not restate the contract.** Where a clause is corrected, the original text is quoted verbatim with its file and section. The reader should treat `GEOH-01`…`GEOH-05` as authoritative except where a `GEOHD-` rule below is adopted over it.

**AC-D3 — every proposed field, state and error code is a proposal.** `ADOPTED_OPTION = None` (`GEOH-04` DC-46) is unchanged. No numeric tolerance, no radius, no accuracy maximum and no licence is adopted here.

**AC-D4 — a wrong expectation is corrected as a numbered erratum, never silently edited.** See §10.

---

## 1. Revision map

| REV | Register severity | Concept split introduced | New rules | New test | New Owner rows | Delta checks |
|---|---|---|---|---|---|---|
| `GEOH-REV-01` | HIGH | *display state* ≠ *render decision*; *marker* ≠ *polygon*; *preview* ≠ *public* | `GEOHD-01.1`–`01.5` | `GEOH-T-42` | `ODR-R-01` | `D-R-01`…`05`, `D-C-01`…`04` |
| `GEOH-REV-02` | HIGH | *representation epsilon* ≠ *positional uncertainty*; a third membership verdict | `GEOHD-02.1`–`02.5` | `GEOH-T-43` | `ODR-R-02a`, `ODR-R-02b` | `D-R-06`…`08`, `D-C-05`…`07` |
| `GEOH-REV-03` | HIGH / OWNER SCOPE | `E-2*` (strict) vs `E-2desc` (same-snapshot record sets) — a choice, not a weakening | `GEOHD-03.1`–`03.4` | `GEOH-T-44` | `ODR-R-03` | `D-R-09`…`10`, `D-C-08`…`10b` |
| `GEOH-REV-04` | MEDIUM / UX | *centre eligibility* ≠ *display role* | `GEOHD-04.1`–`04.4` | `GEOH-T-45` | `ODR-R-04` | `D-R-11`…`12`, `D-C-11`…`13` |
| `GEOH-REV-05` | HIGH / REPORT | `R12` becomes **total over refusals** | `GEOHD-05.1`–`05.5` | `GEOH-T-46` | `ODR-R-05` | `D-R-13`…`14`, `D-C-14`…`15` |
| `GEOH-REV-06` | MEDIUM / UX | Option B's linkage becomes a **named, checked requirement** | `GEOHD-06.1`–`06.5` | `GEOH-T-47` | `ODR-R-06` | `D-R-15`…`16`, `D-C-16`…`18` |
| `GEOH-REV-07` | MEDIUM / ASSURANCE | **88 documentary checks** vs **41 unexecuted application tests**, with evidence tiers | `GEOHD-07.1`–`07.5` | `GEOH-T-48` | `ODR-R-07` | `D-P-07`…`08`, `D-R-20`…`25`, `D-C-21`…`22` |
| `GEOH-REV-08` | LOW / TRACE | three separate axes **S / I / G** in every acceptance row | `GEOHD-08.1`–`GEOHD-08.4` | `GEOH-T-49` | `ODR-R-08` | `D-R-17`…`19`, `D-C-19`…`20` |

**Numbering note (erratum `GEOHD-E4`, §10).** The Owner's directive listed the eight priorities in an order where the last two are "S/I/G axes" then "88 vs 41". The register's table has them the other way round: `GEOH-REV-07` is the assurance row (manifest, 88 checks, 41 tests) and `GEOH-REV-08` is the S/I/G trace row. **This overlay follows the register**, because the register is the cited artefact and the directive says "covering GEOH-REV-01 through GEOH-REV-08" by ID.

---

## 2. `GEOH-REV-01` — the partial-polygon rendering contradiction

### 2.1 Original contract clause (verbatim)

`GEOH-03` §4, the five-display-state table, row 2:

> | `partial` | geometry exists but is **not** validated for display | `tier_defined ∧ identity ≠ null ∧ geometry_state = UNVALIDATED` | **yes**, distinct outline | `PARTIAL / UNVERIFIED` |

`GEOH-03` §7, immediately above the gate table:

> Real polygon display is gated on four independent conditions. **All four must hold; today none does for any tier.**

`GEOH-04` §4, DC-21:

> **DC-21** | A real polygon may be displayed **iff** `geometry_state == VALIDATED_LICENSED` **and** `rights_state == VERIFIED` **and** `parent_field_present == true` **and** `feature_count` matches the catalogue. Any missing gate ⇒ `E_LAYER_NOT_VALIDATED` and **the layer is not rendered** (BL-1…BL-4).

`GEOH-05` §4.4, two rows of the acceptance matrix:

> | **GEOH-T-23** | **`S_PARTIAL`** — 5,973/6,334 coords, 4,209 shifted | U | marker inside a partially-geolocated area, clipped geometry | `partial`; marker drawn; **no** precision claim | `ADM-P-PARTIAL-GEOMETRY` | `G-24`, `G-25` |
> | **GEOH-T-24** | **Case A1 / A2** marker + partial geometry | U | A1 marker inside; A2 marker outside a partial polygon | A1 `partial` drawn; A2 resolves without a boundary claim | `ADM-A1`, `ADM-A2` | `G-24-*` |

### 2.2 Reproduction (machine, against the pinned bytes)

1. `D-R-01` — the two texts above coexist in the same package and cannot both be satisfied.
2. `D-R-02` — the fixture enforces the contradiction, so it is not a drafting slip confined to prose. `ADM-P-PARTIAL-GEOMETRY` carries `geometry_state: "UNVALIDATED"`, `geometry_licensed: false`, **`expected_drawn: true`**, and **none** of `rights_state`, `licence_id`, `parent_field_present`, `feature_count` (`gate fields=[]`).
3. `D-R-03` — the harness's own rule is `drawn = (d in ("verified", "partial") or m in ("verified", "partial"))` (`_verify/harness/geoh_contract_check.py:341`). **Rendering is a function of the display state; no `BoundaryLayer` object is consulted at all.** DC-21's four gates are therefore untestable by the harness that claims 88 `HOLDS`.
4. `D-R-04` — `ADM-A2-GEOMETRY-LICENSED-SYNTHETIC` resolves to `verified`, the badge Rule G-7 reserves for licensed geometry, from a case whose own id declares it synthetic. `synthetic == true` never enters `admin_state()`.
5. `D-R-05` — `GEOH-T-24` expects "A1 `partial` drawn", while `GEOH-03` §6 defines Case A1 as "`both `named`; `NAME ONLY`; **no polygon, outline or shade**" and the fixture `ADM-A1-IDENTITY-ONLY` asserts `named` / `expected_drawn: false`. The test row contradicts both the case table and the data.
6. Additional ambiguity the register does not name: `expected_drawn` is **one boolean** standing for two different objects. §4's `Drawn` column means *the polygon*; `GEOH-T-23`'s "marker drawn" means *a point for a listing*. A listing marker inside an area is not a boundary claim, and today the contract cannot say them apart.

**Consequence, stated plainly.** As written, a developer who implements `GEOH-03` §4 faithfully builds an application that draws unlicensed, unvalidated real boundaries — precisely what BL-1…BL-4 and `ODR-3c-exclusions` exist to forbid — and the 88-check harness scores that behaviour as `HOLDS`.

### 2.3 Proposed replacement

> **`GEOHD-01.1` — `display_state` describes identity and geometry *availability*; it never authorises rendering.** The five states of `GEOH-03` §4 are retained unchanged **as labels**. Their `Drawn` column is **deleted** and replaced by a pointer to `GEOHD-01.2`.
>
> **`GEOHD-01.2` — polygon rendering is a separate total function of the `BoundaryLayer` gates.** For a real (non-synthetic) layer:
> `polygon_render_state = RENDERED_LICENSED` iff DC-21's four gates hold; otherwise `WITHHELD_NOT_VALIDATED` with `E_LAYER_NOT_VALIDATED`. A `partial` state with a withheld polygon is a **normal, expected** combination, not an error.
>
> **`GEOHD-01.3` — `synthetic == true` is a third surface, not a state.** A synthetic layer renders only as `RENDERED_SYNTHETIC_WATERMARKED`, watermarked per Rule G-12, and never carries the `VERIFIED` badge. A case named `…-SYNTHETIC` may resolve to `verified` only if the fixture also asserts `surface = INTERNAL_PREVIEW`; the id alone is not the guard.
>
> **`GEOHD-01.4` — the word channel survives the withheld polygon.** `partial` + withheld renders the badge text `PARTIAL / UNVERIFIED — boundary not displayed`. Rule G-9 is thereby satisfied **in words**, which is stronger than the outline style it currently relies on.
>
> **`GEOHD-01.5` — split `expected_drawn` into `expected_polygon_render` and `expected_marker_display`.** Every fixture case and every acceptance row carries both. A listing marker may display while its tier's polygon is withheld; the reverse is never implied.

New error codes: `E_LAYER_NOT_VALIDATED` is **already** in `GEOH-04` §10 and is now actually reachable; `E_SYNTHETIC_BADGE_MISMATCH` is new.

### 2.4 Adversarial acceptance test — `GEOH-T-42` (tier L1, `NOT_EXECUTED`)

| # | Case | Expected |
|---|---|---|
| 42-a | real district, `geometry_state=UNVALIDATED`, all other gate fields absent | state `partial`; `WITHHELD_NOT_VALIDATED`; badge `PARTIAL / UNVERIFIED — boundary not displayed`; **no outline of any kind** |
| 42-b | same layer, `rights_state=VERIFIED`, `parent_field_present=true`, `feature_count` matching | `RENDERED_LICENSED`, `VERIFIED` badge |
| 42-c | 42-b with `parent_field_present` flipped to `false` | `WITHHELD_NOT_VALIDATED` (mutation screen — a single gate must be enough) |
| 42-d | 42-b with `feature_count` off by one against the catalogue | `WITHHELD_NOT_VALIDATED` |
| 42-e | 42-b with `synthetic=true` | `RENDERED_SYNTHETIC_WATERMARKED`; watermark present; **not** the bare `VERIFIED` badge |
| 42-f | 42-a plus a listing marker at an eligible premises coordinate | marker displays; polygon does not; row text never implies a boundary |
| 42-g | greyscale + colour-vision-deficiency render of 42-a | badge still reads `PARTIAL / UNVERIFIED` in words (G-9) |

Fixture delta: `ADM-P-PARTIAL-GEOMETRY.expected_drawn` → `false` with `expected_polygon_render: WITHHELD_NOT_VALIDATED`, `expected_marker_display: PERMITTED_IF_ELIGIBLE_CENTRE`; `ADM-A2-…` gains `surface: "INTERNAL_PREVIEW"`.

### 2.5 Owner and decision

*Contract text:* Track G author. *Harness and fixtures:* `HC-01`. *Renderer:* Jaspr developer under a bounded synthetic-UI authorisation only (register, Handoff §4). *Independent verification:* the QA reviewer named by `ODR-2`, not `HC-01`.
**`ODR-R-01`** — adopt `GEOHD-01.1`–`01.5`, i.e. the preview/public separation, and accept that **no real polygon renders today**. Bucket `ADOPT_NOW`; status `PROPOSED`; **signing it removes an advertised capability, so it must not be signed on the assumption that a boundary will appear.**

---

## 3. `GEOH-REV-02` — numerical epsilon against positional uncertainty

### 3.1 Original contract clause (verbatim)

`GEOH-03` §9.4:

> **GM-GEO-11** | The boundary is **inclusive**: a venue is inside iff `measured ≤ R + tolerance`.
> **GM-GEO-12** | `tolerance` is a **required argument with no default**. An absent tolerance is an error (`E_TOLERANCE_UNSET`).
> **GM-GEO-14** | The **value** of the tolerance is unset (`null`) until the Owner adopts one. `0.5 m` remains a labelled example, not a policy.

> Measured, not asserted: at exactly `800.0 m` with `tolerance = 0` the venue is **included**; at `800.0000000000036 m` (3.6 × 10⁻¹² m of float noise) it is **excluded**; with `tolerance = 0.5` it is **included** again (`G-09-1`…`G-09-5`).

`GEOH-02` §2.4, `ODR-3-tolerance-policy`:

> A venue at exactly `R` is decided by floating-point noise (~3.6 × 10⁻¹² m reproduced); the contract must require a tolerance argument and reject a missing one.

and `ODR-3-tolerance-value`:

> The value must be derived from the rental's positional accuracy and published beside `R`.

### 3.2 Reproduction

1. `D-R-07` — **the two jobs differ by eleven orders of magnitude.** The example tolerance is `0.5 m`; the noise it is invoked to fix is `3.64 × 10⁻¹² m`; the ratio is **1.37 × 10¹¹**. A number sized to absorb metre-scale coordinate error is 140 billion times the representation noise it is advertised to repair. They cannot be the same quantity.
2. `D-R-07b` — the fixture already hides this: `boundary_cases` has **5 rows over 4 distinct venue ids**; `V-EDGE-NOISE` appears twice, separated only by tolerance, so one venue id carries two verdicts.
3. `D-R-06` — positional uncertainty is *collected but never used*: `classify_centre` reads `has_accuracy` as a boolean and contains no magnitude comparison, so a `1 m` survey and a `5 000 m` guess both return `ELIGIBLE` (`loose=ELIGIBLE tight=ELIGIBLE`).
4. `D-R-08` — `accuracy_m` appears **5** times in `GEOH-04`, **2** times in `GEOH-03`, and **0** times in the harness. The uncertainty that ought to decide boundary cases is the one number no predicate reads.
5. `GEOH-02`'s two tolerance rows point at the same word: the *policy* is justified by floating-point noise, the *value* is to be derived from positional accuracy. One argument cannot serve both masters — and the register's severity HIGH is justified.

### 3.3 Proposed replacement

> **`GEOHD-02.1` — two quantities, two names, no derivation between them.**
> `numerical_epsilon_m` — a **representation guard** on the difference `measured − R`, set by the implementation's arithmetic, published as an implementation constant, **not an Owner decision and not a policy**. It answers "is this difference distinguishable from zero at all?"
> `centre_uncertainty_m` (= `accuracy_m`, plus `entrance_offset_bound_m` for `BUILDING`) and `venue_extent_m` — **physical uncertainty**, recorded per rental. They answer "how far could the truth be?"
> Neither value may be computed from the other. `GM-GEO-14`'s "no adopted tolerance" is retained verbatim and now covers both.
>
> **`GEOHD-02.2` — membership is three-valued.**
> `INSIDE` iff `measured − R > +band` is false **and** `measured − R ≤ numerical_epsilon_m`;
> `OUTSIDE` iff `measured − R > numerical_epsilon_m` **and** `measured − R > band`;
> `BOUNDARY_UNDECIDED` iff `|measured − R| ≤ band` where `band = centre_uncertainty_m + venue_extent_m > numerical_epsilon_m`.
> `BOUNDARY_UNDECIDED` is emitted **only** when a real uncertainty was recorded; if no uncertainty was recorded there is no band and `GM-GEO-07`'s refusal applies before membership is ever computed.
>
> **`GEOHD-02.3` — an undecided venue is listed, never counted into either side.** It appears in the descriptive per-rental list with the reason `position straddles the stated radius`, and it is excluded from any `Competitor records` count by that reason code, so no count silently changes with the epsilon.
>
> **`GEOHD-02.4` — where the band matters, publish bounded distances instead of a point verdict.** The footprint record carries `R`, `centre_uncertainty_m`, `venue_extent_m` and the resulting band; the reader sees "`800 m ± 52 m" rather than a coin-flip inclusion (`GM-GEO-10` extended, not replaced).
>
> **`GEOHD-02.5` — the float guard alone must resolve the measured case with no Owner number adopted.** This is the property that makes `ODR-3-tolerance-value` genuinely defeasible: the noise case no longer requires a policy value.

New codes: `E_MEMBERSHIP_UNDECIDED` (informational, not a refusal), `E_BAND_NOT_RECORDED` (band requested without uncertainty).

### 3.4 Adversarial acceptance test — `GEOH-T-43` (tier L1, `NOT_EXECUTED`)

| # | Input | Expected |
|---|---|---|
| 43-a | `measured = 800.0`, `R = 800`, no uncertainty recorded | `INSIDE` (GM-GEO-11 preserved) |
| 43-b | `measured = 800.0000000000036`, `R = 800`, no uncertainty recorded, epsilon published | `INSIDE` **without any Owner tolerance** — the flip is gone |
| 43-c | `measured = 805.0`, `R = 800`, band 52 m | `OUTSIDE` — a real 5 m excess is not absorbed |
| 43-d | `measured = 800.002`, `R = 800`, `centre_uncertainty = 50 m` | `BOUNDARY_UNDECIDED`; listed; excluded from counts by reason |
| 43-e | `measured = 750`, `R = 800`, band 52 m | `INSIDE` (band must not swallow a real margin) |
| 43-f | `accuracy_m = 1.0` vs `accuracy_m = 5000.0`, otherwise identical fixtures | different **bands**; identical `ELIGIBLE` — proving eligibility is not a quality claim (DC-14) |
| 43-g | request membership with band requested but `accuracy_m = null` | `E_BAND_NOT_RECORDED` / GM-GEO-07 refusal — never a default band |
| 43-h | report text for 43-d | renders `800 m ± 52 m` and the word `undecided`; **no** digit-only inclusion claim |

### 3.5 Owner and decision

*Rule text:* Track G author + scientific reviewer. *Implementation constant:* Jaspr developer. *Band arithmetic:* scientific reviewer, because it changes what a count means.
**`ODR-R-02a`** (`ADOPT_NOW`) — accept that `numerical_epsilon_m` is an implementation constant, **not** an Owner policy, and that `ODR-3-tolerance-policy`'s justification is restated without the float-noise argument.
**`ODR-R-02b`** (`ADOPT_NOW`) — accept `BOUNDARY_UNDECIDED` as a third verdict and the rule that an undecided venue is listed but counted on neither side. **This is the row that touches a reported number, so it cannot be signed as "wording".**
`ODR-3-tolerance-value` remains `OPEN`, `LATER_REAL_DATA`, with **no number proposed**.

---

## 4. `GEOH-REV-03` — `E-2*` against a descriptive same-snapshot record comparison

### 4.1 Original contract clause (verbatim)

`GEOH-02` §3.1:

> **Proposed interpretation `E-2*`:** A cross-rental count requires that **both** footprints were answered from **one versioned snapshot** (`snapshot_id` + `source_release`) **and** that each footprint carries a **written completeness statement naming its area scope and date**. A coverage **label** is a precondition, not satisfaction. Two footprints labelled `UNKNOWN` fail `E-2*`.

> - It makes cross-rental counts **unreachable today**, because no examined source states completeness (`P5` §3.1).
> - **Descriptive per-rental lists remain fully available.**

`GEOH-04` §6.3 publishes the gate as the conjunction `… snapshot_id ∧ source_release ∧ display_rights_established ∧ has_written_completeness_statement ∧ sameWindow(…)`, and DC-42 refuses the equal-`UNKNOWN` case.

### 4.2 Reproduction

1. `D-R-09` — the fixture already isolates the mechanism: `CMP-2-BOTH-UNKNOWN-LABELS` sets `e1_equal_geometry: true`, `e2_equal_acquisition_scope: true`, `e3_shared_snapshot_window: true`, `both_displayable: true` and is refused **only** by `both_have_documented_completeness: false`. The register's reading is exact: completeness is the single term standing between "same snapshot" and "no comparison at all".
2. `D-R-10` — the published gate in `GEOH-04` §6.3 has **no de-duplication term** (2 gate lines, none mentioning de-duplication), although DC-40 makes the emitted number a de-duplicated union and DC-41 makes `dedup_rule` a named disclosed string. A comparison of *unions* is gated on *snapshot* terms only.
3. `GEOH-03` §11.4 already contains the sentence the register asks for. `S7`'s body:

> `<n> is a count of records, not of businesses: <k> merged duplicates, <e> excluded by category, <b> beyond the display radius.`

   So the record/semantics qualifier this overlay requires is **not new prose**; it is the frozen S7 wording, reused.

### 4.3 Proposed replacement — the Owner is given two explicit policies

`E-2*` is **not** weakened. The overlay adds a *separately named*, *narrower* rule and lets the Owner pick which regime governs.

> **Policy `E-2*` (strict, unchanged).** Any cross-candidate **count** requires the full conjunction already published, including a written completeness statement per footprint. Reachable today: **no**. `CMP-2` refuses.
>
> **`GEOHD-03.1` — Policy `E-2desc` (same-snapshot record sets), a distinct output.** Permitted **only** when every term below holds: both sides are `S7`; identical `snapshot_id`; identical `source`; identical `source_release`; identical declared observation window; display rights established on both sides; a **named, identical** `dedup_rule` on both sides; and the emitted sentence carries the frozen S7 qualifier `a count of records, not of businesses` **on each side independently**.
>
> **`GEOHD-03.2` — `E-2desc` is not a demand, suitability, ranking or coverage statement.** Any claim word in either emission string (`fewer`, `more than`, `denser`, `density`, `saturated`, `saturation`, `better`, `worse`, `ranking`) refuses the whole comparison. The check is per side, so **one honest side cannot launder the other** (`D-C-09b`).
>
> **`GEOHD-03.3` — adopting `E-2desc` adds no reachable output today.** It requires two `S7` sides from one licensed, rights-cleared snapshot; `ODR-4` is blank, ADM2/ADM3 are `LICENCE_CHAIN_UNVERIFIED — BLOCKED`, and no source carries a completeness statement. Verified: all four refused comparison fixtures (`CMP-2`…`CMP-5`) stay refused under the candidate rule (`D-C-10`, `refused comparison cases = 4`). **The overlay only refuses more; it unlocks nothing.**
>
> **`GEOHD-03.4` — the choice is recorded, not defaulted.** `COMPARISON_POLICY ∈ {E2_STRICT, E2_DESC}` with **no default**, failing closed like DC-46. The register asks that the rule not be "silently weakened"; a config value with no default is the mechanism that makes silence impossible.

### 4.4 Adversarial acceptance test — `GEOH-T-44` (tier L1, `NOT_EXECUTED`)

| # | Mutation | Expected |
|---|---|---|
| 44-a | two `S7` sides, identical snapshot/source/release/window/rule, both qualified | permitted, and the sentence says *records*, never *businesses* |
| 44-b | one side `S4` (empty result) | `REFUSED_EMPTY_SIDE` |
| 44-c | different `source` | `REFUSED_CROSS_SOURCE` |
| 44-d | different `dedup_rule` | `REFUSED_DEDUP_DIFFERS` |
| 44-e | `dedup_rule` absent on both | `REFUSED_DEDUP_UNDISCLOSED` (closes the gap `D-R-10` measured) |
| 44-f | one side's emission string loses `not of businesses`, the other keeps it | `REFUSED_NO_RECORD_SEMANTICS` — the laundering path is shut |
| 44-g | one side says "fewer nearby" | `REFUSED_CLAIM_WORD` |
| 44-h | `COMPARISON_POLICY` unset | fail closed, no number printed (DC-46 shape) |
| 44-i | `CMP-2` replayed under `E2_DESC` | still refused — **strictness is preserved** |

### 4.5 Owner and decision

*Policy choice:* **Owner alone** (the register marks this row `HIGH / OWNER SCOPE`). *Scientific review of what a record count can mean:* scientific reviewer before `E2_DESC` is usable at all. *Wiring:* Jaspr developer.
**`ODR-R-03`** — choose `E2_STRICT` or `E2_DESC` for the cross-candidate comparison, with `E-2*` unchanged in both branches. Bucket `ADOPT_NOW` for the *choice*; `E2_DESC` is additionally gated on scientific review, so a signature here is not a licence to emit the output.

---

## 5. `GEOH-REV-04` — display-only listing pins against eligible study centres

### 5.1 Original contract clause (verbatim)

`GEOH-04` §2.1:

> | `latitude` | decimal or `null` | conditional | −90 ≤ φ ≤ 90 | **DC-06** — required for `PREMISES`/`BUILDING`, **forbidden** for `AREA_ONLY`/`LISTING_PIN` |

`GEOH-03` §9.2:

> **GM-GEO-05** | Centre classes `AREA_ONLY` and `LISTING_PIN` are **ineligible** — refused, not degraded. | a pin that is not the premises standing in for it (S-03: one venue crosses the boundary at 760 m)

### 5.2 Reproduction

1. `D-R-11` — the fixture and the field rule disagree. `CC-4` is `{centre_class: "LISTING_PIN", has_coord: true, …, expected: "REFUSE_LISTING_PIN"}`: a pin that **carries a coordinate**, which DC-06 forbids, refused by a code about **eligibility**. No code in `GEOH-04` §10 expresses the contradiction — `E_CLASS_COORDINATE_CONTRADICTION` appears 0 times in the contract.
2. The refusal in `CC-4` is silent about the coordinate's *disposition*. A developer may read DC-06 as "drop the field at parse time" (so the marketplace pin can never be shown at all) or as "keep it, refuse the footprint". The register's UX complaint is exactly the first reading being forced.
3. `D-R-12` — the vocabulary has **one axis only**: 10 mentions of `LISTING_PIN` across `GEOH-03`/`GEOH-04` and **zero** words anywhere for a display-only position.

### 5.3 Proposed replacement

> **`GEOHD-04.1` — two orthogonal properties.** `centre_class` answers *"may this be the centre of a study footprint?"*. `display_role` answers *"may a position be drawn for this rental, and under what caption?"*. A rental may be `LISTING_PIN` **and** `DISPLAY_ONLY_MARKER`; it may never be `LISTING_PIN` **and** a footprint centre.
>
> **`GEOHD-04.2` — `display_location_hint` is optional and typed.** Fields: `hint_latitude`, `hint_longitude`, `hint_source` (closed set, `AGENT_LISTING_PIN` included), `hint_class`, and a mandatory `NOT_FOR_PROXIMITY` marker. It **cannot** be read by the distance function: `used_in_distance_math = true` on a hint is `E_DISPLAY_ROLE_USED_IN_QUERY`.
>
> **`GEOHD-04.3` — a `LISTING_PIN` that carries a *footprint* coordinate is a schema contradiction, not a silent downgrade.** New code `E_CLASS_COORDINATE_CONTRADICTION`; the fixture `CC-4` is re-expressed as a *hint* so its `has_coord: true` becomes lawful and its refusal stays about eligibility.
>
> **`GEOHD-04.4` — the marker is captioned, or it is not drawn.** `caption_states_artefact = false` ⇒ `E_MARKER_CAPTION_MISSING`. Under Option B the caption carries no timestamp (DC-44 unchanged) and names the artefact in words: "a marketplace pin, not the premises". **GM-GEO-05 is not relaxed**: `D-C-13` re-runs `CC-4` and `CC-5` through the predecessor's own `classify_centre` and both still refuse.

### 5.4 Adversarial acceptance test — `GEOH-T-45` (tier L1 + L0 UI, `NOT_EXECUTED`)

| # | Case | Expected |
|---|---|---|
| 45-a | `LISTING_PIN` + `display_location_hint` + `NOT_FOR_PROXIMITY` | approximate marker visible; **no circle**; footprint `REFUSE_LISTING_PIN` |
| 45-b | same, caption removed | `E_MARKER_CAPTION_MISSING`; marker suppressed; row still visible (DC-13) |
| 45-c | same, hint fed into the distance function | `E_DISPLAY_ROLE_USED_IN_QUERY`; no output |
| 45-d | same, plus a study circle drawn on the hint | `E_DISPLAY_ROLE_WITH_FOOTPRINT` |
| 45-e | `LISTING_PIN` with `latitude` set (the `CC-4` shape) | `E_CLASS_COORDINATE_CONTRADICTION` at parse, **not** a silent drop |
| 45-f | greyscale/a11y pass over 45-a | caption text alone distinguishes pin from premises (G-9) |
| 45-g | `AREA_ONLY` + hint | `REFUSE_AREA_ONLY` remains; a hint may still show as approximate with the `S3` state intact |
| 45-h | S-03 regression (the 760 m boundary crossing) | the hint changes **no** membership verdict; the study centre is unchanged |

### 5.5 Owner and decision

*Schema:* Track G author + rental teammate (`R-4`, `R-8`). *Caption wording:* Owner, because it is reader-facing text. *Implementation:* Jaspr developer.
**`ODR-R-04`** — permit `display_location_hint` as a display-only artefact with `NOT_FOR_PROXIMITY`. The register requires this be presented **as an Owner option**, and it is: the change alters DC-06's source semantics from *forbidden* to *permitted-as-hint, forbidden-as-centre*. Signing it does **not** sign `ODR-3c-exclusions`; that row stands unmodified.

---

## 6. `GEOH-REV-05` — `R12` provenance when no study footprint exists

### 6.1 Original contract clause (verbatim)

`GEOH-04` §7, the `ReportGeoProvenance` field table:

> | `footprint_ref` | string | **yes** | → `StudyFootprint.footprint_id` |

`GEOH-04` §1:

> **DC-01 — One object, one question.** … A later stage may **refuse** an earlier stage's output; it may never **repair** it.

`GEOH-04` §1.1:

> Every arrow is a **hard** dependency: if the source object is refused, every object downstream is `WITHHELD` with a propagated reason code.

`GEOH-03` §11.4, the S3 body that is nevertheless required to render:

> `Competitor records are listed against a resolved area. This premises has no resolved area, so no query was issued.`

### 6.2 Reproduction

1. `D-R-13` — `footprint_ref` is `string | yes`, i.e. **mandatory and non-null**, while S1 and S3 are reachable with **no footprint**: S1 has no licensed source, S3 has no resolved area and issues no query. Under §1.1 a refused `StudyFootprint` makes `ReportGeoProvenance` `WITHHELD`, so the audit row that would *explain* the refusal is itself withheld. The register names this exactly.
2. `D-R-14` — there is no vocabulary to distinguish "no audit row" from "audit row for a refused footprint": `footprint_state` and `REFUSED_NOT_COMPUTED` appear **0** times in `GEOH-04`. The two cases are byte-indistinguishable.
3. `GEOH-05`'s own rows confirm the demand: `GEOH-T-31` ("`WITHHELD` propagates to every downstream object; the row stays visible") and `GEOH-T-32` ("listed with a reason code; footprint withheld; `null ≠ 0`"). **The tests already ask for an audit trail the schema cannot carry.**

### 6.3 Proposed replacement

> **`GEOHD-05.1` — `R12` is total over refusals.** Exactly one `ReportGeoProvenance` row exists for every emitted `R09` state, **including** S1, S2 and S3, and including the case where no footprint was ever computed.
>
> **`GEOHD-05.2` — `footprint_ref` becomes `string | null`, nullable by declared cause, never by omission.** New companion fields: `footprint_state ∈ {COMPUTED, REFUSED_NOT_COMPUTED}` and, when refused, a **required** `footprint_withheld_reason_code` drawn from the existing `E_*` vocabulary (`E_AREA_ONLY`, `E_LISTING_PIN`, `E_NO_COORD`, `E_NO_PROVENANCE`, `E_NO_ACCURACY`, `E_LAYER_NOT_VALIDATED`, `E_SOURCE_NOT_LICENSED`, …). A row may not exist with `footprint_ref = null` and no reason code: that is DC-11's "absence is invalid, not `false`", applied to R12.
>
> **`GEOHD-05.3` — a field computed for a query that never ran is a false assertion.** When `footprint_state = REFUSED_NOT_COMPUTED`, `distance_method`, `footprint_version`, `tolerance_policy` and `boundary_tolerance_m` are **null**, not the constants. `D-C-15` implements `method_asserted_without_query` precisely to catch the "SPHERICAL_HAVERSINE_R6371000 recorded against a circle that does not exist" defect.
>
> **`GEOHD-05.4` — placeholders are refused.** `""`, `"N/A"`, `"none"`, `0` are invalid where `null` is lawful (GM-GEO-23 `null ≠ 0 ≠ false`, extended to strings).
>
> **`GEOHD-05.5` — rights and licence fields keep their own truth.** `rights_state` and `licence_id` are populated **even when the footprint is refused**, because the refusal of a circle says nothing about whether a boundary may be displayed. This is Rule G-2 (independence of failure) applied inside one row.

New codes: `E_R12_MISSING_FOR_STATE` (an `R09` state with no audit row), `E_NULL_REF_WITHOUT_REASON`.

### 6.4 Adversarial acceptance test — `GEOH-T-46` (tier L1, `NOT_EXECUTED`)

| # | Case | Expected |
|---|---|---|
| 46-a | `AREA_ONLY` candidate through `R09` **and** `R12` (the register's explicit ask) | `R09` renders S3-shaped refusal; `R12` emits **one** row: `footprint_state=REFUSED_NOT_COMPUTED`, `footprint_ref=null`, reason `E_AREA_ONLY`, rights fields present |
| 46-b | no licensed source at all | one row; `rights_state`/`licence_id` recorded; every geometry field null |
| 46-c | refused footprint but `distance_method` populated | `E_*` violation — the false assertion is caught |
| 46-d | `footprint_ref=""` | refused as a placeholder (46-d fails, 46-a passes) |
| 46-e | `footprint_ref=null` with no reason code | `E_NULL_REF_WITHOUT_REASON` |
| 46-f | `R09` state emitted with **no** `R12` row | `E_R12_MISSING_FOR_STATE` — a reader is left with an unexplained claim |
| 46-g | real rental with `R-1`…`R-8` unanswered (`T-32` shape) | row visible; `null ≠ 0` preserved; no invented circle |

### 6.5 Owner and decision

*Schema:* Track G author. *Reason-code list:* must reuse `GEOH-04` §10, not grow it — developer confirms no new vocabulary. *Audit-row display:* Jaspr developer.
**`ODR-R-05`** — make `R12` total over refusals as above. Bucket `ADOPT_NOW`; it **only adds an audit row and forbids a false one**, so it manufactures no claim.
**Amendment consequence (must be disclosed):** `ODR-3-r12-fields` is the field list Owner is presently invited to sign. `GEOHD-05.2` changes it (`footprint_ref` required → nullable-with-reason, plus `footprint_state` and `footprint_withheld_reason_code`). **`ODR-3-r12-fields` is therefore signable only as amended**, and `ODR-3-copy-option` depends on it (`GEOH-02` §5).

---

## 7. `GEOH-REV-06` — accessible `R09` → `R12` linkage, and Option B's real prerequisites

### 7.1 Original contract clause (verbatim)

`GEOH-03` §11.3, Option B:

> **S1–S5 contain no digit anywhere in the block** … **and not in the provenance line**, which **names the source and carries no timestamp**. The retrieval date and the dataset's own vintage are recorded once, per source and per query, in the report's evidence snapshot audit row (`R12`), **which each block names in words**.

`GEOH-04` DC-44:

> Under the recommended **Option B**, **no** date or provenance numeral appears inside an S1–S5 body; **the audit row is a separate accessible region**.

`GEOH-04` §6.1 (the shape used by every block):

> `provenance_ref   : string | null   # pointer to ReportGeoProvenance`

### 7.2 Reproduction

1. `D-R-15` — the pointer Option B is built on is **the one field allowed to be absent**. "Names in words" is prose; `provenance_ref` is nullable; nothing requires the words to resolve to the row.
2. `D-R-16` — across `GEOH-03`, `GEOH-04` **and** `GEOH-05` there are **0** occurrences of `aria`, `describedby`, `focusable`, `focus order`, `screen reader`, `keyboard`, `tab stop`, `provenance_id` or `stable id`. "A separate accessible region" is a phrase (2 occurrences in `GEOH-04`) with no acceptance criterion behind it. The register's MEDIUM/UX severity is well founded: under Option B the linkage is **load-bearing**, because it is the only path from a digit-free block to a date.
3. `D-C-18` — Option B's prerequisites are all present in `GEOH-02` (`ODR-3-r12-fields`, `ODR-3-copy-option`, `ODR-3-blockboundary`), and `E_OPTION_UNSET` is marked "**specified**" in the ledger: DC-46's fail-closed behaviour is designed and unenforced, exactly like the linkage.

### 7.3 Proposed replacement

> **`GEOHD-06.1` — every `ReportGeoProvenance` row carries a stable `provenance_id`**, opaque, non-reused (DC-02's discipline, moved from rental ids to audit rows).
>
> **`GEOHD-06.2` — under Option B, `provenance_ref` is required, not nullable.** It may be `null` **only** where no row exists, and `GEOHD-05.1` makes that impossible. Refusals: `E_PROVENANCE_REF_ABSENT`, `E_R12_ORPHAN_REFERENCE`.
>
> **`GEOHD-06.3` — "names in words" is replaced by a programmatic association.** Each block links to its row by a real accessibility relation (`aria-describedby` or the platform equivalent), reachable by keyboard, announced by a screen reader, and surviving collapse/clipping. `link_is_programmatic = false` ⇒ `E_PROVENANCE_LINK_NOT_PROGRAMMATIC`. Textual naming remains as a **label**, never as the mechanism.
>
> **`GEOHD-06.4` — the link survives export.** In a PDF/plain-text export the row is inlined adjacent to the block or a stable anchor is emitted; otherwise `E_PROVENANCE_LINK_LOST_IN_EXPORT`. Rule G-13 (attribution travels) already implies this for rights; it now covers the date.
>
> **`GEOHD-06.5` — the linkage itself is digit-screened.** `D-C-17` demonstrates the failure mode: a date reaching the block *through the linkage* reproduces defect F-4 exactly, and is caught by the same screen (`E_R12_DIGIT_LEAKED_INTO_BLOCK`). This is why the linkage is a contract term and not an implementation detail.

### 7.4 Adversarial acceptance test — `GEOH-T-47` (tier L1 + **L0 UI**, `NOT_EXECUTED`; requires the browser run `PC-5` cannot currently provide)

| # | Case | Expected |
|---|---|---|
| 47-a | keyboard-only traversal from an `S4` block to its `R12` row and back | reachable in both directions, focus visible, no trap |
| 47-b | screen-reader announcement of the block | state text, then the association to the row, with no date inside the block |
| 47-c | panel collapsed / viewport clipped | association preserved in the accessibility tree |
| 47-d | exported to plain text and PDF | row present adjacent to the block, or a stable anchor (`E_PROVENANCE_LINK_LOST_IN_EXPORT` otherwise) |
| 47-e | rental label `No. 12, Jalan Contoh` in a heading adjacent to the block | `12` remains **outside** the block (reading (i) of `ODR-3-blockboundary`) and does **not** trip a whole-clause `E_DIGIT` (hazard `D38`) |
| 47-f | a date injected through the linkage | `E_R12_DIGIT_LEAKED_INTO_BLOCK` |
| 47-g | `provenance_ref` pointing at a nonexistent row | `E_R12_ORPHAN_REFERENCE` |
| 47-h | `ADOPTED_OPTION` unset | no render, `E_OPTION_UNSET` — the specified refusal actually fires |

### 7.5 Owner and decision

*Accessibility requirement:* Owner + whoever owns report rendering; it cannot be satisfied by a documentary check alone. *Prerequisite order:* unchanged — `ODR-3-r12-fields` **before** `ODR-3-copy-option` (`GEOH-02` §5). *QA:* the independent reviewer, with a real browser (`PC-5`).
**`ODR-R-06`** — adopt `GEOHD-06.1`–`06.5` as a **prerequisite of Option B**. Bucket `ADOPT_NOW`, but it converts a recommendation into a gated dependency: **`ODR-3-copy-option` is signable only as amended**, because Option B as recommended is not implementable without the linkage.

---

## 8. `GEOH-REV-07` — the 88 documentary checks, the 41 unexecuted tests, and independent verification

### 8.1 What the register says it could not check

> **Independent file integrity:** 6/6 uploaded Markdown files match recorded SHA-256. The fixture JSON, Python harness, and execution log were **not uploaded**; consequently the full nine-file manifest and 88 HOLDS are **not independently reproducible in this review**.

That is a fair statement about the reviewer's inputs, and it is the one finding in the register that can be closed by evidence rather than by argument.

### 8.2 Evidence now supplied (all machine-run inside this package)

| Claim under test | Result | Check |
|---|---|---|
| The three un-uploaded artefacts are byte-identical to the pinned originals | fixture `2c937661…`, harness `d0c834c4…`, log `c8d0ab2e…` | `D-P-02`, `D-P-01`, `D-P-03` |
| The **full 9-line manifest** verifies | `9/9 lines verify; failures=[]`; `sha256sum -c` **exit 0** twice, before and after this work | `D-P-04` |
| **88 HOLDS is reproducible by a third party** | rerun in a scratch tree: `{'exit': 0, 'checks': 88, 'holds': 88, 'violated': 0, 'log_matches_pinned': True}` — byte-identical output | `D-P-08` |
| The rerun does not disturb the pinned copy (`GEOH-05` §10.1's ordering hazard) | pinned log still `c8d0ab2e…` after the run | `D-P-09` |
| The 20 earlier ODR-3 experiments still match their pins and were **not** re-run | `ODR3` pins `failures=[]`; `{'designed_not_run': 6, 'executed': 20, 'holds': 18, 'violated': 2}` (`C-2`, `C-6`) | `D-P-05`, `D-P-06` |

### 8.3 The distinction the register asks to be preserved, measured

`GEOH-05` §4's Today column cites harness ids. `_build/build_split.py` parses those citations against the reproduced log and emits `data/HARNESS_CHECK_TO_TEST.csv` (88 rows) and `data/TEST_EVIDENCE_TIER.csv` (41 rows). Machine-derived (`D-R-20`, recomputed and equal):

| Measure | Value |
|---|---|
| harness checks emitted | **88** |
| cited by at least one test | **77** |
| cited by **no** test | **11** (`G-10`, `G-11-R400-T0_0`, `-R500-`, `-R800-T0_0`, `-R800-T0_5`, `-R1200-`, `G-12`, `G-15`, `G-21`, `G-31`, `G-33`) |
| cited by a **specific** reference | **31** |
| covered **only** by an imprecise reference (shared glob or dangling prefix) | **46** |
| dangling citation tokens | **1** — `GEOH-T-23` cites `G-24`, which is not an emitted id; it matches 11 child ids |
| Jaspr acceptance tests specified | **41** |
| tests with ≥1 harness citation | **30** |
| tests with **no** harness citation | **11** (`T-05`, `-07`, `-08`, `-22`, `-31`, `-32`, `-33`, `-34`, `-35`, `-37`, `-40`) |
| Today cells holding a status word instead of an id | **11** |
| evidence tiers | `SPECIFIC_CITATION` 23, `IMPRECISE_CITATION_ONLY` 7, `NO_HARNESS_EVIDENCE` 11 |
| tests executed against an application | **0 / 41** |

`D-C-21` adds the arithmetic that makes the headline number modest: **88 = 64 fan-out instances from 10 parameterised families + 24 standalone assertions**. Eleven of the 64 come from `admin_resolutions` alone. **Adding a fixture row changes the number 88 without changing a single rule.**
`D-R-25` adds the vocabulary nit with teeth: the constant that holds the five display states is named `FOUR_STATES` and has **5 members** — in a package whose subject is exact denominators.
`D-R-24` states the risk directly: the reproduced log's final line is `VERDICT: PASS (contract self-check only; adopts nothing)`. **A token literally reading `PASS` in the artefact `GEOH-05` cites as L0 evidence is how a documentary check comes to be remembered as a test result.**

### 8.4 Proposed replacement

> **`GEOHD-07.1` — two numerators, never merged.** Every GEOH output states `documentary_checks_run / acceptance_tests_executed` as a pair, e.g. `88/0`, `62/0`. A single number is not permitted.
> **`GEOHD-07.2` — the harness verdict line is rewritten** to `VERDICT: 88 HOLDS / 0 VIOLATED — documentary contract self-check only; no Jaspr test executed; nothing adopted`, dropping the token `PASS`.
> **`GEOHD-07.3` — every acceptance row carries an `evidence_tier`** (`SPECIFIC_CITATION` / `IMPRECISE_CITATION_ONLY` / `NO_HARNESS_EVIDENCE`) and an `executed_against_an_application` flag; both columns are populated for all 41 rows in `data/TEST_EVIDENCE_TIER.csv`. `D-C-22` verifies no row can read as a pass.
> **`GEOHD-07.4` — citations name emitted ids only.** `GEOH-T-23`'s `G-24` becomes `G-24-ADM-P-PARTIAL-GEOMETRY` plus the `G-25` reference; a glob is acceptable in a table cell **only** with the count it expands to (`G-24-ADM-* (11)`).
> **`GEOHD-07.5` — the reproduction kit travels with the package.** A reviewer gets the fixture, the harness, the log and this overlay, and is expected to run the three commands in `00_READ_FIRST` §4 rather than trust a quoted count. The register's "supply fixtures/harness/log to independent QA" is discharged by `inputs/` + `_verify/` in this package. **Selective rerun, not re-research:** the 20 ODR-3 rows stay reused under their own pins (`D-P-06`); they were not re-executed.

### 8.5 Adversarial acceptance test — `GEOH-T-48` (tier **L0 + QA process**, `NOT_EXECUTED`)

| # | Step | Expected |
|---|---|---|
| 48-a | `sha256sum -c SHA256_MANIFEST.txt` in the predecessor | 9 `OK`, exit 0 |
| 48-b | run the harness **in a scratch copy**, compare the produced log | 88 checks, 88 HOLDS, exit 0, byte-identical log; pinned log unchanged |
| 48-c | `python -B _verify/geoh_delta_check.py` | 62 checks, 62 HOLDS, exit 0 |
| 48-d | recompute `data/split_summary.json` and diff | byte-stable, `consistent: true` |
| 48-e | scan `GEOH-05` §4 for any row that implies an executed test | 0 rows; every row's Today cell is a check id or a status word, and `T-08`/`T-35` remain "not executed" |
| 48-f | confirm `AC-05`'s exclusivity | exactly one row may be `BLOCKED_SOURCE` (`T-32`), one `ABSENT_INPUT` (`T-40`), the rest `NOT_EXECUTED` |

### 8.6 Owner and decision

*Reproduction kit:* `HC-01` (already delivered by this package). *Reviewer appointment:* **Owner** — `ODR-2` is blank and `H3` is `REVIEW_NOT_EXECUTED`. *Application tests:* the appointed independent QA reviewer, **who must be neither `HC-01` nor the implementer** (register, Handoff §3).
**`ODR-R-07`** — appoint the independent reviewer and adopt the vocabulary rules `GEOHD-07.1`–`07.5`. Bucket `ADOPT_NOW` for the vocabulary; the appointment is a **personnel** decision this package cannot make and does not pretend to.

---

## 9. `GEOH-REV-08` — the S / I / G axes in acceptance tests

### 9.1 Original clause and reproduction

`GEOH-05` §4.4 (`D-R-17`, verbatim):

> | **GEOH-T-23** | **`S_PARTIAL`** — 5,973/6,334 coords, 4,209 shifted | U | marker inside a partially-geolocated area, clipped geometry | **`partial`**; marker drawn; **no** precision claim | `ADM-P-PARTIAL-GEOMETRY` | `G-24`, `G-25` |

`S_PARTIAL` is a **Site**-axis fact about a *source* (from `GEOH-01` P6: 5,973 of 6,334 rows carry coordinates, 4,209 record a shift, 336 substitute a district median). `partial` in §4 is a **Geometry**-axis state about a *boundary layer*. The row's finding is one axis and its expected result is the other, so passing the test would require a coupling that no object expresses. `D-R-18` closes it: the fixture `ADM-P` carries **no** coordinate, accuracy or site field (`keys=['case_id','district','expected_district_state','expected_drawn','expected_mukim_state','jurisdiction','mukim']`) — the evidence cannot reach the precondition.

Three axes are already used elsewhere in the package and are named here for the first time in one place:

| Axis | Question | Vocabulary | Source of evidence |
|---|---|---|---|
| **S** — site/source coordinate quality | do the *listings* have positions, and of what kind? | `S_YES` / `S_PARTIAL` / `S_NO` / `S_MEDIAN` (336 district medians) | `GEOH-01` P6 |
| **I** — identity / coverage | does the area *name* resolve, and for how many rows? | `I_YES` / `I_NO` (8.9 % Selangor district-name coverage) | `GEOH-01` P6 |
| **G** — geometry / rights | may a *polygon* be displayed? | `ABSENT` / `UNVALIDATED` / `VALIDATED_LICENSED`, plus DC-21's gates; `G_NO` for every tier today | `GEOH-03` §7 |

`D-C-19` shows the risk concretely: give the predecessor's `admin_state` a tier that is `UNVALIDATED` for a listing whose coordinate is a **district median**, and it returns `partial` — a display state — although `GEOH-03` §6 puts Case G **first** precisely because a median "poisons every later step". The state machine has no memory of the short-circuit that the case matrix mandates.

### 9.2 Proposed replacement

> **`GEOHD-08.1` — every acceptance row states its three axes explicitly**, e.g. `S=S_PARTIAL, I=I_YES, G=UNVALIDATED → state partial, polygon withheld, marker per GEOHD-01.5`. No row may be written with a finding on one axis and an expectation on another.
> **`GEOHD-08.2` — S is evaluated before G and can short-circuit it.** A `S_MEDIAN` listing yields `SITE_BLOCKED_NO_TIER_EVALUATION` (or the Case-G outcome) **without** deriving a geometry state. `D-C-19` proves the candidate does this and the predecessor does not.
> **`GEOHD-08.3` — `S_PARTIAL` never implies `G=UNVALIDATED`, and `G=UNVALIDATED` never implies `S_PARTIAL`.** `D-C-20`: the candidate function is total over the four site states and derives no tier from a site value.
> **`GEOHD-08.4` — the axis names appear in the fixture too.** `ADM-*` cases gain `site_state`, `identity_state`, `geometry_state`; the `G-24-*` family then asserts the triple, not a single `drawn` boolean.

### 9.3 Adversarial acceptance test — `GEOH-T-49` (tier L1, `NOT_EXECUTED`)

| # | Triple | Expected |
|---|---|---|
| 49-a | `S_PARTIAL`, `I_YES`, `G_ABSENT` | state `named`; **no** polygon; marker permitted if the centre is eligible |
| 49-b | `S_YES`, `I_YES`, `G_UNVALIDATED` | state `partial`; polygon `WITHHELD_NOT_VALIDATED` (GEOHD-01.2) |
| 49-c | `S_MEDIAN`, `I_YES`, `G_VALIDATED_LICENSED` | Case G **first**: no marker, no zone claim, and **no** `partial` derivation (`D-C-19`) |
| 49-d | `S_NO`, `I_NO`, `G_ABSENT` | `unresolved` (or `notApplicable` if the tier is undefined) and the listing stays visible (DC-13) |
| 49-e | `G_VALIDATED_LICENSED` with `I_NO` | rights and identity are independent failures (G-2, G-7) — the conjunction is stated, never inferred |
| 49-f | the 336 district-median rows | counted on the S axis only; **no** geometry state is derived for them |

### 9.4 Owner and decision

*Matrix rewrite:* Track G author + `HC-01` (the `GEOH-05` §4 table is theirs to regenerate). *Fixture fields:* `HC-01`. *Execution:* independent QA.
**`ODR-R-08`** — adopt the three-axis row format for `GEOH-T-01`…`T-49`. Bucket `ADOPT_NOW`. It changes **no** rule semantics; it changes what a test row is allowed to assert. `GEOH-REV-08` is LOW severity in the register and stays a documentation change.

---

## 10. Errata against earlier text (AC-D3 pre-registration, corrected as numbered errata)

| Erratum | Where | Wrong expectation | Correction |
|---|---|---|---|
| `GEOHD-E1` | `GEOH-05` §4.4 `GEOH-T-23` | finding on the **S** axis, expected result on the **G** axis, plus citation `G-24` which is not an emitted id | rewritten as `T-49` triples; citation becomes the exact child ids (`D-R-17`, `D-R-22`) |
| `GEOHD-E2` | `GEOH-05` §4.4 `GEOH-T-24` | "A1 `partial` drawn" | Case A1 is `named`, **not drawn** (`GEOH-03` §6, fixture `ADM-A1`); the row was written for A2 and mislabelled A1 (`D-R-05`) |
| `GEOHD-E3` | `GEOH-05` §4.4 `GEOH-T-30` | expects `subject_to: DISTRICT_MEDIAN` | `subject_to` appears **0** times in `GEOH-03` and `GEOH-04`; either add the field to `AdministrativeAreaResolution` or drop the expectation (`D-R-19`) |
| `GEOHD-E4` | Owner directive vs register | the directive's 7th/8th priorities are transposed relative to the register's rows | this overlay follows the **register**: `REV-07` = assurance, `REV-08` = S/I/G |
| `GEOHD-E5` | this overlay, first draft | `E-2desc` initially screened claim words and the record qualifier over the **concatenation** of both emission strings, so one honest side could launder the other | the screen is **per side**; caught by the harness failing `D-C-09`, corrected and re-run (`D-C-09b`) |
| `GEOHD-E6` | `GEOH-03` §4 / harness | `expected_drawn` is one boolean for two objects (polygon vs marker) | split per `GEOHD-01.5` (§2.2 item 6) |
| `GEOHD-E7` | this overlay's `_verify/geoh_delta_check.py` | the reproduction command was asserted to exit 0 for **any** reviewer | first exit-code check ran with stdout **redirected to a file** and exited **1** on `UnicodeEncodeError: 'charmap' … '\u2227'`: a default Windows cp1252 stdout cannot encode the report text, although the UTF-8 log wrote correctly and all 62 checks held. Fixed by reconfiguring stdout to UTF-8 before the write; the log digest is byte-identical before and after (`3a618f9d…`), and both a redirected and a console run now exit 0. The predecessor's pinned harness has the same latent hazard and was **not** modified (frozen; `D-P-01` still HOLDS). |

`GEOHD-E5` and `GEOHD-E7` are recorded because **the delta harness caught the author's own errors before publication** — E5 as a `VIOLATED` check (`D-R-08`, `D-C-09`, exit 2), E7 as a non-zero exit under the exact command this package tells a reviewer to run.

---

## 11. Consolidated schema delta (everything a developer needs in one place)

**New fields.** `RentalLocationFixture`: `display_location_hint{hint_latitude, hint_longitude, hint_source, hint_class}` + `NOT_FOR_PROXIMITY`. `AdministrativeAreaResolution`: `site_state`, `identity_state`, `geometry_state` (already on the layer, now surfaced), `expected_polygon_render`, `expected_marker_display`. `StudyFootprint`: `centre_uncertainty_m`, `venue_extent_m`, `numerical_epsilon_m` (implementation constant, published). `ReportGeoProvenance`: `provenance_id`, `footprint_state`, `footprint_withheld_reason_code`; `footprint_ref` `string|yes` → `string|null`. `CompetitorEvidenceState`: `dedup_rule` (exists) now **required** whenever a count or record-set comparison is emitted.

**New states/verdicts.** `polygon_render_state ∈ {RENDERED_LICENSED, RENDERED_SYNTHETIC_WATERMARKED, WITHHELD_NOT_VALIDATED, NO_GEOMETRY_TO_RENDER}`; membership gains `BOUNDARY_UNDECIDED`; `COMPARISON_POLICY ∈ {E2_STRICT, E2_DESC}`, **no default**.

**New error codes.** `E_CLASS_COORDINATE_CONTRADICTION`, `E_MARKER_CAPTION_MISSING`, `E_DISPLAY_ROLE_WITH_FOOTPRINT`, `E_DISPLAY_ROLE_USED_IN_QUERY`, `E_MEMBERSHIP_UNDECIDED`, `E_BAND_NOT_RECORDED`, `E_R12_MISSING_FOR_STATE`, `E_NULL_REF_WITHOUT_REASON`, `E_PROVENANCE_REF_ABSENT`, `E_R12_ORPHAN_REFERENCE`, `E_PROVENANCE_LINK_NOT_PROGRAMMATIC`, `E_PROVENANCE_LINK_LOST_IN_EXPORT`, `E_R12_DIGIT_LEAKED_INTO_BLOCK`, `E_SYNTHETIC_BADGE_MISMATCH`.

**Unchanged and explicitly not relaxed.** `GM-GEO-05` (both classes ineligible as centres), `GM-GEO-15` (never clamp), `GM-GEO-16` (display = study), `GM-GEO-20`/`21` (union, never merge across sources), `GM-GEO-23` (`null ≠ 0 ≠ false`), DC-01, DC-11, DC-13, DC-14, DC-44, DC-46, the six forbidden parent inferences (G-10), the `BANNED` phrase list, the S1–S5 digit rule, `E-2*`'s strict form, and every gate residue (`H0`, `H3`, `H4b`, `H-F`, `ODR-1/2/4`, `SGD-25`, `FRG-G08`, `T03/T06/T07`).

**Counts after this overlay.** Owner rows `21 → 30` (`+9`, 0 signatures). Jaspr tests `41 → 49` specified, **0 executed**. Documentary self-check assertions: predecessor 88, this overlay 62. **Readiness: L0.**

---

## 12. What this overlay does **not** establish

| Not established | Because |
|---|---|
| that any REV is adopted | every rule is `PROPOSED_FOR_OWNER_ADOPTION`; 0 signatures |
| that a polygon may be drawn | `GEOHD-01` removes a claimed capability; BL-1…BL-4 still fail for every tier |
| that a boundary layer is licensed | ADM2/ADM3 `LICENCE_CHAIN_UNVERIFIED — BLOCKED`; MyGDI `SOURCE_NOT_ACCESSIBLE` |
| that any tolerance, radius or accuracy maximum exists | `ODR-3-tolerance-value`, `ODR-3a-prod` stay `OPEN`; no number proposed |
| that a `E2_DESC` output may be emitted | it requires scientific review plus two rights-cleared `S7` sides; **0 exist** |
| that Jaspr compiles or that any screen exists | no toolchain (`PC-4`), no browser run (`PC-5`) |
| that `GEOH-T-42`…`T-49` pass | none has been executed against an application |
| that the predecessor was wrong to publish | it was right to publish as `PROPOSED_FOR_OWNER_ADOPTION`; the contradictions were text-internal and are now named |
| that the 88 checks mean much on their own | **88 = 64 fixture fan-out instances + 24 assertions** (`D-C-21`) |

**AC-D10 — the honest one-line status.** *The challenge was real, every one of the eight findings reproduced against the pinned bytes, the corrections are narrower than the original contract and refuse strictly more, and a reviewer can now reproduce all nine files and both harness runs — but nothing is adopted, no polygon may be drawn, no number is chosen, and no Jaspr test has been executed.*
