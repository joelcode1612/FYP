# PROJECT1 — F-01, F-02, BD-01, BD-02 Integration Report

**Date:** 2026-11-17
**Scope:** integration of the governance corrections delivered in
`PROJECT1_QJQG_F01_F02_BD01_BD02_FIX_20261117.zip`
**Status:** `INTEGRATED_TEST_SCOPED` — no production authority created, no approval claimed
**Provider budget:** `spent 5 / limit 6` — **the final free call was NOT spent**

---

## 1. Package intake and verification

| Item | Result |
|---|---|
| Manifest `sha256sum -c` | **8/8 OK** |
| Package reference suite | **28 passed** (reproduced independently, 0.005s) |
| `reference_impl/governance_reference.py` imported into production | **No** — reimplemented from the rules, as the package requires |

The reference implementation is stdlib-only and carries the header "Do not
directly import this code into the production FastAPI service". Nothing in this
integration imports it. The rules were re-expressed against the real contract
(`Measurement`, `WorkflowHeld`, `digest`) in a new production module.

---

## 2. F-01 — the uncertainty version was unguessable

### Root cause, confirmed

`Measurement.uncertainty_version` is a required field
(`contracts.py:57`). `ResearchWorkflow._evaluate` resolved the expected value
server-side (`research.py:139-140`) and compared it (`:152`). But:

* the string `uncertainty_version` did not appear **anywhere** in `prompts.py`;
* the packet's `confirmed_uncertainty` carries only `id`, `confirmation_id`,
  `actor_user_id`, `exact_text` (`business_context_v1.py:352`) — no version field;
* the QJ input was the bare packet, with no statement of the convention.

So the model had to emit a UUID it was never shown. The survey branch was
reachable only by guessing. This is a defect in the *instruction*, not in the
model.

### Evidence that the id is admissible as a version label

| Claim | Evidence |
|---|---|
| Unique | `m2_confirmed_uncertainties.id UUID NOT NULL, PRIMARY KEY (id)` — `supabase/migrations/20261107133000_m2_upstream_foundation.sql:158-165` |
| Immutable | `m2_bcb_append_only BEFORE UPDATE OR DELETE` applied to `m2_confirmed_uncertainties` — `migrations/m2/20261113_01_confirmed_context_persistence.sql:122-129` |
| Revision mints a **new** id | `m2_research_revisions(parent_id PRIMARY KEY, child_id UNIQUE NOT NULL)` — `migrations/m2/20261114_02_research_objective_sources.sql:24-28` |
| Revision is a real write path, not a uuid convention | `confirmation_service.py:235-259` — `revise_objective` inserts a new uncertainty row for the child |
| Ids are server-generated | `m2_repository.py:419-423` (`uuid4()`) |
| Bound to exactly one confirmation | builder refuses a mismatch: `business_context_v1.py:346-351` ("UNCERTAINTY_UNCONFIRMED"); `m2_confirmation_snapshots` is `UNIQUE (assessment_id, assessment_revision)` |

**Verdict: `IMMUTABLE_PROVEN`, with one qualification that must not be lost.**

The map `id → (confirmation, revision, text)` is functional and immutable. The
converse is **false**: `revise_objective(CLARIFY)` mints a new child id even when
the text is unchanged, so two ids may carry identical text.

That direction is required, not tolerated. A version labels a confirmation
*event*; a re-confirmation is a new event whose ancestry differs. A text-derived
label would collide across those events and make the ancestry walk in
`execute_objective` (`research.py:93-100`) ambiguous. The rule is
"same id implies same version", never "same text implies same version".

**Residual risk recorded:** immutability rests entirely on the trigger.
`p1_m2_runtime` holds an `UPDATE` grant on the table and the table is not
`FORCE ROW LEVEL SECURITY`, so a role able to disable the trigger could rewrite a
row. The trigger is the mechanism; it is not additionally defended. A DB-level
`UPDATE`-must-fail test was **not** added (see §8).

### Change

New module `src/sitewise/project1/measurement_policy.py`:

* `resolve_uncertainty_version(packet)` — derives the label from the packet with
  full provenance (`basis`, `rule`, `confirmation_id`, `assessment_revision`,
  `exact_text_digest`, `packet_hash`). Refuses six malformed identities.
* `composite_uncertainty_version(packet)` — the fallback rule for deployments that
  cannot prove immutability. Retained, not default.
* `MeasurementAuthority.admit_qj` returns the resolved value plus its basis;
  `require_current` re-resolves after the model call and refuses a changed
  context; `validate_measurement` refuses a stale admission.

`research.py` now puts the value in the input verbatim:

```python
admission = {'uncertainty_version': uncertainty_version,
             'uncertainty_version_basis': task.get('uncertainty_version_basis'),
             'uncertainty_version_rule': task.get('uncertainty_version_rule'),
             'policy_version': task.get('policy_version'),
             'authorization_status': task.get('authorization_status')}
qj_input = {'context': packet, 'admission': admission}
```

`prompts.py` — QJ prompt **v1 retired, v2 registered** (`QJ-MEASURE-2-CAND`):

> `measurement.uncertainty_version` must be copied character for character from
> `admission.uncertainty_version`. Never derive, reformat, abbreviate or invent
> it, and never reuse a value from an earlier task; any other value rejects the
> candidate.

A second worked example was added showing a survey-shaped output, because no
example previously demonstrated that shape at all.

---

## 3. F-02 — every validator was a no-op

### Actual authority status

| Call site | Authority bound | Validates? |
|---|---|---|
| `research.py:155` (workflow) | whatever the caller passes | **depended on caller** |
| `tests/project1/test_workflow.py:205` | `validate_measurement(self,*a): pass` | **NO-OP** |
| `tests/m2_bcb/connected_chain_checks.py:117` | `validate_measurement(self,*_args): pass` | **NO-OP** |
| `tests/m2_bcb/test_adopted_m2_v1.py:185,439` | `SimpleNamespace(...)` | **NO-OP** |
| production composition | **none exists** | `PRODUCTION_PATH_NOT_FOUND` |

`ResearchWorkflow` has **no production caller**. `project1_workflow.py` composes
`BDJEngine` and `run_model_assisted` only. So "validated" meant nothing anywhere,
and there was no production path to repair — only a rule to build.

### Change

`MeasurementPolicyDocument` — a versioned, hashable document (data, not code)
with two check layers kept deliberately separate:

* **Invariants** (always): version label is the resolved one; no geography; six
  required fields non-blank; codes and labels parallel, distinct, well-formed;
  routing covers exactly the declared codes; denominator built from declared
  codes; limitations substantive; prohibited claims absent from the estimand;
  source refs entailed by the packet; **every currency amount in the stimulus
  appears in the confirmed uncertainty text**.
* **Pinned** (only for a pinned instrument): exact construct, population,
  timeframe, stimulus tokens, currency-token set, response coding, routing,
  denominator wording.

Conflating these was the first draft's error: a fully pinned document makes every
model-authored candidate fail for reasons unrelated to the model's competence — a
validator that reports nothing.

Two documents: `QJ_INVARIANTS_POLICY` (model-authored QJ) and
`LAB_PRICE_RM13_POLICY` (the frozen lab instrument). Both are
`TEST_SCOPED_NOT_AUTHORIZED`. No code path can promote `authorization_status`.

### The no-op bypass is closed

`research.py`, before QG dispatch:

```python
if not getattr(self.authority, 'measurement_policy_version', None):
    raise WorkflowHeld('MEASUREMENT_AUTHORITY_UNVERIFIED')
```

A duck-typed double has no policy version, so it can no longer authorise a new
research question. It may still serve a **reuse** path, but the result then
carries `measurement_validation.status = 'NOT_RECORDED_BY_AUTHORITY'` — labelled,
not silently accepted.

### D-01 fidelity (RM13, never RM12)

Currency amounts are compared as **whole tokens** and the set must match exactly,
so `12 oz` supplying the digits `12` cannot license `RM12`. Proven twice: by the
pinned check, and independently by the uncertainty-binding invariant. A dedicated
case (`test_f02_pinned_instrument_refuses_a_price_drift_within_a_multi_price_uncertainty`)
isolates the pinned rule so it cannot be deleted without a test failing.

---

## 4. Point 3 — reconciliation with the provisional baseline

The first version of `LAB_PRICE_RM13_POLICY` invented its own construct,
population, timeframe and routing, competing with
`tests/m2_bcb/lab_measurement_v0_1.py::canonical_spec`. Two documents both
claiming to pin one instrument is the failure mode where whichever a reviewer read
last wins.

The policy now takes every pinned value **from** the baseline, and
`test_lab_policy_matches_the_provisional_baseline` asserts they agree field by
field. A drift in either now fails the suite.

`test_provisional_baseline_contract_is_admitted_by_the_policy` closes the loop end
to end: baseline → `Measurement` contract → pinned policy → `TEST_SCOPED_VALID`
receipt with `production_eligible=False`.

---

## 5. Point 4 — BD-01 Option B: prepared, not applied

| Check | Result |
|---|---|
| `project1_qgb` occurrences in the Dss inventory | **0** — schema absent, DDL not applied |
| Name collisions with existing objects | none (all five tables and the function are new names) |
| DDL executed during this work | **none** |
| Target database touched | **none** |

### Two defects in the candidate SQL

**BD01-SQL-01 — the append-only triggers make every state transition impossible.**
`refuse_rewrite()` raises on *any* `UPDATE` or `DELETE`, and it is attached to
`question_item_version` and `bank_snapshot`. But both tables define a lifecycle
via `CHECK`: `approval_state IN ('CANDIDATE','INDEPENDENTLY_REVIEWED','APPROVED','RETIRED')`
and `state IN ('DRAFT','ACCEPTED','RETIRED')`. A row can therefore never move from
`CANDIDATE` to `APPROVED`, or from `DRAFT` to `ACCEPTED`. A snapshot can never
become `ACCEPTED`, so **no receipt could ever be issued against it**. The schema,
as drafted, cannot reach any state that authorises anything.

**BD01-SQL-02 — no tenant column, so isolation is not self-contained.**
None of the five tables carries an owner or tenant column. `comparison_receipt`
does carry `objective_id` and `source_confirmation_id`, so a scoped policy is
expressible by subquery against `m2_confirmed_uncertainties` — the same pattern
already used in `migrations/m2/20261117_05_workflow_view_read_scope.sql:100-112`.
But it cannot be expressed from the table alone, and the DDL ships no policy.

Neither defect blocks preparation. Both block adoption.

---

## 6. Point 5 — BD-02, and the empty-bank distinction

`tests/project1/lab_bank.py` makes the bank contract executable for the first time.
Every receipt it issues is stamped `scope='SYNTHETIC_PRIVATE_LAB_ONLY'`; it is a
double and says so.

The distinction BD-02 exists to enforce, now a test rather than a paragraph:
**"I searched and found nothing" and "I searched a complete, reviewed catalogue
and found nothing" are different claims.** Only the second is a receipt. An empty
bank raises `BD02_EMPTY_BANK_CANNOT_PROVE_NO_EQUIVALENT`; a partial comparison
raises `BD02_COMPLETE_HUMAN_COMPARISON_REQUIRED`; a non-boolean verdict is refused
rather than coerced.

BD-01 receipt verification is covered by four independent negatives: tamper,
replay into another packet, reuse for another measurement, and a receipt this bank
never issued.

---

## 7. Tests

| Suite | Before | After |
|---|---|---|
| `tests/project1` + `tests/m2_bcb` | 414 passed, 6 skipped | **489 passed, 6 skipped, 7 subtests** |

75 new tests, no regressions:

* `tests/project1/test_measurement_policy.py` — **52** (F-01 resolution 16,
  F-02 invariants 14, pinned instrument 10, reconciliation 3, uncertainty binding 2,
  plus the composite-rule and admission-provenance cases)
* `tests/project1/test_lab_bank.py` — **18** (BD-01 8, BD-02 7, composed 2, plus
  unverified-bank cases)
* `tests/project1/test_workflow.py` — **+5** at the workflow boundary

Every refusal test asserts the **exact code**, so a guard that stops firing fails
the suite rather than passing silently.

Dry run: 8/8 disclosure checks, 15,572 bytes, `under_64k: true`, zero sockets.

---

## 8. Remaining blockers

| # | Blocker | Status |
|---|---|---|
| 1 | No production authority composition exists | **OPEN** — `PRODUCTION_PATH_NOT_FOUND`; the policy is built and tested, nothing composes it |
| 2 | No policy document is `AUTHORIZED` | **OPEN** — needs a scientific sign-off; no code path can grant it |
| 3 | DB-level `UPDATE`-must-fail test on `m2_confirmed_uncertainties` | **NOT ADDED** — needs the disposable clone; the trigger is evidenced from the migration, not executed |
| 4 | BD-01 Option B cannot reach `ACCEPTED`/`APPROVED` | **OPEN** — `BD01-SQL-01`, schema defect |
| 5 | BD-01 Option B has no tenant column or RLS policy | **OPEN** — `BD01-SQL-02` |
| 6 | Bank remains a test double | **OPEN** — no production bank exists |
| 7 | `AUTHORIZED` promotion is not a code path | **BY DESIGN** |

---

## 9. Readiness for the final free provider call

**Ready, not spent.**

The call would now exercise a materially different path: the model is told the
exact `uncertainty_version` string and its basis, and is shown one worked
survey-shaped example. Previously it was asked to invent a UUID.

What the call can prove: whether a compliant model, given the value, produces a
survey candidate that passes both the repository validator and the invariant
policy.

What it cannot prove: that the *scientific* content is right. The policy is
lab-scoped; `production_eligible` is `False` on every receipt this work can
produce.

**`spent 5 / 6` — one free call held. Not dispatched.**
