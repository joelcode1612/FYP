# `GEOHD-02` — Revised Owner decision matrix

**Package:** `GEOH_INDEPENDENT_CHALLENGE_DELTA_20261030` · **Date:** 2026-10-30
**Directive:** `PROJECT1-GEOH-INDEPENDENT-CHALLENGE-DELTA-20261030`
**Custodian:** `HC-01` — handover custodian only; not a coordinator, not a QA approver, not a developer, and **not the independent reviewer the register asks the Owner to appoint**.
**Signatures in this file: 0.** Rows: **21 predecessor + 9 new = 30.** **Nothing is adopted.** `ADOPTED_OPTION = None` (`GEOH-04` DC-46) is unchanged, and this file cannot change it.

> **The one line:** the predecessor invited the Owner to sign fourteen rows in one sitting. **Ten of those fourteen still can be. Four cannot be signed as written** — this overlay changed what they mean — and the nine new rows must be read beside them. **No row is pre-marked approved, and the blank fields in §7 are deliberately blank.**

---

## 1. How to read this matrix

Every predecessor row is preserved verbatim in `GEOH-02`; this file adds a **disposition** column that says what the overlay did to it.

| disposition | meaning | count |
|---|---|---|
| **`SIGNABLE_UNMODIFIED`** | the row's question and recommended answer are untouched by any `GEOHD-` rule | **10** |
| **`SIGNABLE_ONLY_AS_AMENDED`** | the row is still decidable now, but the text the Owner would have signed last time no longer matches what it commits to | **4** |
| **`WAITS_ON_ARTEFACT`** | unchanged from `GEOH-02` — needs real data, a real rental, a licence, or another person's answer | **7** |
| **`NEW`** | introduced by this overlay (`ODR-R-*`); decidable now in principle, several gated | **9** |

Three rules govern all of it:

- **`AC-D1`** (overlay §0) — no rule here relaxes a refusal. `D-C-23` verifies all 19 radius/centre/display fixture cases keep their verdict; `D-C-24` verifies the banned-phrase list and the S1–S5 digit rule are untouched.
- **`AC-D3`** — every new field, state and error code is a **proposal**. Signing `ODR-R-*` rows adopts text, not data.
- **`GEOH-05` `AC-00`** — L0 does not imply L1. **No combination of signatures in this file produces a compiling application, a real rental, a licensed polygon or a passed Jaspr test.**

The register's own constraint, which this matrix obeys (`inputs/…RETURN.md:25`):

> **Do not sign unmodified:** E-2* until comparative-display product decision; `partial` geometry definition; proposed single tolerance semantics; complete six-object contract as acceptance baseline until REV-01/02/04/05 reconciled.

---

## 2. The fourteen, restated: ten + four

### 2.1 Ten rows signable exactly as written

| row | what it decides | recommendation being signed | untouched by |
|---|---|---|---|
| `ODR-3b` | display radius must equal study radius | mandatory equality; a mismatch is a report defect | `REV-01`–`08` — none touches it |
| `ODR-3c-exclusions` | `AREA_ONLY` and `LISTING_PIN` centres ineligible for a premises circle | yes, both refused | `REV-04` explicitly **does not** reopen it (overlay §5.5); `ODR-R-04` changes only DC-06's *display* semantics |
| `ODR-3c-grants-policy` | the *policy* for granting `PREMISES`/`BUILDING` centres | coordinate + named provenance + numeric accuracy (`BUILDING` also an entrance-offset bound); never defaulted | `REV-02` splits epsilon from accuracy; the policy's three requirements survive verbatim |
| `ODR-3d` | what a geographic section may assert | only the six-part factual statement; never demand/suitability/ranking/walking time/catchment/saturation | `REV-03` adds a narrower comparison regime but removes no prohibition; `REV-08` only changes test-row format |
| `ODR-3-maxradius` | a request above the supported maximum | explicit refusal, never a silent clamp | `REV-01`'s preview/public split does not soften it |
| `ODR-3-label-semantics` | which date the provenance line denotes | `RETRIEVAL_TIME`, with `SOURCE_VINTAGE` shown separately as `as_of` | `REV-06` needs it and does not amend it |
| `ODR-3-surfaces` | whether the phrase ban reaches negated warnings, quotations, a11y labels, the provenance line | yes, every surface a reader can read | `REV-06` relies on it |
| `ODR-3-qualifier` | replacement for the S4/S5 qualifier that contains a banned phrase | `This is an empty result, not a finding about the area.` | `REV-03` reuses the frozen S7 sentence instead of editing this one |
| `ODR-3-blockboundary` | whether a per-rental block includes the rental label | reading (i): the block begins at the component; `No. 12` sits outside it | `REV-06` **depends on** this reading (`GEOH-T-47-e`) and does not amend it |
| `ODR-3-r01-area` | which area `R01` prints when it says "the address and its area" | (a) the rental's administrative area, never the competitor search zone | `REV-01` sharpens the two-object distinction this row already makes |

**Signing all ten produces**: a contract that refuses more than the code does today, and no new output. **Signing all ten does not produce**: a radius, a tolerance, a polygon, a comparison, or a test result.

### 2.2 Four rows that are **not** signable as written

These four are still decidable in the same sitting — the Owner is not being told to wait — but what would be signed must be the amended text, and the amendment comes from this overlay.

| row | the text as written in `GEOH-02` | what changed | amended text to sign | new row carrying it |
|---|---|---|---|---|
| **`ODR-3-tolerance-policy`** | "Must a boundary tolerance be declared, and must it be explicit rather than defaulted?" — justified by *"a venue at exactly `R` is decided by floating-point noise (~3.6 × 10⁻¹² m reproduced)" | `REV-02` measured the gap between that noise and a real venue coordinate: **0.5 m ÷ 3.64 × 10⁻¹² m = 1.37 × 10¹¹**. One quantity cannot serve both. The float-noise **argument** is withdrawn; the **requirement** (declare it, never default it) stands. | yes to declaration and no-defaulting, with the justification restated as positional uncertainty only, and `numerical_epsilon_m` reclassified as an implementation constant | `ODR-R-02a` |
| **`ODR-3-clarification`** | "E-2 is satisfied only by a shared versioned snapshot **and** a written completeness statement per footprint" (`E-2*`) | `REV-03` puts a **product choice** in front of it: `E-2*` governs a *count*, while a same-snapshot *record-set* comparison is a distinct, narrower output with its own policy. Signing `E-2*` unmodified now would silently pre-decide that comparison is impossible. | `E-2*` **unchanged and strict** for any cross-candidate count, with the sentence "which regime governs record-set comparisons is `COMPARISON_POLICY`" added | `ODR-R-03` |
| **`ODR-3-copy-option`** | "Option A (one exempt provenance timestamp) or Option B (no timestamp in the block; dates in the R12 audit row)?" → **Option B** | `REV-05`/`REV-06` show Option B is not implementable as written: its dates need a home (`ODR-3-r12-fields`, now amended) **and** an accessible, named `R09 → R12` linkage that no predecessor clause requires. `D-C-18` records that `E_OPTION_UNSET`'s fail-closed behaviour is likewise "specified" but unenforced. | Option B, **conditional on `ODR-R-05`, `ODR-R-06` and the amended `ODR-3-r12-fields`** — the ordering `GEOH-02` §5 already demands | `ODR-R-06` |
| **`ODR-3-r12-fields`** | field list: `source · queried · retrieved · vintage · coverage · snapshot_id · licence_id · rights_state`, with `footprint_ref` **required** | `REV-05`: an `AREA_ONLY` candidate has **no footprint**, so a required `footprint_ref` makes the honest R12 row unrepresentable — the audit row would either be omitted or carry a invented reference. `GEOHD-05.2` makes it nullable-with-reason and adds two fields. | the same eight fields **plus** `footprint_state` **plus** `footprint_withheld_reason_code`, with `footprint_ref` nullable only when `footprint_state` names why | `ODR-R-05` |

**Why this is disclosed rather than fixed quietly:** `GEOH-02` §4's headline ("Fourteen of the twenty-one rows need nothing but a decision") is now **ten**. If the Owner signed the sheet from the predecessor, four signatures would attach to text this overlay has since corrected. `GEOHD-01` §10 records this as erratum territory, and `AC-D4` forbids silently editing a frozen file — so the predecessor stays byte-identical (re-verified 9/9, exit 0) and the amendment lives here.

### 2.3 Seven rows still waiting (unchanged from `GEOH-02`)

`ODR-3a-dev` (demonstration-only by nature), `ODR-3a-prod`, `ODR-3c-grants-satisfaction`, `ODR-3-tolerance-value`, `ODR-3-mukim-navigation`, `ODR-3-name-reuse`, `ODR-3-rental-interface`.

The overlay changes none of their blockers. Two get **sharper**, and the Owner should know which:

- **`ODR-3-tolerance-value`** — `REV-02`'s `BOUNDARY_UNDECIDED` third verdict resolves the measured float case (`800.0000000000036` m) **with no Owner number adopted**. The row therefore stays `OPEN` *and* stops being urgent: the contract no longer needs a value to avoid a coin-flip. `ODR-R-02b` is the row that changes a reported number, not this one.
- **`ODR-3-rental-interface`** — `REV-04`'s `display_location_hint` (`ODR-R-04`) asks the rental side for something new (a class + provenance + `NOT_FOR_PROXIMITY` flag), so the eight questions gain a ninth field. `ODR-3-rental-interface` itself is a *teammate answer*, not a signature.

---

## 3. The nine new rows

| new row | question the overlay asks | bucket | what signing it **does** | what signing it **does not** | gate beyond the signature |
|---|---|---|---|---|---|
| **`ODR-R-01`** | Adopt `GEOHD-01.1`–`01.5`: separate *display state* from *render decision*, *marker* from *polygon*, *preview* from *public*, and split `expected_drawn` into `expected_polygon_render` / `expected_marker_display`. | `ADOPT_NOW` | removes an advertised capability: **no real administrative polygon renders today** | does not license any polygon, nor resolve `ODR-3-name-reuse` | must **not** be signed expecting a boundary to appear |
| **`ODR-R-02a`** | Accept that representation epsilon is an implementation constant, not Owner policy, and restate `ODR-3-tolerance-policy`'s justification without the float-noise argument. | `ADOPT_NOW` | decouples a picometre artefact from a metre-scale uncertainty | adopts **no** numeric tolerance | — |
| **`ODR-R-02b`** | Accept `BOUNDARY_UNDECIDED` as a third membership verdict: the venue is listed but counted on neither side. | `ADOPT_NOW` | changes **what a count means** near the boundary | does **not** make any count larger or smaller today | **this is the row that touches a reported number — it is not "wording"** |
| **`ODR-R-03`** | Choose `COMPARISON_POLICY ∈ {E2_STRICT, E2_DESC}` (no default). | `ADOPT_NOW` for the *choice* | names which regime governs cross-candidate display | does **not** emit any comparison; `E2_DESC` requires scientific review first | `GEOHD-03.3`: adopting `E2_DESC` unlocks **zero** outputs (all 4 refused fixtures stay refused, `D-C-10`) |
| **`ODR-R-04`** | Permit an optional `display_location_hint` (class + provenance + `NOT_FOR_PROXIMITY`) for `LISTING_PIN`/`AREA_ONLY`. | `ADOPT_NOW` | allows an approximate marker to be *shown* | does **not** allow it as a centre, in a radius, or in a count; does **not** sign `ODR-3c-exclusions` | register requires this be presented as an Owner option — it is |
| **`ODR-R-05`** | Make `R12` **total over refusals**: `footprint_ref` nullable-with-reason, plus `footprint_state` and `footprint_withheld_reason_code`. | `ADOPT_NOW` | every withheld footprint gets an honest audit row | manufactures no claim; **only adds an audit row and forbids a false one** | amends `ODR-3-r12-fields` — sign them together |
| **`ODR-R-06`** | Adopt `GEOHD-06.1`–`06.5` as a **prerequisite of Option B**: stable provenance ids and an accessible, checked `R09 → R12` linkage. | `ADOPT_NOW` | converts a recommendation into a named, gated dependency | does **not** prove a11y — a documentary check cannot; needs a real browser (`PC-5`) | makes `ODR-3-copy-option` signable only as amended |
| **`ODR-R-07`** | Appoint the independent QA reviewer **and** adopt `AC-11`/`AC-12`/`AC-13` (two numerators never merged; family globs are not citations; the harness never prints `PASS`). | `ADOPT_NOW` for the vocabulary | makes the 88-vs-41 distinction structural instead of remembered | the **appointment is a personnel decision** this package cannot make; `ODR-2` is blank | reviewer must be **neither** `HC-01` **nor** the implementer |
| **`ODR-R-08`** | Adopt the three-axis row format (S / I / G recorded independently) for `GEOH-T-01`…`T-49`. | `ADOPT_NOW` | changes what a test row may assert; `S_PARTIAL` no longer implies a polygon decision | changes **no rule semantics**; register severity `LOW` | — |

**Row count: 21 → 30 (+9). Signatures collected: 0.**

---

## 4. Revised ordering — what must be decided before what

`GEOH-02` §5's arrow diagram, with this overlay's additions in **bold**:

```
ODR-3d + ODR-3c-exclusions                 (what may never be shown)
   └ ODR-R-01  ← ADDS: and what may never be *rendered* while it is "named"
ODR-3b + ODR-3-maxradius + ODR-3-tolerance-policy
   └ ODR-R-02a splits tolerance-policy into epsilon vs uncertainty
   └ ODR-R-02b adds the third verdict — decide it before ODR-3-tolerance-value matters
ODR-3-label-semantics → ODR-3-r12-fields → ODR-3-copy-option
   └ ODR-R-05 amends r12-fields ─────────┘  (both must move together)
   └ ODR-R-06 is a prerequisite of copy-option (Option B needs somewhere reachable to point)
ODR-3-qualifier + ODR-3-blockboundary + ODR-3-surfaces
   └ unchanged; ODR-R-06 depends on blockboundary reading (i)
ODR-3-clarification (E-2*/E-3*)
   └ ODR-R-03 sits ABOVE it for record-set comparisons; E-2* itself stays strict
ODR-3c-grants-satisfaction ← R-4 / R-8 ← ODR-4 / H-F
   └ ODR-R-04 asks the rental side for a ninth field (hint class + provenance)
ODR-3a-prod + ODR-3-tolerance-value        (a real radius exists)
   └ ODR-R-07 + ODR-R-08 gate what may be *reported* once anyone builds anything
```

**The arrow that still matters most, unchanged:** `ODR-3-copy-option` cannot be implemented before `ODR-3-r12-fields`, because Option B's dates have nowhere to live. The overlay makes that dependency **two**-sided now: the fields must also be amended (`ODR-R-05`) **and** the linkage must exist (`ODR-R-06`).

---

## 5. What the Owner can sign in one sitting — revised

| sign together | rows | effect |
|---|---|---|
| **Geometry correctness** | `ODR-3b`, `ODR-3-maxradius` + **`ODR-R-01`**, **`ODR-R-02a`** | the drawn circle describes the executed query; no silent clamp; **nothing rendered from an unlicensed boundary** |
| **Boundary semantics** | `ODR-3-tolerance-policy` *(as amended)*, **`ODR-R-02b`** | a venue straddling `R` is undecided and says so; **`ODR-3-tolerance-value` stays `OPEN`** |
| **Refusal set** | `ODR-3c-exclusions`, `ODR-3c-grants-policy`, `ODR-3d` + **`ODR-R-04`** | what may never be drawn, never be a centre, and never be asserted |
| **GM-12 wording** | `ODR-3-label-semantics`, `ODR-3-qualifier`, `ODR-3-blockboundary`, `ODR-3-surfaces` + **`ODR-3-r12-fields` (amended)**, **`ODR-3-copy-option` (conditional)**, **`ODR-R-05`**, **`ODR-R-06`** | closes F-3, F-4/N1, N1-a, N1-b, N1-c and `ODR-V21A-07/-08/-09` — **only as a bundle**; `ODR-3-r12-fields` and `ODR-3-copy-option` are in the amended group |
| **Structure & comparison** | `ODR-3-clarification` *(as amended)* + **`ODR-R-03`**, `ODR-3-r01-area`, **`ODR-R-08`** | E-2/E-3 and R01's "area" decided; S/I/G axes recorded separately |
| **Assurance** | **`ODR-R-07`** | `AC-11`/`AC-12`/`AC-13` adopted; **the reviewer appointment is a separate act** |

Sixteen predecessor rows appear above — ten unmodified, four amended — plus nine new. **The fourteen are not signed, not pre-filled, and not treated as approved by their presence in this table.**

---

## 6. Non-decisions (explicitly not asked for here)

This package does **not** ask the Owner to, and does not by inference:

1. select an official numeric radius (400/500/800/1200 m stay labelled experiments; `ODR-3a-prod` stays `OPEN`);
2. adopt the 0.5 m tolerance as anything but a labelled example (`GM-GEO-14` value still unset);
3. modify any frozen predecessor file (`GEOH_ODR3_TO_JASPR_20261030/` re-verified 9 lines `OK`, `sha256sum -c` exit 0 after all this work);
4. build, compile or integrate Jaspr (L1 not reached; **0 of 41 → 49 acceptance tests executed**);
5. acquire or display real competitor data (`ODR-4` blank; ADM2/ADM3 `LICENCE_CHAIN_UNVERIFIED — BLOCKED`; MyGDI `SOURCE_NOT_ACCESSIBLE`; `G_NO` for every tier);
6. draw one real administrative polygon;
7. approve implementation, a phase gate, or scientific closure;
8. re-run the 20 earlier ODR-3 geometry experiments (they stay reused under their own pins — `D-P-06`).

---

## 7. Signature sheet — 30 rows, all fields blank

Every field below is **blank on purpose**. `HC-01` signs nothing; a directive that says "do not automatically sign the fourteen rows" is obeyed by leaving the sheet empty, not by pre-filling a recommendation column. Sign `Y` / `N` / `DEFER`, then initial and date.

| # | row | disposition | decision | initials | date |
|---|---|---|---|---|---|
| 1 | `ODR-3b` | `SIGNABLE_UNMODIFIED` | ____ | ____ | ____ |
| 2 | `ODR-3c-exclusions` | `SIGNABLE_UNMODIFIED` | ____ | ____ | ____ |
| 3 | `ODR-3c-grants-policy` | `SIGNABLE_UNMODIFIED` | ____ | ____ | ____ |
| 4 | `ODR-3d` | `SIGNABLE_UNMODIFIED` | ____ | ____ | ____ |
| 5 | `ODR-3-maxradius` | `SIGNABLE_UNMODIFIED` | ____ | ____ | ____ |
| 6 | `ODR-3-label-semantics` | `SIGNABLE_UNMODIFIED` | ____ | ____ | ____ |
| 7 | `ODR-3-surfaces` | `SIGNABLE_UNMODIFIED` | ____ | ____ | ____ |
| 8 | `ODR-3-qualifier` | `SIGNABLE_UNMODIFIED` | ____ | ____ | ____ |
| 9 | `ODR-3-blockboundary` | `SIGNABLE_UNMODIFIED` | ____ | ____ | ____ |
| 10 | `ODR-3-r01-area` | `SIGNABLE_UNMODIFIED` | ____ | ____ | ____ |
| 11 | `ODR-3-tolerance-policy` | **`SIGNABLE_ONLY_AS_AMENDED`** (§2.2) | ____ | ____ | ____ |
| 12 | `ODR-3-clarification` | **`SIGNABLE_ONLY_AS_AMENDED`** (§2.2) | ____ | ____ | ____ |
| 13 | `ODR-3-copy-option` | **`SIGNABLE_ONLY_AS_AMENDED`** (§2.2) | ____ | ____ | ____ |
| 14 | `ODR-3-r12-fields` | **`SIGNABLE_ONLY_AS_AMENDED`** (§2.2) | ____ | ____ | ____ |
| 15 | `ODR-3a-dev` | `WAITS_ON_ARTEFACT` (demonstration-only) | ____ | ____ | ____ |
| 16 | `ODR-3a-prod` | `WAITS_ON_ARTEFACT` | ____ | ____ | ____ |
| 17 | `ODR-3c-grants-satisfaction` | `WAITS_ON_ARTEFACT` | ____ | ____ | ____ |
| 18 | `ODR-3-tolerance-value` | `WAITS_ON_ARTEFACT` | ____ | ____ | ____ |
| 19 | `ODR-3-mukim-navigation` | `WAITS_ON_ARTEFACT` (`CONDITIONAL`) | ____ | ____ | ____ |
| 20 | `ODR-3-name-reuse` | `WAITS_ON_ARTEFACT` (`OPEN`) | ____ | ____ | ____ |
| 21 | `ODR-3-rental-interface` | `WAITS_ON_ARTEFACT` (`OPEN`) | ____ | ____ | ____ |
| 22 | **`ODR-R-01`** | `NEW` | ____ | ____ | ____ |
| 23 | **`ODR-R-02a`** | `NEW` | ____ | ____ | ____ |
| 24 | **`ODR-R-02b`** | `NEW` — touches a reported number | ____ | ____ | ____ |
| 25 | **`ODR-R-03`** | `NEW` — policy choice, no default | ____ | ____ | ____ |
| 26 | **`ODR-R-04`** | `NEW` | ____ | ____ | ____ |
| 27 | **`ODR-R-05`** | `NEW` — bundle with row 14 | ____ | ____ | ____ |
| 28 | **`ODR-R-06`** | `NEW` — bundle with row 13 | ____ | ____ | ____ |
| 29 | **`ODR-R-07`** | `NEW` — vocabulary; appointment is separate | ____ | ____ | ____ |
| 30 | **`ODR-R-08`** | `NEW` | ____ | ____ | ____ |

**Totals:** rows 30 · signed 0 · declined 0 · deferred 0 · blank 30.

---

## 8. Evidence index (where each claim in this file is checkable)

| claim | artefact | check |
|---|---|---|
| 21 predecessor rows exist and are quoted correctly | `GEOH-02` §2–§4, §4 table (14 + 7) | read the file; `ODR-3-tolerance-policy` text at `GEOH-02:58` |
| the 10/4 split follows from the overlay | `GEOHD-01` §3.5, §4.5, §6.5, §7.5 (lines 192, 252, 360, 414) | §2.2 of this file cites each |
| the register forbids signing E-2* / `partial` / single-tolerance unmodified | `inputs/GEOH_INDEPENDENT_CHALLENGE_AND_TARGETED_RETURN.md:25` | quoted verbatim in §1 |
| no refusal was relaxed | overlay §0 `AC-D1`; fixtures | `D-C-23` (19 cases), `D-C-24` (wording set) |
| 1.37 × 10¹¹ ratio | `GEOH-03` §9.4 measured float paragraph + `G-09-*` | `D-R-06`…`08` |
| `E2_DESC` unlocks nothing | `comparison_cases` fixture | `D-C-10`, `refused comparison cases = 4` |
| predecessor untouched | `SHA256_MANIFEST.txt` (9 lines) | `D-P-04`, `9/9 lines verify; failures=[]`, exit 0 |
| 88 vs 41, tiers 23/7/11, 11 uncited checks | `data/split_summary.json` + `GEOHD-03` | `D-R-20`, `D-C-21`, `D-C-22` |
| 62 delta checks, 0 violated | `_verify/logs/geoh_delta_check.log` | `python -B _verify/geoh_delta_check.py` |

---

## 9. What this matrix does not establish

- It does **not** adopt a single rule. `ADOPTED_OPTION = None`; dispositions describe *what could be signed today*, not what is true.
- It does **not** sign the fourteen. Ten are merely *still* signable; four need the amended text.
- It does **not** create the independent QA reviewer. `ODR-2` is blank and `H3` remains `REVIEW_NOT_EXECUTED`; the register's requirement (reviewer distinct from `HC-01` and from the developer) is unmet until the Owner acts.
- It does **not** move any readiness level: **L0 only.** No Jaspr build, no real rental, no licensed geometry, no executed acceptance test, no scientific gate.

**AC-D10 (this file's honest one-line status):** *the overlay leaves ten of the fourteen rows exactly as they were, corrects the other four before anyone signs them, adds nine rows the Owner has not yet been asked about, and collects zero signatures — so the decision still belongs entirely to the Owner.*
