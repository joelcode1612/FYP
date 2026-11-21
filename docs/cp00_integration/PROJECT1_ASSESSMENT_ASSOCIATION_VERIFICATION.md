# PROJECT1 — Assessment Association Verification (A6 / B5)

> Historical snapshot (2026-11-17). On 2026-11-18, Dss has an installed
> `m2_assessment_links` table and two active property-to-M2 bindings. The no-link
> verdict and no-join-table recommendation below are superseded for current use.
> See [current relationships and executed queries](../architecture/assessment_cq/CURRENT_RELATIONSHIPS_20261118.md).
> The previously completed synthetic questionnaire remains a separate test chain.

**Date:** 2026-11-17
**Repository:** `sport-marketplace/FYP`, branch `merge_main_jed`, base `ba30035`
**Checkpoints:** A6 (verification) · B5 (owner decision)
**Status:** verification **`VERIFIED`** · association design **`OWNER_DECISION_REQUIRED`** · one defect **`IMPLEMENTED_NOT_VERIFIED`** (not fixed — see §6)

---

## 1. Verdict

**No relationship exists between the web/property assessment store and the M2 research
assessment store, and the separation is deliberate and documented.** The governed chain uses
`public.m2_assessments` exclusively. There is no link to establish, and none should be invented.

One real defect was found in the process: the PROJECT1 readiness endpoint resolves against the
**web** store, so it returns 404 for every M2 assessment id — including ids the rest of the chain
serves normally.

---

## 2. Premise correction (my error, carried in earlier reports)

Earlier checkpoints — including the blocker register — refer to **`public.assessments`**. That
table does not exist. The table is **`public.assessment`**, singular, PK `assessment_id`.

This is not cosmetic. A search for `public.assessments` returns nothing, which reads as "the table
is missing" when it is present under a different name. The register is corrected accordingly.

---

## 3. The two stores (measured on `Dss`)

| | `public.m2_assessments` | `public.assessment` |
|---|---|---|
| Rows | **18** | **0** |
| PK | `id` uuid | `assessment_id` uuid |
| Owner column | `owner_user_id` → `users` | `user_id` → `users` |
| Domain columns | `instrument_id` → `m2_instrument_versions`, `revision`, `confirmed_revision` | `property_id varchar(64)` (soft ref to `fyp.catalogue_properties`, **another database**), `status`, 5 stage timestamps, `requirements` |
| Uniqueness | `UNIQUE(id, owner_user_id)` | — |
| RLS | enabled | not enabled |
| FKs pointing at it | `assessment_workflow_projection`, `project1_ai.runs`, … | **none** (`pg_constraint` count = 0) |

Both id columns are `uuid4`. **A mix-up between them raises no type error and no FK violation** —
it silently finds nothing.

### 3.1 Link tests — all negative

| Test | Result |
|---|---|
| FK in either direction | none |
| Join table / cross-reference column | none |
| `m2_assessments.id` ∩ `assessment.assessment_id` | **0** |
| owner overlap | **0** |

### 3.2 Chain resolution — 100% M2

| Table | Resolves to `m2_assessments` | Resolves to `public.assessment` |
|---|---|---|
| `cq_campaigns` | 2 / 2 | 0 |
| `ee01_measurement_snapshots` | 7 / 7 | 0 |
| `project1_ai.runs` | 9 / 9 | 0 |
| `assessment_workflow_projection` (83 rows) | FK → `m2_assessments(id, owner_user_id)` | 0 |

**"Assessment" in the directive's chain means `m2_assessments`.** That is settled by evidence,
not by convention.

---

## 4. Saved rentals

| Table | Columns | Carries an assessment id? |
|---|---|---|
| `public.favorite_property` | `favorite_id`, `user_id`, `property_id` **integer** FK → `property(property_id)` | **No** |
| `public.entrepreneur_preferences` | `preference_id`, `user_id`, `preferences varchar` | **No** |

Both have 0 rows. `saved_properties.py` contains zero occurrences of "assessment". So a saved
rental has no path to an assessment of either kind today.

---

## 5. Endpoints — the two stores are cleanly partitioned

| File:line | Method | Path | Store |
|---|---|---|---|
| `assessments.py:51` | POST | `/api/v1/assessments/` | `public.assessment` |
| `assessments.py:68` | GET | `/api/v1/assessments/me` | `public.assessment` |
| `assessments.py:96` | GET | `/api/v1/assessments/by-property/{property_id}` | `public.assessment` |
| `assessments.py:120` | GET | `/api/v1/assessments/{assessment_id}` | `public.assessment` |
| `m2.py:62` | GET | `/api/v1/m2/assessments` | `m2_assessments` |
| `m2.py:135` | POST | `/api/v1/m2/assessments` | `m2_assessments` |
| `m2.py:140` | GET | `/api/v1/m2/assessments/{assessment_id}` | `m2_assessments` |
| `project1_workflow.py:67` | GET | `/api/v1/project1-workflow/assessments/{id}/source` | `m2_assessments` |
| `project1_read.py:23` | GET | `/api/v1/project1-read/assessments/{id}/readiness` | **`public.assessment`** ← §6 |

---

## 6. The defect

`dependencies.py:358` constructs `Project1ReadService(AssessmentService(session, analytics))`.
`AssessmentService.repo` is `AssessmentRepository` (`assessment_service.py:563`), which reads
`public.assessment`. `AssessmentService.get_owned` (`:568-575`) raises
`AssessmentError(..., code="assessment_not_found", status_code=404)` when the row is absent.

**Consequence:** `GET /api/v1/project1-read/assessments/{m2_id}/readiness` returns
**404 "That assessment does not exist."** for every one of the 18 M2 assessments — while
`/project1-workflow/assessments/{m2_id}/source` serves the same id correctly. The PROJECT1
namespace's own readiness surface cannot resolve any assessment the chain uses.

It has a live client: `shared_logic/lib/src/data/repositories/api_project1_read_repository.dart:15-16`
is imported by both the mobile and Jaspr apps, and passes through whatever id its caller holds.

**Why it is not fixed here.** Both id columns are `uuid4`, so re-pointing the reader would not
fail loudly if the caller holds the *other* id — it would return a different user's shape or
nothing, silently. The directive is explicit: *"Do not assume the two assessment IDs are
interchangeable."* Choosing the target is a design decision (§8), not a defect fix.

### 6.1 Artifact flags — two traps that would have produced false conclusions

1. **`Final_Location_Analysis.public.assessment` is a different table in a different database.**
   It holds **2 rows and 88 lifetime inserts**, while `Dss.public.assessment` holds 0. A count
   taken without naming the database would have concluded "the web store is in use". It is not.
   The Dss emptiness is real, not RLS: `relrowsecurity = f`, `n_tup_ins = 0`.
2. `m2_assessments` has RLS enabled; the 18-row count was taken as `postgres`
   (`usebypassrls = t`), so it is complete. Counts taken as the application role may be lower —
   that is RLS, not absence.

---

## 7. Frontend

| Finding | Evidence |
|---|---|
| Both apps use the M2 store | `shared_logic` `api_m2_repository.dart:213,220,238` → `/api/v1/m2/assessments`; imported by 89 mobile and 72 Jaspr files |
| Mobile never calls the web store | zero occurrences of `/api/v1/assessments` in `fyp_mobile_app/lib` |
| Jaspr is the only web-store client | `assessment_api.dart:628-756`, used by dashboard / workspace / reports / selector |
| No path passes one id to both stores | `app.dart:681` workspace route takes `?id=` (property), not `?assessment=` |
| **Mislabeled identifier** | `fyp_mobile_app/lib/cq_successor/route_contract.dart:66` — the field named `assessmentId` carries a **CQ session UUID** |
| Dead code | `research_workflow_panel.dart` (the four-step QJ flow) is defined and **never instantiated** — 0 external references |

The last two matter for later phases: a variable named `assessmentId` holding a CQ session id is
the same error class as `public.assessments` — a name that is true of its label and false of its
contents.

---

## 8. B5 — decision required

**Recommendation: do not create a join table.** The chain needs no association, because it never
touches the web store. Adding one would create a second source of truth for "which assessment"
and invite exactly the id confusion §6 describes.

The one thing that genuinely needs deciding is the readiness endpoint's scope:

| Option | Change | Cost | Risk |
|---|---|---|---|
| **B5-A (recommended)** Re-point `/project1-read` to `m2_assessments` | new `M2OwnedAssessmentReader`; `property_id` becomes `None` for M2 records | ~1 file + tests | the response model's `property_id` stops being populated; any Jaspr workspace view relying on it loses that field |
| **B5-B** Keep `/project1-read` web-scoped, add `/project1-read/m2/assessments/{id}/readiness` | additive, no behaviour change | 1 route + 1 dependency | two readiness surfaces with near-identical names — the ambiguity returns |
| **B5-C** Accept both ids with an explicit discriminator | `?store=web\|m2` or a prefixed id | small | pushes the choice onto every caller; silent-empty if omitted |

`property_id` is a web-store concept (`varchar(64)` → `fyp.catalogue_properties`, another
database). Under B5-A it is structurally always `None`, which is honest but should be stated in
the contract rather than left to look like missing data.

**Whatever is chosen, the current behaviour must stop being possible**: an M2 id returning 404
"does not exist" from the PROJECT1 namespace is wrong under every option.

---

## 9. Claims refused

- ❌ "`public.assessments` does not exist, so there is no web assessment store." It exists as
  `public.assessment`; my earlier reports had the name wrong.
- ❌ "The web assessment store is in use — it has 2 rows." Those rows are in
  `Final_Location_Analysis`, a different database.
- ❌ "The readiness endpoint works." It 404s for every M2 assessment.
- ❌ "A join table is needed." Nothing in the chain reads the web store; a join would manufacture
  the ambiguity it claims to solve.
- ❌ "The two ids are interchangeable because both are uuids." That is precisely why they are
  dangerous.

---

## 10. Effect on the chain

`AMB-ASSESSMENT-STORE` is **resolved**: the chain starts at `m2_assessments`. CP-05 (QJ) must be
built against `m2_assessments` only — building it against `public.assessment` would produce a
workflow that never runs on real data, which is the failure the directive anticipated.

CP-05 remains `NOT_RUN`, blocked on `BLK-BCB-AUTH` and `MIG-AUTH-01`, neither of which this
report changes.
