# CP-04A — Activity History V1.1 Fidelity

**Date:** 2026-11-17 · **Endpoint:** `GET /project1-workflow/assessments/{assessment_id}/results`
**Status:** API `VERIFIED` against the clone · Dart/Jaspr `NOT_RUN`

---

## 1. What V1.1 is, and what it is not

V1 (`GET /m2/assessments/{id}/activity`) is a **presentation** feed over existing M2 activity. It is
untouched.

V1.1 is a **readback of persisted model-assisted results** — rows in `project1_ai.bdj_results`. The
difference matters: V1 can be produced from live state, so it cannot prove anything survived. V1.1
reads what was written, so a passing V1.1 test is evidence of durability.

V1.1 is additive. It does not replace, rename or reorder anything in V1, and it introduces no new
outcome vocabulary.

## 2. Response contract

```json
{
  "assessment_id": "…",
  "result_count": 1,
  "status_contract": "UNRECONCILED_PROPOSAL",
  "scientific_acceptance": false,
  "owner_authorization": false,
  "publication_authorized": false,
  "fielding_authorized": false,
  "report_release_authorized": false,
  "results": [{
    "result_id": "…", "run_id": "…", "attempt_no": 1,
    "assessment_id": "…", "assessment_revision": 2,
    "execution_outcome": "returned",
    "review_outcome": "reviewed",
    "review_reason": null,
    "validation_status": "valid",
    "finding_authority": "CANDIDATE_ONLY",
    "finding_count": 1,
    "prompt_version": "…", "model_requested": "…", "model_returned": null,
    "output_digest": "…", "created_at": "…",
    "findings": [{"rule_id": "…", "kind": "…", "observed_condition": "…",
                  "counterargument": "…", "justification": "…", "next_action": "…"}],
    "references": [{"item_key": "M2-04", "answer_revision_id": "…", "item_version_id": "…"}]
  }]
}
```

Headers: `Cache-Control: no-store`. `finding_authority` is forced to `CANDIDATE_ONLY` on every row and
the five authority flags are spread from `no_authority()`, so a persisted result can never render as
approval.

## 3. The four dimensions are surfaced, not collapsed

| Field | Means | Source of truth |
|---|---|---|
| `execution_outcome` | did the provider call complete | `project1_ai.attempts.outcome`, written by `ledger.finish()` |
| `validation_status` | did the returned object pass validation | generated column on `bdj_results` |
| `review_outcome` | the engine's verdict | `BDJEngine.review()` |
| `finding_authority` | may this claim authority | always `candidate_only` |

A `returned` transport outcome coexists with `reviewed`, `rejected` or `stale`. `reviewed` with zero
findings is legitimate and renders as `no_admissible_finding`, not as a failure. `held` never appears
here because it returns before `ledger.reserve()` and therefore has no row — that is why History can
show a hold only from live state, never from a stored result.

## 4. What is deliberately absent, and why

| Absent | Reason |
|---|---|
| `result_payload` | it embeds `source_refs[].quote` — a verbatim substring of an entrepreneur's answer |
| `source_refs[].quote` | same; `REFERENCE_KEYS` has no `quote` member, so it has no path into the output |
| every `bdj_raw_responses` column | the runtime principal has no `SELECT` on that table; only the audit principal does |

These are not omissions by convention. `_project_payload()` copies from two tuples that do not contain
`quote`, and the route never names the raw table. The test asserts the exclusion **while proving the
data was stored**, so a future change that stops persisting the quote cannot make the test pass
vacuously:

```
test_history_projection_excludes_the_quote_sentinel
  'We are takeaway-only.' NOT in response   (and it IS in result_payload, read as admin)
  'DINE_IN_FOCUSED'       NOT in response
  'result_payload'        NOT in response
  every reference has exactly {item_key, answer_revision_id, item_version_id}
```

## 5. Owner scoping

Two independent filters, both required:

1. `restricted_scope()` binds `project1.actor_id`, so row-level security filters by owner.
2. `WHERE assessment_id = :a AND owner_user_id = :o` filters again.

Relying on RLS alone would silently widen the result if a future session ran under a role with
`BYPASSRLS`. Test: `test_history_is_owner_scoped` — a second user with a valid session gets
`result_count: 0`, not an error, because the assessment is not theirs to see.

## 6. Dart DTO shape (for the client, not yet built)

```
ActivityResultV11
  resultId, runId, attemptNo, assessmentRevision
  executionOutcome, reviewOutcome, validationStatus
  findingAuthority          // always "CANDIDATE_ONLY"
  findingCount
  findings: List<FindingV11>   // six fields, no source_refs
  references: List<ReferenceV11>  // itemKey, answerRevisionId, itemVersionId
  createdAt
```

`status_contract` and the five authority flags must be rendered, not dropped. A client that shows
findings without showing `CANDIDATE_ONLY` converts a candidate into an apparent finding — the exact
failure the field exists to prevent.

## 7. Not built in this session

The Dart DTO and the Jaspr rendering. The directive asks for `API → Dart DTO → Jaspr`. The API third
is `VERIFIED`; the other two are `NOT_RUN`. Reporting a UI pass from an API test is the substitution the
directive explicitly forbids, so it is not claimed.

To finish: generate the DTO from §2, render it inside the existing V1 History panel rather than a new
screen (the directive requires preserving V1 presentation), and add a browser test that asserts the
quote sentinel is absent from the rendered DOM as well as from the JSON.

## 8. Evidence

```
cd backend
./.venv/Scripts/python.exe scripts/run_project1_clone_tests.py \
    tests/project1/test_model_assisted_route.py -q
→ 16 passed
```

Four of those sixteen are the History V1.1 tests: persistence + authority, quote sentinel, owner
scoping, and read-back across fresh clients (durability). Full suite: `246 passed, 1 skipped`.
