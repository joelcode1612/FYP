# PROJECT1 — Updated Implementation and Blocker Register

**Date:** 2026-11-17 · **Branch:** `merge_main_jed` · **Supersedes the status sections of**
`PROJECT1_FINAL_IMPLEMENTATION_AND_BLOCKER_REGISTER.md` (which stays as history).

Labels used per item, separately: `IMPLEMENTED` · `CLONE_TESTED` · `API_TESTED` · `BROWSER_TESTED` ·
`EXPECTED_HOLD` · `BLOCKED` · `NOT_RUN`.

---

## 1. Checkpoint status

| Checkpoint | State | One-line evidence |
|---|---|---|
| A1 — outcome vocabulary reconciliation | `CLONE_TESTED` | four independent dimensions; `_02`/`_03` at the hashes in §2 |
| A2 — isolated clone verification | `CLONE_TESTED` | 36-check matrix PASS; both constraints present in the clone, neither in `Dss` |
| A3 — result persistence writer | `CLONE_TESTED` | 13 writer tests, 124 result rows written and read back |
| A4 — runner connected to FastAPI | `CLONE_TESTED` | 16 route tests; fixture provider only |
| A5 — Activity History V1.1 | `API_TESTED` | new `GET …/results`; 4 tests incl. quote sentinel · `BROWSER_TESTED` = `NOT_RUN` |
| A6 — assessment association | `CLONE_TESTED` | chain is 100% `m2_assessments`; `CP04A-D13` open |
| A7 — BCB authority implementation | `BLOCKED` | `BLK-BCB-AUTH`; decision sheet delivered |
| A8 — QJ/QG integration | `BLOCKED` | on A7 + bank adapter |
| A9 — questionnaire and reporting | `BLOCKED` | on A8 |
| B1 — `Dss` migration approval | `OWNER_DECISION_REQUIRED` | approval request delivered, backup+restore drill executed |
| B2/B3 — AI execution and key custody | `OWNER_DECISION_REQUIRED` | security package delivered |
| B4 — BCB authority decisions | `OWNER_DECISION_REQUIRED` | four decisions split out |
| B6 — scientific/publication authorization | `OWNER_DECISION_REQUIRED` | unchanged |
| CP-07 staged tests | `PARTIAL` | E2E-1 API+DB verified (246 tests); E2E-2A verified on a disposable cluster (42 passed, HOLD observed); E2E-0/2B/3/4/5 `NOT_RUN` or `BLOCKED` |

## 2. Frozen artefacts

| Artefact | Hash / value |
|---|---|
| `20261117_02_finding_provenance.sql` | `fb71d0b416633c3b3d3384ee2f4b2c92a781575e91c83859553acfad19b4b185` (101 lines) |
| `20261117_03_bdj_result_persistence.sql` | `e099f133cc4b1f4179c61448ddae3928c8bc28031263b0e53d65ed082cb8d955` (457 lines) |
| `Dss` | 4 `project1_ai` tables · 1 receipt · 9 attempts · 0 `bdj_*` tables |
| clone | 10 tables · 5 receipts · 173 attempts · 5 `bdj_*` tables |

`Dss` was not written to. That is measured (`relation "project1_ai.bdj_results" does not exist`), not
promised.

## 3. Test evidence

```
cd backend
./.venv/Scripts/python.exe scripts/run_project1_clone_tests.py tests/project1 -q
→ 246 passed, 1 skipped, 7 subtests passed

./.venv/Scripts/python.exe tests/m2_bcb/run_isolated.py \
    --output ../docs/cp00_integration/cp07_e2e2a_bcb_isolated.json --suite regression
→ 42 passed, 6 skipped, 4 xfailed in 164.05s
→ Private cluster stopped; live Dss was not written.
→ api_execution.json: 391 interactions / 46 tests, 0 genuine status mismatches
→ observed BCB_BINDING_AUTHORITY_UNVERIFIED (503) and BCB_PERSISTENCE_NOT_CONFIGURED (503)
```

Session start was `200 passed, 3 skipped`. The 200 contained **no** writer or route test — the two
modules covering 23 tests skipped at module level, and pytest reports a module-level skip as one skipped
test, so the absence looked like a small gap rather than a total one. `scripts/run_project1_clone_tests.py`
now makes them executable from `backend/.env` without printing any credential.

## 4. Defects found and closed this session

| ID | Defect | State |
|---|---|---|
| `CP04A-D14` | Disclosure checked 2 of 9 conditions before `ensure_run`; the other 7 could leave an orphan `runs` row that `deny_mutation()` makes undeletable | **Closed** — full predicate extracted to `validate_synthetic()` and called pre-provisioning; 19 tests |
| `CP04A-D15` | `bdj_results` permitted `rejected` / unreviewed rows carrying `finding_count > 0` | **Closed** — `bdj_results_findings_require_review_check` |
| `CP04A-D16` | Three hand-typed copies of the `M2V1` pattern, two wrong (`0[01]` rejects `M2V1-02`..`09`) | **Closed** — one canonical literal + set-equality parity test |
| `CP04A-D17` | `PROJECT1_CLONE_URL` absent → 23 tests silently unexecuted | **Closed** — runner script; 23 now pass |
| `CP04A-D18` | `.env.env.bak.execprincipal` matched no ignore rule; `git add -A` would have staged live secrets | **Mitigated** — `**/.env.*` rule; rotation still required (§5) |

## 5. Credential exposure — what is fixed and what is not

**Fixed:** `backend/.env.env.bak.execprincipal` (created 01:46 today) held `SECRET_KEY`,
`SUPABASE_SECRET_KEY` and four database URLs and matched none of the earlier suffix-based rules.
`.gitignore` now ignores the whole `.env*` family and re-permits only `.env.example`; verified with
`git check-ignore`.

**Not fixed, and not fixable by `.gitignore`:**

1. **`backend/.env` is tracked.** Its working-tree version adds `TOKENHARBOR_API_KEY`,
   `M2_DATABASE_URL`, `PROJECT1_RUNTIME_DATABASE_URL`, `PROJECT1_AUDIT_DATABASE_URL`. Committing the
   working tree publishes them. An ignore rule has no effect on a tracked file.
2. **Three files under `backend/backups/` are already in git history**, including a 5.3 MB dump with 17
   tables. Untracking now does not remove them from history.
3. **The secret is on disk and in OneDrive sync history** regardless of Git.

**The only remedy is rotation**: `TOKENHARBOR_API_KEY`, `SUPABASE_SECRET_KEY`, `SECRET_KEY`, the
`p1ai_engine` and `p1ai_auditor` passwords, and any password appearing in the historical dump. Rotate
before any further commit of the working tree. A history rewrite is a separate decision and would
invalidate every commit hash cited across six reports.

## 6. Open blockers

| ID | Blocker | Owner action needed |
|---|---|---|
| `BLK-BCB-AUTH` | BCB authority undecided | B4-1…B4-4 (§ BCB decision sheet) |
| `MIG-AUTH-01` | How the app reads History | choose `SECURITY DEFINER` functions (B2-04) or another path |
| `B2` | Live provider dispatch | authorise one paid call, or accept fixture-only verification |
| `B3` | Encryption key custody | choose storage (ACL file + DPAPI recommended) |
| `CP04A-D13` | `/project1-read/assessments/{m2_id}/readiness` wired to the web store, 404s for every M2 assessment | decide: repoint, deprecate, or dual-source |
| `CP04B-D01` | `docs/cp00_integration/` is untracked | decide whether to commit the docs |
| `OD-3` | `M2V1-01` GEO question | **deferred — not touched** |
| `RETENTION` | `retention_until` unenforceable while `immutable_history` blocks `DELETE` | accept as known non-compliance or authorise a deletion path |

## 7. Preserved, deliberately

- FastAPI modular monolith — no service split, no new framework.
- M2 revisions and the deterministic BDJ path — untouched; the model-assisted route is a second,
  explicitly labelled entry point.
- Activity History V1 presentation — untouched; V1.1 is additive.
- PostgreSQL RLS and the restricted-principal contract — `p1ai_engine` + `SET LOCAL ROLE p1ai_runtime`,
  enforced in `ledger._scope()`.
- Historical evidence — `Dss` attempts, M2 and CQ records unchanged; no receipt was backfilled with a
  fabricated date.
- `OD-3` — `M2V1-01`, its GEO validation and its frontend semantics are unmodified. No geographic
  approval is claimed anywhere.

## 8. What is explicitly not claimed

1. A live provider call was never made.
2. The Dart DTO and Jaspr History rendering do not exist.
3. `Dss` has not been migrated.
4. BCB authority has not been granted and the resolver still refuses.
5. No scientific approval, publication authorisation, customer fielding or report release.
6. The `E2E-5` browser journey is `BLOCKED_OD3` and downstream.
