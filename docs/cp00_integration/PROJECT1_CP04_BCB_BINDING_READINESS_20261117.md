# PROJECT1 — CP-04 Authoritative BCB Binding Readiness

**Date:** 2026-11-17
**Repository:** `sport-marketplace/FYP`, branch `merge_main_jed`, base `ba30035`
**Checkpoint:** CP-04 (Authoritative BCB bindings)
**Verdict: BLOCKED — 1 of 10 required bindings is resolvable from current persistence.**

> **Superseded for the verdict by CP-04B**
> (`PROJECT1_CP04_BCB_AUTHORITY_AND_CONTEXT_REPORT.md`, 2026-11-17). This file is
> retained unchanged as the record of what the CP-04 probe measured. CP-04B
> re-derived the requirement from `business_context_v1.py` rather than an
> abbreviated column list, and split the result: **`STRUCTURAL=1/10`,
> `OPERATIONAL=0/10`**. The `1` below is a structural count — a table exists —
> and does not mean one binding is obtainable; none is.

No resolver was implemented. Implementing one today would require inventing tenant,
concept, geography, source and access-decision records. That is fabrication, and the
existing composition already refuses it by design:

```python
class UnverifiedContextBindings:
    """Real composition deliberately supplies no guessed tenant/purpose receipts."""
    def resolve(self, selection, actor):
        raise ContextBindingUnavailable()   # BCB_BINDING_AUTHORITY_UNVERIFIED
```

---

## 1. What CP-04 actually requires

`BusinessContextBuilderV1._build` (`services/business_context_v1.py:152-329`) refuses the
packet unless ten governed bindings are present and internally consistent. Each one is
enforced by a specific refusal code, so the binding set is not advisory — it is a hard gate.

---

## 2. Method, and a correction worth recording

**First measurement was wrong.** Querying `information_schema.tables` as the application
role returned 12 relations, all `m2_*`, which would have "proved" that no concept, tenant,
geography or source table exists. That conclusion was an artifact: `information_schema` is
**privilege-filtered**, so a restricted role cannot see tables it has no grant on.

Re-measured with `pg_class` / `pg_attribute`, which are not privilege-filtered:

| Measure | Value |
|---|---|
| Relations in `public` | **70** (not 12) |
| Relations in `project1_ai` | 4 |
| Total in `Dss` | 74 |

**Second measurement was also wrong.** `SELECT count(*)` returned `0` for `m2_assessments`
while the repository happily read an assessment and produced 11 declarations. Cause: RLS
keyed on `current_setting('project1.actor_id')`, plus `set_config(..., true)` being
transaction-local while `M2SourceProjection.read()` rolls back in its `finally` block.
Every count below is therefore taken inside **one explicit transaction** after setting the
actor.

> Error class: *a claim true of the label but false of the thing labelled.* "0 tables" was
> true of the privilege-filtered view and false of the database. Same for "0 rows".

---

## 3. Binding matrix (live evidence)

`assessment=da90aa4a… rev=12`, actor `11111111-1111-4111-8111-111111111111`, single
transaction, RLS active.

| Binding | Refusal code if absent | Status | Evidence |
|---|---|---|---|
| `request.tenant_id` | `ACCESS_DENIED` | **MISSING** | no source table defines `tenant_id` |
| `bindings.snapshot_id` | `SNAPSHOT_SCOPE_INVALID` | **MISSING** | no snapshot registry |
| `bindings.concept` | `CONCEPT_MISSING` / `CONCEPT_STALE` | **MISSING** | no concept table |
| `bindings.current_concept_version` | `CONCEPT_STALE` | **MISSING** | no concept table |
| `bindings.geography` | `GEO_UNAPPROVED` | **MISSING** | no GEO_V1 approved catalogue |
| `bindings.rule_versions` | `FINDING_VERSION_INVALID` | **MISSING** | `m2_bdj_findings` has both columns but **0 rows** at rev 12 |
| `bindings.finding_authorities` | `FINDING_AUTHORITY_INVALID` | **MISSING** | no `finding_hash` / `review_event_id` anywhere |
| `bindings.uncertainty` | `UNCERTAINTY_NOT_CONFIRMED` | **RESOLVABLE** | `m2_confirmed_uncertainties`: 3/3 columns, 1 row |
| `bindings.sources` | `SOURCE_QUALIFICATION_INVALID` | **MISSING** | no external source qualification table |
| `decision` | `ACCESS_DENIED` | **MISSING** | no access-decision table or service |

```
resolvable=1 missing=9
VERDICT=BLOCKED
```

Live row counts in the same transaction: `m2_assessments=2`, `m2_answer_revisions=12`,
`m2_confirmation_snapshots=1`, `m2_bdj_findings=0`, `m2_confirmed_uncertainties=1`,
`m2_business_contexts=0`.

**The decisive structural fact:** `tenant_id` and `concept_version` appear as columns in
exactly one table — `m2_business_contexts`, the BCB **output**. There is no source table
that *defines* them. The output schema anticipates the authority layer that does not exist.

---

## 4. What would unblock CP-04

Seven authority artifacts, none of which exists, and none of which can be inferred:

| # | Artifact | Minimum content |
|---|---|---|
| 1 | Tenant registry | `tenant_id`, owner binding, lifecycle |
| 2 | Concept version registry | `version`, `status=ENTREPRENEUR_CONFIRMED`, `confirmed_by`, `confirmation_event_id`, `content.description`, `source_hash`, `m2_snapshot_digest`, `valid_until` |
| 3 | GEO_V1 approved catalogue | `catalogue_family`, `catalogue_version`, `catalogue_hash`, `approval_state=APPROVED`, `approval_ref`, `area_id`, `source_code`, `jurisdiction`, `area_kind`, `identity_hash` |
| 4 | External source qualification | `citation`, `evidence_class`, `allowed_purposes`, `allowed_viewers`, `valid_until`, `facts`, `limitations`, `review_ref` |
| 5 | Finding authority events | `finding_hash`, `confirmation_id`, `review_event_id` for `review_state=VERIFIED` |
| 6 | Snapshot registry | `snapshot_id`, `consistency=IMMUTABLE_SNAPSHOT` |
| 7 | Access-decision service | `allowed`, `scope`, `owner_id`, `decision_id`, `policy_version`, `valid_until` |

Items 1, 3 and 7 are governance decisions (tenancy model, approved geography source,
access policy), not code. They cannot be closed by engineering alone.

Also required: a **read** path for confirmed uncertainty. `SqlModelM2Repository` has
`create_uncertainty` (`m2_repository.py:332`) but **no** `get_uncertainty`, so even the one
resolvable binding has no accessor today.

---

## 5. Claims explicitly refused

- ❌ "BCB is implemented and just needs enabling" — 9 of 10 bindings have no source.
- ❌ "The database has no concept/tenant tables because there are only 12 tables" — false;
  that was the privilege-filtered view. There are 70 public relations.
- ❌ "`m2_assessments` is empty" — false; RLS hid the rows. 2 assessments exist.
- ❌ "A resolver was written" — deliberately not written; it would fabricate authority.

---

## 6. Reproduction

```bash
cd sport-marketplace/FYP/backend
./.venv/Scripts/python.exe scripts/cp04_bcb_binding_readiness.py   # VERDICT=BLOCKED
```

The probe is read-only: one explicit transaction, actor set, rolled back, no dispatch.
