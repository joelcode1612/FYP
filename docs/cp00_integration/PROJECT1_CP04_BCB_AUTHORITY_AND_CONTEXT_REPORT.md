# PROJECT1 — CP-04B: BCB Authority and Context Binding Report

**Date:** 2026-11-17
**Repository:** `sport-marketplace/FYP`, branch `merge_main_jed`, base `ba30035ecb24b80fa155cc7049cf3cdf94a67844`
**Checkpoint:** CP-04B — authoritative Business Context Builder bindings
**Deliverable:** §19 item 2

**Verdict:**

| Measure | Result | Meaning |
|---|---|---|
| **STRUCTURAL** | **1 / 10** | one binding has an authoritative persisted source with the full field set the builder requires |
| **OPERATIONAL** | **0 / 10** | the wired production composition can obtain **none** of them |
| **CP-04B** | **`BLOCKED`** | `BLK-BCB-AUTH` stands; not bypassed |

The single most important sentence in this report: **the BCB code is not the
blocker.** On a disposable cluster with authority supplied by fixtures the full
path passes **42 tests, 0 failures**. What is missing is authority, and the
production composition refuses *by design and by test*.

---

## 1. Why this checkpoint was re-measured rather than restated

The directive is explicit:

> *"The previous CP-04 investigation found that the BCB builder could not resolve
> most authoritative bindings. **Reinspect the current implementation rather than
> assuming the old count remains unchanged.**"*

CP-04 (`PROJECT1_CP04_BCB_BINDING_READINESS_20261117.md`) reported
`resolvable=1 missing=9`. Re-inspection against the builder source found that
headline number was **true of the thing it measured and false of the thing it
was read as claiming**. Three corrections follow, and all three are corrections
to *my own* prior work.

### C-1 — `resolvable=1` is a structural count, not an operational one

CP-04 asked "does a table with these columns exist?". The builder does not read
tables. Every binding arrives through one call:

```python
# src/sitewise/services/persisted_business_context_service.py:98-99
return BusinessContextBuilderV1(_Authorization(inputs.decision),
    _Snapshot(unit, selection, actor, inputs.bindings)).get_context(request)
```

and `inputs` comes from `unit.resolve_inputs(...)`, which delegates to
`self.resolver.resolve(selection, actor)`. The production factory returns
`UnverifiedContextBindings`:

```python
# src/sitewise/repositories/business_context_repository.py:17-21
class UnverifiedContextBindings:
    """Real composition deliberately supplies no guessed tenant/purpose receipts."""
    def __init__(self, session): pass
    def resolve(self, selection, actor):
        raise ContextBindingUnavailable()
```

wired at `src/sitewise/dependencies.py:321-323`. Therefore **no** binding is
obtainable today — not even the one whose data exists. `resolvable=1` was
correct about the schema and wrong about the system.

### C-2 — `bindings.rule_versions` was right for the wrong reason

CP-04 recorded it `MISSING` because `m2_bdj_findings` had **0 rows**. That is
true, and it is not the reason. A finding row *records* the rule version that
produced it; using that table as the registry would make the builder's own check
circular:

```python
# business_context_v1.py:271
and b["rule_versions"].get(f["rule_id"]) == f["rule_version"]
```

If the mapping were derived from the findings, this would verify each finding
against itself. The binding needs an **independent ruleset registry**. It is
`MISSING` for that structural reason, and it would still be missing if
`m2_bdj_findings` held a million rows. A count that happens to be zero today is
not an argument.

### C-3 — "no `get_uncertainty`" is true of the accessor, false of the capability

CP-04 wrote that `SqlModelM2Repository` has `create_uncertainty` but no
`get_uncertainty`, implying the data is unreachable. Re-inspection: `exact_text`
**is** read in four places (`m2_repository.py:421, 436, 531, 561`;
`uc_history_repository.py:18`). What does not exist is a typed accessor
returning a binding-shaped record scoped to a confirmation — and it would not
help, because the builder reads `b["uncertainty"]` from the resolver, not from
the repository (`business_context_v1.py:294`). So the gap is **one resolver**,
not new persistence and not new queries.

---

## 2. Method, and how the negatives were measured

Two things had to be measured separately, and a third had to be measured
properly rather than asserted.

**Structural.** The full field set per binding was read out of
`business_context_v1.py` (`text_fields`, `require`, `_scoped` calls) and encoded
with line references. CP-04 tested 7 fields for `bindings.concept`; the builder
enforces 12 plus a link to a specific confirmation row. The stronger set is used
here.

**Operational.** The production resolver is invoked directly and the raised code
recorded. This is a pure code path — it writes nothing.

**Negatives.** A negative claim ("no tenant registry exists") is only evidence if
something was searched for. Each such binding carries an indicative column pair,
and the script reports where those columns actually appear. Two candidate
matches were **excluded with reasons**, because both would have produced false
positives:

| Excluded | Why it is not a source |
|---|---|
| `public.m2_business_contexts` | carries `tenant_id` because the packet *emits* it. Counting the output as the source of its own input is precisely the error class this report exists to correct. |
| `public.m2_bdj_findings` | carries `rule_id`/`rule_version` because the finding *records* them. See C-2. |

Row reads use a savepoint each, because an RLS refusal aborts the enclosing
transaction and silently voids every later check. That failure mode cost a
measurement earlier in this project; it is handled here rather than re-learned.

---

## 3. Binding matrix — what the builder actually enforces

Live subject: `assessment=da90aa4a-f9cf-4145-9acf-7de36c9d6fad`, `rev=12`,
`actor=11111111-1111-4111-8111-111111111111`. Live confirmation resolved to
exactly one row: `698ae3eb-24fe-4c6d-bdd3-69e575cc00e6` (unique — a duplicated
confirmation would have made every linkage check meaningless).

| # | Binding | Enforced at | Refusal if absent | Structural | Operational |
|---|---|---|---|---|---|
| 1 | `request.tenant_id` | L118-121, L156 | `ACCESS_DENIED` | **NO** — `tenant_id` appears only on the context output (excluded); no registry carries `tenant_id`+`owner_user_id` | **NO** |
| 2 | `bindings.snapshot_id` | L155-158 | `SNAPSHOT_SCOPE_INVALID` | **NO** — `snapshot_id` exists only on three `ee01_*` tables, none with a `consistency` label | **NO** |
| 3 | `bindings.concept` | L223-241 | `CONCEPT_MISSING` / `CONCEPT_STALE` / `CONCEPT_SOURCE_INVALID` | **NO** — no relation carries all 12 required fields | **NO** |
| 4 | `bindings.current_concept_version` | L228-232 | `CONCEPT_STALE` | **NO** — no relation carries `version`+`status` | **NO** |
| 5 | `bindings.geography` | L242-260 | `GEO_UNAPPROVED` / `GEO_SCOPE_INVALID` / `GEO_IDENTITY_INVALID` | **NO** — no relation carries all 13 required fields | **NO** |
| 6 | `bindings.rule_versions` | L271 | `FINDING_VERSION_INVALID` | **NO** — no registry anywhere (C-2) | **NO** |
| 7 | `bindings.finding_authorities` | L274-285 | `FINDING_AUTHORITY_INVALID` | **NO** — no relation carries all 5 required fields; `m2_review_events` has only `id, assessment_id, assessment_revision, actor_user_id, created_at` | **NO** |
| 8 | `bindings.uncertainty` | L294-304 | downgraded to an `unknown`, not a refusal | **YES** — `m2_confirmed_uncertainties`, 1 row, `confirmation_id` = live confirmation | **NO** |
| 9 | `bindings.sources` | L305-327 | `SOURCE_QUALIFICATION_INVALID` / `SOURCE_ACCESS_DENIED` / `SOURCE_STALE` | **NO** — no relation carries all 12 required fields | **NO** |
| 10 | `decision` | L123-135 | `ACCESS_DENIED` (checked before any content is opened) | **NO** — no access-decision table or service | **NO** |

```
STRUCTURAL=1/10 OPERATIONAL=0/10
VERDICT=BLOCKED
```

**Note the asymmetry on row 8.** Uncertainty is the only binding whose data is
genuinely present and correctly linked, and it is also the only binding whose
absence is *tolerated* — the builder records an `UNCERTAINTY_NOT_CONFIRMED`
unknown and continues (L303-304). So the one binding we could satisfy is the one
whose absence does not block anything, and the nine that do block are all
absent. That is an accurate description of the state and it is not a coincidence:
the parts of the contract that were exercised during M2 development were built;
the governance layer around them was not.

---

## 4. Runtime evidence — the refusal is real, not theoretical

Three independent confirmations, none of which is an inference from source code.

### 4.1 A persisted receipt in the live database

```
m2_business_context_builds
  confirmation_id = 698ae3eb-24fe-4c6d-bdd3-69e575cc00e6
  assessment_revision = 12
  status = HELD
  last_code = BCB_BINDING_AUTHORITY_UNVERIFIED
  context_id = NULL
  attempt_count = 1
```

The system attempted a build against this confirmation, was refused at the
resolver, and **recorded the refusal durably** with no synthetic context
produced. `m2_business_contexts` holds 0 rows. The table does not record whether
the originating call was a test harness or a live request, and this report does
not claim which.

### 4.2 The refusal is a tested invariant

```python
# tests/m2_bcb/test_postgres_api.py:494-500
def test_PG13_production_binding_factory_refuses_and_feature_flag_is_off_gate(lab):
    ...
    override=lab['app'].dependency_overrides.pop(deps.get_bcb_bindings_resolver_factory)
    try: build(lab,mid,cid,503)     # production factory must refuse
```

This matters for sequencing: **implementing a resolver breaks `test_PG13` unless
that test is deliberately changed.** A resolver is therefore a governed decision
about authority, not a bug fix. Treating it as a bug fix would quietly delete an
assertion that exists to prevent exactly that.

### 4.3 The builder works when authority is supplied — isolated lab

`tests/m2_bcb/run_isolated.py` builds a **new** PostgreSQL 18 cluster on
`127.0.0.1:55441`, restores the read-only Dss schema into it, and runs the suite
with a fixture resolver. The live `Dss` is not written.

```
42 passed, 6 skipped, 4 xfailed in 114.36s
run.json: migration_without_receipt_rejected=true, live_database_writes=false,
          production_acceptance=false
```

Passing tests directly relevant to this checkpoint:

| Test | What it establishes |
|---|---|
| `test_PG06_missing_binding_is_durable_hold_not_synthetic_context` | a missing binding produces a durable hold, never an invented context |
| `test_PG13_production_binding_factory_refuses_and_feature_flag_is_off_gate` | the production factory refuses; the feature gate is off-gate |
| `test_PG14_expired_grant_and_changed_source_binding` | expired decisions and changed source bindings are rejected |
| `test_PG17_concurrent_duplicate_context_builds_produce_one_row` | concurrent builds converge on one row |
| `test_PG20_unsupported_or_forged_scope_cannot_open_context` | forged scope cannot open a context |
| `test_PG21_instrument_approval_withdrawal_blocks_context_and_new_answers` | withdrawing instrument approval blocks context |
| `test_PG22_legacy_snapshot_stays_readable_but_context_pins_are_required` | legacy snapshots stay readable, pins still required |
| `test_PG26_valid_multi_answer_reconfirmation_and_context_array_readback` | full construction and readback with supplied authority |

The 10 non-passing outcomes are all explicit opt-in gates or pre-existing source
limitations, none of them BCB authority:

- 5 browser/compiled acceptance tests — require `PART_TWO_JASPR=1` / compiled-browser flags;
- 4 `test_HELLOP_source_conditions…[M2-09/13/16/17]` — source conditions not enforced by the existing string-option DTO (a known DTO limitation, unrelated);
- 1 `test_HELLOP_actual_Jaspr_source_form_revision_and_BDJ_handoff` — opt-in browser test.

**Conclusion from 4.3:** CP-04B is blocked on authority, not on engineering
capacity. Anyone reading `BLOCKED` as "the BCB does not work" would be wrong, and
that misreading would send effort at the wrong problem.

---

## 5. What would actually unblock CP-04B

Seven artefacts. The classification is the useful part: three are governance
decisions that engineering cannot supply, and four are buildable once those
decisions exist.

| # | Artefact | Class | Minimum content | Owner decision required |
|---|---|---|---|---|
| 1 | Tenant registry | **governance** | `tenant_id`, owner binding, lifecycle | tenancy model — single-tenant or multi-tenant |
| 2 | Concept version registry | engineering | `version`, `status=ENTREPRENEUR_CONFIRMED`, `confirmed_by`, `confirmation_event_id`, `content.description`, `source_hash`, `m2_snapshot_digest`, `valid_until` | none — derivable from the confirmation snapshot once the rule is set |
| 3 | GEO_V1 approved catalogue | **governance** | `catalogue_family`, `catalogue_version`, `catalogue_hash`, `approval_state=APPROVED`, `approval_ref`, `area_id`, `source_code`, `jurisdiction`, `area_kind`, `identity_hash` | which geography source is approved, and by whom |
| 4 | External source qualification | engineering | `citation`, `evidence_class`, `allowed_purposes`, `allowed_viewers`, `valid_until`, `facts`, `limitations`, `review_ref` | none — but requires an actual external evidence set |
| 5 | Finding authority events | engineering | `finding_hash`, `confirmation_id`, `review_event_id` for `review_state=VERIFIED` | depends on the review workflow |
| 6 | Snapshot registry | engineering | `snapshot_id`, `consistency=IMMUTABLE_SNAPSHOT` | none |
| 7 | Access-decision service | **governance** | `allowed`, `scope`, `owner_id`, `decision_id`, `policy_version`, `valid_until` | access policy: who may read which context for which purpose |
| 8 | **The resolver itself** | engineering | implements `resolve(selection, actor) -> GovernedContextInputs`; replaces `UnverifiedContextBindings`; requires amending `test_PG13` | authorisation to change a tested invariant |

Item 8 is the point most easily missed. Even with items 1-7 built, the system
stays blocked until someone authorises replacing a resolver that currently
refuses **on purpose**. That is a signed decision, not a code change.

Items 1, 3 and 7 are the three that cannot be closed by engineering at all.

---

## 6. Claims explicitly refused

- ❌ **"CP-04B is unchanged from CP-04, so nothing needed doing."** The headline
  `1/10` was re-derived and split; the operational figure is `0/10`, which is a
  different blocker description and implies a different unblock sequence.
- ❌ **"1 of 10 bindings is resolvable."** One has a *source*. Zero are
  *resolvable*. Conflating the two is the error class this project keeps
  re-encountering.
- ❌ **"The BCB is broken / unimplemented."** False. 42 tests pass on a fresh
  cluster with supplied authority. The builder, its refusals, its idempotency and
  its concurrency behaviour all work.
- ❌ **"A resolver was implemented."** Deliberately not. Implementing one would
  invent tenant, concept, geography, source and access decisions, and would
  require deleting the assertion in `test_PG13`.
- ❌ **"`rule_versions` is missing because there are no findings."** It is missing
  because there is no registry. The zero row count is incidental.
- ❌ **"Uncertainty is unreadable."** `exact_text` is read in four places. What is
  absent is a binding-shaped accessor and a resolver, and the builder would not
  use the accessor anyway.
- ❌ **"The isolated lab proves production acceptance."** It does not, and its own
  `run.json` says `production_acceptance: false`. It proves the code path works
  under fixture authority.

---

## 7. Reproduction

```bash
cd sport-marketplace/FYP/backend

# Structural + operational matrix (read-only; one transaction; rolled back)
./.venv/Scripts/python.exe scripts/cp04b_bcb_binding_reverify.py
#   STRUCTURAL=1/10 OPERATIONAL=0/10
#   VERDICT=BLOCKED

# Builder works when authority is supplied (disposable cluster on :55441)
./.venv/Scripts/python.exe tests/m2_bcb/run_isolated.py \
    --output C:/Users/HP/AppData/Local/Temp/cp04b_bcb_lab
#   42 passed, 6 skipped, 4 xfailed
```

Evidence hashes:

| Artefact | SHA-256 |
|---|---|
| `scripts/cp04b_bcb_binding_reverify.py` | `c8785305823455be820fcaf3adb9d7b33d4f8277bbf6d4189ce80ac661feb65c` |
| `tests/m2_bcb/run_isolated.py` | `c59e9b3017c2ee2d3fbe3e302e5f9ea7767829d443da2d6320672e996ed668a1` |
| lab `run.json` | `8b8ab07954ebab1f6f0c319bae07a00a7a15b2b35d74e8ce7a038be82958c633` |
| lab `pytest.xml` | `9a1e2b6bfb50b6467197b870608385c51f203e882197a3809858345dfa2c5e69` |

The CP-04 probe (`cp04_bcb_binding_readiness.py`,
`f49590f3…b67774`) is retained unmodified so the two measurements can be
compared. It is superseded for the verdict by the CP-04B script.

---

## 8. Effect on the checkpoint chain

CP-04B does **not** unblock CP-05, and it does not claim to. What it changes is
the accuracy of the blocker:

| Before | After |
|---|---|
| "9 of 10 bindings have no source table" | "9 of 10 have no source; 10 of 10 are unobtainable; the obstruction is one resolver, guarded by a test" |
| implied fix: build tables | actual fix: 3 governance decisions → 4 engineering artefacts → 1 authorised resolver replacement |
| "the BCB cannot resolve" | "the BCB resolves correctly when given authority; it is given none" |

`BLK-BCB-AUTH` remains **open**. CP-05, CP-06, CP-07 and CP-08 remain `NOT_RUN`
for the reasons recorded in the blocker register, and this report does not
advance them.
