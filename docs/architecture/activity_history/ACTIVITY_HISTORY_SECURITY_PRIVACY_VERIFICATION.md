# Activity History — Security and Privacy Verification (Stage E)

**Date:** 2026-11-25
**Target:** `project1_pg18_migrated_tests` @ `127.0.0.1:5544`
**Change under review:** the five governance streams added in Stage B.
**No RLS policy and no grant was changed by this work.**

## 1. Identity and ownership are enforced in SQL, not only by RLS

Every added statement carries an explicit owner predicate:

| Stream | Predicate |
|---|---|
| proposals | `assessment_id = :aid AND owner_user_id = :actor AND confirmation_revision <= :rev` |
| decisions | `p.assessment_id = :aid AND p.owner_user_id = :actor` (join to proposals) |
| admissions | `assessment_id = :aid AND actor_user_id = :actor` |
| candidates | `assessment_id = :aid AND owner_user_id = :actor AND assessment_revision <= :rev` |
| reviews | `c.assessment_id = :aid AND c.owner_user_id = :actor` (join to candidates) |

Belt and braces: the predicate would still hold if RLS were accidentally
disabled, and RLS still holds if a predicate were ever dropped.

## 2. RLS is in force on all five tables

| Table | `relrowsecurity` | Policy | Roles | Predicate |
|---|---|---|---|---|
| `m2_bdj_objective_proposals` | true | `owner_scope` (ALL) | `{public}` | `owner_user_id = project1_actor() AND EXISTS (assessment owned by project1_actor())` |
| `m2_bdj_objective_decisions` | true | `owner_scope` (ALL) | `{public}` | `decided_by = project1_actor()` |
| `m2_bdj_objective_admissions` | true | `owner_scope` (ALL) | `{public}` | `actor_user_id = current_setting('project1.actor_id')` |
| `m2_qg_candidates` | true | `owner_scope` (ALL) | `{public}` | `owner_user_id = current_setting('project1.actor_id')` |
| `m2_qg_candidate_reviews` | true | `owner_scope` (ALL) | `{public}` | `owner_user_id = current_setting('project1.actor_id')` |

Note on the `decisions` policy: it is keyed on `decided_by`. A decision recorded
by a different actor is invisible to the owner. That is the existing policy and
it is consistent with actor scoping — it is stated here so the behaviour is not
later mistaken for a missing row.

## 3. Cross-owner isolation, proven

`test_governance_events_are_owner_scoped` calls
`read_activity_supplement(assessment, <random uuid4>, revision, limit)` and
asserts **zero** governance events. It passes.

The live probe additionally binds `project1.actor_id` to the real owner and
confirms `current_setting('project1.actor_id')` equals that owner inside the
transaction — the guard against the skip-shaped false pass where RLS hides
everything and every assertion loops over an empty list.

## 4. A source reference grants no extra access

`source_id` is a **pointer, not a capability**. It is emitted only for rows the
owner predicate already returned, and it is never accepted as an input to any
read. There is no route that takes a `proposal_id`/`candidate_id` and returns
the referenced row; the endpoint takes an assessment id and returns that
assessment's timeline. Confirmed by inspection: the only parameters are
`assessment_id` (path), `actor_id` (from the token) and `limit`.

## 5. No respondent PII

The endpoint issues **no** query against any `cq_*` table. `cq_participants` and
`cq_sessions` are not referenced in the repository's activity paths. CQ appears
only as a static `BLOCKED_AUTHORIZATION` state string. No respondent identity,
answer, session or per-respondent history can be produced by this endpoint.

## 6. No raw AI payload

Projected columns were chosen to exclude model output and entrepreneur wording.
A test (`test_prose_and_model_output_are_not_projected`) asserts that none of
`candidate_json`, `problem`, `research_objective`, `rationale`,
`prompt_sha256`, `output_sha256`, `reason` appears on any governance event. It
passes. `project1_ai` is never queried.

## 7. No leak through ordering, filtering, counts or errors

* **Ordering** is on columns the owner already sees. A row cannot be ordered
  into the result without satisfying the predicate.
* **Filtering**: the only filter is the assessment id, which is already
  authorized by the assessment lookup that precedes it
  (`get_assessment_for_update` returns `None` for a non-owner, which raises
  `NotFoundError` — the same response as a missing record).
* **Counts**: no count is returned. `truncated` is a boolean over the merged
  owner-scoped set; it reveals only whether the owner has more events than the
  limit, which they can observe anyway by paging.
* **Errors**: a refused stream is reported as `BLOCKED_SOURCE` with a generic
  detail. The driver's message (which can name a relation) is not propagated.
* **Identifiers**: `event_id` values are either stored primary keys or a
  namespace UUIDv5 derived from them. Neither is guessable-before-disclosure,
  and neither grants access.

## 8. Privileges: unchanged by this work

`p1_m2_runtime` on the five tables:

| Table | Privileges |
|---|---|
| `m2_bdj_objective_proposals` | `INSERT, SELECT, UPDATE` |
| `m2_bdj_objective_decisions` | `INSERT, SELECT` |
| `m2_bdj_objective_admissions` | `INSERT, SELECT` |
| `m2_qg_candidates` | `INSERT, SELECT` |
| `m2_qg_candidate_reviews` | `INSERT, SELECT, UPDATE` |

These are the M2 engine's own pre-existing write privileges, not grants made
here. The policies are `FOR ALL`, so a row visible to the owner is also
writable by `p1_m2_runtime` — again pre-existing. **The Activity History
projection performs no write**: it runs under a session that is rolled back, and
its statements are `SELECT` only.

## 9. What was explicitly not done

* No `GRANT`, `REVOKE`, `CREATE POLICY`, `ALTER POLICY` or RLS flag change.
* No query against `Dss` or `Final_Location_Analysis`.
* No write to any protected database.
* No change to `cq_*` privileges, and therefore no movement on DD-086.
* No activation of fielding, no synthetic lifecycle execution.

## 10. Residual risks

| Risk | Severity | Note |
|---|---|---|
| Policies are `FOR ALL`, not `FOR SELECT` | Low | Pre-existing. A read-only principal with `SELECT` cannot exploit it; `p1_m2_runtime` legitimately writes. |
| `decisions` policy keyed on `decided_by` | Low | A decision by another actor is hidden from the owner. Documented, not changed. |
| `source_states` strings are server-supplied and rendered verbatim | Low | They are constants in the repository, not user input; React-equivalent escaping applies to the surrounding text. |
