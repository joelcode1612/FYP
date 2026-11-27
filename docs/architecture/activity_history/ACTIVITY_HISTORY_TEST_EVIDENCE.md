# Activity History — Test Evidence (Stage F)

**Date:** 2026-11-25
**Target:** `project1_pg18_migrated_tests` @ `127.0.0.1:5544`, HTTP `127.0.0.1:8093`
**Principal:** `p1_m2_runtime` (RLS-subject), owner `32ef694a-69b0-4863-a77f-b9cf6c056b56`

## Evidence classes used

| Class | Meaning | Used here |
|---|---|---|
| **E1** | Source inspection (catalogue, columns, constraints, policies, privileges) | yes |
| **E2** | Component / integration test against real PostgreSQL | yes |
| **E3** | Controlled failure injection | partially — see §5 |
| **E4** | LIVE provider execution | **not claimed** |
| **B** | Browser / visual acceptance | **not run** — see §7 |

## 1. Real PostgreSQL records, not mocks

Every database assertion runs against the production code path
(`M2Service` → `SqlModelM2Repository` → PostgreSQL) under the real
`p1_m2_runtime` principal with `project1.actor_id` bound per transaction. No
fake repository is used as proof of live integration. The two unit-level tests
(`_qg_review_event` identity) are explicitly about a pure function and are
labelled as such.

## 2. Backend DB tests

```
SITEWISE_TEST_ISOLATION=off \
DATABASE_URL=postgresql+psycopg2://p1_m2_runtime:m2_runtime_dev_only@127.0.0.1:5544/project1_pg18_migrated_tests \
ACTIVITY_HISTORY_DB_URL=<same> \
ACTIVITY_HISTORY_OWNER_ID=32ef694a-69b0-4863-a77f-b9cf6c056b56 \
./.venv/Scripts/python.exe -m pytest tests/m2_bcb/test_activity_governance_history.py -q
```

**Result: 9 passed.**

| Test | Asserts |
|---|---|
| `test_actor_binding_is_in_force` | the transaction is bound to the owner (guards the skip-shaped false pass) |
| `test_the_governance_streams_actually_return_rows` | a silently-failing statement is not mistaken for an empty module |
| `test_source_states_are_reported_for_every_module` | nine sources reported; CQ/EE01/REPORTS/CLOUD_BDJ stay `BLOCKED_AUTHORIZATION` |
| `test_a_candidate_is_never_projected_as_an_approved_item` | no candidate carries `APPROVED`/`ADOPTED` |
| `test_prose_and_model_output_are_not_projected` | no `candidate_json`/`problem`/`research_objective`/`rationale`/hash/`reason` |
| `test_governance_events_are_owner_scoped` | a random actor sees zero governance events |
| `test_no_governance_event_exceeds_the_assessment_revision` | revision bound respected |
| `test_a_second_reviewer_keeps_a_distinct_identity` | two reviewers on one candidate do not collapse |
| `test_the_review_identity_is_a_namespaced_uuid5` | deterministic, documented derivation |

## 3. Pre-existing module: one known failure, not a regression

```
pytest tests/m2_bcb/test_activity_projection.py -q
→ 1 failed, 5 passed
```

`test_evaluation_version_is_not_reported_as_a_reason` fails because it selects
the owner's assessment with the most persisted answers (`c30051ba…`, revision
43) and asserts at least one `BDJ_EVALUATED` event. `BDJ_EVALUATED` is derived
from `m2_bdj_evaluations`, which holds **0 rows** on this target
(`m2_bdj_findings` and `m2_clarification_events` are also 0). The test's premise
does not hold here.

Evidence that this is not caused by this change:

* `git diff -U0` shows changed hunks at lines 6, 30–124, 265, 342 and 378 of
  `m2_repository.py`; `read_activity` (lines 127–253) — the only producer of
  `BDJ_EVALUATED` — is **untouched**.
* `SELECT count(*) FROM public.m2_bdj_evaluations` → `0`.

The digest test in the same module still passes after the digest projection
change, so that change is not a regression either.

## 4. Frontend tests

```
cd fyp_jaspr_web
dart analyze lib/features/assessment/data/activity_event_presentation.dart \
             lib/features/assessment/presentation/components/m2_activity_panel.dart
→ No issues found!

dart test test/activity_event_presentation_test.dart
→ 16 passed
```

The 7 new cases pin: a proposal is not an established objective; an admission
names its objective; a candidate is never an approved item; a review with no
stored decision says so; a review reports its decision and expected option; an
earlier-revision record is marked historical; a current record carries no
historical suffix.

## 5. Failure isolation (E3, incidental)

The per-stream savepoint was exercised by accident and worked: an early draft
selected `objective_id`/`policy_version`/`policy_disposition` from
`m2_bdj_objective_proposals`, which does not have those columns. PostgreSQL
raised `UndefinedColumn`; the savepoint rolled back; the stream was marked
`BLOCKED_SOURCE`; the M2 stream still returned. That is the designed behaviour.

It is recorded as a *caution* rather than a success: the same mechanism makes a
column typo indistinguishable from a missing table, which is why
`test_the_governance_streams_actually_return_rows` exists.

## 6. Live HTTP verification

The server on 8093 was serving **pre-change code** (verified: the response had
no `source_states` and only 2 events). It was stopped and restarted on the
current code, then validated:

```
./.venv/Scripts/python.exe var/e2e/pg18/activity_history_20261125/validate_http_activity.py
→ ALL CHECKS PASSED
```

The validator re-implements the **exact** Dart client rules from
`api_m2_repository.dart:1010-1081`: UUID-shaped `event_id`/`actor_id`/`source_id`,
unique `kind:event_id`, `occurred_at` carrying a `Z`/offset suffix,
`assessment_revision` within `0..envelope`, 64-hex `snapshot_digest` when
present, `history_extension` in the accepted set, `bcb_statuses` shape and
`authorization_decisions_included == false`.

Payloads captured for three assessments:

| Assessment | Events | Kinds |
|---|---|---|
| `f063b4c6…` | 12 | 5 `QG_CANDIDATE_RECORDED`, 3 `QG_REVIEW_RECORDED`, 1 each `OBJECTIVE_PROPOSED`/`OBJECTIVE_ADMITTED`, `CONTEXT_CONFIRMED`, `ASSESSMENT_CREATED` |
| `df15adf3…` | 37 | 23 `ANSWER_SAVED`, 5 `CONTEXT_PERSISTED`, 3 `REVIEW_RECORDED`, 3 `CONTEXT_CONFIRMED`, 2 `OBJECTIVE_PROPOSED`, 1 `ASSESSMENT_CREATED` |
| `ef5c028e…` | 9 | 2 `QG_CANDIDATE_RECORDED`, 2 `QG_REVIEW_RECORDED`, 1 each `OBJECTIVE_PROPOSED`/`OBJECTIVE_DECIDED`/`OBJECTIVE_ADMITTED`, `CONTEXT_CONFIRMED`, `ASSESSMENT_CREATED` |

Historical-vs-current is proven on `df15adf3…`: its proposals sit at revision 21
while the assessment is at 23, and every one is `source_is_current = false`.
`f063b4c6…` additionally shows a candidate recorded at revision 18 with
`source_is_current = false` alongside revision-19 candidates that are current.

Evidence files:

* `backend/var/e2e/pg18/activity_history_20261125/probe_activity_projection.json`
* `backend/var/e2e/pg18/activity_history_20261125/http_activity_verified.json`
* `backend/var/e2e/pg18/activity_history_20261125/http_activity_stale.json` (the pre-restart payload, kept as proof of the stale server)

## 7. Not done, and why

* **No browser / visual acceptance (B).** The panel was not rendered in a
  browser in this pass. The wire contract is proven at the HTTP layer and the
  presentation mapping is unit-tested; what is *not* proven is the rendered
  layout. Owner visual acceptance remains open.
* **No E4.** No LIVE provider call was made. Nothing here is a claim about
  provider behaviour.
* **No synthetic respondent lifecycle, no fielding activation.** Out of scope by
  directive and still blocked by DD-086.
