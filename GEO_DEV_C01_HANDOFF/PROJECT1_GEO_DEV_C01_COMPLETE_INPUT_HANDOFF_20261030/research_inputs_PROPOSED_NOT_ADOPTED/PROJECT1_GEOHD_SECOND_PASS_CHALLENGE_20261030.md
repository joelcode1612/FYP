# PROJECT1 — GEOHD second-pass independent documentary challenge

**Date:** 2026-10-30  
**Subject:** `GEOH_INDEPENDENT_CHALLENGE_DELTA_20261030`, especially `GEOHD-01`, `GEOHD-02`, `GEOHD-03`.  
**Verdict:** `DOCUMENTARY_DELTA_RECEIVED — TARGETED_CONTRACT_CORRECTION_REQUIRED`. No Owner adoption, release, Jaspr or scientific approval.

## Scope and verification boundary

Five uploaded inputs were inspected: four Markdown files and `SHA256_MANIFEST(20261030-000711).txt`. The four Markdown files matched their SHA-256 values in the provided 14-entry manifest. The other 10 entries (harnesses, fixture, logs, builder, data tables and register input) were not uploaded and have **not** been independently rehashed or executed by this reviewer. The claimed 62/62 and 88/88 are team-reported. The 49 Jaspr tests are unexecuted according to the package.

**Do not sign all 10+4+9 proposed decisions merely because the research harness is green.** The following findings require changes to the proposed contract or its acceptance oracle, not repetition of the old geographic research.

## Priority blockers

### GEOHD-S2-01 — Three-way boundary classification is not a partition (CRITICAL)

- **Source:** `GEOHD-01` §3.3 `GEOHD-02.2` and §3.4 `GEOH-T-43`.
- `INSIDE` and `BOUNDARY_UNDECIDED` can both be true when the measured distance lies inside the radius but within the positional uncertainty band. `43-e` has measured 750 m, R=800 m, band 52 m: both predicates are true, despite expected `INSIDE` alone.
- `43-c` has measured 805 m, R=800 m, band 52 m: the written predicates give `BOUNDARY_UNDECIDED`, not the expected `OUTSIDE`.
- At exactly R with a positive band, `INSIDE` and `BOUNDARY_UNDECIDED` overlap.
- **Correction:** Specify one exhaustive, mutually exclusive total decision function, with explicit equality rules. As a starting mathematical model for review: let `delta=measured-R`, `U` be a defensible worst-case positional error band, and `eps` a separately justified arithmetic guard. For `U>0`, certainly-inside when `delta < -U-eps`, certainly-outside when `delta > U+eps`, otherwise uncertain. For `U=0`, explicitly preserve or revise inclusive equality for `|delta|<=eps`.
- **New tests:** cases `d=800,805,750,740,860`, `R=800`, `U=52`, plus no uncertainty, nonfinite accuracy, huge uncertainty, edge equality, and a mutation proving exactly one verdict for each input. Replace the incorrect expectations in `43-c`, `43-e`; include a machine assertion that the original erroneous rule fails.
- **Decision:** `ODR-R-02b` must not be signed before this correction and independent validation. A scientific/method reviewer must vet the interpretation of uncertainty.

### GEOHD-S2-02 — `GEOH-T-42-b` contradicts the render gate (HIGH)

- **Source:** `GEOHD-01` §2.3 `GEOHD-01.2`, §2.4 `GEOH-T-42`.
- `42-a` says real district geometry is `UNVALIDATED`; `42-b` says **same layer**, adding rights, parent and matching count, should become `RENDERED_LICENSED` / `VERIFIED`.
- The published `DC-21` / `GEOHD-01.2` also requires `geometry_state=VALIDATED_LICENSED`. Without changing that state, `42-b` must remain withheld. A test cannot grant validation by implication.
- **Correction:** Make `42-b` explicitly set `geometry_state=VALIDATED_LICENSED`, including validation evidence; add `42-b-negative` where that state remains `UNVALIDATED` and the polygon remains withheld. Check each of the four gates independently.
- **Decision:** `ODR-R-01` may be accepted in principle, but the detailed acceptance oracle needs correction before sign-off.

### GEOHD-S2-03 — `E2_DESC` fails to encode equal-geometry prerequisite and count-policy precedence (HIGH)

- **Source:** `GEOHD-01` §4.3–4.4 `GEOHD-03.1` and `GEOH-T-44`.
- Its written gate lists shared snapshot, source, release, window, rights, dedup and qualifiers, but **does not explicitly require equal study radius, method, centre-eligibility policy, footprint version, numerical boundary semantics and comparable category filtering** (`E-1`). Different-sized circles could pass the listed `E2_DESC` gate.
- The text keeps `E-2*` strict for **any cross-candidate count**, while `E2_DESC` intends to display a *numeric* record-set comparison without a completeness statement. This is a real semantic-policy exception, not just a different name for the same count. The claim that it only refuses more is not established by testing four already-refused cases; its positive `44-a` defines a newly permitted case.
- **Correction:** State the precedence and exact output type: per-candidate raw observations, controlled-snapshot record-set comparison (if chosen), verified-completeness population claim (not currently supported). Define the permitted presentation and whether comparable counts may appear side by side without unsupported real-world conclusions. Add E-1, category and geometry/uncertainty gates and positive/negative counterfactual fixtures.
- **Decision:** `ODR-R-03` and amended `ODR-3-clarification` remain `OWNER_CHOICE_PENDING`; scientific/report-owner review required before authorising numerical comparison.

### GEOHD-S2-04 — `BOUNDARY_UNDECIDED` count semantics conflict with GM-12 S7 (HIGH)

- **Source:** `GEOHD-01` §3.3 `GEOHD-02.3`; §4.2 quotes S7's returned-record count.
- The overlay says an uncertain venue is listed but excluded from **any `Competitor records` count**. Frozen GM-12 S7 counts records returned by the source, distinct from deduplicated/eligible records. A source returning only one position-uncertain record is still a source that returned a record; the overlay must not silently reclassify it as S4/S5 or describe one count as another.
- **Correction:** Define separately `raw_records_returned`, `canonical_records_after_dedup`, `confirmed_within_footprint`, `boundary_undecided` and `excluded`, with conservation/traceability checks; decide which is shown in S7 and in a proposed descriptive comparison. Never show `0` for unknown-completeness absence states. Add an all-uncertain and duplicated-uncertain case.

### GEOHD-S2-05 — R12 one-row rule needs multi-source and no-source cardinality (MEDIUM-HIGH)

- **Source:** `GEOHD-01` §6.3 `GEOHD-05.1` requires exactly one R12 row per R09 state, while the existing `ODR-3-r12-fields` proposal says one row per source per query.
- A future report can use multiple eligible source observations for one candidate, or zero sources when S1 is shown. Exactly one flat row per R09 state cannot also mean one row per source/query without specifying a parent audit record and child source records.
- **Correction:** Specify cardinality and foreign keys: one R09 state has a stable audit-reference entity, containing zero or more source/query provenance records and a required cause when none was queried. Differentiate administrative-boundary source rights from competitor-source rights. Preserve the valid zero-source state without fabricating a source id.
- **Decision:** Correct `ODR-R-05`, amended `ODR-3-r12-fields` and `ODR-R-06` together before adopting Option B.

### GEOHD-S2-06 — Documentary arithmetic / test assurance issues (MEDIUM)

- **Source:** `GEOHD-02` §5 incorrectly states **16 predecessor rows** while immediately stating **10 unmodified + 4 amended = 14**.
- `GEOHD-03` properly finds 11 uncited harness checks, 11 test rows without harness support, 46 checks referenced only through imprecise citations; the overlay is not itself an independent functional verification.
- **Correction:** Correct the 16→14 mismatch, preserve predecessor history, give each Jaspr acceptance row unique fixture IDs and exact expected behavior; attach all 14 manifest-listed files to an independently accessible review package. Execute selected adversarial mutations with distinct reviewer identity and report actual application tests separately.
- **Decision:** `ODR-R-07` process vocabulary is reasonable, but appoint a genuinely separate reviewer; GEOH QA appointment does not itself close the FRG/H3 reviewer appointment unless the governing protocol expressly authorises that scope.

## Owner decision routing

**Low-consequence safeguards may progress separately:** `ODR-3b`, `ODR-3-maxradius`, `ODR-3c-exclusions`, `ODR-3d`, `ODR-3-r01-area` (review their exact proposed text). No signatures have been recorded by this review.

**Hold dependent rows:** `ODR-R-02b`, `ODR-R-03`, `ODR-R-05`, `ODR-R-06`, amended `ODR-3-clarification`, amended `ODR-3-r12-fields`, and final `ODR-3-copy-option` until the above contracts are reconciled. A preferred *conditional* Option B need not be mistaken for an adopted report contract.

**Still deferred real-data dependencies:** production radius and accuracy threshold, rental interface R-1..R-8, real boundary licensing and lineage, ODR-4/H-F permissions and feasibility, and real source-driven evaluations.

## Narrow research-team correction brief and exit criteria

**Assign to:** HC-01 / existing GEOH contract author, with method/scientific consultation on uncertainty and report-owner consultation on comparative count semantics. Research team does not implement Jaspr or self-approve QA.

1. Produce `GEOHD-S2-01` through `-06` tracked correction rows, each mapping source clause → failing counterexample → precise replacement → deterministic acceptance oracle → authority. Preserve originals; version the overlay.
2. Run a stand-alone independent oracle for the new boundary partition, with all named edge cases, proving exactly one classification per valid input and explicitly demonstrating failure of the predecessor predicates.
3. Amend `T-42`, `T-43`, `T-44`, `T-46`, `T-47` and reconcile GM-12 raw-record/eligible-record definitions.
4. Add explicit E-1 prerequisite and output-policy precedence to `E2_DESC`; do not enable it for real reports without Owner and scientific decisions.
5. Specify R09→R12 cardinality and all refusal/no-source/multiple-source cases; ensure audit rows remain accessible and export-safe.
6. Supply the full reproducible package (all manifest entries) to an **independent** reviewer, get a written verdict, and return the actual Owner choice sheet with **only text that was reviewed**.

**Exit:** All corrected predicates mutually exclusive and exhaustive; counterexamples fail the predecessor and hold under the successor; strict-vs-descriptive comparison behavior and report wording unambiguous; 14/14 package files accessible and verified; QA findings and unresolved decisions explicit. `DOCUMENTARY_CORRECTIONS_READY_FOR_OWNER_REVIEW` is the highest possible research-team outcome here. No `L1`, `H3`, or real-data gate changes.
