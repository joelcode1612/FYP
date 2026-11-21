# CP-04A — Migration Deployment and BCB Integration: Execution Report

**Date:** 2026-11-17 · **Branch:** `merge_main_jed` · **Target:** `Dss`
**Overall:** migration `PASS` · BCB `PARTIAL` · **two checkpoints BLOCKED**

---

## Checkpoint table

| Checkpoint | Status | Evidence |
|---|---|---|
| **A1** migration deployment | **PASS** | `MIGRATION_DEPLOYED_VERIFIED`; 12/12 post-checks; 4/4 behavioural privilege tests |
| **A2** retention / security | **PARTIAL** | custody + retention + key isolation proven (36 tests); requirement 3 partially satisfied — see §3 |
| **A3** receipt reconciliation | **PASS** | 14/14 object checks then 2 rows recorded; execution dates explicitly not claimed |
| **BCB** production resolver | **PASS** (caveat) | `M2ContextBindings` replaces `UnverifiedContextBindings`; 51 passed; GEO contract 1.1 |
| **BCB** authorization and RLS | **BLOCKED** | resolver never sets `project1.actor_id`; harness runs as superuser — see §5 |
| **M2 → BDJ → BCB** integration | **PARTIAL** | findings binding proven (PG41) but `public.m2_bdj_findings` is **empty on `Dss`**; real-data path NOT_RUN |
| **BCB → QJ** smoke test | **NOT_RUN** | not attempted; QJ harness requires a confirmed measurement not present on `Dss` |

---

## 1. Phase 1 — safeguards

| Item | Result |
|---|---|
| Frozen hashes | `_02` `fb71d0b4…185` · `_03` `e099f133…955` — both matched, verified again at execution |
| Fresh backup | `backups/cp04a/dss_pre_apply_pg16_20261117.dump`, 649,882 bytes, sha256 `d215f73d38bc6edcc4b344fb0596efcfe7e1af3e694961027086669ea721f4ae` |
| Restore drill | PG16.14 `pg_restore --exit-on-error --single-transaction` → **rc=0**; 4 tables, rows 9/9/9/1, ledger 1 row, identical to `Dss`; scratch DB dropped |
| Receipt reconciliation | dry run 14/14 VERIFIED, then 2 rows recorded |
| App write gate | `project1_workflow_enabled=False`, `tokenharbor_enabled=False`, `db_auto_create=False` |
| Secrets | `backend/.env` and `test/.env` **were tracked**; untracked with `git rm --cached` (files intact on disk); `git check-ignore --no-index` now matches `.gitignore:105`; only `.env.example` files remain tracked |

## 2. Phase 2 — deployment

Commands: `scripts/cp04a_apply_migrations.py --check` then `--apply`.

- Administrative identity: **`postgres`** (local superuser — administrative, not an application role)
- Order: `_02` → `_03`, each a self-contained `BEGIN; … COMMIT;`, `lock_timeout 3s`, `statement_timeout 30s/60s`
- Receipt recorded verbatim in each row, naming the backup hash and the preflight result

Post-state: `project1_ai` **10 tables** · ledger **5 rows** · runs/attempts/receipts **9/9/9 preserved** ·
**10/10** signature constraints · **6/6** tables `rls+force+2 policies+1 trigger` · grant matrix matches each
table's contract (`bdj_raw_responses` `INSERT`-only for runtime, `SELECT` for audit).

Behavioural test as `p1ai_runtime` (rolled back, nothing persisted): SELECT `bdj_results` allowed ·
SELECT `bdj_raw_responses` denied · UPDATE denied · DELETE denied — **4/4**.

### Verifier defect, corrected rather than hidden

The first post-deploy run reported `MIGRATION_VERIFICATION_FAILED`. **The verifier was wrong.** It asserted
`SELECT` on every runtime table including `bdj_raw_responses`, which the schema deliberately makes
write-only. The check was rewritten to honour each table's own contract and verification re-ran **without
touching the database**: 12/12 pass. Both runs are preserved in
`backups/cp04a/MIGRATION_EXECUTION_EVIDENCE_20261117.json` under `verifier_correction`.

## 3. Phase 3 — A2 controls (`PARTIAL`)

Built: `project1/key_custody.py` (`KeyCustody` protocol, `LocalKeyCustody` with 0600 keys and tombstones,
path-validated key ids, no key material in error messages), `project1/retention.py` (expiry selection,
crypto-shred, append-only JSONL receipts), two settings in `core/config.py`.

Proven: authorized decrypt round-trip; unauthorized denial; expiry (ciphertext byte-identical, decrypt then
fails); **key isolation with three independent keys** — destroying A leaves B and C decryptable; destruction
idempotent with one receipt per key.

Requirement 3 — **PARTIALLY_SATISFIED**:

- **Closed:** verbatim quote spans no longer reach `bdj_results.result_payload`. `redact_payload()` strips
  `quote` from `source_refs` before the INSERT. Measured on the persisted payload: 26 strings, **0** contain
  the `QUOTE-MARKER-9f2c` sentinel, `"quote"` absent, pointers intact.
- **Residual, unprotected by design:** model-generated prose (`justification`, `counterargument`,
  `observed_condition`, `next_action`) may restate declaration text. Redaction deliberately leaves it — it
  is the finding's substance. Closing this requires encrypting `result_payload` under the custody key,
  which is a migration.
- **Not verifiable here:** backups. Logs: no logging exists in the `project1` modules.

I corrected one test rather than delete it: `test_history_projection_excludes_the_quote_sentinel` asserted
the quote **was** stored. It now asserts the stronger guarantee (absent from response *and* at rest,
`"quote"` gone, finding and 2 pointer rows preserved).

## 4. Phase 4 — BCB production resolver

`M2ContextBindings` + `M2OwnershipAuthorization` replace `UnverifiedContextBindings` (the stub is gone from
source). Bindings come from `m2_assessments.owner_user_id`, the confirmation row, `m2_answer_revisions`,
`m2_bdj_findings` and `m2_confirmed_uncertainties`. `sources=[]` because no M2 external-evidence table
exists → `EXTERNAL_EVIDENCE_MISSING`; `finding_authorities={}` so a VERIFIED finding still fails closed.

GEO scope correction is a **versioned contract change**: `BCB-V1-1.0.0-SANDBOX` / `business-context-package/1.0`
(requires an APPROVED GEO binding) remains registered and unchanged; `BCB-V1-1.1.0` /
`business-context-package/1.1` drops the GEO requirement, carries `geography: null`, states the exclusion in
its limitations, and **refuses** a supplied geography object. The builder default is still 1.0, so the frozen
sandbox contract is untouched. No GEO approval record was fabricated and no historical snapshot meaning
changed.

`test_PG13` renamed to `..._authorizes_owner_and_refuses_others` and now asserts **both** halves: owner → 201
with `owner_id`=actor and `geography`=null; none → 401, staff → 403, cross-owner → 404, exactly one context
row; the `M2_BCB_PERSISTENCE_ENABLED` off-gate still returns 503. The refusal half was retained, not deleted.

Independent run of `tests/m2_bcb/run_isolated.py`: **51 passed, 6 skipped, 4 xfailed** (baseline was 42
passed), live `Dss` not written.

## 5. BLOCKED — BCB authorization and RLS

**The 51 passing tests do not prove RLS-scoped operation.** `run_isolated.py:74-77` connects as
`postgres` — a superuser, which bypasses RLS entirely.

`M2ContextBindings.resolve()` reads through `SqlModelM2Repository(session)` and **never** sets
`project1.actor_id`. Every `m2_*` table is protected by an `owner_scope` policy keyed on that GUC, so under
a restricted principal the predicate evaluates to `owner_user_id = NULL` → zero rows → the resolver fails
closed with `M2_CONFIRMATION_MISSING`. Safe, but non-functional: BCB cannot build a context in production
under the restricted principal.

The established pattern already exists at `project1/ledger.py:31-38`: verify the session is not
superuser/BYPASSRLS, `SET LOCAL ROLE`, then `set_config('project1.actor_id', …, true)`. BCB needs the same,
but under **`p1_m2_runtime`** — the role that holds the `public.m2_*` grants — not `p1ai_runtime`, which
holds the `project1_ai` grants. Two schemas, two principals.

I did not patch this in a way that would let the superuser tests keep passing, because that is exactly how a
false PASS is manufactured.

## 6. Other open items

| Item | Status | Detail |
|---|---|---|
| `CONFIRMATION_VALIDITY = 90 days` | **Owner decision** | Not a declared contract term. The only 90-day figure in the project is raw-response retention (`B3-04`), a different object. Comment corrected to say so; consequence is that a context self-reports expiry 90 days after confirmation. |
| `--suite current-instrument` | **NOT_RUN** | Fails before any BCB code on a pre-existing digest mismatch in `src/sitewise/instruments/m2v1_20261114/source.txt`. Verified **unmodified** in git — not caused by this work. So M2V1-through-production-resolver is unverified; the template itself is covered by PG43. |
| `public.m2_bdj_findings` on `Dss` | **empty** | Findings binding is proven on fixtures only. No real deterministic finding exists to bind. |
| BCB → QJ smoke test | **NOT_RUN** | Not attempted. |

## 7. Rollback readiness

Restore from `dss_pre_apply_pg16_20261117.dump` (sha256 recorded, restore drill rc=0). Each migration is a
single transaction, so a failed apply leaves no partial state. **Do not** roll back by dropping the six
tables — that destroys audit evidence; restore from the dump instead. Cluster roles from
`_20261116_02`/`_20261117_01` are cluster objects and are not covered by a database-level restore.

## 8. Files changed

Created: `backend/scripts/cp04a_migration_preflight.py`, `cp04a_apply_migrations.py`,
`cp04a_backup_restore_drill.py`; `backend/src/sitewise/project1/key_custody.py`, `retention.py`;
`backend/src/sitewise/repositories/m2_context_bindings.py`;
`backend/tests/project1/test_key_custody.py`, `test_retention.py`;
`backend/tests/m2_bcb/production_binding_checks.py`.

Modified: `project1/result_store.py` (redaction), `core/config.py`, `services/business_context_v1.py`,
`services/persisted_business_context_service.py`, `repositories/business_context_repository.py`,
`dependencies.py`, `tests/project1/test_model_assisted_route.py`, `tests/m2_bcb/test_postgres_api.py`,
`.gitignore`. Nothing committed.
