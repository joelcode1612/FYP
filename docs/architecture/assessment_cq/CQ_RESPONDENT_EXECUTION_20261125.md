# CQ respondent execution — DD-095 resolution and the first real session

**Date:** 2026-11-25
**Database:** `project1_pg18_migrated_tests` @ `127.0.0.1:5544`
**Principals used:** `p1_ee01_runtime` (respondent evidence, EE-01), `postgres`
(operator, unrestricted counts and read-only probes)
**Fielding state:** `cq_runtime_enabled` unset on 8093 → the customer-facing CQ
route still answers `503 PRODUCTION_FIELDING_HOLD`. Nothing in this record
activates fielding.

---

## 1. DD-095 — the campaign was never bound to a second release

### What was claimed

`publish_cq_entrepreneur_release.py --apply` "published a release successfully
(`release_id 9c6328f8…`, `manifest_hash 226bdbd7…`) and then refused the campaign
step", leaving a published-but-unbound release.

### What the database says

`var/e2e/pg18/dd095_binding_probe.py` (read-only; receipt
`var/e2e/pg18/activity_history_20261125/dd095_binding.json`):

| Fact | Value |
|---|---|
| release rows in `cq_manifest_releases` | **1** |
| rows matching `9c6328f8…` or `226bdbd7…` | **0** |
| campaigns for `df15adf3` | **1** (`de3121ff…`) |
| release bound by that campaign | `577e61b0…` — the only release |
| assignments on `577e61b0` | 13 |

### Why the log was misleading

The publisher writes the release and the campaign inside one transaction
(`scripts/publish_cq_entrepreneur_release.py:297`) and raises `SystemExit` when the
campaign points at a different release (`:338`). `SystemExit` unwinds the
`engine.begin()` block, so the release INSERT was rolled back. The script printed
`=== publication ===` **before** the campaign check, which is why the log reads as
"published, then refused" when neither happened.

`9c6328f8` never existed. There is no unbound release, and no binding conflict.

### What is actually true

The bound release was composed at 04:50:38 from BCB context `48e3d217`. The
DD-093 fix makes every reader resolve the build receipt's `265cd868`. Both are the
same confirmation (`5ab831b8`) and revision (23).

`var/e2e/pg18/dd095_manifest_diff.py` (receipt `…/dd095_manifest_diff.json`)
compares the stored manifest against what the builder produces now:

```
stored manifest_hash  47f36d3aa944d45001ea5c7ec6bca61a97c02fe6c4d7b554a9b21b810ad29cb7
planned manifest_hash 226bdbd7b3feb595a7a1db24104432d9a18134119f7e6f630fe5632e9f4a0064
assignment set equal  True        (13 for 13, by (slot_id, content_hash))
differing paths       2
  assignment.bcb_context_id    48e3d217… -> 265cd868…
  assignment.bcb_packet_hash   14cb2e9c… -> 30d80bdc…
VERDICT: SAME_INSTRUMENT_METADATA_ONLY
```

The assignment set is compared the way `builder.publish` compares it, by
`(slot_id, content_hash)`. The served questionnaire is the same instrument.

The release also still re-verifies against the authoritative records:
`load_authoritative()` + `assert_authoritative_binding()` against the stored
manifest **PASS**, resolving `48e3d217` / `14cb2e9c…` / revision 23 confirmed 23.
The earlier context row still exists, so the release is consistent with the
context it actually used.

### Why a corrected release still cannot be bound

`release_id_for(digest(manifest))` makes release identity content-addressed and
`publish()` idempotent by `manifest_hash`. Republishing an identical manifest
returns the same row (`ALREADY_PUBLISHED`) and the campaign check passes. A
*changed* manifest always produces a new release id, so
`campaign.release_id != release_id` is true by construction.

`cq_campaigns` carries `UNIQUE (assessment_id)`
(`cq_campaigns_assessment_id_key`), an append-only trigger (`cq_append_only`),
and `cp12_barrier`; `cq_lifecycle_events` is session-scoped
(`session_id`, 0 rows). A supersession therefore requires a schema change.

**Disposition:** DD-095 closed as **not blocking**. The pipeline proceeds against
`577e61b0`. Recording the corrected provenance would need a campaign lifecycle
column or dropping `UNIQUE (assessment_id)`; that is not authorised here and buys
a bookkeeping change, not a different questionnaire. Nothing was rebound.

---

## 2. The release is admissible under `ISOLATED_TEST`

`var/e2e/pg18/cq_release_admission_probe.py` walks the runtime's own admission
chain as the real respondent login:

```
principal  p1_ee01_runtime @ project1_pg18_migrated_tests:5544 superuser=False bypassrls=False
manifest_hash  47f36d3aa944d45001ea5c7ec6bca61a97c02fe6c4d7b554a9b21b810ad29cb7
execution_scope ISOLATED_TEST   production_authorized False
questions 13   authorized 7 ['Q01','Q02','Q03','Q04','Q05','Q07','Q08']
stimulus_order ['concept','offer']
campaign visible (owner) True    assessment owned True
campaign visible (unbound actor) False   assessment owned False
VERDICT: RELEASE_ADMISSIBLE_UNDER_ISOLATED_TEST
```

The release passes manifest/policy/bank/assignment integrity, authority and
consent-notice approval. RLS scopes the campaign to its owner and hides it from an
unbound actor.

---

## 3. DD-086 proven by execution, not by grants

`var/e2e/pg18/cq_respondent_execution_verify.py` drives one complete session
through `CustomerQuestionnaireService` — the same class the HTTP route builds —
as `p1_ee01_runtime`. Receipt:
`var/e2e/pg18/activity_history_20261125/cq_respondent_execution.json`.

**The only simulated component is the authority grant.** `HarnessAuthority`
returns `CqGrant('ISOLATED_TEST', 'HARNESS-ISOLATED-TEST-NOT-A-PRODUCTION-GRANT',
False, …)` for exactly this campaign's release. The production authority refuses
every request by design, and the developer-synthetic authority needs a bound
synthetic case that cannot yet be prepared for this assessment (§5). The grant is
a declared double with an explicit receipt; it is not persisted, `PRODUCTION`
scope is never returned, and `production_fielding_authorized` stays `False`.

### Session

| Field | Value |
|---|---|
| session | `45c6d31f-b2fc-4ebf-9737-34f406256275` |
| campaign | `de3121ff-8e96-46dc-9330-1cc438b143a5` |
| release | `577e61b0-84cf-529b-b581-2f21283f3629` |
| respondent | `32ef694a-69b0-4863-a77f-b9cf6c056b56` (the owner, acting as the synthetic respondent) |
| locale / revision / state | `EN` / `10` / `SUBMITTED` |
| consented / consent version | `True` / `consent/1` |

No `public.users` row was created and none was modified.

### Walk

| Revision | Operation | Detail |
|---|---|---|
| 1 | consent | `consented=True`, `consent/1`, request hash `009758b4…` |
| 2 | answer Q01 | `["LIVE"]` → `ANSWERED_SUBSTANTIVE` |
| 3 | expose | `concept`, stimulus hash `952c725ee0dc…` |
| 4 | expose | `offer`, stimulus hash `c53ee630746a…` |
| 5 | answer Q03 | `HOME` |
| 6 | answer Q04 | `FOUR_SEVEN` |
| 7 | answer Q05 | `PROB_YES` |
| 8 | answer Q07 | `SOMEWHAT_ACCEPTABLE` |
| 9 | answer Q08 | `["WORK_BREAK"]` |
| 10 | submit | receipt issued, state `SUBMITTED` |

### Submission receipt

| Field | Value |
|---|---|
| receipt id | `07b14b53-f53e-4687-834e-9e2baef7c2ba` |
| receipt hash | `78c0c4ee16e419113aa7477bcf5e763943156805cc5d9c4bc075b3e549019667` |
| decision hash | `5ac87e8b6937d94321dddc71e39a6556ecd6717903462f7c78b4d2bb2ba113a7` |
| disposition | `ELIGIBLE` |
| execution scope | `ISOLATED_TEST` |
| production fielding authorized | `False` |

Read-back through `service.read()` returns the same `receipt_hash`, and
`service.history()` returns the 6 accepted answer revisions.

### Rows actually written

| Table | Rows |
|---|---|
| `cq_participants` | 1 |
| `cq_sessions` | 1 |
| `cq_session_controls` | 1 |
| `cq_consent_events` | 1 |
| `cq_stimulus_deliveries` | 2 |
| `cq_routing_decisions` | 9 |
| `cq_presentations` | 6 |
| `cq_render_events` | 6 |
| `cq_answer_revisions` | 6 |
| `cq_effective_answers` | 13 |
| `cq_submission_receipts` | 1 |

Owner-scoped counts equal the unrestricted totals, and an unbound actor sees **0**
in every table — RLS is doing the scoping, not the query.

**DD-086 is now verified by execution.** The grants were necessary and are
sufficient for a full session write.

---

## 4. Authorised ≠ shown: Q02 is withheld

The manifest authorises 7 questions, but only **6** are ever shown:

| Slot | Verdict | Reason |
|---|---|---|
| Q01 | SHOWN | — |
| **Q02** | **NOT_SHOWN** | `CLAUSE_FAILED:{'op':'is_true','lhs':'Q02_VISIBLE'}` |
| Q03, Q04, Q05, Q07, Q08 | SHOWN | — |
| Q06, Q09, Q10, Q11, Q12, Q13 | NOT_SHOWN | `QUESTION_AUTHORITY_UNVERIFIED` |

`manifest.q02_policy` is `UNDECIDED`, and the policy states "UNDECIDED withholds".
That is a deliberate governance hold, not a bug — but the publication plan reports
`authorized_count: 7 / 13` and the manifest lists Q02 in
`authorized_question_ids`, so a reader of the release concludes 7 questions are
fielded. **The effective respondent-facing instrument is 6 questions.** Recorded
as DD-104.

---

## 5. EE-01 cannot write its own snapshot — DD-103

`var/e2e/pg18/ee01_measurement_verify.py` runs `Ee01Service.build_diagnostic()` as
`p1_ee01_runtime` over the persisted session above. It stops at the first INSERT:

```
sqlalchemy.exc.ProgrammingError: (psycopg2.errors.InsufficientPrivilege)
  permission denied for table ee01_measurement_snapshots
```

`p1_ee01_runtime` holds **`SELECT` only** on all four EE-01 tables:

| Table | Granted |
|---|---|
| `ee01_measurement_snapshots` | `SELECT` |
| `ee01_source_units` | `SELECT` |
| `ee01_category_cells` | `SELECT` |
| `ee01_report_readbacks` | `SELECT` |

`cq/20261116_02_ee01_snapshots.sql:107` grants `SELECT,INSERT` on exactly those
four tables and creates the `ee01_actor` policies. The policies, RLS
(`ENABLE` + `FORCE`) and the append-only triggers are all present — so the DDL ran
— but the ledger does not contain the migration:

```
cq_schema_migrations: 20261116_04, 20261124_01, 20261124_02, 20261124_03
```

No migration in the repository revokes `INSERT` on these tables. So the grant was
never issued, and EE-01 cannot be executed by the principal it is designed to run
as. This is the same defect class as DD-086, one layer up.

**Not fixed here.** Re-issuing `GRANT INSERT` is a privilege change and needs
separate authorisation. Recorded as DD-103 with the exact remediation.

---

## 6. What is still not executable, and why

| Item | State | Blocker |
|---|---|---|
| Controlled synthetic retrieval over HTTP | not connected | `get_inspector()` pins `u.database == 'Dss'` (`api/v1/synthetic_inspection.py:18`), so `/api/v1/cq/developer-imports…` answers `503 SYNTHETIC_TARGET_UNVERIFIED` on PG18. DD-105. |
| Synthetic case preparation for `df15adf3` | not possible | `prepare_cases()` hard-codes assessment `6a59045c…` and requires `authorized_question_ids == Q01…Q13` (`services/synthetic_case_setup.py:14,18`). DD-105. |
| EE-01 measurement | refused `42501` | missing `INSERT` grant. DD-103. |
| 100+ respondent verification | not started | needs §5 resolved and a repeatable synthetic respondent identity. |

None of these is worked around by weakening a guard. Each is recorded with the
statement or line that causes it.

---

## 7. Files added

| File | Purpose |
|---|---|
| `var/e2e/pg18/dd095_binding_probe.py` | read-only: releases, campaigns, constraints, triggers |
| `var/e2e/pg18/dd095_manifest_diff.py` | read-only: stored vs planned manifest, assignment-set equality |
| `var/e2e/pg18/cq_release_admission_probe.py` | read-only: the runtime admission chain as `p1_ee01_runtime` |
| `var/e2e/pg18/cq_respondent_execution_verify.py` | writes one full session; idempotent; reports per-table deltas |
| `var/e2e/pg18/ee01_measurement_verify.py` | runs EE-01 and reports what it returns, including a refusal |

Receipts are under `var/e2e/pg18/activity_history_20261125/`.

No migration was applied, no privilege or RLS policy was changed, `Dss` and
`Final_Location_Analysis` were not touched, fielding remains disabled, and **E4 is
not claimed** — the authority grant in §3 is a harness double, and the owner has
not run this themselves.
