# PROJECT1 — D02 Decision Record: `BDJ-M2V1-0.1-CAND` Retirement

**Decision ID:** D02
**Date:** 2026-11-17
**Decision owner:** Project Owner
**Recorded by:** CP-03F implementation
**Status:** **DECIDED — RETIRE**

---

## 1. Question put to the Owner

CP-03F-03 required a review of the four candidate M2V1 rules against a single test: *is this a
contradiction between two declarations, or is it an undecided planning assumption?* The directive
was explicit that **"rule classification must not automatically be treated as `SOURCE_CONFLICT`
without an independently defensible justification"**, and that the implementer must not self-adopt.

## 2. Findings presented

| Rule | Trigger | Verdict |
|---|---|---|
| `M2V1_PRODUCT_EMPHASIS_UNDECIDED_PRODUCTS` | `M2V1-03=[UNDECIDED]` + `M2V1-06 ∈ {QUALITY, DISTINCTIVE_CONCEPT}` | **Not a contradiction** — planning uncertainty. A business may intend a quality position before fixing the range; both statements can hold at once. |
| `M2V1_PRODUCT_PREFERENCE_UNDECIDED_PRODUCTS` | `M2V1-03=[UNDECIDED]` + `M2V1-09 ∋ PRODUCT_PREFERENCE` | **Research-clarification requirement** — the stimulus is undefined, and the entrepreneur may intend to use the research to decide the range. |
| `M2V1_SEGMENT_INTEREST_UNDECIDED_GROUPS` | `M2V1-04=[UNDECIDED]` + `M2V1-09 ∋ SEGMENT_INTEREST` | **Research-clarification requirement** — undefined population, not a logical conflict. |
| `M2V1_DELIVERY_WITH_ON_PREMISE_OCCASION` | `M2V1-02=DELIVERY` + `M2V1-07 ∈ {STUDY_WORK, SOCIAL, LEISURE}` | **Not a contradiction** — delivery-only can serve social occasions off-premise (group orders, office delivery). |

All four are better described as `INFORMATION_GAP`. Reclassifying them would be a **contract and
classification change**, not a rename, and was therefore an Owner decision.

Independently, CP-03E proved by execution that every genuine cross-item contradiction on M2V1 is
already **structurally prevented at write time** by `validate_m2_answer` (derived options,
`exclusive`, `requires_priority`). Those classes are documented in `STRUCTURALLY_PREVENTED` rather
than implemented, because a rule that can never fire is a false claim of coverage.

## 3. Options offered

| Option | Consequence |
|---|---|
| **A. Retire the ruleset** (chosen) | Accept that M2V1 BDJ is contradiction-free by design. No contract change. |
| B. Adopt as `INFORMATION_GAP` | Amend the `Finding` contract to add a new class, reclassify all four rules, and shift admission, persistence and UI. Requires independent scientific review first. |
| C. Defer | Leave the ruleset inactive and undecided; P0 stays blocked. |

## 4. Decision

**Option A — retire `BDJ-M2V1-0.1-CAND`.**

The ruleset is not adopted, not registered, and cannot be activated. No `INFORMATION_GAP` class is
introduced at this time. The M2V1 instrument's BDJ contribution is contradiction-free by design.

## 5. What was changed to implement it

| Change | Effect |
|---|---|
| `backend/src/sitewise/project1/bdj.py` — `'BDJ-M2V1-0.1-CAND'` removed from `RULE_MODULES` | `load_rules()` now raises `BDJ_RULE_ADOPTION_REQUIRED` for this version, **even with a valid adoption receipt and a correct sha256**. Retirement is not bypassable. |
| `backend/src/sitewise/domain/bdj_m2v1_candidate_rules.py` — docstring rewritten to `RETIRED_NOT_ADOPTED`; `ADOPTED = False`, `STATUS = "RETIRED_NOT_ADOPTED"` added | Status is readable at import time. |
| **Rule code left byte-for-byte unchanged** | The historical candidate remains auditable; the evidence behind CP-03E/CP-03F is preserved. |
| `backend/tests/project1/test_bdj_m2v1_rules.py` — 4 retirement tests added | Proves the ruleset is unregistered, that a forged receipt cannot revive it, that the status is recorded, and that an empty rule vocabulary causes `BDJ_RULE_NOT_REGISTERED` for any model candidate. |

The 20 pre-existing tests still pass unchanged. They continue to prove that each rule *would* fire
and that the prevented classes are real — which is what makes the retirement a decision rather than
an unverified assertion.

## 6. Consequences, stated plainly

1. **Cloud BDJ cannot contribute a finding on M2V1.** `BDJEngine.review` computes `allowed` from the
   registered ruleset; for M2V1 that set is now empty, so any model-proposed issue is refused with
   `BDJ_RULE_NOT_REGISTERED`. This is the adopted position, not a regression.
2. **The finding-decision UI (CP-03F-01) stays correct but unexercised.** It is implemented and
   gated on real findings; with no findings producible on the only authorized instrument, it cannot
   be demonstrated in a browser. That is a consequence of this decision.
3. **E2E-01 remains `EXPECTED_HOLD`.** The directive forbids inventing a finding to pass it. No
   finding was invented.
4. **`BDJ-RULE-COVERAGE-01` is closed as *restated*, not as *delivered*.** The accurate statement is
   now: *M2V1 has no defensible deterministic contradiction rule, and none is needed because the
   contradictions it could express are prevented at write time.*
5. **Re-opening requires a new decision.** If a future instrument permits genuine contradictions, or
   if the Owner later wants `INFORMATION_GAP` findings, that is a fresh contract change with its own
   review — not a re-registration of this module.

## 7. Evidence preserved

| Artefact | Location |
|---|---|
| Historical ruleset (unchanged) | `backend/src/sitewise/domain/bdj_m2v1_candidate_rules.py` |
| Rule-firing and structural-prevention tests | `backend/tests/project1/test_bdj_m2v1_rules.py` |
| Rule review and reasoning | `docs/cp00_integration/PROJECT1_CP03F_BDJ_UI_AND_HISTORY_VERIFICATION_20261117.md` §D02 |
| Live admission attempt (10/10 gates) | `docs/cp00_integration/PROJECT1_CP03D_BDJ_EXECUTION_EVIDENCE_20261117.md` |
| Ledger runs | `project1_ai.runs` / `attempts` / `attempt_receipts` (9 runs) |

## 8. Not decided here

This record does not authorize publication, fielding, QJ/QG execution, or any scientific claim. It
does not modify the instrument, the admission contract, or the ledger.
