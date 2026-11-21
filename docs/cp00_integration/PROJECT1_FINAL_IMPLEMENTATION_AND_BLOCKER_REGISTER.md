# PROJECT1 — Final Implementation and Blocker Register

**Date:** 2026-11-17 · **Branch:** `merge_main_jed` · **Base:** `ba30035ecb24b80fa155cc7049cf3cdf94a67844`
**Scope:** the full directive, CP-00 → CP-08.
**Status vocabulary:** `IMPLEMENTED` · `VERIFIED` · `BLOCKED` · `EXPECTED_HOLD` · `NOT_RUN` · `OWNER_DECISION_REQUIRED`

This register is the honest index. Where a checkpoint did not run, it says so and
names the blocker. No checkpoint is marked `VERIFIED` because its files exist.

---

## 1. Checkpoint status

| CP | Scope | Status | Decisive reason |
|---|---|---|---|
| **CP-00** | Baseline and dependency verification | **`VERIFIED`** | branch/commit/tree recorded, 74 relations mapped, roles and RLS enumerated, 9-attempt ledger classified, regression baseline reproduced (44F/478P/8E) |
| **CP-04A** | Cloud BDJ persistence + History V1.1 | **`IMPLEMENTED`** on clone · **`BLOCKED_DBA_AUTHORIZATION`** for `Dss` · **`BLOCKED`** for readback | schema built and proven 19/19 on `project1_workflow_tests`; app role has no `project1_ai` usage |
| **CP-04B** | BCB authoritative bindings | **`BLOCKED`** (re-measured, not re-guessed) | `STRUCTURAL=1/10 OPERATIONAL=0/10`; 7 authority artefacts absent. **But the code is proven**: 42 tests pass on a disposable cluster with fixture authority, so the blocker is authority, not implementation |
| **CP-05** | QJ, approved-bank matching, QG | **`NOT_RUN`** | the QJ/QG workflow *exists* (`project1/research.py`) but its `authority` and `bank` ports have no production implementation, and it consumes a BCB context that is `BLOCKED`. `attempts.stage` already permits `QJ`/`QG` |
| **CP-06** | Questionnaire, EE-01, explanation, R01–R12 | **`NOT_RUN`** | depends on CP-05 for an approved instrument; EE-01 and reporting exist but were not re-verified in this pass |
| **CP-07** | Full-workflow E2E (A–E) | **`NOT_RUN`** | E2E-A/B require CP-05; E2E-E is `BLOCKED_OD3` by the directive's own rule |
| **CP-08** | History V1–V2 acceptance | **`BLOCKED`** | V1 unchanged and preserved; V1.1 blocked on read path; V1.2/V2 depend on CP-04B/05/06 |

**Nothing in CP-05 through CP-08 was executed.** Stating that plainly is more
useful than a roadmap that implies progress.

---

## 1A. What already exists but is **not wired** (measured, not assumed)

This is the single most important correction in this register. Most of the chain
is already written. It is not missing — it is unreachable.

| Component | Where | Reachable from |
|---|---|---|
| `TokenHarbor` provider adapter | `src/sitewise/project1/tokenharbor.py` | scripts only |
| `ModelRunner` + `configured_runner()` | `src/sitewise/project1/runner.py` | **`configured_runner()` has zero callers** |
| `PostgresAttemptLedger` | `src/sitewise/project1/ledger.py` | scripts only |
| BDJ prompt contract | `PROMPTS['BDJ']` | scripts only |
| `SyntheticBdjDisclosure` | `src/sitewise/project1/disclosure.py` | scripts only; **rejects any `stage != 'BDJ'`** |
| QJ + QG workflow | `src/sitewise/project1/research.py` (`ResearchWorkflow.execute`, `validate_measurement`, `validate_draft`, `QJOutput`, `QGOutput`) | **tests only** |
| EE-01 evidence engine | `Ee01Service`, role `p1_ee01_runtime` | wired (restricted role) |
| Explanation module | exists | wired, but **deliberately never calls an LLM** (`llm_execution: 'NOT_ATTEMPTED'`) |

Absent entirely: an **approved question bank** implementation (`bank.lookup()` /
`verify_receipt()` are only *called*, never implemented), **QJ/QG routes**,
**R01–R12 report code** (placeholders only), and **`ReportAdmission`** (no module,
route or table).

**Why this matters for the directive.** The nine ledger attempts exist because
scripts drive the runner. No production request can reach it. So History has no
LLM results for **two independent reasons**: no route invokes the runner, *and*
no result store exists. CP-04A fixed the second. The first is a separate gap
(`BLK-RUNNER-UNWIRED`) and was not in the directive's explicit scope, but it
means V1.1 readback would show nothing even after the migration is applied.

**`AMB-ASSESSMENT-STORE` is RESOLVED (A6, 2026-11-17).** The table is **`public.assessment`**
(singular — earlier revisions of this register said `public.assessments`, which does not exist).
The governed chain uses `m2_assessments` exclusively: `cq_campaigns` 2/2,
`ee01_measurement_snapshots` 7/7, `project1_ai.runs` 9/9, and `assessment_workflow_projection`
all resolve to it; zero resolve to the web store. There is no link and none is needed. **CP-05
must be built against `m2_assessments` only.** Evidence:
`PROJECT1_ASSESSMENT_ASSOCIATION_VERIFICATION.md`.

One defect fell out of that verification: `dependencies.py:358` wires `Project1ReadService` to
`AssessmentService` → `public.assessment`, so `GET /project1-read/assessments/{m2_id}/readiness`
returns 404 for every M2 assessment while the rest of the chain serves it. Both id columns are
`uuid4`, so a wrong-store lookup fails silently rather than loudly. Not fixed — choosing the
target store is B5, because re-pointing it would assume the interchangeability the directive
forbids.

---

## 1B. CP-04B state (measured) — the BCB works; it is given no authority

The CP-04B re-measurement produced one finding that changes how the blocker
should be read, and one that changes how it should be fixed.

**The code is proven.** `tests/m2_bcb/run_isolated.py` builds a disposable
PostgreSQL 18 cluster, restores the read-only Dss schema into it, and runs the
full M2 → BCB path with a fixture resolver: **42 passed, 6 skipped, 4 xfailed,
0 failed**, `live_database_writes=false`. Construction, refusal codes, durable
holds, idempotency under concurrency, forged-scope rejection and instrument
withdrawal all behave correctly. "BCB is blocked" must therefore never be read
as "BCB does not work".

**The obstruction is one resolver, and it refuses on purpose.** All ten bindings
arrive through `resolve_inputs` → `UnverifiedContextBindings.resolve`, which
raises `BCB_BINDING_AUTHORITY_UNVERIFIED` unconditionally. A persisted receipt in
the live database records exactly that (`status=HELD`, `attempt_count=1`,
`context_id=NULL`, `m2_business_contexts`=0 rows), and `test_PG13` asserts the
production factory must return 503.

**Consequence for sequencing.** Replacing the resolver requires amending
`test_PG13` — i.e. deliberately retiring an assertion that exists to prevent
invented authority. That makes it a governed decision, not a bug fix. Any plan
that treats it as engineering-only will silently delete the guard.

| | CP-04 (prior) | CP-04B (this pass) |
|---|---|---|
| Bindings with a source | 1 of 10 | 1 of 10 (structural) |
| Bindings obtainable | not measured | **0 of 10** |
| Blocker description | missing tables | missing authority + one guarded resolver |
| Implied fix | build tables | 3 governance decisions → 4 artefacts → authorise resolver replacement |

Detail: `PROJECT1_CP04_BCB_AUTHORITY_AND_CONTEXT_REPORT.md`.

---

## 1C. CP-06 state (measured) — one engine is real, the rest is contract only

| Element | State | Evidence |
|---|---|---|
| **EE-01 evidence engine** | **`IMPLEMENTED` and independently verified** | `Ee01Service` runs as `p1_ee01_runtime`, deterministic Python over SQL, no model. `tests/cq_runtime/ee01_checks.py` re-derives every count with a **raw-SQL oracle** (`VERIFY_DSS_EE01_RAW_ORACLE.sql`) that never reads the snapshot rows. Official `percentage` is forced `NULL`; only `diagnostic_percentage` may be set, and only for `ISOLATED_TEST` |
| Questionnaire runtime | **`IMPLEMENTED`**, held | full session lifecycle + 28 `cq_*` tables; `/cq/availability` returns `PRODUCTION_FIELDING_HOLD` by design |
| **Publication / release admission** | **`NOT FOUND`** | no table, no service, no route. Only a `source_class` label (`ADOPTED`/`CANDIDATE`/`SYNTHETIC_FIXTURE`), a runtime `CqGrant`, and a contract that states `"grants": "NONE. No formal approval exists."` |
| Explanation module | **partial** | validation and contracts exist; the **approved deterministic template registry does not**, the **LLM path is never dispatched** (`PROMPTS['EXPLANATION']` has no caller, and the ledger stage allowlist is `('BDJ','QJ','QG')` with no `EXPLANATION`), and the required "use existing validated explanation else render template" fallback is **not implemented** |
| **R01–R12 reporting** | **`NOT FOUND`** | no report tables, no ReportAdmission record, no evidence appendix, no per-claim refs, no staleness/revalidation. `report_admission` is hard-locked to `Literal['NOT_VERIFIED']` |
| `ee01` research-source registry | **orphan** | schema exists in the live database but **no migration in the repository creates it** |

**The honest reading:** EE-01 is the one engine in the whole chain that is
implemented, deterministic and independently oracle-verified. It is also the one
the directive says must never be model-driven — and it isn't. That part can be
relied on today. Everything downstream of it (explanation fallback, R01–R12,
ReportAdmission) does not exist, so no report can be produced, admitted or shown.

---

## 2. Deliverable register (§19)

| # | Deliverable | State | Note |
|---|---|---|---|
| 1 | `PROJECT1_CLOUD_BDJ_PERSISTENCE_AND_SECURITY_REPORT.md` | **`DELIVERED`** | this checkpoint's substantive report |
| 2 | `PROJECT1_CP04_BCB_AUTHORITY_AND_CONTEXT_REPORT.md` | **`DELIVERED`** | re-measured against the builder, not restated: `STRUCTURAL=1/10 OPERATIONAL=0/10`. Supersedes the CP-04 headline for the verdict; CP-04 probe retained unmodified for comparison |
| 3 | `PROJECT1_CP05_QJ_QG_BANK_AND_REVIEW_REPORT.md` | **`NOT_RUN`** | no QJ/QG execution attempted; no QJ/QG code written |
| 4 | `PROJECT1_CP06_QUESTIONNAIRE_REPORT_INTEGRATION.md` | **`NOT_RUN`** | — |
| 5 | `PROJECT1_ACTIVITY_HISTORY_V1_TO_V2_FIDELITY_REPORT.md` | **`PARTIAL`** | V1 fidelity already proven and preserved; V1.1–V2 not achievable |
| 6 | `PROJECT1_FULL_WORKFLOW_E2E_VERIFICATION.md` | **`NOT_RUN`** | — |
| 7 | `PROJECT1_R01_R12_TRACEABILITY_MATRIX.md` | **`NOT_RUN`** | requires CP-06 |
| 8 | `PROJECT1_FINAL_IMPLEMENTATION_AND_BLOCKER_REGISTER.md` | **`DELIVERED`** | this file |
| 9 | Updated file-structure and dependency snapshots | **`DELIVERED`** | `docs/cp00_integration/snapshots/` from CP-03F; tree unchanged this pass (0 deleted, 0 renamed), so the snapshot remains accurate |

Producing 3, 4, 6 and 7 as documents with no evidence behind them would be the
"another implementation roadmap" the directive explicitly rejects. They are
recorded as `NOT_RUN` instead.

---

## 3. Blocker register

| ID | Blocker | Blocks | Owner action required |
|---|---|---|---|
| `MIG-AUTH-01` | `project1_ai` is frozen against every application principal. `p1_m2_runtime` has no `USAGE` on the schema; `p1ai_engine` has no `USAGE` either and is designed to be entered via `SET LOCAL ROLE p1ai_runtime` | CP-04A readback, History V1.1, all of CP-05/06 | decide whether the M2 request path may read the AI ledger, and through which connection |
| `BLK-DBA-APPLY` | no DBA-controlled migration procedure is available to this checkpoint | applying `20261117_02` / `_03` to `Dss` | run the reviewed migration through the authorised procedure |
| `BLK-BCB-AUTH` | **re-measured CP-04B: `STRUCTURAL=1/10`, `OPERATIONAL=0/10`.** 9 bindings have no source; the 10th (uncertainty) has a correctly linked row but is still unobtainable, and its absence is the one the builder tolerates. All 10 are gated behind one resolver, `UnverifiedContextBindings`, whose refusal is asserted by `test_PG13` | CP-04B → CP-05 → CP-06 → CP-07 | 3 governance decisions (tenancy model, approved geography source, access policy) → 4 engineering artefacts → **authorise replacing the resolver and amending `test_PG13`** |
| `BLK-MIG-RECEIPT` | `20261116_02` and `20261117_01` were applied but never wrote a `schema_versions` receipt, so the ledger cannot be trusted as applied-state | safe re-application anywhere | backfill receipts or adopt object-based state verification |
| `OD-3` | `M2V1-01` (REQUIRED, `GEO`) is inert in the panel | E2E-E, a fresh UI-completed assessment | **explicitly DEFERRED by the Owner** — not touched |
| `CP04A-D06` | `m2_workflow_summary.summary->'campaigns'` is `NULL` for the app role (`cq_*` policies are `p1_ee01_runtime`-only) | History V1.2 campaign section | approve a scoped grant migration |
| `CP04A-D08` | `m2_candidate_review_assignments`: RLS enabled, zero policies | silent-empty the day it is used | approve a policy migration |
| `BLK-RUNNER-UNWIRED` | `configured_runner()` has zero production callers; no route composes a runner | cloud BDJ can only be driven by scripts | authorise an API entry point for cloud BDJ |
| `BLK-FINDING-GRANT` | `p1ai_runtime` has no grant on `public.m2_bdj_findings`, so a cloud result cannot write a finding under the restricted principal | finding-level admission from a cloud result | approve a scoped grant, or keep findings on the deterministic path only |
| `BLK-KEY-MGMT` | no encryption helper exists; `cryptography` is present in the venv but is not a declared dependency | the protected raw-response store | approve a key-management decision and the dependency |
| `BLK-VOCAB` | `admission_status` in the new DDL does not match the Python admission vocabulary (`held`/`rejected`/`reviewed`/`stale`) | applying `20261117_03` for real | reconcile the vocabulary before application |
| `CP04A-D09` | raw model output exists only as untracked plaintext files under `backend/backups/` | any claim of protected retention | retention decision, then migrate or delete |
| `CP04A-D10` | `backend/migrations/project1_ai/` is untracked in git | migration history / reviewability | commit the migration directory |
| `CP04B-D01` | **`docs/cp00_integration/` and `docs/architecture/` are entirely untracked** (`git ls-files docs/cp00_integration` → empty; `git status` reports both as `??`). Every CP-00…CP-04B report and every Activity History acceptance record exists only as working-tree files | independent review, audit trail, any claim that this evidence is version-controlled | authorise a scoped commit of the two documentation trees. Not committed here — a commit is a governance action this checkpoint was not authorised to take |
| ~~`AMB-ASSESSMENT-STORE`~~ | **RESOLVED (A6)** — the stores are `public.m2_assessments` (chain, 18 rows) and `public.assessment` (web, 0 rows in `Dss`). No relationship; none needed; chain is 100% M2 | — | no longer blocking CP-05 |
| `CP04A-D13` | `GET /project1-read/assessments/{m2_id}/readiness` returns 404 for every M2 assessment: `dependencies.py:358` wires `Project1ReadService` to the **web** store. Has a live `shared_logic` client | the readiness surface; the R01–R12 gate UI | choose B5-A / B5-B / B5-C, then implement |

---

## 4. What was actually built or reused

### Built

| File | What |
|---|---|
| `backend/migrations/project1_ai/20261117_03_bdj_result_persistence.sql` | 5-table additive persistence extension (provenance, structured result, sources, validation, finding decisions, encrypted original response) |
| `backend/scripts/cp04a_clone_migrate.py` | applies the candidate migrations to the isolated clone; proves idempotency refusal |
| `backend/scripts/cp04a_clone_security_verify.py` | 19-check authorisation and constraint matrix |

### Reused, not duplicated

| Existing thing | Reused as |
|---|---|
| `project1_ai.runs` / `attempts` / `attempt_receipts` | provenance source; the new result table FKs into `attempts`, it does not copy it |
| `project1_ai.deny_mutation()` | append-only trigger on all five new tables |
| `owner_scope` + `technical_audit_read` policy pattern | identical posture to the existing ledger |
| `p1ai_runtime` / `p1ai_audit` / `p1ai_owner` | same three-role split, no new roles invented |
| `20261117_02_finding_provenance.sql` | applied to the clone to validate the pre-existing candidate |
| `public.m2_bdj_findings` | FK target for finding-level admission decisions |

**No new role, no new schema, no change to any existing table.**

---

## 5. Database changes and authority

| Item | State |
|---|---|
| Changes to `Dss` | **none** — `schema_versions` still holds only `20261111_01_candidate`; `to_regclass('project1_ai.bdj_results')` is `NULL` |
| Changes to `project1_workflow_tests` (clone) | 5 tables + 1 pre-existing candidate migration applied |
| Roles modified | none |
| RLS weakened | **no** — five tables had RLS forced and two policies added each |
| Superuser used | read-only inspection, and DDL **only inside the clone**, stated explicitly |

---

## 6. Security outcomes

- 19/19 checks passed, each for the mechanism named in the CP-04A report.
- Cross-owner read returns 0 rows; cross-owner write is refused by the policy.
- Unbound actor sees 0 rows.
- Append-only enforced twice over: no `UPDATE`/`DELETE` grant for the runtime, and a trigger for the owner.
- The protected raw response is write-only for the runtime.
- Two checks initially passed for the wrong reason and were corrected rather than reported.

---

## 7. Real versus synthetic execution

| Claim | Classification |
|---|---|
| 9 ledger attempts exist | `VERIFIED` (rows counted) |
| ≥3 are synthetic fixtures | `VERIFIED` (placeholder fingerprints `aaa…`, `ccc…`, `ddd…`) |
| The other 6 are real provider calls | **`UNDETERMINED`** — no request id, model id or response body exists to corroborate |
| Any attempt produced a validated result | **`VERIFIED` false** — no store exists |
| Any attempt produced an admitted finding | **`VERIFIED` false** — `m2_bdj_findings` = 0 rows |
| Any LLM output is visible in Activity History | **`VERIFIED` false**, and structurally impossible today |

---

## 8. What this checkpoint did **not** do

- Did not apply any migration to `Dss`.
- Did not grant the application role access to `project1_ai`.
- Did not weaken RLS, and did not use a superuser to obtain a result the app could not.
- Did not invent a QJ/QG implementation on top of a `BLOCKED` BCB.
- Did not touch `M2V1-01` / OD-3.
- Did not write a History V1.1 endpoint, because there is no authorised read path to serve it.
- Did not claim the nine attempts are real model calls.
- Did not produce documents 3, 4, 6 or 7 as if they had evidence.

---

## 9. Next authorised step, in dependency order

1. **Decide `MIG-AUTH-01` read path** — may the M2 request context read `project1_ai` through `p1ai_engine` with `SET LOCAL ROLE p1ai_runtime`? Until this is answered, no amount of History work can surface a result.
2. **Run `20261117_02` + `_03` through the DBA procedure** — the SQL is reviewed and clone-proven; only authority is missing.
3. **Backfill the two missing migration receipts** (`BLK-MIG-RECEIPT`).
4. **Approve `CP04A-MIG-02`** for the `cq_*` read scope, closing the `campaigns: null` defect.
5. **Decide the three CP-04B governance questions** — tenancy model, approved GEO source, access policy. These are the only things standing between a proven BCB and a usable one; they cannot be answered by engineering.
6. Only then: History V1.1 readback, then the four CP-04B engineering artefacts plus authorisation to replace `UnverifiedContextBindings` (which requires amending `test_PG13`), then CP-05.

Steps 1–5 are decisions and procedures, not code. Step 6 is code.

---

## 10. Overall verdict

**`PARTIAL` — one checkpoint delivered with evidence, six blocked or not run, all
blockers named.**

The durable persistence contract the directive asked for exists, is applied to an
isolated clone, and is proven by 19 independent security and constraint checks.
It is not applied to a real database and is not readable by the application,
because both require authority this checkpoint does not hold. Those boundaries
were recorded, not crossed.

CP-04B was re-measured rather than restated, and the correction is worth more
than the number: the Business Context Builder is **not** broken — 42 tests pass
on a disposable cluster once authority is supplied. It is given none, by a
resolver that refuses on purpose and a test that asserts it must. That is a
governance blocker wearing an engineering costume, and it should be answered as
one.
