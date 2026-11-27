# CP-04B — BCB Authority and Resolver Decision Sheet

**Date:** 2026-11-17 · **Status:** `OWNER_DECISION_REQUIRED` · `BLK-BCB-AUTH` **remains open**
**Rule applied throughout:** authority is never inferred from an output table, a circular finding row,
or a synthetic fixture receipt. Where evidence is absent the system must HOLD, and it does.

---

## 1. What is verified in this session, and what is quoted

| Claim | State | How |
|---|---|---|
| Production binding factory refuses (`UnverifiedContextBindings`) | `VERIFIED` (source) | `dependencies.py:322-323` returns `UnverifiedContextBindings`; no production resolver is wired |
| A feature-flag-off gate returns 503 `BCB_PERSISTENCE_NOT_CONFIGURED` | `VERIFIED` (test exists) | `test_PG13` at `tests/m2_bcb/test_postgres_api.py:494` |
| `test_PG13` **executes** here | `VERIFIED` | `tests/m2_bcb/run_isolated.py`: 42 passed / 6 skipped / 4 xfailed on a disposable cluster; observed `BCB_BINDING_AUTHORITY_UNVERIFIED` (503) and `BCB_PERSISTENCE_NOT_CONFIGURED` (503), both expected and actual |
| `STRUCTURAL=1/10`, `OPERATIONAL=0/10` | `CITED_NOT_REVERIFIED` | taken from the directive's baseline; the isolated run exercises the refusal path, not a per-binding inventory |

The safeguard is now both read and observed. What it proves is that the production composition
**fails closed**; it does not prove that any authority exists, and none does.

## 2. The blocker, split into four decisions

`BLK-BCB-AUTH` is one identifier covering four separable questions. Deciding them together is why it has
stayed open.

### B4-1 — Where does tenant/owner scope come from?

**Option A — ownership on `public.m2_assessments`.** No new registry. Scope is the existing owner
column. Cheapest, and consistent with the governed chain (`m2_assessments` → `cq_campaigns` →
`ee01_measurement_snapshots` → `project1_ai.runs`, all 100% M2).
**Option B — a separate tenancy registry.** Enables multi-tenant delegation. Requires a new table, a new
authority source, and a migration.

**Recommendation: A.** Nothing in the current product asks for delegation, and B introduces a second
owner concept that would have to be reconciled with RLS on every existing table.

### B4-2 — What is the GEO catalogue's approved scope?

OD-3 defers the `M2V1-01` GEO *question*. This is a different question: which geographic reference data
may BCB treat as authoritative. **No approved GEO source exists today.** Any resolver that claims GEO
authority before this is decided is fabricating it.

**Recommendation: no GEO authority until an approved catalogue is named, with a version and an owner.**
BCB must HOLD with `BCB_BINDING_AUTHORITY_UNVERIFIED` for any binding that needs GEO. This is not a
delay tactic — it is the only non-fabricating answer available.

### B4-3 — Who may build, and who may read, a context for which purpose?

Three separate grants, currently conflated: build, read, and purpose. A party able to read a context for
"internal diagnosis" is not thereby able to read it for "public report".

**Recommendation: purpose is a first-class part of the access decision, not a parameter of the caller.**
The existing disclosure adapter already models this for AI dispatch (`purpose` is checked, not trusted);
BCB should mirror that shape rather than invent a second one.

### B4-4 — What confers finding authority?

Today `finding_authority` is `candidate_only` everywhere, and the database enforces it with a
single-value CHECK on two tables. That is the safe state, and it is why nothing can currently be
displayed as an admitted business finding.

The directive forbids AI self-approval. So authority must come from one of:
- **a human decision event** recorded with a reviewer identity, a timestamp, and the finding hash; or
- **a deterministic rule** whose adoption is itself a recorded operator act.

**Recommendation: human decision event only, for now.** A deterministic rule path requires an adopted
ruleset and an adoption receipt, and neither exists for BCB (`BDJ-RULESET-0.2-CAND` is explicitly a
*candidate* ruleset, not a scientific one).

Whatever is chosen must be **additive**: `candidate_only` stays valid, and the new state is a new value,
not a rename. A second incompatible vocabulary is prohibited.

## 3. What each downstream workstream is waiting for

| Workstream | Waiting on | Consequence of delay |
|---|---|---|
| A7 — BCB authority implementation | B4-1, B4-4 | Cannot write a resolver that confers anything |
| A8 — QJ/QG production integration | A7, plus an approved bank adapter | QJ/QG cannot consume a context that does not exist |
| A9 — questionnaire and reporting | A8 | R01–R12 cannot be produced from an unbuilt chain |
| E2E-2B (fixture-authorized positive BCB) | a disposable cluster | Can run now; proves the mechanism, not the authority |
| E2E-3 (BCB→QJ→QG) | B4-1..4 and the bank adapter | `COMPONENT_TEST_ONLY` until then |

## 4. What must NOT be done while the decision is open

1. Do not delete or weaken `test_PG13`. It asserts the refusal. When authority rules are approved, it is
   **revised** to assert that unapproved configurations still HOLD *and* approved ones execute — both
   halves, not just the second.
2. Do not wire a production resolver that returns a non-`UnverifiedContextBindings` factory without a
   recorded decision. That single line change is what turns a fail-closed system into a fabricating one.
3. Do not let QJ or QG approve a generated question. A generated question is a candidate; approval is a
   separate act by a separate party.
4. Do not treat a synthetic fixture receipt as a publication receipt.

## 5. What I recommend as the decision, in one sentence

> Owner scope is the existing `m2_assessments.owner_user_id`; no GEO authority is granted until an
> approved catalogue is named; purpose is part of the access decision; finding authority requires a
> recorded human decision event carrying reviewer identity, finding hash and timestamp; everything else
> continues to HOLD.

## 6. Decision block

```
B4-1 owner scope:        [ ] A: m2_assessments.owner_user_id   [ ] B: separate tenancy registry
B4-2 GEO authority:      [ ] withheld until an approved catalogue is named
                         [ ] granted — catalogue name/version/owner: ______________________
B4-3 access decision:    [ ] purpose is part of the decision   [ ] purpose is a caller parameter
B4-4 finding authority:  [ ] recorded human decision event     [ ] adopted deterministic rule
                             (requires an adopted ruleset + adoption receipt, neither exists)

test_PG13 treatment on approval: [ ] revised to assert HOLD *and* execute   [ ] other: ______

Owner: ______________________  Date: __________
```
