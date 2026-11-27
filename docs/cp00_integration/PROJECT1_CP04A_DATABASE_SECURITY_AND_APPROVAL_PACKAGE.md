# CP-04A — Database Security and Approval Package (B2 / B3)

**Status:** `OWNER_DECISION_REQUIRED` — every recommendation is a proposal.
**Date:** 2026-11-17 · **Author:** b2b3-decisions · **Resolves:** `MIG-AUTH-01`, `BLK-KEY-MGMT`, `CP04A-D09`

> **Non-authorisation.** Nothing here is implemented. No grant changed, no role created, no key generated, no migration applied to `Dss`, no file deleted.

Reporting cites; recommending says **RECOMMENDED**.

---

## B2 — Cloud AI execution and History-read security

### B2-01 Which principal dispatches BDJ

**RECOMMENDED: reuse `p1ai_engine`, on a dedicated engine built from `project1_runtime_database_url` (`core/config.py:76`) — never on the M2 session.**

`p1ai_engine` is `LOGIN NOINHERIT NOSUPERUSER NOBYPASSRLS` (`20261117_01_execution_principal.sql:25`), member of `p1ai_runtime` (`:34`), denied every direct privilege (`:39-40`), reaching data only after `SET LOCAL ROLE p1ai_runtime` (`ledger.py:31-38`).

| Option | Verdict | Why |
|---|---|---|
| Reuse `p1ai_engine` | **ACCEPT** | No new credential; `_scope()` rejects superuser/BYPASSRLS before dispatch (`ledger.py:29-30`) |
| Dedicated dispatcher login | REJECT | Second secret, no added isolation |
| Background worker as sole holder | REJECT for V1.1 | Best posture, but needs a job store that does not exist (`BLK-RUNNER-UNWIRED`) and an async route. **Target for real data** |

The ledger must not run on the M2 session: `p1_m2_runtime` has no `USAGE` on `project1_ai`, so `_scope()` raises `RESTRICTED_WORKFLOW_PRINCIPAL_REQUIRED` (`ledger.py:32-38`). It fails closed today; that must survive.

### B2-02 Who writes, who reads, who may retrieve originals

| Operation | Role | Grant | State |
|---|---|---|---|
| `runs`/`attempts`/`attempt_receipts` insert | `p1ai_runtime` | `SELECT, INSERT`; `UPDATE(id)` on `runs` | exists (`20261111_01:82,93`) |
| `bdj_results` + 3 children insert | `p1ai_runtime` | `SELECT, INSERT` | exists (`20261117_03:367-370`) |
| `bdj_raw_responses` insert | `p1ai_runtime` | **`INSERT` only** | exists (`:375`) |
| Any table, incl. originals | `p1ai_audit` | `SELECT` | exists (`:378-382`) |
| History read | `p1_m2_runtime` | `EXECUTE` on `project1_api` | **PROPOSED** (§B2-04) |

**Buys:** the request path records a completion but cannot read it back, so compromising the M2 process yields no model text. **Costs:** an auditor must read it at all. Clone-proven (`PROJECT1_CLOUD_BDJ_PERSISTENCE_AND_SECURITY_REPORT.md` §6). **Limitation:** `bdj_results` is readable by `p1ai_runtime`, and its payload holds quoted answer text (§B2-07).

### B2-03 Owner identity

Bound per transaction from the authenticated principal, never from a request body: `m2_session_for(actor_id)` (`db/m2_session.py:38-58`), `ledger._scope()` via `set_config(..., true)` (`ledger.py:39-40`). `owner_scope` keys on `nullif(current_setting('project1.actor_id', true), '')::uuid` in `USING` and `WITH CHECK` (`20261111_01:76-78`; `20261117_03:310-312`); an unbound actor sees nothing and every write is refused. **No new mechanism.** A History reader must read the GUC, never take an owner argument.

### B2-04 How History may read

**RECOMMENDED: two `SECURITY DEFINER` functions owned by `p1ai_owner` in a new schema `project1_api`, `EXECUTE` granted to `p1_m2_runtime` (PROPOSED).** Each takes **no owner parameter**, refuses an empty `project1.actor_id`, and returns an explicit column list (§B2-07). `project1_ai` keeps zero `USAGE` for the app role, so `MIG-AUTH-01`'s literal property survives.

| Alternative | Trade-off | Verdict |
|---|---|---|
| `SECURITY DEFINER` function | Needs `SET search_path = pg_catalog` and `REVOKE EXECUTE FROM PUBLIC`; supports paging | **ACCEPT** |
| Dedicated read role + narrow view | No definer footgun, but new LOGIN, secret, third pool; no parameters | REJECT |
| Separate `p1ai_engine` read pool | Makes the request path a ledger reader, bypassing the allow-list | REJECT |

`FORCE ROW LEVEL SECURITY` (`20261117_03:308`) binds `p1ai_owner` too, so the functions stay owner-scoped.

### B2-05 What History must never expose

Raw completions; prompts; answer text in any form; `ciphertext`; `plaintext_digest`; provider errors or payload fragments. `review_reason` is a fixed code only (`20261117_03:192-195`).

### B2-06 What changes on `Dss` — dependency order

1. Backfill `schema_versions` receipts for `20261116_02`, `20261117_01` (`BLK-MIG-RECEIPT`).
2. Apply `20261117_02_finding_provenance`.
3. Apply `20261117_03_bdj_result_persistence` (vocabulary-corrected, `BLK-VOCAB`).
4. `CREATE SCHEMA project1_api AUTHORIZATION p1ai_owner` (PROPOSED).
5. Create `project1_api.history_attempts`, `project1_api.history_result` (PROPOSED).
6. `GRANT USAGE ON SCHEMA project1_api TO p1_m2_runtime` (PROPOSED).
7. `GRANT EXECUTE ON FUNCTION project1_api.* TO p1_m2_runtime` (PROPOSED).

Unchanged: `p1ai_*` roles, `project1_ai` grants, existing RLS.

### B2-07 `result_payload` projection allow-list

`bdj_results.result_payload` holds `Finding.source_refs[].quote`, a verbatim substring of the entrepreneur's answer — stated in the migration (`20261117_03:24-27`), enforced by substring test (`bdj.py:41-53`). **Therefore `bdj_raw_responses` encryption does not protect answer text at rest:** the same text sits in a plaintext column readable by `p1ai_runtime` (`:367`) and `p1ai_audit` (`:378`).

| Permitted | Excluded |
|---|---|
| `result_id`, `run_id`, `attempt_no`, `assessment_id`, `assessment_revision` | `result_payload` as an object |
| `execution_outcome`, `review_outcome`, `validation_status`, `finding_authority`, `finding_count`, `review_reason` | `findings[].source_refs[]`, `.quote`, `.explanation`, `.observed_condition` |
| `ruleset_version`, `prompt_version`, `model_requested`, `model_returned`, `created_at` | `validations.detail` (free text) |
| `validations.check_code`, `.severity`, `.passed` | — |

**Residual risk, flagged not fixed:** the allow-list is application SQL; the text remains in the column. The real fix is an Owner schema decision — (a) drop `quote` from the persisted payload, keeping it only in the encrypted original, or (b) encrypt `result_payload` too. (a) removes the duplicate; (b) costs a second decrypt path.

---

## B3 — Encryption key custody and retention

### B3-01 Key storage

**RECOMMENDED: an ACL-restricted key file outside the repository, DPAPI-protected at rest, path from `PROJECT1_RAW_RESPONSE_KEY_FILE` (PROPOSED). Staging only — never real data.**

| Option | Verdict | Why |
|---|---|---|
| File outside repo, restrictive ACLs | **ACCEPT (staging)** | No new dependency; survives a clone |
| OS keyring | REJECT | A service process has no interactive profile |
| External secret manager | **REQUIRED before real data** | No helper in `core/`, no store provisioned |
| HSM / KMS | REJECT | No account, library or operator for 18,892 bytes |
| Beside the ciphertext, or in the DB it protects | **FORBIDDEN** | One compromise becomes full disclosure |

### B3-02 Versioning and rotation

`key_id` (`:275`) names the key material — not a secret, not a row key. Rotation adds a new encrypting key and retains the old for decrypt (`MultiFernet`); **no historical row is re-encrypted**, because each row names its key. `encryption_alg` is pinned (`:272-273`), so rotation is key-material only. `key_id` selects the key and lets a re-wrap job find retired-key rows.

### B3-03 Authorised decryption

`p1ai_audit` holds `SELECT` on `bdj_raw_responses` (`:382`) under `technical_audit_read` (`:361-362`), reachable only via `p1ai_auditor` (`20261117_01:52-54`). **Honest gap:** the record proves who *could* read, not who *did*. **RECOMMENDED:** `pgaudit` on the audit connection, or a PROPOSED insert-only `project1_ai.raw_response_access` receipt (actor, `result_id`, purpose code, timestamp) with no delete grant.

**Conflict to see:** `retention_until` is `NOT NULL` (`:280`) but `immutable_history` raises on `DELETE`. Retention is **declarative only**; enforcing it means disabling the trigger as `p1ai_owner` — break-glass. Authorise that, or add a tombstone column.

### B3-04 Retention duration

**RECOMMENDED: 90 days** from `created_at` for raw completions. The provider retains, staff-readable, up to 24 months (`backend/docs/project1_workflow/IMPLEMENTATION.md:95-99`), our copy is never longest-lived. A disputed finding is answered by the structured result and digest, retained indefinitely; raw text matters for one review cycle, and minimisation favours the shortest interval covering a review plus a re-review.

### B3-05 Plaintext artifacts on disk

Governed by `CP04A_PLAINTEXT_ARTIFACT_RETENTION_PROPOSAL.md`; not repeated. **Ordering:** rotate the leaked `M2`/`EE01` credentials, confirm the app runs on them, delete the file **only afterwards** (§1 there). Deleting first destroys the only record of the exposure.

### B3-06 Loss and recovery

A lost key leaves historical raw completions **permanently unreadable**; `plaintext_digest` (`:278`) lets a candidate be *verified*, never *recovered*. **Acceptable for synthetic; not for real data.** Escrow costs a second custodian, a wrapped-key procedure, a runbook and an annual drill — process, not code.

### B3-07 Dependency declaration

`cryptography` 50.0.2 imports in `backend/.venv` but is **not declared** — it arrives only via `pyjwt[crypto]>=2.9` (`pyproject.toml:20`). **RECOMMENDED:** add `cryptography>=42` to `[project].dependencies`; a transitive pin can vanish on a bump, and the failure looks like an unopenable ciphertext, not a build error.

---

## Decision table

| ID | Question | Recommendation | Alternative | If deferred |
|---|---|---|---|---|
| `B2-01` | Who dispatches BDJ | `p1ai_engine`, own pool | Background worker | Route unwired |
| `B2-02` | Grants | Keep as migrated; raw INSERT-only | Runtime reads raw | Compromise yields model text |
| `B2-03` | Owner binding | GUC from JWT, transaction-scoped | — | RLS has no subject |
| `B2-04` | History read | `SECURITY DEFINER` in `project1_api` | Read role + view | V1.1 unservable |
| `B2-05` | Never expose | Raw, prompts, quotes, digests, errors | — | Silent disclosure |
| `B2-06` | `Dss` changes | 7 steps, §B2-06 order | — | Nothing durable or readable |
| `B2-07` | `result_payload` | Allow-list, quote excluded | Drop quote; encrypt payload | Answer text exposed |
| `B3-01` | Key storage | ACL file outside repo (staging) | Keyring / KMS | No key, so no encryption |
| `B3-02` | Rotation | New key primary, old retained | Re-encrypt history | Rotation rewrites history |
| `B3-03` | Decryption authority | `p1ai_audit` + `pgaudit` | Access-receipt table | Reads unrecorded |
| `B3-04` | Retention | 90 days | Provider's 24 months | Indefinite retention |
| `B3-05` | Disk artifacts | Rotate, confirm, delete | — | Live credentials stay valid |
| `B3-06` | Key loss | Accept (synthetic); escrow before real data | Escrow now | Originals unrecoverable |
| `B3-07` | Dependency | Declare `cryptography>=42` | Rely on transitive | Encryption breaks on a bump |

---

## Open questions I could not resolve

1. **Is `p1_m2_runtime` the right grantee?** Three app runtime roles exist; only this one appears in evidence. Whether EE-01 or the UC staging roles need the same path is unrecorded.
2. **Which schema hosts the reader functions?** `project1_api` is my proposal; no precedent exists.
3. **Who operates the audit connection, and is `pgaudit` installed on `Dss`?** Unverified; if neither, `B3-03` needs the receipt table.
4. **Does the DPAPI posture apply?** Unknown whether the API runs interactively, as a service, or in a container. In a container, `B3-01` fails and a secret manager is mandatory.
5. **Are the `.dump` `owner_user_id` values live accounts?** Asked in the retention proposal (§4), unanswered; it decides whether that dump is a git or a data-retention question.
