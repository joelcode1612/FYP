# ACTIVITY_HISTORY_PRESENTATION_SPEC_V1

**Status:** `PRESENTATION_DEFINED` for V1 · `PROPOSED` / `DECISION_REQUIRED` where marked
**Supersedes:** nothing. This is the first consolidated record of the agreed presentation.
**Companions:** `ACTIVITY_HISTORY_CONTRACT_V1.md`, `ACTIVITY_HISTORY_DECISION_REGISTER.md`

---

## 0. Provenance — what this document is based on, and what it is not

This specification was reconstructed from artefacts that exist in the repository:

| Source | What it established |
|---|---|
| `fyp_jaspr_web/lib/pages/entrepreneur/activity_history_page.dart` (763 lines) | The implemented layout, sections, copy, filters, states and read-only rules. |
| `fyp_jaspr_web/lib/components/m2_activity_panel.dart` | Data binding, coverage lines, JSON dialog, assessment picker. |
| `docs/cp00_integration/PROJECT1_CP03F_BDJ_UI_AND_HISTORY_VERIFICATION_20261117.md` D06, D14 | The fidelity requirements and their verdicts. |
| `backend/src/sitewise/services/m2_service.py`, `repositories/m2_repository.py` | What the presentation can actually be fed. |
| `docs/architecture/activity_history/snapshots/*.png` | The page as rendered on 2026-11-17. |

**What is not available:** the original design discussions and the reference
mockup `SiteWise_Activity_History_With_Assessment_Selector.html` that the page's
own header comment cites. That file is **not in the repository** and was not
accessible for this pass. No claim below is sourced to it.

Anything not evidenced by the artefacts above is marked `PROPOSED` or
`DECISION_REQUIRED`. Nothing is marked `APPROVED` on the strength of a design
conversation this pass could not read.

---

## 1. Overall page layout and navigation

The page is a single read-only workspace rendered inside the existing
application shell. It does **not** add its own sidebar or navigation.

Vertical order, top to bottom:

| # | Block | Purpose | Status |
|---|---|---|---|
| 1 | Page heading + breadcrumb | `Assessments › Review portal › Activity history`; title *Activity history*; one-sentence scope statement | `IMPLEMENTED` |
| 2 | Assessment picker | Native `<select>` of the owner's saved assessments | `IMPLEMENTED` |
| 3 | Assessment identity + context stats | Business name, assessment id, three counters | `IMPLEMENTED` |
| 4 | Filters | Engine, activity type, status, start date, end date, plus *Reset filters* | `IMPLEMENTED` |
| 5 | Workflow history coverage | Per-engine availability, and the BCB snapshot block | `IMPLEMENTED` |
| 6 | Two-column grid | Timeline (left) + Activity details (right) | `IMPLEMENTED` |
| 7 | Footnote | "Engine completion is not scientific acceptance, owner acceptance, report admission, or evidence sufficiency." | `IMPLEMENTED` |

**Scope statement (verbatim, must not be weakened):**

> See what has happened during this assessment, including processing steps,
> decisions and updates. Saved workflow metadata only — private answers,
> business text and model payloads are not shown.

**Context stats** are three fixed counters: *Recorded activities* (total events
loaded), *Modules in current view* (distinct engines after filtering), *Latest
matching activity* (timestamp of the newest matching event, or `No matching
activity`). They describe the loaded window, not the whole system.

The picker is a native `<select>` rather than a custom menu **because** a custom
menu had no readable loading, empty or error state. Recorded as `AH-D-02`.

---

## 2. Assessment selection and filtering

### 2.1 Selection

* Options come only from the authenticated M2 assessment list for the signed-in
  owner. No illustrative or sample identifiers are ever inserted.
* An unbound History route (no `?assessment=`) defaults to the **first
  server-returned** saved assessment.
* A direct link keeps its explicit id even when that assessment falls outside
  the bounded 50-item list window.
* When the list is exactly 50 items the page states that it is showing the 50
  most recent and that a direct link can still open an older one.
* Invalid or duplicate rows in the list are a **format error**, not silently
  treated as "no records".

### 2.2 Filters

| Filter | Type | Behaviour | Status |
|---|---|---|---|
| Engine / module | select | Exact match on the event's module | `IMPLEMENTED` |
| Activity type | select | Exact match on the event kind | `IMPLEMENTED` |
| Status | select | Exact match on the stored status string | `IMPLEMENTED` |
| Start date | date | `event_date_utc >= value` | `IMPLEMENTED` |
| End date | date | `event_date_utc <= value` | `IMPLEMENTED` |

Filter option lists are derived from the **loaded events**, except the engine
list, which is seeded with the fixed workflow vocabulary (M2, BDJ, Business
Understanding, BCB, QJ, Question Bank / QG, Scientific / Owner / Fielding,
Customer Questionnaire). Seeding the engine list is deliberate: it lets a user
select an engine that has produced nothing and see an honest empty result,
rather than the engine being absent from the UI entirely. Recorded as `AH-D-03`.

Changing any filter clears the current event selection. *Reset filters* clears
all five and the selection.

Dates are compared in **UTC**, not local time, so a filter means the same thing
regardless of the viewer's timezone.

---

## 3. Engine-specific sections

The page does not render one section per engine. It renders **one timeline** and
one detail panel, and expresses per-engine availability in the *Workflow history
coverage* block. This is a deliberate choice: a per-engine section for an engine
with no records would be an empty box that reads as "nothing happened", which is
not the same as "nothing is recorded".

| Engine | Records shown in the timeline | Coverage line | Status |
|---|---|---|---|
| **M2** | `ASSESSMENT_CREATED`, `ANSWER_SAVED` | "Persisted records loaded. Creation, answers, candidate-rule evaluation, findings, decisions, review and confirmation only; validation failures and distinct submission attempts are not durably exposed." | `IMPLEMENTED` · `VERIFIED` |
| **BDJ** | `BDJ_EVALUATED`, `CANDIDATE_FINDING_RECORDED`, `CLARIFICATION_RECORDED` | "NOT_VERIFIED — no owner-scoped durable execution, output-validation or recovery history API. Candidate-rule receipts are not cloud completion." | `IMPLEMENTED` (deterministic receipts) · cloud `BLOCKED` |
| **Business Understanding** | `REVIEW_RECORDED`, `CONTEXT_CONFIRMED`, `UNCERTAINTY_CONFIRMED` | folded into the M2 line | `IMPLEMENTED` · `VERIFIED` |
| **BCB** | `CONTEXT_PERSISTED` + the snapshot block | "Persisted context metadata and latest status snapshots loaded. Currentness is a read-time revision check, not an invalidation event or new authorization." | `IMPLEMENTED` · `VERIFIED` (state only) |
| **QJ** | none | "NOT_VERIFIED — no version-bound research processing/route/review history API." | `BLOCKED` |
| **Question Bank / QG** | none | "NOT_VERIFIED — no authorized reuse/candidate/technical-review history API." | `BLOCKED` |
| **Scientific / Owner / Fielding** | none | "NOT_VERIFIED — independent authorization decisions are not supplied by this history source." | `BLOCKED` |
| **Customer Questionnaire** | none | "NOT_VERIFIED — respondent history contains private answers; no authorized assessment-level campaign/session metadata binding is available." | `BLOCKED` |
| **Reporting / R01–R12** | none | not yet represented | `DECISION_REQUIRED` (§7 of the directive) |

The coverage block is prefaced by the sentence that keeps it honest:

> Coverage describes available sources, not workflow execution or authorization.
> Missing history does not mean NOT_STARTED, FAILED or COMPLETED.

---

## 4. Record details and source references

The detail panel has a fixed structure.

| Block | Content | Status |
|---|---|---|
| Header | `Activity details` + `Event <kind>:<event_id>` | `IMPLEMENTED` |
| Title row | Human title, `engine · timestamp`, status badge | `IMPLEMENTED` |
| What happened | One sentence derived from stored fields; optional recorded reason; source-currentness line | `IMPLEMENTED` |
| Inputs | Assessment id, plus `source_id` when present | `IMPLEMENTED` |
| Outputs | The event id | `IMPLEMENTED` |
| Processing details | Engine / module, Activity type, **Assessment revision**, **Engine version**, Event ID | `IMPLEMENTED` |
| Audit information | Recorded by, Recorded at, and the read-only statement | `IMPLEMENTED` |
| Actions | `View full log (JSON)` | `IMPLEMENTED` |

**Assessment revision and engine version are separate rows.** They were one row
labelled *Version* showing the revision number; that is now corrected
(`AH-D-05`). When the record stores no version, the row reads
`Not recorded on this event` — it is not filled with the revision.

**Recorded by** reads `Actor not stored on this record` when the source has no
actor column (all `ANSWER_SAVED`, `BDJ_EVALUATED`, `CANDIDATE_FINDING_RECORDED`,
`CONTEXT_PERSISTED`). This is a property of the schema, not a gap in the UI.

**JSON dialog.** Read-only, shows only the fields the page already displays, and
states that in its own copy. Copy failure is reported honestly ("Copy is
unavailable in this browser. Select and copy the JSON manually.") rather than
silently succeeding.

The dialog is an **opaque** surface: a solid card over a dimmed backdrop, with
the JSON in a distinct inset block. It is rendered as a sibling of the workspace
so the fixed overlay is not clipped, which means the design tokens must be scoped
to `.sr-json-backdrop` as well as `.sr-workspace` — without them the card paints
fully transparent over the page (`AH-FMT-16`, `AH-D-18`). Any future engine that
adds a dialog to this page inherits the same requirement.

---

## 5. Status presentation and interpretation

A status badge is rendered for every event. Four tones exist:

| Tone | Trigger (substring, case-insensitive) | Meaning |
|---|---|---|
| success | `completed`, `persisted` | the record states this outcome |
| warning | `review`, `pending` | awaiting a decision |
| danger | `fail` | recorded failure |
| neutral | anything else | unrecognised or absent outcome |

**An unrecognised status stays neutral.** A status the build does not classify
must never read as success. This is a hard rule (`AH-D-06`).

When the source stores no outcome, the badge reads:

> Recorded — outcome not supplied

That string is a factual statement about the source. It is **not** a
placeholder for success, and no code path may substitute a success tone for it.

Observed statuses and their rendering:

| Stored value | Rendered badge |
|---|---|
| `ANSWERED` | success |
| `NOT_PROVIDED`, `SKIPPED_OPTIONAL` | neutral |
| `UNREVIEWED` | warning |
| `KEEP_ORIGINAL`, `REVISE_ANSWER`, `DEFER`, `DISMISS` | neutral |
| `PERSISTED` (context) | success |
| `HELD` | neutral |
| `FAILED` | danger |

> **Open point.** `PERSISTED` renders in the success tone. A persisted context
> is stored, not authorized, and the coverage text says so. Whether a stored-only
> outcome should use the success tone is `DECISION_REQUIRED` (`AH-Q-02`).

---

## 6. Revision and historical snapshot presentation

* Every event displays the **revision it was written against**, in the list and
  in the detail panel.
* `source_is_current` renders as one of two sentences:
  * `Source revision matches the current saved revision.`
  * `Historical source revision — original outcome retained; not a current handoff.`
* Historical events are **retained and displayed**, never hidden when the
  assessment moves on. An earlier answer remains visible after later edits.
* The confirmation digest is shown as a 12-character prefix plus `…`, so a
  reader can compare snapshots without the payload being exposed.
* The BCB block is explicitly titled **"Latest BCB status snapshots — not attempt
  history"**, with the sentence "Earlier failed build attempts may have been
  overwritten by recovery. No synthetic failure or invalidation events are
  created."

Known limitation: `source_is_current` is a revision-equality test and does not
mean "this answer is still in force" (`AH-D-07`).

---

## 7. Model execution and validation details

V1 shows **deterministic receipts only**.

| Shown | Not shown (and why) |
|---|---|
| `BDJ_EVALUATED` with `evaluator_version` (e.g. `BDJ-RULESET-0.2-CAND`) | Cloud model identity, prompt version, token usage — no durable read API |
| `CANDIDATE_FINDING_RECORDED` with `rule_id`, `rule_version`, `review_state` | Model output payload — private, and not stored in a readable form |
| `CLARIFICATION_RECORDED` with the entrepreneur's decision | — |
| BCB build status, `last_code`, `attempt_count` | Attempt sequence — overwritten by recovery |

A candidate-rule evaluation is **not** presented as a cloud model execution, and
the coverage line says so in as many words. No execution receipt is presented as
proof that a business finding was accepted.

Validation failures and distinct submission attempts are not durably exposed and
are declared as such rather than omitted silently.

---

## 8. Loading, empty, blocked and unavailable states

Four distinct states, each with its own copy. They must not be collapsed into
one another.

| State | Trigger | Rendered | Status |
|---|---|---|---|
| **Loading** | request in flight | `Loading saved activity…`; filters disabled; previous assessment's records cleared immediately | `IMPLEMENTED` |
| **Known empty** | source loaded, zero events | `No activities recorded yet` / `This assessment has no recorded events to show.` | `IMPLEMENTED` |
| **Filtered empty** | events exist, filters exclude all | `No matching activities` / `Try clearing some filters.` | `IMPLEMENTED` |
| **Unavailable** | load failed or source refused | `Saved activity could not be loaded from the current service. No substitute activity records are shown.`; timeline reads `Timeline unavailable`; pagination reads `Pagination unavailable` | `IMPLEMENTED` |
| **Blocked engine** | engine has no read API | coverage line `NOT_VERIFIED — <reason>` | `IMPLEMENTED` |

A stale assessment's records are never left on screen while a new one loads.

---

## 9. Read-only interaction rules

The page is a projection. It creates, edits and deletes nothing.

| Allowed | Not allowed |
|---|---|
| Select an assessment | Create, edit, delete an event |
| Filter, reset, paginate | Approve, reject, regenerate, confirm |
| Select an event, open the JSON record, copy it | Correct an audit record |
| — | Any action that would imply authorization |

Stated in the UI:

> This projection is read-only. Audit corrections require a new authorized
> backend event.

and

> All events must be backend-sourced.

---

## 10. Viewport scope — desktop only, no mobile presentation

**Activity History is a desktop surface. There is no mobile presentation and no
mobile requirement.** This is an Owner decision, recorded as `AH-D-21`.

| Breakpoint | Behaviour | Status |
|---|---|---|
| Wide | Timeline and detail side by side | `IMPLEMENTED` · `VERIFIED` |
| Narrow | **Not a supported presentation.** No mobile layout is designed, accepted, or evidenced. | `OUT_OF_SCOPE` (`AH-D-21`) |

The stylesheet still carries narrow-width rules (`@media (max-width: 1170px / 850px / 600px)`)
that predate this work and were inherited with the file. They are **not** an
accepted design and **not** evidence of mobile support: they have not been
reviewed against this specification, and no acceptance claim rests on them. A
future change may delete them, but deleting them is a separate decision and was
not taken here — the page is judged at desktop widths only.

Consequences for later work:

- Do not add a mobile capture to the evidence set, and do not cite one.
- Do not treat the narrow-width rules as a specification to preserve or extend.
- If a mobile presentation is ever wanted, it is a new decision that must reopen
  this section — not an inference from existing CSS.

Pagination is fixed at 6 events per page and is presented as
`Page N of M` with `‹ Previous` / `Next ›`.

---

## 11. Presentation elements that are not yet defined

These are required by the directive but have no implemented or agreed form. They
are recorded here so a later checkpoint does not invent them inconsistently.

| Element | Status | Blocking reason |
|---|---|---|
| QJ record section | `DECISION_REQUIRED` | no QJ history API |
| QG candidate vs approved-question section | `DECISION_REQUIRED` | no QG history API |
| Publication / manifest section | `DECISION_REQUIRED` | no manifest builder or authorization API |
| EE-01 evidence and explanation outcomes | `DECISION_REQUIRED` | not exposed to this source |
| R01–R12 report versions and ReportAdmission | `DECISION_REQUIRED` | reporting not implemented |
| Claim-level evidence references | `DECISION_REQUIRED` | no claim model |
| Cloud BDJ attempt timeline | `PROPOSED` | `project1_ai` frozen (`MIG-AUTH-01`) |

Each will be added as a **new section fed by its own versioned contract**, not by
widening the M2 event envelope.
