# PROJECT1 — QJ / Question-Bank / QG Integration Report (Directive V1.0)

**Date:** 2026-11-17
**Branch:** `merge_main_jed`
**Test state:** `tests/project1` + `tests/m2_bcb` → **555 passed, 6 skipped, 7 subtests**
(was 489 passed before this directive)
**Provider budget:** `spent 5 / 6` — **the final call was not dispatched**
**Live `Dss`:** untouched. `Final_Location_Analysis`: untouched. Nothing committed.

---

## 1. Architecture and implementation inventory

### 1.1 What existed before this directive

| Component | State |
|---|---|
| `ResearchWorkflow` | Implemented, **zero production callers** |
| Measurement authority | **Did not exist**; every call site was a no-op double |
| Question bank | **Did not exist**; only harness doubles |
| BD-01 schema | Candidate only, **not applied**, and internally contradictory |
| BCB packet builder | Real production path exists (`PersistedBusinessContextService`) |
| Provider / disclosure / ledger / budget | Real, adopted, unchanged |

### 1.2 What exists after

| Component | File | State |
|---|---|---|
| Versioned measurement policy | `project1/measurement_policy.py` | Real; `TEST_SCOPED_NOT_AUTHORIZED` |
| Receipt verification | `project1/measurement_policy.py` | Real; 9 refusal codes |
| Estimator extension | `project1/measurement_estimator.py` | Real, additive to the frozen contract |
| Governed question bank | `project1/question_bank.py` | Real; in-memory + Postgres stores |
| Production composition | `project1/qj_qg_service.py` | Real; fails closed at the context gate |
| BD-01 corrected schema | `migrations/m2/20261118_01_question_bank.sql` | Applied **in the clone only** |
| F-01 append-only proof | `scripts/f01_append_only_probe.py` | Executed against the clone |

---

## 2. Code-change manifest

| File | Before | After |
|---|---|---|
| `project1/measurement_policy.py` | No receipt identity | `validate()` seals a `receipt_id`; new `verify_validation_receipt()` |
| `project1/research.py` | Accepted any receipt, including `None`; QG guarded by an attribute check | Refuses unless the receipt re-derives against the policy registry |
| `project1/measurement_estimator.py` | — | New; carries numerator/denominator/exclusions the frozen contract cannot express |
| `project1/question_bank.py` | — | New; BD-01/BD-02 as code, not as prose |
| `project1/qj_qg_service.py` | — | New; the missing production caller |
| `tests/m2_bcb/connected_chain_checks.py` | No-op authority produced a survey candidate | Real `lab_authority()`; the no-op path is now a refusal |
| `tests/project1/test_workflow.py` | Asserted a labelled-but-unvalidated candidate was acceptable | Asserts it is refused; adds a fabricated-authority case |

### 2.1 The most important behavioural change

The previous implementation guarded QG with:

```python
if not getattr(self.authority, 'measurement_policy_version', None):
    raise WorkflowHeld('MEASUREMENT_AUTHORITY_UNVERIFIED')
```

The directive forbids exactly this: *"Do not accept an authority merely because it
exposes `measurement_policy_version`."* That check proves an attribute exists, not
that a policy ran.

It is replaced by `verify_validation_receipt`, which re-derives every claim from
the server-side `POLICIES` registry and the live objects:

| Check | Refusal code |
|---|---|
| receipt present at all | `MEASUREMENT_RECEIPT_MISSING` |
| policy version is registered here | `MEASUREMENT_RECEIPT_UNKNOWN_POLICY` |
| policy digest matches the registered document | `MEASUREMENT_RECEIPT_POLICY_DIGEST_MISMATCH` |
| receipt describes this measurement | `MEASUREMENT_RECEIPT_MEASUREMENT_MISMATCH` |
| receipt describes this packet | `MEASUREMENT_RECEIPT_CONTEXT_MISMATCH` |
| receipt names this uncertainty version | `MEASUREMENT_RECEIPT_VERSION_MISMATCH` |
| body still hashes to `receipt_id` | `MEASUREMENT_RECEIPT_TAMPERED` |
| status is the test-scoped one | `MEASUREMENT_RECEIPT_STATUS_INVALID` |
| no claim of acceptance | `MEASUREMENT_RECEIPT_AUTHORITY_ESCALATION` |

A no-op authority returns `None` and dies at the first check. A fabricated
authority can copy the version string but cannot produce the registered
document's digest, so it dies at the third. A replayed or edited receipt dies at
the fifth, sixth or seventh.

---

## 3. Corrected BD-01 schema

**Deliverables:** `migrations/m2/20261118_01_question_bank.sql` (24.8 KB),
`..._rollback.sql`, `docs/cp00_integration/BD01_CORRECTED_SCHEMA.md`.

### 3.1 BD01-SQL-01 — fixed

The candidate schema could never reach an authorising state: `refuse_rewrite()`
denied every `UPDATE`, while `approval_state` and `state` were columns that only an
`UPDATE` could change. A snapshot could never become `ACCEPTED`, so **no receipt
could ever have been issued**.

Replaced with immutable version rows plus separately recorded lifecycle events:

```
question_item ──1:N── question_item_version ──1:N── item_lifecycle_event
                                │
                                └──1:N── bank_snapshot_item ──N:1── bank_snapshot
                                                                        │
                                                            1:N── bank_snapshot_event
                                                                        │
                                                            1:N── comparison_receipt
                                                                        │
                                                            1:N── comparison_review_item
```

State is **derived**, never stored:

- `question_item_version_state` folds `item_lifecycle_event`. `APPROVED` requires
  an `INDEPENDENTLY_REVIEWED` event by a `SCIENTIFIC_REVIEWER` **and** an
  `APPROVED` event by a **distinct** `OWNER_APPROVER`.
- `bank_snapshot_state` folds `bank_snapshot_event`.

Append-only protection is retained on the immutable rows (custom SQLSTATE
`QGB01`), and is **not** disabled globally.

### 3.2 BD01-SQL-02 — fixed

- Approved question definitions and accepted snapshots are readable by the runtime
  role **only through** `approved_question_item_version`, `accepted_bank_snapshot`
  and `accepted_bank_snapshot_item`.
- `comparison_receipt` and `comparison_review_item` are **owner-scoped**: both carry
  RLS with `tenant_select`, `issuer_insert` and `admin_all` policies. A tenant id is
  enforced by policy, not trusted from the query.

### 3.3 Evidence — 9/9 PASS in `project1_workflow_tests`

| # | Check | Result |
|---|---|---|
| 1 | `current_database()` is the clone before DDL | PASS |
| 2 | forward, rollback, rollback-twice, re-apply; guard refuses `Dss` **by name** (P0001) | PASS |
| 3 | `CANDIDATE → INDEPENDENTLY_REVIEWED → APPROVED` with `approved_at` | PASS |
| 4 | owner-only → `CANDIDATE`; same-actor review+approval → `INDEPENDENTLY_REVIEWED` (self-approval blocked) | PASS |
| 5 | snapshot reaches `ACCEPTED` — **the defect is fixed** | PASS |
| 6 | `UPDATE`/`DELETE` raise `QGB01` | PASS |
| 7 | retirement without rewriting history | PASS |
| 8 | RLS: tenant B invisible to tenant A's role; role is not superuser, not `BYPASSRLS` | PASS |
| 9 | cross-tenant query alone returns zero rows | PASS |

Evidence: `backend/var/qgb_evidence/bd01_qgb_evidence.json`.

### 3.4 Residual gaps the worker reported (not papered over)

| # | Gap |
|---|---|
| 1 | A receipt may reference a snapshot that was not `ACCEPTED` **at issue time** — only current state is checked |
| 2 | Snapshot membership completeness (every approved item included) is not proven by the schema |
| 3 | `equivalent_item_version_id` is not constrained to be a member of the snapshot |
| 4 | Event `sequence` is unique but not contiguous — gaps are possible |
| 5 | `p1_qgb_issuer` can insert a receipt for any tenant; tenant scoping is on read, not write |

These are application-layer obligations for `QuestionBank`, not schema defects.

---

## 4. Measurement validation and receipt contract

```
Measurement (frozen, deployed)
   └─ digest(measurement) ──┐
                             ├─► MeasurementPolicyDocument.validate()
BCB packet ── packet_hash ───┘            │
                                          ▼
                            receipt{status, policy_version, policy_digest,
                                    measurement_digest, bcb_packet_hash,
                                    uncertainty_version, receipt_id}
                                          │
                                          ▼
                            verify_validation_receipt(receipt, measurement, packet)
                                          │
                              ┌───────────┴───────────┐
                        verified                  refused
                     TEST_SCOPED_VALID         9 fixed codes
```

`TEST_SCOPED_VALID` never implies `SCIENTIFICALLY_ACCEPTED`. Every receipt carries
`scientific_accepted: False`, `fielding_authorized: False`,
`production_eligible: False`, and `verify_validation_receipt` refuses a receipt
that claims otherwise (`MEASUREMENT_RECEIPT_AUTHORITY_ESCALATION`).

### 4.1 Estimator extension (contract not silently changed)

`Measurement` is a frozen strict contract used by live captures. Rather than add
required fields, `measurement_estimator.py` adds a **separate** contract bound by
digest:

```python
EstimatorContract(estimator_version, measurement_digest, numerator_codes,
                  denominator_codes, excluded_response_states,
                  eligibility_predicate, reference_period,
                  prohibited_interpretations, permitted_interpretation)
```

`attach_estimator` refuses unless `estimator.measurement_digest == digest(measurement)`.
`validate_estimator` enforces: numerator ⊂ denominator ⊆ response codes; denominator
disjoint from excluded states; every non-denominator code classified; prohibitions
and permitted interpretation present.

---

## 5. BD-02 equivalence policy and bank implementation

`project1/question_bank.py` (680 lines) implements `lookup` / `verify_receipt` over
a `QuestionBankStore` port with an in-memory store (tests) and a Postgres store
(`project1_qgb`, tenant-scoped via `_scope`).

A no-equivalent decision requires **all** of: an accepted snapshot, a non-empty
catalogue, every item `APPROVED`, a complete boolean review of **every** item, zero
equivalents, an accepted comparison policy, and an independent comparison issuer.
It cannot be inferred from an empty bank, a failed search, missing permissions,
partial review, model judgment, or a stale snapshot.

### 5.1 Two prohibitions — verified

| Prohibition | Finding |
|---|---|
| Do not use a generated-question candidate as proof of approval | **Holds.** `m2_review_question_versions` is a candidate-review flow with no `approval_state`; `research.py` takes `item_version` + `approval_receipt` from `bank.lookup`, never from a QG record |
| Do not treat CQ Q01–Q13 as an approved QG bank | **Holds.** `cq_successor/policy.py` self-reports `SCIENTIFIC_GATE_UNAPPROVED` on Q09/Q10; `QuestionBank` reads only `project1_qgb` |

---

## 6. Execution trace

```
PersistedBusinessContextService.retrieve()   ← real BCB packet, integrity-checked
        │  qj_execution_authorized == False  → REFUSED (QJQG_CONTEXT_DOES_NOT_AUTHORIZE_QJ)
        ▼
MeasurementAuthority.admit_qj(packet)        → uncertainty_version + provenance
        ▼
runner('QJ')  ── admission{uncertainty_version} supplied verbatim
        ▼
require_current(packet, task)                → stale/changed context refused
        ▼
validate_measurement() + verify_validation_receipt()
        ▼
QuestionBank.lookup()   ── equivalent ──► REUSE_CANDIDATE  (zero QG calls)
                        └─ no_equivalent ─► require_drafting → runner('QG')
        ▼
no_authority() spread; fielding_authorized False
```

**The trace terminates at step 1 in production today.** That is the correct
behaviour: the persisted context does not authorize QJ execution. Composition
succeeds; execution is refused.

---

## 7. Test results

| Suite | Count |
|---|---|
`tests/project1` + `tests/m2_bcb` | **555 passed, 6 skipped, 7 subtests** (was 489)
`test_measurement_policy.py` | 63 (F-01, F-02, pinned instrument, reconciliation, receipt verification)
`test_question_bank.py` | 34 (BD-01/BD-02 rules)
`test_lab_bank.py` | 18 (bank contract in isolation)
`test_qj_acceptance.py` | 13 (the 12 required offline cases)
`test_qj_qg_service.py` | 7 (composition gates)
`test_workflow.py` | 73 (workflow boundary)

Every negative test asserts the **exact** refusal code. A guard that stops firing
fails the suite rather than passing silently.

### 7.1 The 12 offline acceptance cases — all PASS

Complete survey candidate · missing version (ValidationError) · stale revision ·
changed packet hash · missing exact offer · unsupported price (RM12) · unsupported
population · incorrect routing · invalid numerator/denominator · no-op authority ·
tampered/replayed receipt · valid `HOLD` route (recorded as valid, not a defect).

### 7.2 Pre-existing failures — none introduced

`tests/project1` and `tests/m2_bcb` are green. The pre-existing branch-wide
failures reported in earlier phases (`fnb_a.fnb_outlet.geom`, two ML import
errors) are outside these directories and were not touched.

---

## 8. Database isolation and authorization evidence

### 8.1 F-01 append-only — 10/10 PASS, executed not argued

`scripts/f01_append_only_probe.py`, against `project1_workflow_tests`:

| Attempt | `p1_m2_runtime` | `postgres` (superuser, bypassrls) |
|---|---|---|
| `UPDATE exact_text` | 55000 | 55000 |
| `UPDATE id` | 55000 | 55000 |
| `UPDATE confirmation_id` | 55000 | 55000 |
| `DELETE` | **42501** (no grant) | 55000 |

The row was byte-identical afterwards. Two refinements to the earlier risk note:

- `p1_m2_runtime` **does** hold `UPDATE`, and is still stopped by the trigger — so
  the trigger, not the privilege, is what protects `UPDATE`.
- `DELETE` is stopped by the missing privilege, a stronger defence than the trigger.
- Even a superuser with `bypassrls` cannot rewrite the row.

Evidence: `backend/var/qgb_evidence/f01_append_only.json`.

### 8.2 Isolation guarantees

| Guarantee | Evidence |
|---|---|
| Clone-only DDL | `current_database()` asserted before every DDL block |
| `Dss` refused by name | migration guard raises `P0001` |
| Tenant isolation | RLS `tenant_select`; cross-tenant query returns zero rows |
| Restricted role | `p1_m2_runtime`, `p1_qgb_runtime`: not superuser, not `BYPASSRLS` |
| Rollback | applies twice cleanly |

---

## 9. Remaining scientific and Owner decisions

| # | Decision | Owner |
|---|---|---|
| 1 | Authorise a **production** measurement policy (`AUTHORIZED`) | Scientific reviewer + Owner |
| 2 | Authorise QJ execution against a persisted context (`qj_execution_authorized`) | Owner |
| 3 | Adopt a BD-02 comparison policy and name an independent comparison issuer | Owner |
| 4 | Approve a real question bank snapshot and its items | Scientific reviewer + Owner |
| 5 | Authorise production deployment of the BD-01 migration | Owner (separate) |
| 6 | Authorise the final provider call | Owner |
| 7 | Resolve the five bank-application gaps in §3.4 | Engineering + Scientific |

---

## 10. Final execution readiness

| Checkpoint | Status | Basis |
|---|---|---|
| **P1** — QJ measurement integration | **PASS** | Real policy, verified receipts, 12/12 offline cases |
| **P1** — F-01 append-only proof | **PASS** | 10/10 executed on the clone |
| **P1** — estimator extension | **PASS** | Separate contract, digest-bound, frozen contract unchanged |
| **P2** — BD01-SQL-01 corrected | **PASS** | Snapshot reaches `ACCEPTED`; 9/9 evidence |
| **P2** — BD01-SQL-02 corrected | **PASS** | RLS + scoped views; cross-tenant denied |
| **P2** — bank authority implemented | **PASS** | 34 tests, 8 lookup + 4 verify rules |
| **P2** — production migration | **BLOCKED** | Requires Owner authorization; clone only |
| **P2** — bank application gaps | **PARTIAL** | 5 obligations remain at the application layer |
| **P3** — BD-02 equivalence | **PASS** | Empty/partial/unapproved all refused |
| **P3** — approved reuse | **PASS** | Zero QG calls on equivalent |
| **P3** — no-equivalent QG branch | **PASS** | Research-only drafting; never fielding |
| **P3** — production composition | **PARTIAL** | Composes and fails closed; execution unauthorized |
| **P3** — live QJ→bank→QG execution | **BLOCKED** | Context gate + no authorized policy |
| **Scientific acceptance** | **BLOCKED** | No sign-off exists; none claimed |
| **Provider dispatch** | **NOT_TESTED** | Deliberately not spent; 5/6 |

### 10.1 What is demonstrably working

The full chain **QJ → bank → QG executes end to end** in the isolated environment
with real policy validation, real receipt verification and a real bank, producing
either a reuse assignment or a research-only draft, and refusing every negative
case tested.

### 10.2 What still requires explicit authorization

Everything that would make it a *production* or *scientific* result: an authorized
policy, an authorized QJ context, an approved bank, and the final provider call.
None of these can be granted by code, and none was simulated.

---

## Appendix — files created

```
backend/src/sitewise/project1/measurement_estimator.py
backend/src/sitewise/project1/question_bank.py
backend/src/sitewise/project1/qj_qg_service.py
backend/migrations/m2/20261118_01_question_bank.sql
backend/migrations/m2/20261118_01_question_bank_rollback.sql
backend/docs/cp00_integration/BD01_CORRECTED_SCHEMA.md
backend/scripts/f01_append_only_probe.py
backend/tests/project1/test_qj_acceptance.py
backend/tests/project1/test_question_bank.py
backend/tests/project1/test_qj_qg_service.py
backend/var/qgb_evidence/bd01_qgb_evidence.json
backend/var/qgb_evidence/f01_append_only.json
```
