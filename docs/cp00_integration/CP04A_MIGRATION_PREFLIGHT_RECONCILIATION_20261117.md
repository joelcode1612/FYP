# CP-04A — Migration Preflight Reconciliation

**Date:** 2026-11-17 · **Scope:** pre-approval verification only · **Modules frozen**
**Verdict:** `BLOCKED` on 1 receipt gap and 1 retention control — the migration itself is ready.

Every database read in this report ran under `default_transaction_read_only = on`. `Dss` was not
modified, no migration was executed, no TokenHarbor call was made.

---

## Verdict summary

| # | Check | Verdict | Basis |
|---|---|---|---|
| 1 | Catalog on both databases | **PASS** | `Dss` 4 tables · clone 10 tables, read-only sessions |
| 2 | 4-vs-10 reconciliation, six-object difference | **PASS** | difference is exactly the six frozen tables, no extras |
| 2b | `finding_provenance` is a table, not an alteration | **PASS** | `relkind='r'`; no `ADD COLUMN` in either file |
| 3 | Real `Dss` receipt state | **BLOCKED** | execution **proven by objects**, receipts absent for two migrations |
| 4 | Both frozen SHA-256 values | **PASS** | file hashes match the frozen pair; clone carries all 10 signature constraints |
| 5 | PG16 backup restores without errors | **PASS** | `pg_restore` rc=0, `--exit-on-error`, restored catalog identical to `Dss` |
| 6 | `retention_until` | **BLOCKED** | unenforceable as written; remediation defined below, not merely accepted |

---

## 1–2. Catalog reconciliation

`python scripts/cp04a_migration_preflight.py` (both connections `read_only=on`):

```
Dss                      db='Dss'                     read_only=on  tables=4
project1_workflow_tests  db='project1_workflow_tests' read_only=on  tables=10
```

| Database | `project1_ai` tables |
|---|---|
| `Dss` (4) | `attempt_receipts`, `attempts`, `runs`, `schema_versions` |
| clone (10) | the four above + `bdj_raw_responses`, `bdj_result_findings`, `bdj_result_sources`, `bdj_result_validations`, `bdj_results`, `finding_provenance` |

**The exact six-object difference** — `missing` on `Dss`, `extra` on the clone: **none**.

```
['bdj_raw_responses', 'bdj_result_findings', 'bdj_result_sources',
 'bdj_result_validations', 'bdj_results', 'finding_provenance']
```

This corrects the earlier "five missing tables" list, which omitted `bdj_raw_responses`. The count was
wrong because it was derived from the clone's inventory rather than from the migrations' own DDL. The
migrations create exactly six tables:

- `20261117_02_finding_provenance.sql:36` → `CREATE TABLE project1_ai.finding_provenance` — **one table**
- `20261117_03_bdj_result_persistence.sql:83,249,275,303,342` → `bdj_results`, `bdj_result_sources`,
  `bdj_result_validations`, `bdj_result_findings`, `bdj_raw_responses` — **five tables**

`finding_provenance` is an **ordinary table**, not an alteration of an existing one: `relkind='r'` on the
clone, it has its own primary key, and `grep -Ei "add column"` returns nothing in either file. It carries
`assessment_id → public.m2_assessments(id)` and `finding_id → public.m2_bdj_findings(id)`, so it is a
satellite of the existing deterministic store rather than a replacement.

All six carry the full guard set on the clone: `rls=True force=True policies=2 triggers=1`.

## 3. Real receipt state on `Dss` — execution versus receipt

The `Dss` ledger holds **one** row:

```
20261111_01_candidate   2026-11-16 20:11   CP-01 2026-11-16: candidate ledger applied after verified backup c50b84fd…
```

`20261116_02_m2_runtime_role` and `20261117_01_execution_principal` have **no row**. Per your instruction
this is *not* treated as evidence that they did not execute. Object inspection on `Dss` shows they did:

| Object-level proof | Result on `Dss` |
|---|---|
| `p1_m2_runtime` role exists (created by `_20261116_02:40`) | **present** |
| `p1ai_engine`, `p1ai_runtime`, `p1ai_auditor` exist (created by `_20261117_01:25,48`) | **all present** |
| `m2_*` policies in `public` | **18**, identical list to the clone |
| `p1ai_runtime` has `USAGE` on `project1_ai` | **true** |

So the correct status is: **executed, receipt missing** — `BLK-MIG-RECEIPT`, a ledger-integrity defect, not
a schema defect. The practical consequence is narrow and worth stating plainly: the ledger cannot be used
to decide whether a migration is applied, so apply-state must be decided by object inspection until the
receipts are backfilled. The clone already demonstrates the backfill wording (`RECONCILED 2026-11-17 by
object inspection (7/7 checks) … its application date is unknown and is not claimed here`).

## 4. Frozen SHA-256 verification

| File | SHA-256 (measured now) | Frozen value in approval request | Match |
|---|---|---|---|
| `20261117_02_finding_provenance.sql` (101 lines) | `fb71d0b416633c3b3d3384ee2f4b2c92a781575e91c83859553acfad19b4b185` | `_02 fb71d0b4…` | **yes** |
| `20261117_03_bdj_result_persistence.sql` (457 lines) | `e099f133cc4b1f4179c61448ddae3928c8bc28031263b0e53d65ed082cb8d955` | `_03 e099f133…` | **yes** |

That the **tested clone** was built from these files is shown by object equivalence, not by trust:

- **10/10** signature constraints extracted from `_03` exist on the clone, with matching definitions —
  including `bdj_results_findings_require_review_check` (`finding_count = 0 OR review_outcome IN
  ('reviewed','stale')`), `bdj_results_returned_requires_review`,
  `bdj_results_review_requires_validation`, `bdj_results_payload_requires_valid`,
  `bdj_results_unreviewed_has_no_payload`, `bdj_results_digest_matches_outcome`,
  `bdj_results_one_per_attempt`, `bdj_results_attempt_fk`,
  `bdj_result_sources_locator_pointer_check`, `bdj_raw_responses_retention_forward`.
- All six tables carry two policies and one `immutable_history` trigger.

## 5. Backup restore

`python scripts/cp04a_backup_restore_drill.py` — PG16.14 client against the PG16.14 server, restoring
`backups/cp04a/dss_pre_cp04a_pg16_20261117_155626.dump` (649,882 bytes) into a throwaway database:

```
pg_restore rc=0                       (--exit-on-error --single-transaction)
restored tables: attempt_receipts, attempts, runs, schema_versions
restored counts: 9 / 9 / 9 / 1        Dss counts: 9 / 9 / 9 / 1
restored ledger: ['20261111_01_candidate']
scratch database dropped
```

**PASS.** The earlier failure (`unrecognized configuration parameter "transaction_timeout"`) was a PG18
client against a PG16 server; with the matching 16.14 client the dump restores cleanly with
`--exit-on-error`. Rollback material is therefore proven, not assumed.

## 6. `retention_until` — reported separately, with a remediation

**The conflict.** `bdj_raw_responses.retention_until` is `NOT NULL` with
`CHECK (retention_until > created_at)` (`_03:354-357`). The same table carries
`immutable_history BEFORE UPDATE OR DELETE` → `project1_ai.deny_mutation()`. No code path can delete a row,
so a retention deadline cannot be honoured. This is not hypothetical: the clone already holds **8** rows
with `retention_until = 2027-02-15`, written by `result_store.py:332-341`
(`now() + make_interval(days => :retention_days)`).

**Recommended remediation — crypto-shredding, no schema change needed.** The table already has
`key_id`, `ciphertext` and `encryption_alg` (`FERNET-AES128-CBC-HMAC-SHA256`). Deleting the key at
`retention_until` makes the ciphertext permanently unreadable while the audit row survives intact. This
satisfies the retention obligation and the append-only design simultaneously, which deletion cannot.

Minimum components:

1. **Key custody store** — `key_id → key material`, separate from `project1_ai`, with its own access
   control. This is the existing `B3-01` item; retention and key custody are the same decision, not two.
2. **Destruction job** — select `key_id` where `retention_until <= now()`, destroy the key, record the
   receipt. Currently `key_id` holds ad-hoc `test-*` values, so there is no store to destroy from yet.
3. **Destruction receipt** — insert-only, append-only, actor + `result_id` + timestamp + reason code.
4. **Proof test** — after shred: row still present, `plaintext_digest` unchanged, decryption fails with a
   specific code, and the row is still returned by no general History response.

**Alternatives considered and not recommended.** *Partition expiry* (`DETACH` + `DROP`) works around the row
trigger but deletes the audit record itself and requires partitioning the table — a schema change to solve
a control problem. *Amending the policy to "retention reviewed, deletion deferred"* is not a remediation.

**Timing matters.** `Dss` has **zero** `bdj_raw_responses` rows because the table does not exist there yet.
The control can be in place before the first row is written. That window closes at the moment of apply.

## 7. Minimum remaining approval decisions

| # | Decision | Why it cannot be inferred | Blocks |
|---|---|---|---|
| **A1** | Sign §12: both hashes, apply identity, rollback scope, and the `retention_until` acknowledgement | a governance signature | the apply itself |
| **A2** | Retention control: adopt crypto-shredding (recommended), or choose another, or defer with a named owner | product/legal choice; key custody owner must be named | writing any `bdj_raw_responses` row |
| **A3** | `BLK-MIG-RECEIPT` disposition: backfill receipts for `20261116_02`/`20261117_01` on `Dss` after apply, or formally adopt object-based state verification | record-integrity policy | trusting the ledger as applied-state |

**Not required for this apply:** `B2-04` (`SECURITY DEFINER` functions in a new `project1_api` schema — a
separate change), `MIG-AUTH-01` (read path, not schema), `OD-3` (remains deferred).

**Apply order:** `_02` then `_03`. `_02` guards itself (`IF to_regclass('project1_ai.finding_provenance')
IS NOT NULL THEN RAISE EXCEPTION`), so a re-run raises rather than duplicating.

## 8. What was and was not done

| Action | Status |
|---|---|
| `Dss` reads | performed, `default_transaction_read_only = on` |
| `Dss` writes / DDL | **none** |
| Migration execution | **none** |
| TokenHarbor paid call | **none** |
| Scratch database | created and dropped for the restore drill only |
| BDJ / BCB / QJ responsibilities | untouched, frozen |
