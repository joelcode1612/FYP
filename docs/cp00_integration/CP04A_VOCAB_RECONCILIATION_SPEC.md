# CP-04A Vocabulary Reconciliation Spec (A1 / `BLK-VOCAB`)

**Status:** engineering spec — implement, then verify on the isolated clone.
**Author:** team lead, 2026-11-17
**Supersedes:** the vocabulary in `20261117_03_bdj_result_persistence.sql` as written.

---

## 1. The actual defect (measured, not assumed)

An earlier report described `BLK-VOCAB` as "`admission_status` does not match the Python
admission vocabulary (`held`/`rejected`/`reviewed`/`stale`)". Re-reading the code shows the
problem is **larger and differently shaped**: there are **two** collisions, and in both the
*existing* vocabulary is authoritative and the *new* SQL is the interloper.

### Collision 1 — same dimension, two spellings

| | Existing | Proposed |
|---|---|---|
| Where | `project1_ai.attempts.outcome`, written by `ledger.finish()` | `bdj_results.execution_outcome` |
| Values | `returned`, `rejected`, `unknown_outcome` | `RETURNED`, `REJECTED`, `TIMED_OUT`, `UNKNOWN_OUTCOME` |

`ledger.py:70` hard-rejects anything outside the lowercase triple
(`MODEL_RECEIPT_OUTCOME_INVALID`). The proposed enum is a second spelling of a dimension that
already has an owner.

`TIMED_OUT` is not merely extra — it is **wrong**. `provider.py:137` maps
`E_PROVIDER_TIMEOUT_OUTCOME_UNKNOWN` to `unknown_outcome` deliberately: when a provider times
out, whether the request was processed *is unknown*. Recording `TIMED_OUT` would assert
"did not complete", which the provider explicitly declines to confirm, and which matters
because the call may still have been billed.

**Resolution:** reuse `('returned','rejected','unknown_outcome')` verbatim. Add nothing.

### Collision 2 — same dimension, different cardinality and different semantics

| | Existing (`BDJEngine.review()` return) | Proposed (`admission_status`) |
|---|---|---|
| Values | `held`, `reviewed`, `rejected`, `stale` | `ADMITTED`, `REJECTED`, `HELD`, `NO_ADMISSIBLE_FINDING` |

Neither is a superset of the other:

| Existing value | Meaning (bdj.py) | Fate under the proposed enum |
|---|---|---|
| `held` | rules not adopted — returns at L70-73, **before any dispatch** | merged into `HELD` |
| `rejected` | `validate_candidates` raised — L125-128 | kept as `REJECTED` (wrong axis, see below) |
| `stale` | source fingerprint changed after validation — L131-133 | **dropped entirely** |
| `reviewed` | success; findings may be empty or not — L136 | renamed `ADMITTED` |
| — | — | `NO_ADMISSIBLE_FINDING` has no counterpart |

Three distinct failures were being collapsed into one value, one was lost, and the success
value was renamed. Renaming is not cosmetic: `api/v1/project1_workflow.py:99-105` is a dict
literal keyed on the four lowercase strings — a rename raises `KeyError` at request time.

**Resolution:** keep `('held','reviewed','rejected','stale')` as the review verdict. Express
`NO_ADMISSIBLE_FINDING` as a **derived** state, not a fifth enum value.

---

## 2. The four dimensions

The directive requires four separate dimensions. They map onto the code as follows.

### D1 — Provider / transport execution outcome

Did the provider call complete? **Owner:** `project1_ai.attempts.outcome` + `attempt_receipts`.

Values: `returned` | `rejected` | `unknown_outcome`. Existing, unchanged, not extended.

### D2 — Structured response validation outcome

Did the returned object pass `validate_candidates()`? **No owner today** — failure is signalled
only by the exception path and the reason string `CANDIDATE_VALIDATION_FAILED`.

Values: `not_validated` | `invalid` | `valid`.

This dimension is **functionally determined** by D3 in the current engine, because
`review()` validates if and only if it dispatched. It is therefore stored as a **generated
column**, not an independent one: explicit and queryable, but structurally unable to drift
from D3.

### D3 — BDJ review outcome

The engine's verdict. **Owner:** `BDJEngine.review()` return value.

Values as persisted: `reviewed` | `rejected` | `stale`, **plus `NULL`** for "never reviewed".

`held` is **excluded from the persisted enum, with a reason**: it is returned at
`bdj.py:70-73` before `ledger.reserve()` is ever called, so no `attempts` row exists, and
`bdj_results` has a composite FK to `attempts(run_id, owner_user_id, attempt_no)`. A `held`
result therefore has no FK target. Persisting one would require either a nullable FK
(weakening integrity) or a synthetic attempt row (fabricating an attempt). Neither is
acceptable. `held` remains where it already lives: the response body and the workflow
projection.

### D4 — Finding authority and persistence

May this result create a business finding, and at what authority?
**Owner:** `finding_authority` on the result (`bdj.py:144`), `review_state` on
`m2_bdj_findings` (`CANDIDATE` | `VERIFIED`).

Values: `candidate_only` — **the only value a cloud result may hold.**

A model-assisted result can never produce `VERIFIED`. That requires independent review, and
BCB enforces it (`FINDING_AUTHORITY_INVALID` unless `review_state='VERIFIED'` with a
`finding_hash`, `confirmation_id` and `review_event_id`). The column is constrained to the
single value so that the schema itself refuses to let a cloud result claim authority.

**This is the safety property the directive names:** "No rejected or unknown-outcome attempt
may be displayed as an admitted business finding." D3 `reviewed` means *the engine completed*,
never *the finding is true*. The two are separated by construction, not by convention.

---

## 3. Resulting column set for `project1_ai.bdj_results`

| Column | Type | Values | Notes |
|---|---|---|---|
| `execution_outcome` | text NOT NULL | `returned`/`rejected`/`unknown_outcome` | D1. Must equal the attempt receipt's outcome — see C5. |
| `review_outcome` | text NULL | `reviewed`/`rejected`/`stale` | D3. `NULL` = dispatched but never reviewed (provider failure). |
| `validation_status` | text GENERATED ALWAYS AS … STORED | `not_validated`/`invalid`/`valid` | D2. Derived, cannot drift. |
| `finding_authority` | text NOT NULL | `candidate_only` | D4. Single-value CHECK. |
| `finding_count` | integer NOT NULL | `>= 0` | Makes `NO_ADMISSIBLE_FINDING` derivable without reading JSONB. |

Generated expression:

```sql
validation_status text GENERATED ALWAYS AS (
  CASE WHEN review_outcome IS NULL      THEN 'not_validated'
       WHEN review_outcome = 'rejected' THEN 'invalid'
       ELSE 'valid' END) STORED
```

`NO_ADMISSIBLE_FINDING` is then `review_outcome = 'reviewed' AND finding_count = 0` — a derived
state, documented in a comment, requiring no enum member.

### Forced combinations

Every reachable state, and every cell is forced — there is no default-to-success path:

| `review_outcome` | `validation_status` | `execution_outcome` | `output_digest` | `result_payload` |
|---|---|---|---|---|
| `NULL` | `not_validated` | `rejected` / `unknown_outcome` | NULL | NULL |
| `rejected` | `invalid` | `returned` | NOT NULL | NULL |
| `stale` | `valid` | `returned` | NOT NULL | NOT NULL |
| `reviewed` | `valid` | `returned` | NOT NULL | NOT NULL |

### Constraints to keep, adjust, or add

| ID | Constraint | Action |
|---|---|---|
| C1 | `(execution_outcome='returned') = (output_digest IS NOT NULL)` | keep |
| C2 | `(validation_status='valid') = (result_payload IS NOT NULL)` | keep (works on generated column) |
| C3 | `admission_status <> 'ADMITTED' OR validation_status='VALID'` | **replace** with `review_outcome <> 'reviewed' OR validation_status = 'valid'` |
| C4 | `bdj_results_one_per_attempt` UNIQUE `(run_id, attempt_no)` | keep |
| C5 | `execution_outcome` must equal the attempt receipt's `outcome` | **add** — cross-table, so implement as a trigger or defer to the service with a test; prefer a service-level check plus an assertion test |
| C6 | `finding_authority = 'candidate_only'` | **add** |
| C7 | `review_outcome IS NULL` → `result_payload IS NULL` | **add** |

---

## 4. Implementation tasks

1. **Correct** `backend/migrations/project1_ai/20261117_03_bdj_result_persistence.sql` in place
   (it has never been applied to `Dss`; it is only applied to the clone, so amending it is
   correct — but the clone must be recreated, not patched, so the receipt stays truthful).
   Rename the column `admission_status` → `review_outcome`, change the value set, add
   `finding_authority`, `finding_count`, and the generated `validation_status`. Update every
   CHECK and every `COMMENT ON`.

2. **Add** `backend/src/sitewise/project1/result_contracts.py`:
   - the four value tuples as module constants, each with a comment naming its owner;
   - `classify(review_result: dict, execution_outcome: str) -> dict` — a **total** function
     that maps a `BDJEngine.review()` result plus the ledger outcome to a `bdj_results` row
     body. It must `raise WorkflowHeld('RESULT_OUTCOME_UNCLASSIFIED')` on any input it does not
     recognise. **No `.get(key, default)`.** No branch that silently returns `reviewed`.
   - `derived_admission(row) -> str` returning `'admitted'` | `'no_admissible_finding'` |
     `'rejected'` | `'held'` | `'stale'` | `'not_reviewed'` for display, computed from the row.
     This is a *presentation* helper; it is never stored.

3. **Tests** at `backend/tests/project1/test_result_contracts.py`, exhaustive over the
   cartesian product of D1 × D3 (including `NULL`) — every pair asserted to produce exactly one
   row shape or raise, with the invalid pairs asserted to raise by name. Plus:
   - round-trip: for each valid row, insert into a live clone and read back, asserting
     `validation_status` is the generated value;
   - a test that inserting `finding_authority='verified'` is refused by the database;
   - a test that `review_outcome='reviewed'` with `result_payload IS NULL` is refused (C3/C2);
   - a test that an unknown `review_outcome` string is refused by the CHECK.

4. **Round-trip scope, stated honestly.** Python → PostgreSQL → API is testable today. The
   **Dart leg does not exist**: no Dart file in `fyp_mobile_app/lib` or `fyp_jaspr_web`
   references `/business-understanding`. The Dart round-trip is therefore `NOT_RUN`, not
   "passing". Do not invent a Dart test to make the row look green.

---

## 5. Non-goals — do not do these

- Do **not** modify `attempts`, `attempt_receipts`, or any historical `outcome` value. The
  existing rows are evidence.
- Do **not** add `TIMED_OUT`, `ADMITTED`, `NO_ADMISSIBLE_FINDING` or any uppercase value to any
  database enum.
- Do **not** apply anything to `Dss`.
- Do **not** widen `finding_authority` beyond `candidate_only` to "future-proof" it.
- Do **not** make `review_outcome` NOT NULL to simplify the FK story — `NULL` is a real state
  (provider failed after the attempt was reserved) and collapsing it would misreport a failed
  call as a review.
