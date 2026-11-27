# PROJECT1 — CP-01 / CP-02 Execution Report

**Repository:** `C:\Users\HP\OneDrive\Desktop\sport-marketplace\FYP` (`merge_main_jed` @ `ba30035`)
**Date:** 2026-11-16
**Scope:** Phase 1 (secure backend/DB recovery) and Phase 2 (restore live M2). Phase 3–5 status is
recorded at the end with precise blockers.

---

## 1. Phase 1 — backup receipt

| Item | Value |
|---|---|
| Dump | `backend/backups/cp01_20261116/Dss_20261116.dump` (custom format, `-Fc -Z6`) |
| Bytes / SHA-256 | 605,316 · `c50b84fd2ba3c9d451bc647624b51757595b311379612975448f768d9e80b361` |
| Archive entries | 603 (`pg_restore --list` exit 0) |
| Role dump | `Dss_roles_20261116.sql` (`pg_dumpall --roles-only`, 1,760 bytes) |
| **Restorability proof** | restored into scratch DB `p1_backup_verify` → **exit 0, 68 tables**, then dropped |
| Receipt | `backend/backups/cp01_20261116/BACKUP_RECEIPT_20261116.json` |

The migration was gated on this receipt: the apply script refuses to run without
`archive_list_ok` and `restore_exit == 0`.

---

## 2. Phase 1 — runtime identity and RLS

### 2.1 What was found

* `Dss` M2/CQ tables had **ROW LEVEL SECURITY enabled with zero policies** (19 M2, 25 CQ). A
  non-owner role therefore read nothing at all — table grants alone were not enough.
* Only `postgres` (superuser, `BYPASSRLS`) could use them, which is exactly what the brief forbids.
* `M2_DATABASE_URL` / `EE01_DATABASE_URL` were empty, so `m2_session.get_m2_engine()` fell back to
  `DATABASE_URL` = `Final_Location_Analysis` and every M2/CQ call returned
  `503 M2_DATABASE_TARGET_UNVERIFIED`.

### 2.2 What was applied

`backend/migrations/project1_ai/20261116_02_m2_runtime_role.sql` (review candidate, operator-run,
refuses a wrong target or missing receipt):

* `CREATE ROLE p1_m2_runtime LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS`
* `SELECT` on `m2_instrument_versions`, `m2_item_versions` (reference data)
* `SELECT, INSERT, UPDATE` on the 8 M2 core tables + 2 BCB tables. **No DELETE.**
* **12 owner-scoped policies**: direct `owner_user_id` scope on `m2_assessments`,
  `m2_business_contexts`, `m2_business_context_builds`; `assessment_id IN (SELECT id FROM
  m2_assessments)` on the six child tables; `confirmation_id IN (…)` on
  `m2_confirmed_uncertainties`; `reference_read` on the two reference tables.
* **Deliberately withheld:** `m2_research_*`, `m2_review_question_versions`, `m2_desired_options`,
  `m2_candidate_*`. Their owner scope cannot be expressed from the current columns and they have
  no execution endpoint, so access stays closed rather than approximated.
* Receipt: `backend/backups/cp01_20261116/MIGRATION_RECEIPT_20261116_02.json`

### 2.3 RLS proof under the actual runtime role

Connected as `p1_m2_runtime` to `Dss` (not as `postgres`):

| Probe | Result |
|---|---|
| `current_user` / super / bypassrls | `p1_m2_runtime` / **false** / **false** |
| `SELECT m2_assessments` with **no actor bound** | **0** |
| actor A (`1111…`) | **2** assessments, **12** answers |
| actor B (`2222…`) | **0** assessments, **0** answers, **0** confirmations |
| actor B INSERT into `m2_answer_revisions` | **no row written** |
| actor A INSERT (probe, rolled back) | reached the table (rejected only by a CHECK constraint, i.e. the policy allowed it) |

The application binds the actor per request: `m2_session.m2_session_for()` issues
`set_config('project1.actor_id', <uuid>, false)` on a **NullPool** connection and clears it in
`finally`, so a connection can never be reused across owners. `dependencies.get_m2_scoped_db()`
takes the id from the verified profile, never from the request body.

### 2.4 Startup schema creation

`main.py` no longer calls `create_db_and_tables()` unconditionally. New setting
`db_auto_create: bool = False`; startup logs `Startup schema creation disabled` unless explicitly
enabled. No `CREATE TABLE` / `CREATE SCHEMA` can occur at boot.

### 2.5 Attempt ledger

`migrations/project1_ai/20261111_01_candidate_ledger.sql` applied after the backup and role checks:

```
schema=project1_ai
tables=attempt_receipts, attempts, runs, schema_versions
roles=p1ai_audit, p1ai_owner, p1ai_runtime
force_rls=attempt_receipts=true, attempts=true, runs=true
schema_versions=20261111_01_candidate / CP-01 2026-11-16: candidate ledger applied after verified backup c50b84fd…
```

### 2.6 Identity divergence (new finding, not fixed)

M2 enforces `fk_m2_owner_user → public.users` **in `Dss`**, while the application's authoritative
profile lives in `Final_Location_Analysis`:

| | rows |
|---|---|
| `Dss.users` | 19 |
| `Final_Location_Analysis.users` | 3 |
| overlap | **1** (`32ef694a…`, the only active entrepreneur present in both) |
| only in `Dss` / only in `Final` | 18 / 2 |

So an entrepreneur who can sign in may still be unable to create an M2 assessment unless their row
exists in **both** databases. This is the previously reported missing account mapping, now measured.
It was **not** bypassed; the synthetic test used its own isolated row.

---

## 3. Phase 2 — live M2 chain against real `Dss`

Run through the **real FastAPI router** (TestClient) with only the Supabase token check replaced by
an in-process override that lives in the test script — the application itself is unmodified. Every
call executed as `p1_m2_runtime` under the policies above.

Synthetic identity: `11111111-1111-4111-8111-111111111111`,
`cp02.synthetic@example.test`, `full_name = "CP-02 SYNTHETIC TEST ONLY (not a real person)"`.
Assessment: **`da90aa4a-f9cf-4145-9acf-7de36c9d6fad`**, instrument `M2V1 / M2V1-20261114-1`
(`AUTHORIZED`).

| Step | Endpoint | Result |
|---|---|---|
| 1 | `GET /api/v1/m2/instruments` | **200** — 1 authorized instrument |
| 2 | `POST /api/v1/m2/assessments` | **201** — created, revision 0 |
| 3 | `PUT /m2/assessments/{id}/answers/{item_key}` × 12 | **200** each, revision 0 → 12 |
| 4 | `GET /m2/assessments/{id}` (reload) | **200** — 12 answers persisted |
| 5 | `POST /m2/assessments/{id}/bdj/evaluate` | **200** — ruleset `BDJ-RULESET-0.2-CAND` |
| 6 | `GET /m2/assessments/{id}/business-understanding` | **200** — 0 findings |
| 7 | `POST /m2/assessments/{id}/review` | **200** |
| 8 | `POST /m2/assessments/{id}/confirm` | **200** — confirmation `698ae3eb-24fe-4c6d-bdd3-69e575cc00e6`, digest `8cfc90dd…568eafb9`, `qj_handoff_authorized: false` |
| 9 | `POST /m2/confirmations/{cid}/research-objectives` | **201** — objective `5f5e1442-fa14-483d-9b2c-45b805dac5ee` |
| 10 | `GET /m2/research-objectives/{oid}/qj-context` | **200** — `qj-objective-context/1` |
| 11 | `GET …/business-context-status` | **200** — `HELD` |
| 12 | `POST /m2/assessments/{id}/business-context` | **503 `BCB_BINDING_AUTHORITY_UNVERIFIED`** |
| 13 | `GET …/confirmed-review` | **200** |
| 14 | `GET /m2/assessments/{id}/activity` | **200** — **17 events** |
| 15 | cross-owner `GET /m2/assessments/{id}` as another actor | **404** "Assessment not found." |

Evidence file: `backend/backups/cp01_20261116/CP02_M2_CHAIN_EVIDENCE.json`
(35 recorded steps: 22 × 2xx, 13 × 4xx — all 4xx are the intentional probe failures listed below).

### 3.1 Independent database readback (as owner, not through the API)

```
assessment = da90aa4a-…  rev=12  confirmed=12  owner=11111111-…
answers    = 12
evaluations= 1  ruleset=BDJ-RULESET-0.2-CAND
findings   = 0
reviews    = 1
confirmations = 1  digest=8cfc90ddd091b735e47190e808ec5102374daf55c557ae409544c570568eafb9
objectives = 1
bcb_builds = 1  status=HELD  code=BCB_BINDING_AUTHORITY_UNVERIFIED
```

### 3.2 QJ context (source-bound, as returned)

```json
{"contract_version":"qj-objective-context/1",
 "objective_id":"5f5e1442-fa14-483d-9b2c-45b805dac5ee",
 "objective":"Validate whether students and office workers would buy coffee and baked goods at the intended service format.",
 "source":{"origin":"ENTREPRENEUR","priority":"CONCEPT_INTEREST",
   "assessment_id":"da90aa4a-…","confirmation_id":"698ae3eb-…",
   "snapshot_digest":"8cfc90dd…",
   "answer_revisions":{"M2V1-09":{…},"M2V1-10":{…},"M2V1-11":{…}}}}
```

`qj_execution_authorized: false` on both the objective and the context.

### 3.3 Intentional 4xx probes (not defects)

`PUT M2V1-05/M2V1-10 = NOT_APPLICABLE` → **422** ("This item is applicable to the current saved
selections"), then answered from the server's own `effective_options`. `bdj/evaluate` → **409**
until every effective-required item was answered. These confirm the validator refuses guessed
answers instead of accepting them.

---

## 4. What the M2 run does NOT show

* **0 BDJ findings.** The deterministic ruleset recorded no candidate issue for this profile. That
  is not a viability, completeness or scientific verdict, and no finding was invented to make the
  demo look richer.
* **BCB is blocked by design.** `UnverifiedContextBindings.resolve()` raises; the build row records
  `HELD / BCB_BINDING_AUTHORITY_UNVERIFIED`. A legitimate resolver needs authoritative tenant,
  concept-version, geography-catalogue and source-authority records — the same four bindings the
  builder hashes into the packet (`scope`, `concept`, `geo`, `authority`). None exist in this
  deployment, so implementing a resolver now would mean inventing them.
* **No model was called.** No provider request, no receipt, no cost.

---

## 5. Checkpoint results

| # | Checkpoint | Result |
|---|---|---|
| 1 | Preserve source changes and historical records | **PASS** — no reset/stash; only additive migrations and two new frontend files from CP-00 |
| 2 | Recoverable backup before any write | **PASS** — restored into a scratch DB, exit 0 |
| 3 | Do not use the exposed TokenHarbor credential | **PASS** — no provider call made |
| 4 | Restricted least-privilege runtime identities | **PASS** — `p1_m2_runtime`, non-superuser, no BYPASSRLS, scoped grants |
| 5 | Keep `Final_Location_Analysis` for property/workspace | **PASS** — untouched |
| 6 | Bind M2/CQ sessions to `Dss` via `M2_DATABASE_URL` | **PASS** for M2; CQ inherits the same engine but stays held by its own flag/authority |
| 7 | Configure EE-01's dedicated `Dss` connection | **BLOCKED** — needs the `p1_ee01_runtime` login secret; the role exists with correct grants, but I will not rotate a password another tool may hold. Set `EE01_DATABASE_URL` with that role's secret. |
| 8 | Verify M2/CQ feature gates without bypassing scientific authorization | **PASS** — `M2_UPSTREAM_ENABLED=true` only; CQ fielding still returns `held`; confirmation keeps `qj_handoff_authorized: false` |
| 9 | Apply `project1_ai` ledger migration after checks | **PASS** — 4 tables, 3 roles, FORCE RLS |
| 10 | No automatic schema creation at startup | **PASS** — `db_auto_create=false` default |
| 11 | Verify identity, restrictions and RLS with runtime roles | **PASS** — table in §2.3 |
| 12 | M2 creation / save / reload | **PASS** |
| 13 | BDJ deterministic findings | **PASS (execution)** — 200, ruleset recorded; 0 findings |
| 14 | Review, confirmation, revision binding | **PASS** — digest + `confirmed_revision=12` |
| 15 | Research-objective persistence | **PASS** — 201, 1 row |
| 16 | QJ-context retrieval | **PASS** — source-bound, `qj_execution_authorized:false` |
| 17 | BCB construction | **BLOCKED** — `BCB_BINDING_AUTHORITY_UNVERIFIED` |
| 18 | Live BDJ/QJ model execution (Phase 3) | **BLOCKED** — no QJ/QG route exists; key not rotated; disclosure + bank adapters absent |
| 19 | QG structured questions | **BLOCKED** — no QG route; approved bank not populated |
| 20 | Frontend browser verification (Phase 4) | **BLOCKED** — needs a real Supabase session; the panel is built and compiles but has not been driven against a signed-in browser |
| 21 | Activity History read-only | **PASS (API)** — 17 persisted events returned; UI not browser-verified |

---

## 6. Remaining blockers, precisely

1. **BCB bindings.** Implement a resolver that reads operator-provisioned tenant/concept/GEO/
   authority records, or leave the 503. Do not synthesise them from the M2 answers.
2. **QJ/QG endpoints.** `ResearchWorkflow.execute_objective` exists in `project1/source` but no
   router calls it; there is no QG route and no approved-bank lookup. This is a build, not a config.
3. **Provider credential.** Rotate the exposed TokenHarbor key, then `TOKENHARBOR_ENABLED=true`.
   The ledger now exists, so a dispatch would finally be receipted.
4. **EE-01 login secret** for `p1_ee01_runtime`.
5. **Identity sync.** `Dss.users` (19) and `Final_Location_Analysis.users` (3) overlap by 1. M2
   needs the row in `Dss`; the app reads the profile from `Final`. Until these agree, most real
   accounts cannot create an M2 assessment even though they can sign in.
6. **Browser session.** Phase 4 needs a real signed-in Supabase user to drive the UI; no test
   bypass was added to the application.

---

## 7. Files added or changed

**Added**

* `backend/migrations/project1_ai/20261116_02_m2_runtime_role.sql`
* `backend/backups/cp01_20261116/` — dump, role dump, backup receipt, migration receipt, chain evidence

**Changed (backend, this pass)**

* `src/sitewise/db/m2_session.py` — NullPool + `m2_session_for()` actor binding
* `src/sitewise/dependencies.py` — `get_m2_scoped_db` / `M2Session` used by the three M2 services
* `src/sitewise/core/config.py` — `db_auto_create` (default false)
* `src/sitewise/main.py` — startup schema creation gated

**Changed (frontend, CP-00 pass, unchanged here)**

* `fyp_jaspr_web/lib/data/assessment_api.dart`, `.../assessment_workspace_page.dart`,
  `.../components/m2_workflow_panel.dart` (new), `.../app.dart`, `.../data/navigation.dart`,
  the five pages with repaired `/entrepreneur/assessments?id=` links,
  `shared_logic/lib/src/data/repositories/api_m2_repository.dart`

**Database (Dss only)**

* role `p1_m2_runtime`, 12 policies, grants
* schema `project1_ai` (4 tables, 3 roles, FORCE RLS)
* one synthetic user row, one synthetic M2 assessment chain
