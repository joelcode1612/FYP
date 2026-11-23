# Stage 2 / Enhanced BDJ — Task Report

**HEAD** `33f20050c8d06282561c3d755d4b616574a88d79` · branch `merge_main_jed`
**Cluster** `project1_workflow_tests@127.0.0.1:5433` (disposable). Port 5432 never read or written.

| Task | Verdict | Note |
|---|---|---|
| 1 — Version-aware invalidation | **PARTIAL** | Implemented + 17 tests pass; positive path verified live. Supersession cannot be exercised live — no runtime role may write the revision chain. |
| 2 — `BCB-REPRO-02` diagnostics | **PASS** | 7 tests. Stable codes, no source leakage, refusal behaviour unchanged. |
| 3 — New synthetic M2 V2 assessment | **PASS** | 19/19 answers, confirmed, BCB built by the real builder, reproduces byte-identically twice. |
| 4 — Authorisation request | **EMITTED** | Exact record printed. **No row written. No dispatch enabled.** |
| 5 — Live TokenHarbour execution | **BLOCKED** | Awaits owner approval of Task 4 and `TOKENHARBOR_ENABLED=true`. |

---

## Task 1 — version-aware invalidation when a confirmed uncertainty changes

A confirmed uncertainty is immutable, but the owner may confirm a *newer version* of the same research intention. That supersession invalidated the old context without ever saying so: `read_current_objective` deliberately returns nothing once a child revision exists, so the refusal collapsed **"superseded by version N+1"**, **"never existed"** and **"source moved"** into one misleading answer.

**Change** — `backend/src/sitewise/services/persisted_business_context_service.py`
- New `_uncertainty_version()` classifies the packet's bound version as `CURRENT` / `SUPERSEDED` / `ABSENT` / `UNBOUND` / `UNREADABLE` using a new lineage read.
- `UNBOUND` is normal for M2 V2 packets (`confirmed_uncertainty = null` by contract).
- `UNREADABLE` is treated as **neutral**: a missing lineage capability is not evidence of staleness, so no store without the read is mass-invalidated.
- Supersession is classified **after** a failed rebuild, never instead of one — a successor carrying identical text still reproduces byte-identically and is correctly *not* called stale.
- `retrieve()` now raises `BCB_CONTEXT_UNCERTAINTY_SUPERSEDED` / `BCB_CONTEXT_UNCERTAINTY_ABSENT` instead of `BCB_CONTEXT_SOURCE_CHANGED` when a version event is the real cause.
- `status()` gains `uncertainty_version_status`, `superseded_by_objective_id`, `uncertainty_supersession_action`; `source_is_current` is now False for a superseded version even when the packet still rebuilds.

**Change** — `backend/src/sitewise/repositories/m2_repository.py`: `read_objective_version()` — owner-scoped, read-only, keeps the distinction the current-objective read discards.
**Change** — `backend/src/sitewise/api/v1/m2_business_context.py`: the three new fields are declared on `ContextStatusResponse` and validated against live payloads.

**Preservation guarantees (asserted, not assumed)**
- No M2 reconfirmation: supersession touches no assessment revision, no confirmed revision, no snapshot digest.
- No historical context rewritten: same `packet_hash`, same `canonical_body`.
- No writes during diagnosis: `commit()` count is zero on both the status and readback paths.

**Live evidence** (`var/e2e/task1_live_supersession.out`)

| Context | Bound uncertainty | Classifier | Compatible | Current |
|---|---|---|---|---|
| `50e1761a` (M2V1, entrepreneur objective) | set | `CURRENT` | True | True |
| `fa3cb714` (M2V2) | null | `UNBOUND` | True | True |
| `80dbc244` (M2V2) | set | `CURRENT` | True | True |

All three real payloads validate against the response model (`SERIALISES: True`).

**Why this is PARTIAL, not PASS.** A genuine supersession cannot be created in this cluster:

```
roles_that_may_write_the_chain : ['pg_write_all_data', 'postgres']
INSERT attempt as p1_m2_runtime : DENIED (SQLSTATE 42501)
```

`m2_research_revisions` and `m2_research_clarifications` have **no application-level writer**. Neither `p1_m2_runtime`, `p1ai_engine` nor `sitewise_e2e` holds INSERT, so `ConfirmationService.revise_objective()` cannot link a successor version under any runtime login. Granting that privilege is a governance change, so it was not made; the supersession path is covered by the 17 unit tests instead. Nothing was written during the attempt (`counts_unchanged: True`).

---

## Task 2 — `BCB-REPRO-02`

`_reproduces()` returned a bare `False`, so an operator could not tell a missing contract from a builder refusal from a hash mismatch. It now delegates to `_reproduction_failure()`, which returns a stable code and records it on `last_reproduction_failure`; `status()` exposes it as `context_incompatible_reason`.

Codes are exception **classes** and the contract's own `code` attribute — never a message, never a source value, never a packet fragment. The boolean contract and the refusal behaviour are unchanged. 7 tests in `tests/m2_bcb/test_reproduction_diagnostics.py`.

---

## Task 3 — new synthetic M2 V2 assessment

`var/e2e/task3_new_m2v2_assessment.py`, driven through the real services.

| | |
|---|---|
| Assessment | `4fc0abc2-ba52-4e41-aaa3-cf14fc822b37` |
| Instrument | `M2V2-20261122-1` (`PROPOSED_NOT_AUTHORIZED`, unchanged) |
| Answers | 19 / 19 → revision 19 |
| Confirmation | `337bf19e-326f-4643-9c06-d28b7a4cc1fe`, revision 19 |
| Snapshot digest | `e3453ad57a568af217b3d4e163cbbe5c90dbdbe92106e90510ab9dc030caf5c6` |
| Context | `6c719944-1b7b-59ea-be32-275a0f66c937` (BCB-V1-1.2.1) |
| Packet hash | `858c40d9ad07bec5bf2172f6682169cb798a5ab38fc2061b84c8f65f9609a2ba` |
| Rebuilt twice | byte-identical to stored hash |
| Readback | hash matches |
| Status | `compatible=True`, `reason=None`, `source_is_current=True`, `UNBOUND` |

Answer values were replayed from an already-confirmed assessment of the same instrument version, so they are known-valid against this instrument's conditional logic — nothing was invented to make the write path pass. Governance held: pre-existing contexts preserved, 0 proposals on the new assessment, total proposals unchanged, instrument state unchanged.

---

## Task 4 — the exact authorisation request (awaiting your approval)

Read live at `2026-11-23`; full record in `var/e2e/bdj_auth_request.out`.

```
stage                 BDJ_OBJECTIVE
data_class            SYNTHETIC_NONHUMAN
decision              APPROVED
max_attempts          1
owner_id              b9e62014-b7bc-426e-a950-a95b25965639
assessment_id         4fc0abc2-ba52-4e41-aaa3-cf14fc822b37
revision              19
confirmation_id       337bf19e-326f-4643-9c06-d28b7a4cc1fe
source_fingerprint    608b10b33c84377ca416bbf7f81d9a139d948922e95351c8ba4d16019b962dd2
context_packet_hash   858c40d9ad07bec5bf2172f6682169cb798a5ab38fc2061b84c8f65f9609a2ba
prompt_version        BDJ-OBJECTIVE-3-CAND
prompt_fingerprint    76027bfffbce17711fe2c9190bc610eb8e8bfaf8a57cf4a16913b87cddd7b8ab
endpoint              https://tokenharbor.ai/v1/chat/completions
model                 deepseek-v4.1-flash-1017
operator_receipt      <OWNER TO SUPPLY: unique reference, at least 8 characters>
```

Three things are required from you, and only you can supply them:

1. **`operator_receipt`** — a unique reference of at least 8 characters.
2. **Approval of this exact record.** Any change to assessment, revision, confirmation, source fingerprint, packet hash, prompt or model voids it; the gate then refuses with `DISCLOSURE_CURRENT_SOURCE_REQUIRED`.
3. **`TOKENHARBOR_ENABLED=true` for one attempt.** It is currently `false`.

The API key is present (length 73) but the gate does not depend on it: the cloud-dispatch requirement is bound to the real `TokenHarbor` class at import time, so no configuration switch can disable it, and a substituted adapter is not a cloud dispatch.

**Not done by this task:** no authorisation row was written, no cloud dispatch was enabled, no proposal was created. Writing that row *is* your consent to send synthetic declarations to a cloud model, so it was left to you.

---

## Task 5 — blocked

Not executed. Requires Task 4 approval plus `TOKENHARBOR_ENABLED=true`. The historical three `SIMULATED` proposals were not touched.

---

## Regression

`tests/project1`: **1512 passed, 25 failed, 3 skipped**. The 25 are the identical pre-existing set recorded in `var/e2e/junit_p1_after.xml` — `REGRESSIONS: none`, `NEWLY PASSING: none`.

Targeted suites: `tests/m2_bcb` + `test_bcb_contract_lineage.py` + `test_objective_proposal_route.py` + `test_objective_disclosure_mandatory.py` → **93 passed, 8 skipped**. Task 1 file 17/17; Task 2 file 7/7.

---

## Remaining blockers

1. **`BCB-INV-01` (new, blocking Task 1's live negative path).** `m2_research_revisions` and `m2_research_clarifications` have no application-level writer, so `revise_objective()` cannot succeed under any runtime role. Fixing this is a privilege grant, i.e. a governance decision — not taken.
2. **Live dispatch.** `TOKENHARBOR_ENABLED=false` and no operator-provisioned `synthetic_trial_authority` row. Awaiting your decision on the Task 4 record.
3. **`tests/api` still unbaselined** — no claim is made about it either way.

## Governance invariants held

`POLICY_ADOPTED = False` · 0/6 approved measurements · M2 V2 instrument still `PROPOSED_NOT_AUTHORIZED` · no O1–O6 promotion · no production QG authorisation · historical `SIMULATED` proposals unchanged · all pre-existing BCB contexts preserved byte-for-byte.
