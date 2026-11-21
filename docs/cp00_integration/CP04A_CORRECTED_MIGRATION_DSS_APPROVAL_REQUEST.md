# CP-04A — Corrected Migration: Request to Promote `_02` and `_03` into `Dss`

**Status:** `OWNER_DECISION_REQUIRED` — nothing has been written to `Dss`.
**Date:** 2026-11-17 · **Branch:** `merge_main_jed`
**This document is a request, not a record of a migration.** `Dss` is unchanged and verified unchanged.

---

## 1. Decision requested

Authorise a DBA to apply exactly two migrations to `Dss`, at the hashes below, using a PostgreSQL
administrative identity — **not** the web application role, and not `p1ai_owner` (which stays
`NOLOGIN`).

**Not authorised by this request:** any grant change beyond what the migrations themselves create, any
real-data AI dispatch, any History read path, any `SECURITY DEFINER` function in a new schema
(`B2-04` is still a recommendation), and any change to `M2V1-01` or its GEO validation (`OD-3`
remains deferred).

## 2. Exact artefacts

| File | SHA-256 | Lines |
|---|---|---|
| `backend/migrations/project1_ai/20261117_02_finding_provenance.sql` | `fb71d0b416633c3b3d3384ee2f4b2c92a781575e91c83859553acfad19b4b185` | 101 |
| `backend/migrations/project1_ai/20261117_03_bdj_result_persistence.sql` | `e099f133cc4b1f4179c61448ddae3928c8bc28031263b0e53d65ed082cb8d955` | 457 |

These are the only hashes claimed as applied anywhere. `_03` passed through four superseded drafts
(`4d0f902c`, `a54aa52b`, `048f38bb`, `17367dfe`, plus transient on-disk states); all are withdrawn and
none corresponds to the verified clone. Verify with `sha256sum` before applying; if either hash differs,
**stop** — the file is not the artefact this request describes.

## 3. Measured state, both databases

Read with `psql` against `pg_constraint` and `information_schema`, not from a script's output:

| | `project1_ai` tables | receipts | `attempts` | `bdj_*` tables |
|---|---|---|---|---|
| `Dss` (target, unchanged) | 4 | 1 | 9 | **0** |
| `project1_workflow_tests` (verified clone) | 10 | 5 | 173 | 5 |

`Dss` answers `ERROR: relation "project1_ai.bdj_results" does not exist`. That error is the proof the
corrected schema is absent — not an absence of evidence.

## 4. Backup and restore drill — executed, not planned

A drill was run before writing this request. Both attempts are recorded because the first one failed in
an instructive way.

| Attempt | Client | Result |
|---|---|---|
| 1 | PostgreSQL **18** (`pg_dump`/`pg_restore` 18 against server 16.14) | dump 653,316 B, restore `rc=1`: `unrecognized configuration parameter "transaction_timeout"` — PG 18 writes a server setting PG 16 rejects. Data restored anyway (4/1/9), but the run was not clean. |
| 2 | PostgreSQL **16** (matching server 16.14) | dump 649,882 B, restore `rc=0` with `--exit-on-error`, drill database reported **tables=4, receipts=1, attempts=9** — identical to `Dss`. Drill database dropped. |

**Operational consequence:** use the client whose major version matches the server. A mismatched client
produces a restore that looks successful while emitting errors, which is the worst kind. The server here
is 16.14, so use `C:\Program Files\PostgreSQL\16\bin`.

Artifacts retained under `backend/backups/cp04a/` (gitignored — `backend/backups/` is in `.gitignore`,
so `git add -A` cannot stage them; that was verified, not assumed).

## 5. Preconditions — each checkable before apply

```sql
-- 5.1 Target still matches the baseline in §3
select count(*) from information_schema.tables where table_schema='project1_ai';   -- expect 4
select count(*) from project1_ai.schema_versions;                                  -- expect 1
select count(*) from project1_ai.attempts;                                          -- expect 9

-- 5.2 The corrected schema is genuinely absent
select count(*) from information_schema.tables
 where table_schema='project1_ai' and table_name like 'bdj%';                      -- expect 0

-- 5.3 No session is holding the target tables
select count(*) from pg_stat_activity
 where datname='Dss' and state <> 'idle' and pid <> pg_backend_pid();              -- expect 0

-- 5.4 Apply identity is administrative, and p1ai_owner is not it
select current_user, session_user;
select rolname, rolcanlogin from pg_roles where rolname like 'p1ai%';              -- p1ai_owner: false
```

Also required: a fresh dump per §4 taken immediately before apply, and a recorded restore of that
specific dump. A backup that was never restored is a hope, not a backup.

## 6. Execution order

```sql
-- 1. Apply the provenance migration, then the results migration. _03 depends on _02's
--    authority vocabulary and on public.m2_assessments / public.m2_bdj_findings.
\i backend/migrations/project1_ai/20261117_02_finding_provenance.sql
\i backend/migrations/project1_ai/20261117_03_bdj_result_persistence.sql
```

Each file writes its own receipt into `project1_ai.schema_versions`. If a file stops part-way, do **not**
re-run it blind: `_03` refuses a second run with `bdj result tables already exist: reconcile version
before migrating`, which is a deliberate guard. A partial apply must be diagnosed against
`information_schema`, not retried.

**Receipt gap, to be handled before `_02`/`_03`.** `20261116_02_m2_runtime_role` and
`20261117_01_execution_principal` are present in `Dss` but wrote no receipt. Run
`backend/scripts/cp04a_receipt_reconcile.py` first: it verifies the objects each migration creates and
records a receipt that explicitly does **not** claim an application date. Never backfill a date.

## 7. Verification after apply

```sql
-- 7.1 Both constraints exist, with these exact definitions
select conname, pg_get_constraintdef(oid) from pg_constraint
 where conname in ('bdj_results_findings_require_review_check',
                   'bdj_result_sources_locator_pointer_check');
-- expect:
--   bdj_result_sources_locator_pointer_check ::
--     CHECK (((locator IS NULL) OR (locator ~ '^(?:M2-(?:[0-9]{2}|O-0[12])|M2V1-(?:0[1-9]|1[01]))(@[^[:space:]]{1,128})?$'::text)))
--   bdj_results_findings_require_review_check ::
--     CHECK (((finding_count = 0) OR (review_outcome = ANY (ARRAY['reviewed'::text,'stale'::text]))))

-- 7.2 Ten tables, five receipts, and the nine historical attempts untouched
select count(*) from information_schema.tables where table_schema='project1_ai';   -- expect 10
select count(*) from project1_ai.schema_versions;                                  -- expect 5
select count(*) from project1_ai.attempts;                                         -- expect 9
```

The nine existing attempts, the M2 records and the CQ records must be byte-identical afterwards. `_02`
and `_03` contain no `DROP`, `TRUNCATE`, `DELETE FROM` or `ALTER … DROP` — that was verified by grep
across both files — so row impact is **additive only**.

## 8. Rollback, and what does not roll back

| Object | Rolls back with a database restore? |
|---|---|
| `project1_ai` tables created by `_02`/`_03` | Yes |
| Receipts written by `_02`/`_03` | Yes |
| Cluster-level roles from `_01`/`_20261116_02`/`_20261117_01` | **No** — they are cluster objects, not database objects |
| Role memberships (`GRANT p1ai_runtime TO p1ai_engine`) | **No** |
| `SECURITY DEFINER` function ownership, if B2-04 is ever approved | **No** |

Dropping and restoring the database therefore does **not** return the cluster to its prior state. Role
objects must be dropped explicitly, and doing so while any session is connected as that role will fail.
This is the part of "rollback" that a restore-only plan silently omits.

## 9. Blast radius

- **Touched:** nothing existing is altered. Five new tables (`bdj_results`, `bdj_result_findings`,
  `bdj_result_sources`, `bdj_result_validations`, `bdj_raw_responses`) plus the `finding_provenance`
  alteration.
- **Read by an in-flight application:** none. `p1_m2_runtime` has no `USAGE` on `project1_ai`, so the
  web application cannot see the new tables at all until a grant decision (`MIG-AUTH-01`) is made. That
  is the reason applying the schema is safe before the read path exists.
- **Behaviour change for the app:** none, because the app cannot reach the schema.

## 10. Open decisions that change the outcome

| ID | Decision | Cost of deciding late |
|---|---|---|
| `B2-01` | `p1ai_engine` on its own engine vs the shared one | Grant rework only; schema unchanged. Cheap either way. |
| `B2-02` | Keep the `bdj_raw_responses` INSERT-without-SELECT asymmetry | Cheap — it is already the installed state. |
| `B2-04` | Two `SECURITY DEFINER` functions in a new `project1_api` schema | **Expensive after apply** — adds a schema and an ownership model the migration does not create. |
| `B3-01` | Encryption key custody | Independent of the migration; blocks only raw-output persistence. |
| `MIG-AUTH-01` | How the app reads History | Blocks the read path, not the schema. |

## 11. Known non-compliance to be acknowledged, not signed over

`retention_until` is **unenforceable**. `immutable_history` blocks `DELETE`, so a retention deadline
that requires deletion cannot be honoured by any code path. A signature that implies otherwise would be
a false assurance.

## 12. Approval block

```
Migration files and hashes:  _02 fb71d0b4… / _03 e099f133…   [ ] approved as listed
Backup taken and restored:   dump ____________________ date ________   [ ]
Receipt reconciliation run before apply:                                [ ]
Apply identity (administrative, not app role): ________________________
Rollback understood to exclude cluster roles:                           [ ]
retention_until non-compliance acknowledged:                            [ ]

Owner: ______________________  Date: __________
DBA:   ______________________  Date: __________
Executed (commands actually run, if different from §6): ______________________________
```
