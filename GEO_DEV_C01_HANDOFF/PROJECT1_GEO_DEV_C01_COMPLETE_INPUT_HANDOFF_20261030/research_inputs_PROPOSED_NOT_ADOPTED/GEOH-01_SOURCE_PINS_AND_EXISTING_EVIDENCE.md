# GEOH-01 — Source pins and existing evidence reused

**Directive:** `PROJECT1-ODR3-RESEARCH-FIRST-GEO-CONTRACT-20261030`
**Package:** `GEOH_ODR3_TO_JASPR_20261030`
**Custodian:** `HC-01` (see §1)
**Status:** `DOCUMENTARY_HANDOVER_CANDIDATE` — every pin below is verified against bytes.
**Evidence classes:** `D` (documentary) and `S` (synthetic execution). There is **no `R` evidence in this package**, and none is claimed.

---

## 1. Custodian nomination

The directive asks for **one research-side handover custodian** who assembles and versions the outputs.

**`HC-01` — GEOH handover custodian (research side).** The role is held by the FRG / Track G research author who produced `FRG-01`, `FRG-02`, `FRG-03` and `ODR3_DECISION_DELTA_20261030`, because this package is a continuation of that work rather than a new appointment. If the Owner prefers a different holder, the role transfers without changing anything in this package.

| `HC-01` may | `HC-01` may **not** |
|---|---|
| maintain the evidence register in §2 | appoint itself or anyone else Project1 coordinator |
| version this package and re-issue its manifest | grant Owner approval, sign an `ODR-*` decision, or mark any row `ADOPTED` |
| receive and record answers to `R-1`…`R-8` | speak for the rental teammate |
| declare a document `DOCUMENTARY_HANDOVER_READY` | declare Jaspr `COMPILED`, `TESTED`, or real-rental/integration complete |
| refuse a source that fails verification | substitute a near-copy for a pinned original |

**One authority limit is load-bearing and is stated here rather than discovered later:** `HC-01` authored the harness in this package, so `HC-01` cannot sign off the acceptance matrix in `GEOH-05` as independent QA. That signature belongs to the Owner's nominated reviewer (`GEOH-05` §6). This is the same disqualification `WGC_06` §5 records for its own author.

---

## 2. Pinned inputs — verified against bytes

All hashes are SHA-256 of the file as it exists in this workspace on 2026-10-30. Byte counts are the file sizes the hashes were computed over. Nothing below is quoted from a document that was not hashed.

### 2.1 The ODR-3 decision record

| # | Path | Bytes | SHA-256 | Supplies | Status |
|---|---|---|---|---|---|
| P1 | `New_Goal/ODR3_BOUNDED_FOOTPRINT_20261030/ODR3_DECISION_DELTA_20261030.md` | 47,813 | `f37294da6de8cd93da6d180b712498a7efe4e95ae4c8d352fb4829aa76f8e9f3` | the 20 executed synthetic rows, D-1, F-2, F-3, F-4, `ODR-3a`…`3d`, P-1…P-9 | `PINNED` |
| P2 | `New_Goal/ODR3_BOUNDED_FOOTPRINT_20261030/harness/odr3_harness.py` | 54,892 | `7bde059561f42d7760f7cb7990bc24354ee8bee36e55a9efb5a4e3e03185ebef` | the executable experiment behind P1 | `PINNED` |
| P3 | `New_Goal/ODR3_BOUNDED_FOOTPRINT_20261030/logs/odr3_results.json` | — | `55a68a521766baa0b229e0fa8b3da8228799c3fa341f71ebe257f481cc991dd4` | machine-readable results | `PINNED` |
| P4 | `New_Goal/ODR3_BOUNDED_FOOTPRINT_20261030/logs/odr3_harness_run.log` | — | `32cee5a0d8075a82af6998ae77c7c0bd9ffadd5047174570d68aa90851906853` | run transcript, exit 0 | `PINNED` |

`P1`'s hash is independently confirmed: the Jaspr package's technical spec (`P14`) cites `f37294da…` as its source input, so the developer-side spec was written against **these** bytes, not an earlier draft.

### 2.2 The frozen contract documents

| # | Path | Bytes | SHA-256 | Supplies | Status |
|---|---|---|---|---|---|
| P5 | `New_Goal/TRACK_G_GEO_MAP_20261028_CORR_01/GM_12_COMPETITOR_ABSENCE_STATES.md` | 16,007 | `cbed0aecfa16c248fa4d59e79c267c86e6760fad0e43fc1be36643f20a883ce8` | the seven states, §2 digit rule, §3 R-19/R-20/R-21, §4 copy, §4.1 banned phrases, §7.1 `UI-01` | `PINNED` |
| P6 | `New_Goal/FRG_FINAL_REPORT_GEO_COMPARE_01_20261028/FRG-01_DISTRICT_MUKIM_FALLBACK_MATRIX.md` | 24,902 | `7a0d7f91108762e86386a2befd43448cce00a201481484a2e171d73c9a9755c0` | three axes S/I/G, five display states, Cases A1–G, KL `00`, 228/4×, 8.9 % | `PINNED` |
| P7 | `New_Goal/FRG_FINAL_REPORT_GEO_COMPARE_01_20261028/FRG-02_COMPETITOR_COMPARISON_METHOD.md` | 24,897 | `ca5842f486510dcc4e4974c555c72291e3140b08bb8fa9a5d6325b65525bbd1b` | E-1/E-2/E-3, C-R1/C-R2, D-1/D-2/D-3, V-1…V-7 | `PINNED` |
| P8 | `New_Goal/FRG_FINAL_REPORT_GEO_COMPARE_01_20261028/FRG-03_CLMA_SHARED_AREA_EVIDENCE_RULES.md` | 22,873 | `39483aac6687d7f5a546d1cc6d2edaeb0b2fa6cd37d154e94e794260d97c0982` | SA-1…SA-8, DP-1…DP-7, the seven unmet requirements | `PINNED` |
| P9 | `New_Goal/FRG_FINAL_REPORT_GEO_COMPARE_01_20261028/FRG-08_OWNER_DECISIONS_AND_CHANGE_REQUESTS.md` | 22,828 | `bb83927eeb40600222558a7d21b3a86419ac1c85242c5c61dc4f2414d6dc10ff` | the decision register this package must not pre-empt | `PINNED` |
| P10 | `New_Goal/FRG_FINAL_REPORT_GEO_COMPARE_01_20261028/FRG-09_WORKSTREAM1_READ_ONLY_HANDOFF.md` | 18,479 | `3958e066b6acd67c4f1129b11a974fc2da8b36991804fc25b7c572813daee2fd` | workstream-1 handover state | `PINNED` |
| P11 | `New_Goal/FRG_OWNER_OPTION_C_20261028/FRG-06_V3_FINAL_REPORT_OPTION_C.md` | 31,844 | `d23e753d9054d3bad7bdfcbc39981b73f5361520299cd52a67d727e604009f7b` | §2.3.2 section-scope matrix (R01–R12), `DP-9` | `PINNED` |
| P12 | `New_Goal/P3R3_TRACK_G_COVERAGE_V2_20261027/WGC_06_TEST_REQUIREMENTS_AND_EXPECTED_RESULTS.md` | 8,988 | `73ce5ee951b8ee3b151e17a13b789bf1652481b2eee667c18b550fca1df4e6a6` | verdict vocabulary, four case kinds, COR-06 privacy conditions | `PINNED — controlling` |
| P13 | `New_Goal/P3R3_TRACK_G_REVIEW_20261027/WG_05_ELIGIBILITY_AND_A10_DEPENDENCY_CROSSWALK.md` | 3,252 | `27e7d48c27c61f479433e1b292a3fea9149484d3b068e194353bc985d0f98428` | eligibility crosswalk | `PINNED` |
| P13b | `New_Goal/P3R3_TRACK_G_REVIEW_20261027/WG_08_OWNER_AND_SCIENTIFIC_DECISION_REGISTER.md` | 5,139 | `d93905250ec2ceebea5a919a6f2181e039915724a96a8f6e9548a0b50b2cf66c` | ten decision rows, 0 signatures | `PINNED` |
| P13c | `New_Goal/WS1_GEO_HANDOVER_20261026_CLOSEOUT_REPORT.md` | 19,206 | `5051270816b074cc6df0449dda4131823fd068b9ab3e357c54ed9df7064fec00` | geographic handover closeout | `PINNED` |

### 2.3 The R09 wording adjudication

| # | Path | Bytes | SHA-256 | Supplies | Status |
|---|---|---|---|---|---|
| P14a | `New_Goal/FRG_WS1_RECONCILIATION_20261029_V21A/05_R09_WORDING_DATE_AND_SEMANTIC_ADJUDICATION.md` | 21,930 | `f40c73419caa38153d3491121caaeef192957678285f5ff20dfa331b83dc6455` | N1/N1-a/N1-b/N1-c, Option A vs B, `PROPOSED_BLOCK_SEMANTICS`, paraphrase screen 0/12 + 8/12 | `PINNED` |
| P14b | `New_Goal/FRG_WS1_RECONCILIATION_20261029_V21A/03_R01_R09_DEPENDENCY_AND_RENTAL_INTERFACE.md` | 9,659 | `d3753c052c9286fb20789e6dd64891f0bf903c92d66b4dc883a0fe55acbc24ea` | the R01/R09/R12 dependency table, `ODR-V21A-04`, `ODR-V21A-05` | `PINNED` |
| P14c | `New_Goal/FRG_WS1_RECONCILIATION_20261029_V21A/08_TEAMMATE_HANDOFF_IF_REQUIRED.md` | 7,653 | `4985b088ed4231abd4c2df680b565b592ecc81013d63858f2c97fa16df862568` | questions `R-1`…`R-8` and their fallbacks | `PINNED` |
| P14d | `New_Goal/FRG_WS1_RECONCILIATION_20261029_V21A/SHA256_MANIFEST.txt` | 3,662 | `1169d44272d9d7d4f53acbe5e496095e76a8b2ed337c2e0aabf0600ddeec48e9` | the parent package's own pin set | `PINNED` |

### 2.4 Code reused as the measurement basis

| # | Path | Bytes | SHA-256 | Supplies | Status |
|---|---|---|---|---|---|
| P15 | `New_Goal/UC_GEO_01_Proximity_Analysis/src/geo_proto.py` | 21,519 | `4777791d620cee86a2be66e63526feb83ca087a5d031402cfe5f625a7738551a` | `haversine` L54, `EARTH_R = 6371000.0`, `count_stores_within_radius` L178 with the silent clamp L180–181 | `PINNED` |
| P16 | `New_Goal/Search_Fallback_Pilot_20261017/src/competitor_context/engine.py` | 42,859 | `66864646bd753eb8b8cb388e6fd339f0dd1e60ac29afffa58ac13d14adc7429a` | `fold_name` L106, `MEMBERSHIP_RULES` L114, `DEDUP_RULES` L121, `PROHIBITED_OPERATIONS` L131, `PROHIBITED_TERMS` L134 | `PINNED` |

### 2.5 Documents treated as **proposals**, never as adopted policy

| # | Path | Bytes | SHA-256 | Status |
|---|---|---|---|---|
| P17 | `Downloads/01_OWNER_ODR3_DECISION_CHALLENGE.md` | 5,089 | `2b4928f21a543d6adff698dc6ff5759f10caa00a072f28e052e551788ce4031a` | `OWNER_PROPOSAL` (unsigned register: `ODR-3a-dev` PROPOSED, `ODR-3a-prod` OPEN, `ODR-3b`/`3c-exclusions`/`3d` READY_FOR_ADOPTION, `ODR-3c-grants` CONDITIONAL) |
| P18 | `Downloads/PROJECT1_JASPR_THREE_COORDINATE_INCREMENT_20261030.zip` → `docs/01_GEOMETRY_AND_REPORT_TECHNICAL_SPEC.md` | 9,589 | `2ee976600bae9f273aad95ed4059885f1391eb3b711b982030258bb319189e4e` | `DEVELOPER_PROPOSAL` |
| P19 | same archive → `lib/geometry_contract.dart` | 7,919 | `c09430ded58d211744007883dee68632649e1797747e7123df9f68a207fb6e26` | `DEVELOPER_PROPOSAL` — a candidate implementation, **not executed** |
| P20 | same archive → `docs/03_PROCEED_NOW_WITH_THREE_SYNTHETIC_COORDINATES.md` | 5,392 | `537911dd425ed0e84abc6c169ce343154841a593407b5e6fa75d6eaadb84b26b` | `DEVELOPER_PROPOSAL` — fixture SYN-A/B/C and the nine GEO obligations |
| P21 | same archive → `test/geometry_contract_test.dart`, `test/synthetic_venue_geometry_test.dart` | 3,323 / 2,233 | `4adedfdd2ff32f113c9005bf7faafb481babbce77985bdeabf60d0cad919cfbd` / `6129546e886a4445ae300084942e23dce111922b21580e0d7877430b64e903a4` | `PROVIDED_NOT_EXECUTED` |
| P22 | `Downloads/01_RESEARCH_TEAM_ODR3_GEOGRAPHY_TO_JASPR_CONTRACT.md` | 8,636 | `70712cc49e1f355af346b8beb7d1cfecb6aeee79cf5858c70edda5da44455a30` | the directive itself |

`P17`–`P21` are inputs to be *reconciled*, not authorities. Where this package contradicts them it says so and gives the reason (`GEOH-03` §12, `GEOH-04` §8).

---

## 3. Sources that are not accessible, and what that costs

Marked `SOURCE_NOT_ACCESSIBLE` rather than substituted, per the directive.

| Source | Status | Consequence for this package |
|---|---|---|
| `00_OWNER_DECISION_DOSSIER.md` §A–B (the pre-existing 400/800/1200 m rationale) | `SOURCE_NOT_ACCESSIBLE` — absent from the workspace, `Downloads/` and the geographic handover archive | the three candidate radii are used **only** as the directive designates them: *illustrative experiment inputs*. No claim is made about what §A–B argued. `P1` §0.2 records the same. |
| MyGDI / NRES boundary service | `SOURCE_NOT_ACCESSIBLE` — DNS failure 2026-10-27 (`FRG-01` §4) | `G_YES` (licensed geometry) remains unobtainable; Case A2 stays synthetic-only |
| geoBoundaries ADM2 / ADM3 licence chain | `LICENCE_CHAIN_UNVERIFIED — BLOCKED` (`FRG-01` §4) | no real polygon may be imported or published (`GEOH-03` §9) |
| Commercial F&B datasets | `NOT_RETRIEVED` (`FRG-02` §6, V-5) | S6 remains unreachable; no completeness statement exists |
| The rental teammate's schema, IDs, revision model | `NOT_RECEIVED` (`P14b` §4, `P14c` §4) | the rental side of `GEOH-04` is an **interface proposal**, and every field is marked "not claimed to exist" |
| `R-4` coordinate precision and `R-8` provenance for a real rental | `OPEN` | `ODR-3c` grants stay `CONDITIONAL`; no real rental may draw a circle |
| Jaspr / Dart toolchain | `NOT_PRESENT` in this environment | no Dart test in `P21` is executed by this package; `GEOH-05` records them as the developer's obligations, unrun |

---

## 4. Reuse ledger — old evidence, and exactly where it lands

The directive is explicit: *reuse, do not re-study*. Nothing in this package re-measures a fact that `P1`–`P16` already establish.

| Existing finding | Source | Reused in | Reused as |
|---|---|---|---|
| 20 executed synthetic rows (18 `HOLDS`, 2 `VIOLATED`) | `P1` §3.2–3.3 | `GEOH-02` readiness column, `GEOH-05` test seed | the evidence base; **not re-run** |
| **D-1** silent 5 km clamp | `P1` C-2, `P15` L180–181 | `GEOH-03` §7, `GEOH-04` §6 `E_MAX_RADIUS`, `GEOH-05` `GEOH-T-01` | defect carried into a refusal contract |
| **F-2** float boundary | `P1` C-6 | `GEOH-03` §7, `GEOH-04` §6 `E_TOLERANCE_UNSET`, `GEOH-05` `GEOH-T-02` | defect carried into an explicit-tolerance contract |
| **F-3** banned substring vs caveated copy | `P1` §3.4, `P5` §4/§4.1, `P14a` §4 | `GEOH-03` §11, measured at `GEOH-T-03` | reproduced in `logs/geoh_contract_check.log` G-20 |
| **F-4 / N1** digit rule vs `queried <date>` | `P1` §3.4, `P14a` §2 | `GEOH-03` §11, measured at `GEOH-T-04` | reproduced at G-21 |
| **N1-a** S2 introduces its time with `at` | `P14a` §3 | `GEOH-03` §11.4 | a gap in the predecessor repair, now covered |
| **N1-b** the qualifier contains the banned phrase | `P14a` §4 | `GEOH-03` §11.5 | replacement sentence proposed |
| **N1-c / `ODR-V21A-09`** undefined block boundary | `P14a` §5 | `GEOH-03` §11.6, `GEOH-02` row `ODR-3-blockboundary` | left open, options stated, none adopted |
| **`UI-01`** numeral separated from qualifier | `P5` §7.1 | `GEOH-05` `GEOH-T-05` | a browser test, not a wording fix |
| S1–S7 canonical states | `P5` §2/§2.1 | `GEOH-04` §5 `CompetitorEvidenceState` | schema source of truth |
| E-1/E-2/E-3 and C-R1/C-R2 | `P7` §3 | `GEOH-03` §10, `GEOH-02` row `ODR-3-clarification` | the ambiguity this package must reconcile |
| `SA-1`…`SA-8`, `DP-1`…`DP-7`, `DP-9` | `P8` §3–4, `P11` §2.3.4 | `GEOH-04` §7 emission rules | unchanged, restated as machine constraints |
| `S_PARTIAL`, three axes, Cases A1–G | `P6` §1.1, §2, §3 | `GEOH-03` §3–6 | the administrative contract |
| `R-1`…`R-8` | `P14c` §3 | `GEOH-02` row `ODR-3-rental-interface`, `GEOH-04` §8 | integration dependency, unanswered |
| Verdict vocabulary and four case kinds | `P12` §3–4 | `GEOH-05` §3 | the acceptance-matrix vocabulary |
| Nine `GEO-*` obligations | `P20` §7 | `GEOH-05` §4 | mapped, not replaced |
| Three synthetic coordinates and their pairwise distances | `P20` §"Exactly three…" | `fixtures/GEOH_SYNTHETIC_FIXTURES.json` | re-derived independently (§5) |

**Not re-studied, deliberately:** the radius sensitivity sweep, the 20 synthetic rows, the source-rights assessment, the CLM-A requirement audit, the administrative tier counts. Re-running any of them without new data would produce the same numbers and add no evidence.

---

## 5. Independent re-derivation of the three synthetic distances

`P20` publishes pairwise haversine distances for SYN-A/B/C. Because two implementations that disagree on Earth radius will disagree on membership (F-2), the distances are recomputed here from the coordinates alone rather than quoted.

| Pair | Published (`P20`) | Recomputed (this package) | Δ |
|---|---:|---:|---:|
| SYN-A – SYN-B | 1,319.8 m | 1,319.79 m | 0.01 m |
| SYN-A – SYN-C | 1,672.6 m | 1,672.60 m | 0.00 m |
| SYN-B – SYN-C | 1,666.8 m | 1,666.80 m | 0.00 m |

Max |error| ≤ 0.2 m, asserted as `G-05` in `logs/geoh_contract_check.log`. The developer's numbers reproduce under `R = 6371000.0`, so both sides are using the same convention — a fact worth having measured rather than assumed.

---

## 6. Re-verification

```bash
cd "C:/Users/HP/OneDrive/Desktop/Project1/New_Goal"
sha256sum \
  ODR3_BOUNDED_FOOTPRINT_20261030/ODR3_DECISION_DELTA_20261030.md \
  TRACK_G_GEO_MAP_20261028_CORR_01/GM_12_COMPETITOR_ABSENCE_STATES.md \
  FRG_FINAL_REPORT_GEO_COMPARE_01_20261028/FRG-01_DISTRICT_MUKIM_FALLBACK_MATRIX.md \
  FRG_FINAL_REPORT_GEO_COMPARE_01_20261028/FRG-02_COMPETITOR_COMPARISON_METHOD.md \
  FRG_FINAL_REPORT_GEO_COMPARE_01_20261028/FRG-03_CLMA_SHARED_AREA_EVIDENCE_RULES.md \
  FRG_OWNER_OPTION_C_20261028/FRG-06_V3_FINAL_REPORT_OPTION_C.md \
  P3R3_TRACK_G_COVERAGE_V2_20261027/WGC_06_TEST_REQUIREMENTS_AND_EXPECTED_RESULTS.md \
  FRG_WS1_RECONCILIATION_20261029_V21A/05_R09_WORDING_DATE_AND_SEMANTIC_ADJUDICATION.md \
  UC_GEO_01_Proximity_Analysis/src/geo_proto.py \
  Search_Fallback_Pilot_20261017/src/competitor_context/engine.py
```

Every line must equal the corresponding hash in §2. A changed byte means a pinned input moved and the conclusion that rests on it must be re-read, not silently kept.

Parent-package integrity is separately re-checked by `sha256sum -c --quiet` inside `FRG_WS1_RECONCILIATION_20261029_V2`, `…_V21` and `…_V21A`; all three passed on 2026-10-30.

---

## 7. Discrepancies found while pinning

Four, recorded because silence would make them invisible later.

**7.1 `WGC_06` exists in two versions and the shorter one is not controlling.**
`WS_QNR_FINAL_01_20261028/_frg_intake/…/WGC_06_TEST_REQUIREMENTS_AND_EXPECTED_RESULTS.md` is **5,668 B** (`e9cfa5c4…`) and stops before the `CORRECTION (COR-06)` section. The copy pinned at `P12` is **8,988 B** (`73ce5ee9…`) and is a strict superset — `diff` reports a single pure addition at line 108. The short copy is therefore a **derived extract, incomplete**, and is not cited for anything in this package. The COR-06 privacy conditions (`C-a`…`C-f`) exist only in `P12`.

*Why it matters:* the missing section strengthens `T-4a` from one privacy condition to six, and marks `T-2b` `CONDITIONAL_ON_CS01_ADJUDICATION`. A reader who pinned the short copy would accept a weaker oracle.

**7.2 The developer's spec calls Option B "Owner-preferred" and no Owner recorded that.**
`P18` §5 reads *"Source dates are outside digit-restricted R09 absence body under Owner-preferred Option B."* `P14a` §6 records `ADOPTED_OPTION = None` and both statuses `PROPOSED_NOT_ADOPTED`. The word "preferred" overstates the record by one authority level. This package keeps the recommendation (`GEOH-03` §11.7 recommends B) and keeps it visibly unadopted. The discrepancy is not a defect in the developer's code — the Dart contract behaves compatibly with B — but the *labelling* must not travel into the Owner's decision sheet as a fact.

**7.3 `FRG-06` exists in V2 and V3; only V3 is cited.**
`FRG_CORRECTION_01_20261028/FRG-06_V2_…` and `FRG_OWNER_OPTION_C_20261028/FRG-06_V3_…` both exist. `P11` (V3) is the Option C organisation the Owner directed on 2026-10-28, and its §2.3.2 section-scope matrix is the one `P14b` §2 quotes by line number. The V2 file is not used.

**7.4 `_odr3_src_20261030/` in `Downloads` is a convenience copy, not an authority.**
Eight of its nine files are byte-identical to their in-repo originals (§2.2). The ninth (`WGC_06`) is the abridged copy described in 7.1. This package cites the in-repo paths, so the convenience copy can be deleted without breaking a pin.

---

## 8. What this document does not do

It does not approve, adopt, sign or close anything. It does not claim that a source was read whose bytes were not hashed. It does not upgrade `P17`–`P21` from proposals to authority. And it does not treat `P12`'s existence as evidence that any verdict in it was ever executed — `P12` §6 says of itself only that it is a specification.
