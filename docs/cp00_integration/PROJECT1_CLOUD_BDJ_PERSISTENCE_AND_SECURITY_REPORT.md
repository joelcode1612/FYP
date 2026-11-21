# PROJECT1 — Cloud BDJ Persistence and Security (CP-04A)

**Date:** 2026-11-17 · **Branch:** `merge_main_jed` · **Base commit:** `ba30035ecb24b80fa155cc7049cf3cdf94a67844`
**Directive:** Governed AI Workflow Integration, Activity History V1.1–V2, §3–§6
**Verdict: `IMPLEMENTED` on an isolated clone, `BLOCKED_DBA_AUTHORIZATION` for `Dss`, `BLOCKED` for History V1.1 readback.**

No migration was applied to `Dss`. No superuser was used to obtain a demonstration
that the application could not otherwise obtain.

---

## 1. What was actually missing (measured, not assumed)

The execution ledger records that an attempt happened and what its output hashed
to. It does not record the result.

| Table | Columns | Consequence |
|---|---|---|
| `project1_ai.runs` | `id, owner_user_id, assessment_id, assessment_revision, source_fingerprint, policy_fingerprint, work_identity, created_at` | no result |
| `project1_ai.attempts` | `run_id, owner_user_id, attempt_no, stage, prompt_version, prompt_hash, request_hash, reserved_at` | no result |
| `project1_ai.attempt_receipts` | `run_id, owner_user_id, attempt_no, outcome, output_digest, created_at` | **digest only** |

There is **no column anywhere** in `project1_ai` that can hold a model response,
a structured result, a validation finding or an admission decision. Confirmed by
`information_schema.columns` across all four relations.

The consequence for Activity History is not a rendering bug: there is nothing to
render. `output_digest` is a SHA-256, and — importantly — it is **not** a digest
of the provider's raw bytes. `provider.py:140` computes `digest(output)` where
`output` is the already-validated Pydantic `model_dump()`. The digest therefore
attests the *structured result*, not the response, and the raw response is never
digested, logged or stored by the application.

### 1.1 Correction: the raw output does survive — on disk, unprotected

An earlier draft of this report said no payload is stored anywhere. That is true
of the database and **false of the filesystem**. The three harness scripts dump
the raw structured output into untracked JSON files:

| Path | Key |
|---|---|
| `backend/backups/cp03d_96cefb30…/bdj_output.json` | `output` |
| `backend/backups/cp03d_uncertainty_fd0b4380…/probe.json` | `output` |
| `backend/backups/cp03e_{bb54ef7b,9aefb13d,79ee04e1}…/result.json` | `model_output_raw` |

These are plaintext, untracked, not gitignored, and carry no access control.
They are harness evidence, not a store — but they are the only copy of any model
output in the system, and they must not be mistaken for an audit trail. Recorded
as `CP04A-D09`; the protected store designed in §3 is what replaces them.


---

## 2. The nine recorded attempts, classified

Read directly from `project1_ai` (`Dss`, read-only, superuser session):

| Measure | Value |
|---|---|
| `runs` / `attempts` / `attempt_receipts` | 9 / 9 / 9 |
| Assessment | all `da90aa4a-f9cf-4145-9acf-7de36c9d6fad`, revision 12 |
| `stage` | `BDJ` × 9 |
| `prompt_version` | `BDJ-SOURCE-1-CAND` ×4, `BDJ-SOURCE-2-CAND` ×4, `BDJ-SOURCE-3-CAND` ×1 |
| Receipt `outcome` | `returned` 5 · `rejected` 2 · `unknown_outcome` 2 |
| `output_digest` | present on `returned` rows, `NULL` on `rejected` |

**Classification — and its limits.** This is the classification the directive
asks for, and it is deliberately conservative:

| Class | Count | Basis |
|---|---|---|
| Synthetic fixture execution | **2** | `verify_ledger_execution_principal.py` inserts fixed placeholder fingerprints (`aaa…`, `ccc…`, `ddd…`). Identified by reading the script, not inferred from the hash shape |
| Produced by a script that calls the provider | **7** | `cp03d_bdj_execution.py`, `cp03d_bdj_uncertainty.py`, `cp03e_*.py` all compose `configured_runner()` and make real TokenHarbor calls |
| Actual provider response per attempt | **UNDETERMINED** | the ledger stores no provider request id and no model id; three rows are corroborated only by the on-disk backups in §1.1, and those files record the response without binding it to an attempt id |
| Returned but invalid output | **UNDETERMINED** | nothing records validation, so "returned" cannot be split into valid/invalid |
| Validated result | **0** | no store exists |
| Admitted business finding | **0** | `public.m2_bdj_findings` has 0 rows |

Note the vocabulary trap this exposes: the transport outcome (`returned` /
`rejected` / `unknown_outcome`) is a **different axis** from candidate admission
(`held` / `rejected` / `reviewed` / `stale`, per `decision.py`). They must never
be collapsed into one status — see `CP04A-D11`.


**A returned model response is not a validated or admitted finding.** Nothing in
the current ledger can distinguish those states, which is precisely the gap this
checkpoint closes at the schema level.

---

## 3. The persistence extension

**File:** `backend/migrations/project1_ai/20261117_03_bdj_result_persistence.sql`
**Status:** review candidate. Applied only to `project1_workflow_tests`.

Purely additive: five new tables, no alteration of any existing relation, no
backfill, no change to existing RLS.

| Table | Purpose | Key constraints |
|---|---|---|
| `bdj_results` | one result per attempt: provenance + structured result + validation + admission | `(run_id, owner_user_id, attempt_no)` FK to `attempts`; `UNIQUE (run_id, attempt_no)`; `(execution_outcome='RETURNED') = (output_digest IS NOT NULL)`; `(validation_status='VALID') = (result_payload IS NOT NULL)`; `admission_status<>'ADMITTED' OR validation_status='VALID'` |
| `bdj_result_sources` | the source references the result depends on | `PK (result_id, source_rank)` |
| `bdj_result_validations` | individual checks and their outcome | `severity IN (ERROR, WARNING, INFO)` |
| `bdj_result_findings` | per-finding `ADMITTED` / `REJECTED` / `HELD` | FK to `public.m2_bdj_findings` |
| `bdj_raw_responses` | encrypted original model output | `encryption_alg` fixed to `FERNET-AES128-CBC-HMAC-SHA256`; `plaintext_digest` 64-hex; `retention_until > created_at` |

### Why the protected response is a separate table

`bdj_results.result_payload` holds the **validated structured result**.
`bdj_raw_responses` holds the **original model output**, encrypted. They are
different artefacts and are granted differently:

| Role | `bdj_results` | `bdj_raw_responses` |
|---|---|---|
| `p1ai_runtime` (write path) | `SELECT, INSERT` | **`INSERT` only** |
| `p1ai_audit` | `SELECT` | `SELECT` |
| `PUBLIC` | nothing | nothing |

The runtime cannot read the raw response back. That is deliberate: an ordinary
Activity History query physically cannot return model text, even if a future
query is written carelessly. Reading it needs `p1ai_audit` **and** an access
decision.

Encryption is application-side (Fernet, `cryptography` present in the venv), so
the database never holds the key. `plaintext_digest` allows integrity checking
without the key, and `key_id` allows rotation to find old rows.

### What is deliberately *not* stored

No raw prompt. No completion text in `result_payload`. No entrepreneur-private
answer content. The result payload is the structured BDJ result only, which is
what makes it safe to return through History.

---

## 4. Migration authority — `BLOCKED_DBA_AUTHORIZATION`

| Requirement (§5) | State |
|---|---|
| `p1ai_owner` stays `NOLOGIN` | preserved — `rolcanlogin = false` |
| No schema-ownership granted to `p1ai_engine` or the app role | preserved — `p1ai_engine` has **no** `USAGE` on `project1_ai` |
| Append-only execution records | preserved — `immutable_history` on all ledger tables, and now on all five new tables |
| Separate DBA-controlled process | **not available to this checkpoint** |
| Apply only through an authorised procedure | **not done** — `Dss` is unmodified |

`Dss` evidence that nothing changed: `schema_versions` still contains
`20261111_01_candidate` only, and `to_regclass('project1_ai.bdj_results')` is
`NULL` in `Dss`.

**Two migrations in the repository have never written a receipt.**
`20261116_02_m2_runtime_role.sql` and `20261117_01_execution_principal.sql`
contain no `schema_versions` insert, so the roles they create exist while the
ledger says they were never applied. `schema_versions` therefore **cannot** be
used as the applied-state ledger; state must be verified from objects. Recorded
as `BLK-MIG-RECEIPT`.

### Isolation procedure actually used

1. `CREATE DATABASE project1_workflow_tests TEMPLATE "Dss"` — a full clone.
2. Apply `20261117_02_finding_provenance.sql` → **applied cleanly** (this also
   validates the pre-existing candidate the directive asked to inspect).
3. Apply `20261117_03_bdj_result_persistence.sql` → applied.
4. Negative authorisation and constraint matrix → 19/19.
5. Re-run refused (idempotency).

Reproduce: `scripts/cp04a_clone_migrate.py` → `VERDICT=PASS failures=0`.

The clone is permitted by name in the migration guard itself
(`current_database() IN ('Dss','project1_workflow_tests')`), so this is the
intended test target, not an improvised one.

---

## 5. Security results — 19 checks, 19 passed

`scripts/cp04a_clone_security_verify.py`, each check executed under
`SET ROLE` with the actor GUC bound, inside a savepoint.

| Check | Result | Mechanism observed |
|---|---|---|
| runtime records a result for its own owner | PASS | insert accepted |
| runtime reads back its own result | PASS | `rows=1` |
| a different actor sees zero rows | PASS | `rows=0` |
| RLS WITH CHECK refuses a row owned by someone else | PASS | `new row violates row-level security policy for table "bdj_results"` |
| runtime holds no UPDATE privilege | PASS | `permission denied for table bdj_results` |
| runtime holds no DELETE privilege | PASS | `permission denied` |
| owner UPDATE stopped by the append-only trigger | PASS | `Workflow history is append-only` |
| owner DELETE stopped by the append-only trigger | PASS | `Workflow history is append-only` |
| runtime can write the raw response | PASS | insert accepted |
| runtime **cannot** read the raw response | PASS | `permission denied for table bdj_raw_responses` |
| audit role can read the raw response | PASS | `rows=1` |
| audit role can read results | PASS | `rows=1` |
| audit role cannot write | PASS | `permission denied` |
| unbound actor sees zero rows | PASS | `rows=0` |
| ADMITTED without VALID is refused | PASS | `bdj_results_admission_requires_validation` |
| RETURNED without a digest is refused | PASS | `bdj_results_digest_matches_outcome` |
| REJECTED carrying a digest is refused | PASS | `bdj_results_digest_matches_outcome` |
| a second result for one attempt is refused | PASS | `bdj_results_one_per_attempt` |
| migration receipt recorded | PASS | `rows=1` |

Two of these checks were **wrong on the first run** and were corrected, not
reported as passes:

- Every constraint check initially "passed" on a `syntax error` because
  `exec_driver_sql` does not bind `:name` parameters. Fixed to `text()`; the
  constraints then fired by name.
- "Cannot write another owner's row" initially passed on a `UniqueViolation`,
  because the composite FK already binds the owner and fires before RLS. Re-run
  against a spare attempt with the actor bound to a different owner, which
  isolates the policy: `new row violates row-level security policy`.

---

## 6. Why History V1.1 readback is `BLOCKED`, and not by this migration

The tables are correct and tested. The application still cannot read them:

```
identity: ('p1_m2_runtime', 'Dss')
project1_ai USAGE for app role: False
```

`p1_m2_runtime` has **no** `USAGE` on `project1_ai` and no grant on any ledger
table. This is `MIG-AUTH-01` working as designed, not a defect.

There is an existing, intended path: `PROJECT1_RUNTIME_DATABASE_URL` uses the
`p1ai_engine` login role, which carries `SET` on `p1ai_runtime` and is designed
to be entered with `SET LOCAL ROLE p1ai_runtime`. A History readback would have
to run through that connection, not the M2 one.

**That is a governance decision this checkpoint did not take.** Enabling a
read path from the M2 request context into the AI ledger is exactly the boundary
`MIG-AUTH-01` protects, and choosing it silently would defeat the control.

| Consequence | Status |
|---|---|
| Schema + security for V1.1 | `VERIFIED` on clone |
| PostgreSQL → API → Dart → Jaspr readback | **`BLOCKED`** — no authorised read path from the app role |
| Raw model output visible when authorised | **`IMPLEMENTED`** (write-only to runtime, audit-readable); not yet wired to any authorised endpoint |

The directive's acceptance for V1.1 — *"Demonstrate PostgreSQL → API → Dart →
Jaspr → reload fidelity using genuinely persisted result records"* — is
**NOT ACHIEVED**. No endpoint was written that pretends otherwise.

---

## 7. Defects found while doing this

| ID | Defect | Status |
|---|---|---|
| `CP04A-D01` | `to_regclass()` used to check for a **function** — always `NULL`, so the guard would refuse a correct database | fixed (`to_regproc`) |
| `CP04A-D02` | A `%` inside an SQL **comment** breaks the psycopg2 parameter parser, aborting the whole migration | fixed (comment reworded) |
| `CP04A-D03` | A failed multi-statement migration leaves the session in an aborted transaction, making every later check report a misleading error | fixed (`ROLLBACK` after failure) |
| `CP04A-D04` | Constraint tests passed on a syntax error rather than the constraint | fixed, re-run |
| `CP04A-D05` | RLS check passed on a unique violation rather than the policy | fixed, re-run |
| `CP04A-D06` | `m2_workflow_summary.summary->'campaigns'` is **`NULL` for the application role** — `cq_*` policies are granted to `p1_ee01_runtime` only, so `20261117_06` does not deliver campaign data to the History path | **OPEN** — verified live; needs a reviewed grant migration (`CP04A-MIG-02`) |
| `CP04A-D07` | `project1_ai.schema_versions` is incomplete: two applied migrations never wrote a receipt | **OPEN** (`BLK-MIG-RECEIPT`) |
| `CP04A-D08` | `m2_candidate_review_assignments` has RLS enabled with zero policies — inert today, silent-empty the day it is used | **OPEN**, flagged not fixed |
| `CP04A-D09` | Raw model output sits in **untracked, plaintext, un-gitignored** files under `backend/backups/` with no access control — the only copy of any model output in the system | **OPEN** — must be migrated into the protected store or deleted under a retention decision |
| `CP04A-D10` | `backend/migrations/project1_ai/` is **entirely untracked** in git, so every migration there — including the one this report describes — has no version-control history | **OPEN** |
| `CP04A-D11` | The proposed `admission_status` vocabulary (`ADMITTED`/`REJECTED`/`HELD`/`NO_ADMISSIBLE_FINDING`) does **not** match the Python admission vocabulary (`held`/`rejected`/`reviewed`/`stale`), and ADMITTED/REJECTED/HELD exist *only* in this DDL. A future implementer would have to guess the mapping | **OPEN** — must be reconciled before the migration is applied for real |
| `CP04A-D12` | `p1ai_runtime` holds **no grant on `public.m2_bdj_findings`**, so a cloud result cannot write a finding under the restricted principal — the finding-admission path is not writable as designed | **OPEN** (`BLK-FINDING-GRANT`) |

---

## 8. Regression baseline (CP-00)

| Measure | Value |
|---|---|
| Branch / commit | `merge_main_jed` / `ba30035e` |
| Working tree | 59 modified, 127 untracked, **0 deleted, 0 renamed** |
| Test run (`-m "not slow"`, excl. `tests/api`) | **44 failed, 478 passed, 30 skipped, 8 errors** |
| Collection errors (pre-existing) | `tests/test_age_band_raster_service.py` (`rasterio` missing), `tests/test_fnb_category_model.py` (`CATEGORY_BACKGROUND_CSV` missing) |

All 44 failures and 8 errors are in the property/recommendation app
(`test_property_insights_service.py`, `test_explore_nearby_filter.py`) and are
untouched by this work. This is the same baseline recorded at CP-03F, so the
numbers are stable rather than newly broken.

---

## 9. Rollback and recovery

| Scenario | Procedure |
|---|---|
| Abandon the clone | `DROP DATABASE project1_workflow_tests` — nothing else references it |
| Undo in the clone only | `DROP TABLE` the five tables; the migration is additive and touches nothing else |
| Undo in a real database (if ever applied) | restore the pre-migration backup; the five tables can be dropped individually because no existing table has an FK **into** them |
| Partial application | the guard refuses to re-run while `bdj_results` exists; reconcile by a human, never by dropping evidence |
| Key loss | `plaintext_digest` still verifies integrity of any ciphertext whose key is available; rows whose key is gone are unreadable and must be recorded as such, not deleted |

---

## 10. Verdict

| Element | Status |
|---|---|
| Ledger gap identified and measured | `VERIFIED` |
| Nine attempts classified | `VERIFIED`, with 6 of 9 left `UNDETERMINED` rather than guessed |
| Persistence schema designed and written | `IMPLEMENTED` |
| Schema applied to `Dss` | `BLOCKED_DBA_AUTHORIZATION` |
| Schema applied to isolated clone | `VERIFIED` |
| Security and constraint matrix | `VERIFIED` (19/19) |
| Idempotency | `VERIFIED` |
| History V1.1 API readback | `BLOCKED` — no authorised read path |
| History V1.1 browser evidence | `NOT_RUN` — depends on the above |
| Actual model output viewable when authorised | `IMPLEMENTED`, not wired |

**CP-04A is not complete.** The durable persistence contract exists, is applied
and is proven on an isolated clone. It is not applied to a real database, and it
is not readable by the application. Both are governance blockers, not
engineering ones, and neither was bypassed.

**Two caveats that must be closed before this migration is applied for real:**

1. The `admission_status` vocabulary is my design, not the codebase's. The Python
   layer uses `held` / `rejected` / `reviewed` / `stale`; `ADMITTED` / `REJECTED`
   / `HELD` exist only in this DDL. Applying it as-is would create a second,
   incompatible vocabulary (`CP04A-D11`).
2. `p1ai_runtime` cannot write `public.m2_bdj_findings`, so the
   finding-admission table is currently unwritable under the restricted
   principal (`CP04A-D12`).

Neither was discovered by review. Both were found by reading the execution path
after the migration was already clone-proven — which is a reminder that a schema
that passes its own tests can still be the wrong schema.

