# Activity History — CQ publication integration and fixture digest correction

**Date**: 2026-11-25
**Scope**: the three owner decisions on the Activity History pass
**Database**: `project1_pg18_migrated_tests` @ `127.0.0.1:5544` (read-only except where stated)
**Evidence classes**: E1 source inspection · E2 component/unit test · B browser · DB direct read

---

## 1. Decisions applied

| Proposal | Decision | Outcome |
|---|---|---|
| A — BCB append-only attempt ledger | **DEFER** | No table, migration or write path created. The latest-state snapshot is retained and the panel states that individual attempts are unavailable. |
| B — CQ assessment-level metadata | **APPROVE (bounded)** | Implemented with **no GRANT, no policy, no RLS change**. |
| C — Fixture digest + rebuild + browser verification | **PROCEED** | Generators corrected, bundle rebuilt and deployed, page verified over CDP. |

---

## 2. Proposal B — owner-scoped read-only CQ interface

### 2.1 The problem the obvious fix would have created

`p1_m2_runtime` holds `SELECT` on `cq_campaigns` and `cq_manifest_releases`, but
**no policy grants it a row**. Every CQ `SELECT` policy is declared
`TO p1_ee01_runtime`:

```
cq_campaigns            ee01_owner_read   USING (owner_user_id::text = current_setting('project1.actor_id', true))
cq_manifest_releases    ee01_owner_read   USING (id IN (SELECT release_id FROM cq_campaigns))
cq_question_assignments ee01_owner_read   USING (release_id IN (SELECT release_id FROM cq_campaigns))
```

So an M2-side read returns zero rows *silently*. Widening the grant or adding a
policy for `p1_m2_runtime` would have duplicated the ownership predicate in a
second place — a second thing to keep correct.

### 2.2 What was built instead

`backend/src/sitewise/services/cq_publication_metadata.py` reads CQ metadata as
**the principal that already owns it**:

1. `get_cq_engine()` — the existing cached engine, which refuses a DSN whose
   declared database is not the expected one (`CQ_DATABASE_TARGET_UNVERIFIED`).
2. `SET TRANSACTION ISOLATION LEVEL REPEATABLE READ` then `SET TRANSACTION READ ONLY`
   as the first statements, so this path cannot write evidence even by mistake.
3. The effective principal is verified to be exactly
   `('p1_ee01_runtime', rolsuper=false, rolbypassrls=false)`; anything else is
   refused rather than trusted.
4. `set_config('project1.actor_id', <actor>, true)` — transaction-local.
5. Two statements only (`CAMPAIGN_SQL`, `ASSIGNMENT_SQL`), both named constants so
   the privacy boundary is testable.

The scoping is therefore performed by the **database**, not by Python. No
`GRANT`, no `CREATE POLICY`, no `ALTER POLICY`, no `ALTER TABLE` was issued.

### 2.3 What is exposed

Assessment-level facts only:

`state`, `campaign_id`, `release_id`, `campaign_created_at`, `release_created_at`,
`manifest_hash`, `policy_hash`, `source_class`, `bank_version`, `bank_version_rows`,
`lane`, `mode`, `title`, `question_count`, `authorized_question_count`,
`assignment_count`, `distinct_slot_count`, `release_complete`,
`published_at_revision`, `current_revision`, `is_current_for_revision`,
`fielding_enabled`.

**Not read**: `cq_participants`, `cq_sessions`, `cq_answer_revisions`,
`cq_effective_answers`, `cq_submission_receipts`, `cq_presentations`,
`cq_render_events`, `cq_routing_decisions`, `cq_consent_events`. There is no
respondent identity, answer, session or even a respondent *count* on this path.

### 2.4 Currentness is derived, not asserted

`manifest.assignment.assessment_revision` records the revision the release was
built against. `is_current_for_revision` is the comparison
`published_at_revision == m2_assessments.revision`, evaluated at read time. For
`df15adf3` both are 23. A later assessment revision makes the release
**historical**, and the UI says so instead of presenting an older release as
current.

### 2.5 Failure is a state, never an inference

| Condition | Reported |
|---|---|
| Interface could not run | `state='UNAVAILABLE'` + reason code → `source_states['CQ'] = BLOCKED_SOURCE` |
| No campaign owned by the actor | `NOT_PUBLISHED` (never `UNAVAILABLE`) |
| Stored manifest/policy hash ≠ stored body | `INTEGRITY_FAILED`, **no timeline event emitted** |
| Principal is superuser / BYPASSRLS | `CQ_RESTRICTED_ROLE_REQUIRED` |

A publication is never inferred from the absence of an error.

### 2.6 The timeline event

`QUESTIONNAIRE_PUBLISHED`, one per campaign. Identity is the campaign id, which
is durable because `cq_campaigns.assessment_id` is `NOT NULL UNIQUE`. The event
carries `status='PUBLISHED'`, `source_version=<bank_version>`,
`assessment_revision=<revision the release was built for>` and
`source_is_current` from the derived comparison. `PERSISTED` is never relabelled
`COMPLETED`, and publication is never presented as fielding authority.

---

## 3. Proposal C — fixture digest

### 3.1 Two defects, not one

`verify_snapshot_digests.py` (new, read-only) recomputes every stored digest
using the application's own canonicalisation and classifies it:

```
DERIVED      rev=23  df15adf3-...          (×13 rows)
NOT_DERIVED  rev=19  ef5c028e-...  stored=e7e492209a392bcf… expected=e0ac34470a4e0f07…
NOT_A_SHA256 rev=19  f063b4c6-...  stored=synthetic-snapsh… expected=8ea2a29f420a936a…
totals: {'DERIVED': 13, 'NOT_DERIVED': 1, 'NOT_A_SHA256': 1}
VERDICT: DIGEST_INTEGRITY_GAPS
```

* `f063b4c6` stored the literal `synthetic-snapshot-digest-stage5` — obvious, and
  rejected by the client, which rejected the **whole** response.
* `ef5c028e` stored `sha256("qg-simulated-pipeline|snapshot")` — a **real**
  64-hex hash of a *label*. It passes every format check and describes nothing.
  This one was not previously known and is the more dangerous of the two.

The canonicalisation is proven, not assumed: it reproduces **13 of 15** stored
digests exactly, so the corrected value is derived from the row's own content.

### 3.2 Correction, and why the rows were not rewritten

`fixture_snapshot_digest.py` (new) holds the single canonical definition plus
`assert_derived()`. Both generators now compute the digest from the same object
they store, and refuse to write a row whose digest they cannot reproduce.

The two legacy rows were **not** edited, because they cannot be, by design:

* `m2_bcb_reject_mutation()` raises `55000` on any `UPDATE` (verified: the
  attempt was refused), and on `DELETE`;
* `uq_m2_confirmation_revision UNIQUE (assessment_id, assessment_revision)`
  allows one snapshot per revision, so a corrected row cannot be added beside the
  old one.

The only legitimate correction is a new revision, which would rewrite the
fixture's history and make every dependent row (proposal, admission,
authorization, candidates at revision 19) appear historical. That is a
misrepresentation of synthetic scaffolding, not a repair. The rows are therefore
**preserved**, disclosed at read time (`snapshot_digest_state`), and the defect is
now *detectable* by a repeatable check instead of silent.

**DD-091 remains open at source** for those two rows; the mechanism that produced
them is closed.

---

## 4. Verification

### 4.1 Browser (E-B), Chrome CDP 9222, 1440×1800

A Chrome-CDP acceptance probe (local script `activity_history_acceptance_20261125.js`,
kept out of the repository at handoff and archived alongside it) — **28 checks, all pass**,
with one honest non-claim (below).

| Requirement | Evidence |
|---|---|
| Assessment selection | switched through the real `<select>`; dropdown populated from the authenticated list |
| Historical activity records | 38 / 9 / 1 records across three assessments |
| Current vs historical revision | *"Source revision matches the current saved revision."* and *"Historical source revision — original outcome retained; not a current handoff."* on a revision-21 record of a revision-23 assessment |
| Available Sources | all nine sources rendered from `source_states` |
| Eligibility / admission metadata | `Objective admitted`, disposition `WORTH_RESEARCHING` |
| Questionnaire publication status | *"Questionnaire published … bank CQ-ENTREP-df15adf3-r23-cq-manifest-1 · 13 questions · 7 authorized … fielding disabled."* |
| Empty / unavailable states | `EE-01`, `Report generation / admission`, `BDJ cloud` all `BLOCKED_AUTHORIZATION`; `NOT_PUBLISHED` for four assessments |
| Cross-assessment isolation | each assessment renders only its own records |
| Cross-owner isolation | `m2_assessments` visible: owner **11**, second actor **0**, unbound **0** |

Artefacts: `deliverables/screenshots/20261125_activity_history/`
(`01_published_assessment`, `02_historical_revision`, `03_admitted_assessment`,
`04_not_published`, `05_single_record_assessment`, `06_empty_filtered`, plus the
captured page text and `results.json`).

**Not claimed**: the zero-match empty state was not driven through the UI. The
date filter is a framework-bound input and a synthetic change did not reach its
handler. The renderer strings (`No matching activities`, `Try clearing some
filters.`) are present in the served bundle, and the "no records at all" branch
is unreachable because every saved assessment carries at least an
`ASSESSMENT_CREATED` record (min = 1 across all 11). Neither statement is a
substitute for driving the widget.

### 4.2 Tests (E2)

```
tests/m2_bcb/test_fixture_snapshot_digest.py        8 passed
tests/m2_bcb/test_cq_publication_metadata.py        6 passed
tests/m2_bcb/test_activity_governance_history.py    9 passed
tests/m2_bcb/test_activity_projection.py            5 passed, 1 pre-existing failure
fyp_jaspr_web/test/activity_event_presentation_test.dart  19 passed
```

The single failure, `test_evaluation_version_is_not_reported_as_a_reason`, needs
a `BDJ_EVALUATED` row and `m2_bdj_evaluations` has 0 rows on this target.
`read_activity` is untouched by this pass.

### 4.3 Deployment

`jaspr build` → 172 files. Served copy
`backend/var/e2e/frontend/main.client.dart.js` is byte-identical to the build
(`d163360b96369b60b527590bffbeb90cc42a867532e16d3e42bdd07239c5faaa`), and contains
the new literals (`QUESTIONNAIRE_PUBLISHED`, `Questionnaire publication: not
published`, `not an open fielding authorization`).

Note: the API process serving 8093 was already running and holds the module as it
was **before** the `CAMPAIGN_SQL`/`ASSIGNMENT_SQL` constant extraction. That
refactor moved the same SQL strings to module constants and changed no behaviour;
the new code was exercised directly by the probe and the pytest run.

---

## 5. Remaining blockers

1. **DD-090 — BCB attempt history** is unavailable (latest-state only). Deferred by
   decision; proposal unchanged.
2. **DD-091 — two legacy fixture digests** cannot be corrected without a new
   revision. Detectable, disclosed, not repaired.
3. **`cq_campaigns` has no status column** — the campaign's lifecycle state cannot
   be reported, only its existence and `created_at`. Recorded as DD-092.
4. **Fielding remains disabled** (`cq_runtime_enabled` unset/False). Publication is
   not fielding authorization.
5. **EE-01 / reports / cloud BDJ** remain `BLOCKED_AUTHORIZATION`. Unchanged.

---

## 6. Next separately approvable proposal

**CQ campaign lifecycle state.** `cq_campaigns` stores only
`(id, assessment_id, owner_user_id, release_id, created_at)`, so Activity History
can say *published* but not whether the campaign is open, paused, closed or
exhausted. A `status` column plus an append-only transition table would let the
timeline show real campaign decisions instead of a single creation fact. This
needs a migration and a write path, so it is **not** proposed for unilateral
implementation.

Cheaper alternative requiring no schema change: expose the existing
`cq_lifecycle_events` rows (already `SELECT`-granted to `p1_ee01_runtime`) through
the same owner-scoped interface. That would give a genuine lifecycle timeline
without any new storage — recommended as the next step.
