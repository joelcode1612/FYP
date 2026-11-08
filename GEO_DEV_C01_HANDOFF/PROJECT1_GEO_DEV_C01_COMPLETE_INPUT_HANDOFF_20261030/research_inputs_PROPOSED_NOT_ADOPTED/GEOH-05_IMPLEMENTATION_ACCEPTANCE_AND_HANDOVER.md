# GEOH-05 — Implementation acceptance and handover

**Status:** `DOCUMENTARY_HANDOVER_READY` — **and nothing more.** No test below has been run against a Jaspr application. No Dart toolchain exists in this environment.
**Custodian:** `HC-01`. **Date:** 2026-10-30. **Independent QA owner: unassigned** (§6).

---

## 1. The four readiness levels, kept apart

The directive requires that four very different claims never collapse into one word.

| Level | Claim | Evidence required | True today |
|---|---|---|---|
| **L0** | *documentary handover ready* — the contract, decision matrix, fixtures and acceptance criteria are complete and hash-pinned | this package, `SHA256_MANIFEST.txt`, `logs/geoh_contract_check.log` | **yes**, subject to §7 residuals |
| **L1** | *Jaspr compiles and its own tests pass* | `dart pub get`, `dart test`, `jaspr build` with logged versions and exit codes | **no** — toolchain absent (`GEOH-01` §3); `NOT_EXECUTED`, never `PASS` |
| **L2** | *a real rental is integrated* | teammate `R-1`/`R-4`/`R-7`/`R-8` answered; adapter built; a real `rental_id` resolved end-to-end | **no** — `R-1`…`R-8` unanswered |
| **L3** | *licensed real competitor evidence is displayed* | ODR-4 four-way rights granted; a versioned snapshot with a written completeness statement; the cross-candidate gate satisfied | **no** — ODR-4 and H-F postponed |

> **AC-00 — A package cannot skip a level.** L0 does not imply L1: a correct specification and a compiling application are different achievements. L1 does not imply L2 or L3: a green Dart suite proves arithmetic, not that a rental exists. Writing `PASS` at any level without that level's evidence is a manufactured approval, which `AGENTS.md` forbids.

**The 20 executed synthetic cases are reused, not re-run.** `P1` §3.2–3.3 records 18 `HOLDS` and 2 `VIOLATED`; the two `VIOLATED` rows are **C-2** (`D-1`, the silent clamp) and **C-6** (`F-2`, float-decided boundary). They are reused here as the *expected-before-fix* baselines of `GEOH-T-01` and `GEOH-T-02`. Re-executing them would reproduce the same numbers and add no evidence.

---

## 2. Acceptance vocabulary — five verdicts, not three

Every row below resolves to exactly one of `WGC_06` §4's five values (`P12`):

| Verdict | Meaning in this package |
|---|---|
| `HOLDS` | the contract rule is implemented and the test passes |
| `VIOLATED` | the implementation contradicts the rule |
| `BLOCKED_SOURCE` | the input exists but is not approved or not present in the required form |
| `ABSENT_INPUT` | the input does not exist — *"I have no registry"*, never merged into `BLOCKED_SOURCE` |
| `NOT_VERIFIABLE` | cannot be determined — never used to mean *absent* |

**AC-01 — `ABSENT_INPUT ≠ BLOCKED_SOURCE`.** The distinction is the reason `WGC_06` exists; a harness that reports the first as the second is a finding, not a nuisance.

**AC-02 — the baseline verdicts for every row here are `NOT_EXECUTED`.** That is a sixth state this package uses deliberately: *specified, not run*. It is not a synonym for `NOT_VERIFIABLE`, which means *run and indeterminate*.

---

## 3. The nine existing developer obligations, mapped not replaced

`docs/01_GEOMETRY_AND_REPORT_TECHNICAL_SPEC.md` §7 (`P20`, `2ee97660…`) already defines nine obligations. This package does not invent a parallel set; it supplies the preconditions and expected results those rows lack.

| Existing ID | Existing status | Becomes | Difference |
|---|---|---|---|
| `GEO-D1` | "Dart test provided, not executed" | `GEOH-T-01` | adds the 9-value acceptance/refusal table and a no-clamp observation |
| `GEO-F2` | "provided, not executed" | `GEOH-T-02` | replaces one edge case with **five**, including the real 3.6×10⁻¹² m case and a genuine 5 m excess |
| `GEO-POS` | "provided, not executed" | `GEOH-T-09` | adds `E_PROVENANCE_UNRECOGNISED` and the `BUILDING` offset bound |
| `GEO-GM12` | "provided, not executed" | `GEOH-T-03`, `-04`, `-11`…`-17` | splits one obligation into nine, one per state plus two text screens |
| `GEO-COMP` | "provided, not executed" | `GEOH-T-18`…`-21` | splits into E-1, E-2*, E-3* and the gate |
| `GEO-UI` | "**not executed**" | `GEOH-T-08`, `-35` | two browser tests; `H3F-01` remains open |
| `GEO-TILE` | "JS static source inspect only; no browser run" | `GEOH-T-35` | a browser run, not a source read |
| `GEO-INT` | "**blocked** until teammate handover" | `GEOH-T-32` | unchanged status; now has a precondition list |
| `GEOH-*` (new) | — | `GEOH-T-22`, `-23`…`-31`, `-33`, `-34`, `-36`…`-39` | findings the developer spec did not enumerate |

---

## 4. Acceptance matrix — one finding, one test

Each row names the **single** test that decides it. The reverse index in §5 proves no test is claimed by two findings and no finding lacks a test.

Columns: **Type** = `U` unit regression, `B` browser, `X` static/contract check. **Today** = the harness evidence that already exists in `logs/geoh_contract_check.log` (`88 HOLDS / 0 VIOLATED`, exit 0).

### 4.1 Geometry — the two defects and the rules that replace them

| Test | Finding | Type | Exact precondition | Expected | Fixture | Today |
|---|---|---|---|---|---|---|
| **GEOH-T-01** | **D-1** silent 5 km clamp (`P15` L180–181) | U | call radius query with `R ∈ {400, 500, 800, 1200, 5000, 5000.5, 6000, 0, −800}` | 400/500/800/1200/5000 accepted; 5000.5 & 6000 throw `E_MAX_RADIUS`; 0 & −800 throw `E_RADIUS_NON_POSITIVE`; **no** returned radius differs from the requested one | `radius_requests` | `G-07-*`, `G-08` |
| **GEOH-T-02** | **F-2** float-decided boundary | U | five venues at declared distances 800.0, 800.0000000000036, 800.0000000000036, 805.0, 799.4 with `R=800` | IN / EXCLUDED at τ=0 / INCLUDED at τ=0.5 / EXCLUDED / INCLUDED | `boundary_cases` | `G-09-1`…`-5` |
| **GEOH-T-09** | `AREA_ONLY` / `LISTING_PIN` / missing attributes | U | 7 centre cases | `REFUSE_AREA_ONLY`, `REFUSE_LISTING_PIN`, `REFUSE_NO_COORDS`, `REFUSE_NO_PROVENANCE`, `REFUSE_NO_ACCURACY`, `REFUSE_BUILDING_NO_OFFSET_BOUND`, `ELIGIBLE` | `centre_class_cases` | `G-06-*` |
| **GEOH-T-10** | `GM-GEO-16` display vs study radius (**unenforced in `P19`**) | U | display 800 vs study 800; display absent; display 1200 vs study 800 | `OK`, `E_DISPLAY_RADIUS_ABSENT`, `E_DISPLAY_STUDY_MISMATCH` | `display_radius_cases` | `G-30-*` |
| **GEOH-T-33** | `GM-GEO-22` polygon vs circle layers | U | render a polygon over a circle footprint | two layers, two provenances, no clip, no substitution | — | **specified** |
| **GEOH-T-34** | `GM-GEO-20` union not sum | U | three rentals sharing venues | union cardinality printed; the sum is not printed | — | **specified** |
| **GEOH-T-37** | `GM-GEO-19` de-duplication | U | one venue as `node/1` and `way/1` at ≤30 m | counted once under the disclosed rule | — | **specified** |

### 4.2 GM-12 wording — one test per state, plus three text screens

| Test | Finding | Type | Exact precondition | Expected | Fixture | Today |
|---|---|---|---|---|---|---|
| **GEOH-T-03** | **F-3** banned substring inside S4/S5's own qualifier | U | screen every S1–S7 body + qualifier against the six §4.1 phrases | 0 hits | proposed copy | `G-17-*`, `G-20`, `G-22` |
| **GEOH-T-04** | **F-4 / N1** digit ban vs a rendered date | U | screen S1–S5 bodies for `\d` | 0 digits; S6 and S7 are the only numeral-bearing states | proposed copy | `G-16-*`, `G-18` |
| **GEOH-T-05** | **N1-a** S2 introduces its time with `at`, not `queried` | U | Option A only: locate the single exempt timestamp span | introduced by `at` in S2 and `queried` in S4/S5/S6; exactly one span | frozen S2 copy | **specified** |
| **GEOH-T-06** | **N1-b** the qualifier contains the banned phrase | U | S4/S5 qualifier after repair | banned-phrase free **and** the meaning of partial/unknown coverage retained | §11.5 sentence | `G-22` |
| **GEOH-T-07** | **N1-c / `ODR-V21A-09`** undefined block boundary | U | a rental label containing a house number, e.g. `No. 12, Jalan X` | the block boundary is **defined**, so the label sits outside it and produces no `E_DIGIT` | — | **OPEN — no option adopted** |
| **GEOH-T-08** | **`UI-01`** numeral separated from its qualifier | **B** | render S7 and S6 | the numeral, the state and the qualifier are in **one** accessible widget; removing the qualifier from the DOM also removes the numeral | — | **not executed** |
| **GEOH-T-11** | **S1** `COMPETITOR_DATA_UNAVAILABLE` | U | snapshot null, or `display_rights_established=false` | state S1; body has no digit; no count field | `SNP-S1` | `G-13-SNP-S1` |
| **GEOH-T-12** | **S2** `COMPETITOR_QUERY_FAILED` | U | `query_failed=true`; and separately `source_answered=false` | S2 in both, with `state_basis = QUERY_UNANSWERED` | `SNP-S2-FAILED`, `SNP-S2-SILENT` | `G-13-*` |
| **GEOH-T-13** | **S3** `COMPETITORS_NOT_QUERIED_ZONE_UNRESOLVED` | U | `area_resolved=false` | S3, **even if** `query_failed=true` (precedence rule `DC-38`) | `SNP-S3` | `G-13-SNP-S3` |
| **GEOH-T-14** | **S4** `COMPETITORS_NO_RECORDS_COVERAGE_UNKNOWN` | U | 0 records, coverage `UNKNOWN` | S4 | `SNP-S4-UNKNOWN` | `G-13-*` |
| **GEOH-T-15** | **S5** `COMPETITORS_NO_RECORDS_COVERAGE_PARTIAL` | U | 0 records, coverage `PARTIAL` | S5 | `SNP-S5-PARTIAL` | `G-13-*` |
| **GEOH-T-16** | **S6** `COMPETITORS_RECORDED_ZERO` | U | 0 records, coverage `COMPLETE`, written statement | S6 **and** the literal `0` | `SNP-S6-COMPLETE-ATTESTED` | `G-14` |
| **GEOH-T-17** | **S7** `COMPETITORS_RECORDED` | U | ≥1 record | S7 with the count and the census-denial sentence | `SNP-S7` | `G-19` |

**AC-03 — `G-15` is the anti-cheat.** The state must be derived from `coverage`, not `items.length`. A mutant that keys on list length passes `T-11`…`T-17` individually and fails `G-15`; that is why both exist.

**AC-04 — the two unreachable states are the point, not a gap.** `S3` is reachable only through an area-resolution failure and `S6` only through a written attestation. A suite in which every state is easy to reach is a suite that cannot detect the empty-array-becomes-zero defect.

### 4.3 Comparison — C-R1 and its three axes

| Test | Finding | Type | Exact precondition | Expected | Fixture | Today |
|---|---|---|---|---|---|---|
| **GEOH-T-18** | **C-R1** count only when `E1 ∧ E2 ∧ E3` | U | 5 comparison cases | one `COUNT_PERMITTED`, four refusals; **each refusal still renders per-rental states** | `comparison_cases` | `G-23-*` |
| **GEOH-T-19** | **E-1** unequal geometry | U | same snapshot, `R=800` vs `R=1200` | refused | `CMP-4` | `G-23-CMP-4` |
| **GEOH-T-20** | **E-2\*** equal labels are not equal observation | U | both footprints `coverage = UNKNOWN`, geometry and window identical | **refused** | `CMP-2` | `G-23-CMP-2` |
| **GEOH-T-21** | **E-3\*** shared snapshot window (erratum `GEOH-E1`) | U | two different `retrieved_at` windows | refused; a **second** date is required only for temporal-change analysis | `CMP-3` | `G-23-CMP-3` |
| **GEOH-T-22** | **C-R2** no rate/ratio/density/saturation/index/score | X | enumerate the output contract | none of the six forms exists as a field or a formatter | `GEOH-04` §8.3 | **specified** |

### 4.4 Administration — `S`/`I`/`G` axes and Cases A1–G

| Test | Finding | Type | Exact precondition | Expected | Fixture | Today |
|---|---|---|---|---|---|---|
| **GEOH-T-23** | **`S_PARTIAL`** — 5,973/6,334 coords, 4,209 shifted | U | marker inside a partially-geolocated area, clipped geometry | `partial`; marker drawn; **no** precision claim | `ADM-P-PARTIAL-GEOMETRY` | `G-24`, `G-25` |
| **GEOH-T-24** | **Case A1 / A2** marker + partial geometry | U | A1 marker inside; A2 marker outside a partial polygon | A1 `partial` drawn; A2 resolves without a boundary claim | `ADM-A1`, `ADM-A2` | `G-24-*` |
| **GEOH-T-25** | **Case B** no polygon | U | identity present, `geometry_state = ABSENT` | `NAMED`; no polygon; no zone claim | `ADM-B` | `G-24-B` |
| **GEOH-T-26** | **Case C** name reuse | U | two districts sharing a name | the name is displayable; the **boundary** is not transferable (`G-8`) | `ADM-C` | `G-24-C` |
| **GEOH-T-27** | **Case D** no area | U | locality present, no `area_id` | `UNRESOLVED`; no area identity printed; the rental still listed | `ADM-D` | `G-24-D`, `G-29` |
| **GEOH-T-28** | **Case E** non-uniform hierarchy (KL, Sabah) | U | KL district tier; Sabah mukim tier | `NOT_APPLICABLE` in each — **never** `UNRESOLVED` | `ADM-E-KL`, `ADM-E-SABAH` | `G-26` |
| **GEOH-T-29** | **Case F** `bandar`/`pekan` row | U | a Selangor layer row tagged `bandar` | renders as a bandar; **not** counted as a mukim | `ADM-F-BANDAR-ROW` | `G-27` |
| **GEOH-T-30** | **Case G** district-median substitute | U | a coordinate that is a district median | no marker, no zone claim, `subject_to: DISTRICT_MEDIAN` | `ADM-G-DISTRICT-MEDIAN` | `G-28` |
| **GEOH-T-39** | `NOT_APPLICABLE ≠ UNRESOLVED` as a **total** function | U | every tier in every jurisdiction | the five states partition the space; no sixth state, no overlap | `admin_resolutions` | `G-25` |

### 4.5 Integration, provenance and tiles

| Test | Finding | Type | Exact precondition | Expected | Fixture | Today |
|---|---|---|---|---|---|---|
| **GEOH-T-31** | **`ODR-V21A-04`** rental location unverifiable | U | a rental whose position fails `T-09` | `WITHHELD` propagates to every downstream object; the row stays visible | — | **specified** |
| **GEOH-T-32** | **`R-1`…`R-8`** adapter | U | an unmappable teammate record | listed with a reason code; footprint withheld; `null ≠ 0` | — | **`BLOCKED_SOURCE`** — no teammate schema |
| **GEOH-T-35** | **`GEO-TILE`** attribution and viewport behaviour | **B** | open the map at default viewport | OSM attribution visible; only visible tiles requested; no bulk preload | — | **not executed** |
| **GEOH-T-36** | synthetic reaching an evidence path | U | export a `synthetic = true` object | `E_SYNTHETIC_IN_EVIDENCE_PATH`; never written | `fixture_meta` | `G-01`…`G-04` (declaration only) |
| **GEOH-T-38** | **R01** area identity ≠ search footprint | U | render R01 beside a circle | two distinct fields; the circle is never labelled as an administrative area | `geo_provenance` | `G-32`, `G-34` |
| **GEOH-T-40** | **`SA-1`/`SA-3`/`DP-1`/`DP-3`/`DP-9`** shared-area figure printed once | U | a survey finding keyed by `(area_id, catalogue_version, concept_card_version, contract_hash, campaign_id)` | exactly **one** figure per key; two rental members carry a **pointer**, not a copy; duplicate emission fails the build | — | **`ABSENT_INPUT`** — no campaign exists |
| **GEOH-T-41** | `R⊕` convention — the developer's own three published distances | U | `haversine` over SYN-A/B/C | 1319.8 / 1672.6 / 1666.8 m, each within 0.2 m of `P20` | `rental_pair_distances_expected_m` | `G-05` |

**AC-05 — `GEOH-T-32` is the only row whose status may be `BLOCKED_SOURCE`.** Every other row is `NOT_EXECUTED` (specified, no toolchain, no app), except `GEOH-T-40`, which is `ABSENT_INPUT`: no campaign exists, so the shared-area figure cannot be computed at all. Marking `T-32` as `ABSENT_INPUT` would be wrong in the other direction — the rental team's schema is *withheld*, not absent — and `T-40` is the worked example of the distinction `AC-01` requires.

---

## 5. Coverage proof — the mapping is one-to-one

| Test | Count of findings assigned |
|---|---|
| `GEOH-T-01`…`GEOH-T-41` | 41 |
| Findings with **exactly one** test | 41 |
| Findings with zero tests | 0 |
| Tests claimed by two findings | **0** |

**AC-06 — a finding with two tests is a finding whose result is ambiguous.** `GEO`-level obligations that the developer spec bundled (e.g. `GEO-GM12` covering three rules) are deliberately split, so that "GM-12 passes" cannot be said when only the wording and not the derivation was checked.

**AC-07 — the matrix is checkable.** Read §4's Test column: 41 cells, 41 distinct IDs. Read `GEOH-01` §4's finding column: every entry appears in §4 above, with two explicit exceptions that are not testable rules — the verdict vocabulary (which is §2 itself) and the nine `GEO-*` obligations (which are §3's input). A reviewer can confirm all of this without trusting this sentence.

---

## 6. Independent QA ownership

| Question | Answer |
|---|---|
| Who authors this matrix? | `HC-01` |
| Who may **approve** it? | **not `HC-01`** — `GEOH-01` §1 self-disqualifies the author from independent QA. The `WGC_06` precedent applies verbatim: *"WorkBuddy authors both the harness and this table and is disqualified from approving it."* |
| Who owns execution? | **unassigned.** The Owner's `ODR-1`/`ODR-2` pattern applies: a reviewer is named by the Owner, not by the research team |
| What must the reviewer be independent of? | (a) the ODR-3 research authorship, (b) the Jaspr developer team, (c) the rental teammate |
| What is handed to the reviewer? | `GEOH-01`…`05`, the fixture set, the harness, the log, and this matrix — **before** any implementation exists, so the expectations are frozen first |
| What may the reviewer change? | the expected results, by written challenge. Silently relaxing an expectation to make a suite pass is the failure mode `WGC_06` §3.1 names |

**AC-08 — pre-registration.** The expected values in §4 are frozen **now**, before any implementation is written. A suite whose expectations are adjusted after seeing the output measures nothing. If an expectation is wrong, the correction is recorded as an erratum with the reason, not as an edit.

---

## 7. Preconditions, exact

A reviewer can only start when **all** of the following hold.

| # | Precondition | State |
|---|---|---|
| PC-1 | this package present and its manifest verifying (`sha256sum -c`) | **satisfied** — `SHA256_MANIFEST.txt` |
| PC-2 | `harness/geoh_contract_check.py` exits 0 with `88 HOLDS / 0 VIOLATED` | **satisfied** — `logs/geoh_contract_check.log` |
| PC-3 | fixture file pinned by hash and declaring `reportable_as_evidence: false` | **satisfied** |
| PC-4 | Dart / Jaspr toolchain installed and version logged | **not satisfied** — absent. `jaspr serve` and `jaspr build` are `NOT_EXECUTED` |
| PC-5 | a browser reachable for `GEOH-T-08` and `GEOH-T-35` | **not satisfied** for this environment |
| PC-6 | teammate `R-1`/`R-4`/`R-7`/`R-8` answered | **not satisfied** — `GEOH-T-32` and L2 blocked |
| PC-7 | ODR-4 rights decision and a versioned snapshot | **not satisfied** — L3 blocked |
| PC-8 | Owner records `ADOPTED_OPTION` for Option A or B | **not satisfied** — `ADOPTED_OPTION = None`; `GEOH-T-05`, `-07` cannot be finalised |
| PC-9 | Owner records a tolerance **value** and policy | **not satisfied** — `tolerance_policy = UNSET_PENDING_OWNER_ADOPTION`; `GEOH-T-02` may run with a test-only value, not as policy |

**AC-09 — a test may run with a test-only constant; a report may not.** `GEOH-T-02` requires *some* tolerance to demonstrate the flip. Using `0.5` in the test is legitimate **provided** the suite also asserts that the production default is `null` and that a null tolerance raises `E_TOLERANCE_UNSET`. That second assertion is what stops the test from ratifying the example.

---

## 8. Residual work, numbered

| # | Residual | Blocks | Owner |
|---|---|---|---|
| **RW-01** | Dart/Jaspr toolchain install and a real compile log | L1, `T-01`…`T-07`, `T-09`…`T-34`, `T-41` execution | developer |
| **RW-02** | browser run for `T-08` and `T-35`; `H3F-01` stays open | L1 UI | developer + QA |
| **RW-03** | numeric study radius (`ODR-3a-prod`) | any production footprint | Owner + scientific |
| **RW-04** | tolerance **value** and boundary policy | `T-02` as policy; `GEOH-04` DC-26 | Owner |
| **RW-05** | Option A vs B (`ADOPTED_OPTION`) | `T-05`, `T-07`; `GEOH-04` DC-46 | Owner |
| **RW-06** | `N1-c` block boundary definition | `T-07` | Owner |
| **RW-07** | teammate `R-1`/`R-4`/`R-7`/`R-8` and a stable rental ID | L2, `T-32` | rental team |
| **RW-08** | ODR-4 four-way rights (source / query / store / display&redistribute) | L3 | Owner + DPO |
| **RW-09** | real polygon lineage, parent field, licence chain (ADM2/ADM3 `BLOCKED`) | real district/mukim display | source owner |
| **RW-10** | MyGDI access at the documented endpoint | the only candidate for a licensed national boundary set | source owner |
| **RW-11** | `Q_post` partition defect (`INVALID` omitted; 780 vs 800) — not geographic, but it sits on the same report | any area-level figure | scientific |
| **RW-12** | independent QA reviewer named and `GEOH-T-*` executed | acceptance | Owner |

---

## 9. What this handover does **not** establish

| Not established | Because |
|---|---|
| that Jaspr compiles | no toolchain (`PC-4`) |
| that any screen has been seen | no browser run (`PC-5`) |
| that the contract is adopted | `PROPOSED_FOR_OWNER_ADOPTION`; zero signatures |
| that a real rental resolves | `R-1`…`R-8` unanswered |
| that any competitor state is real | every state is synthetic; no snapshot exists |
| that a licensed boundary layer exists | ADM2/ADM3 `LICENCE_CHAIN_UNVERIFIED — BLOCKED`; MyGDI `SOURCE_NOT_ACCESSIBLE` |
| that `GEOH-T-01`…`-41` pass | none has been executed against an application |
| that the research team has been replaced by a coordinator | this appoints **one handover custodian**, `HC-01`, and nothing else |

**AC-10 — the honest one-line status.** *The research side has delivered a versioned, hash-pinned, self-checked contract that a developer can implement against; the implementation does not exist, the real data does not exist, and the Owner has signed nothing.*

---

## 10. Handover checklist — what physically moves

| Item | Path | Status |
|---|---|---|
| Source pins and evidence reuse | `GEOH-01_SOURCE_PINS_AND_EXISTING_EVIDENCE.md` | complete |
| Owner decision matrix | `GEOH-02_ODR3_OWNER_DECISION_MATRIX.md` | complete, 0 signatures |
| Administrative / geometry / GM-12 contract | `GEOH-03_ADMIN_DISTRICT_MUKIM_AND_GEOMETRY_CONTRACT.md` | complete |
| Data contract | `GEOH-04_JASPR_INPUT_OUTPUT_DATA_CONTRACT.md` | complete, 14 deltas |
| This acceptance and handover record | `GEOH-05_IMPLEMENTATION_ACCEPTANCE_AND_HANDOVER.md` | complete |
| Executable fixtures | `fixtures/GEOH_SYNTHETIC_FIXTURES.json` | 11 blocks |
| Self-check harness | `harness/geoh_contract_check.py` | 88 checks |
| Self-check result | `logs/geoh_contract_check.log` | exit 0, 88 `HOLDS` |
| Owner-facing decision sheet | `00_OWNER_DECISION_SHEET.md` | complete |
| Integrity manifest | `SHA256_MANIFEST.txt` | 5/5 documents + 4 enumerated files |

### 10.1 Reproducing this package's integrity

```bash
cd "C:/Users/HP/OneDrive/Desktop/Project1/New_Goal/GEOH_ODR3_TO_JASPR_20261030"
sha256sum -c SHA256_MANIFEST.txt          # 9 lines, all OK, exit 0
PYTHONIOENCODING=utf-8 python -B harness/geoh_contract_check.py
echo "exit=$?"                            # 0, and 88 HOLDS / 0 VIOLATED
```

The manifest is LF-terminated; a CRLF checkout fails `sha256sum -c` with *"no properly formatted checksum lines"*, which is a transport fault and not a content change. The manifest cannot pin itself — an empty or self-referential digest for `SHA256_MANIFEST.txt` would be a false pin.

**Order matters.** The harness **rewrites** `logs/geoh_contract_check.log` on every run, so verify the manifest **first** (as above) and re-pin the log afterwards if the recorded run is meant to be replaced. Do not run the harness inside a checkout whose log hash is still load-bearing. This is the same hazard the manifest rule for `SHA256_MANIFEST.txt` itself exists to prevent.
