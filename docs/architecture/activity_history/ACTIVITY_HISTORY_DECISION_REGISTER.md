# ACTIVITY_HISTORY_DECISION_REGISTER

**Purpose.** Every material presentation or integration decision about Activity
History, in one place, so a later checkpoint does not redesign it by accident.

**Honesty rule for this register.** *Owner approval state* is `NOT RECORDED`
unless an artefact in this repository records it. No decision below is marked
approved on the strength of a conversation this pass could not read.

**Contract version:** `m2-activity/1` + `workflow-history-metadata/2`
**Last updated:** 2026-11-17

---

## AH-D-01 — One timeline, not one section per engine

| Field | Value |
|---|---|
| Component | Whole page |
| Requirement | All engines render into a single chronological timeline plus a single detail panel. Per-engine availability is expressed as a coverage line, not as a section. |
| Reason | A per-engine section with no records is indistinguishable from "nothing happened". A coverage line can say *NOT_VERIFIED — no API*, which a blank section cannot. |
| Evidence | `activity_history_page.dart` build(); coverage block; `snapshots/01_activity_history_overview.png` |
| Implementation | `IMPLEMENTED`, `VERIFIED` |
| Rejected | (a) tabs per engine — hides cross-engine chronology and multiplies empty states; (b) one card per engine — same problem, more vertical space |
| Open questions | Whether a future engine with high volume needs its own filtered view (`AH-Q-01`) |
| Owner approval | `NOT RECORDED` |
| Date | 2026-11-17 (recorded) |

---

## AH-D-02 — Native assessment picker

| Field | Value |
|---|---|
| Component | Assessment picker |
| Requirement | A native `<select>`, populated only from the authenticated assessment list. |
| Reason | A custom button+menu had no readable loading, empty or error state, and could display nothing at all while the list was unavailable. |
| Evidence | `activity_history_page.dart` picker comment + `data-testid="saved-assessment-select"` |
| Implementation | `IMPLEMENTED`, `VERIFIED` |
| Rejected | Custom dropdown (unreadable states); free-text id entry (inventable) |
| Open questions | none |
| Owner approval | `NOT RECORDED` |
| Date | 2026-11-17 |

---

## AH-D-03 — Engine filter seeded with the workflow vocabulary

| Field | Value |
|---|---|
| Component | Filters → Engine / module |
| Requirement | The engine list is the fixed workflow vocabulary, not only the engines present in the loaded events. |
| Reason | Otherwise an engine with no records is invisible, and a user cannot discover that it is unsupported. Selecting it yields an honest empty result. |
| Evidence | `build()` seeds `M2, BDJ, Business Understanding, BCB, QJ, Question Bank / QG, Scientific / Owner / Fielding, Customer Questionnaire`; `snapshots/08_empty_filter_result.png` |
| Implementation | `IMPLEMENTED`, `VERIFIED` |
| Rejected | Deriving the list from loaded events only |
| Open questions | none |
| Owner approval | `NOT RECORDED` |
| Date | 2026-11-17 |

---

## AH-D-04 — `reason` is a reason, never a version or an identifier

| Field | Value |
|---|---|
| Component | Event envelope (`m2-activity/1`, per-kind fields) |
| Requirement | `reason` carries a human-readable explanation only. Versions get `evaluator_version` / `rule_version` / `builder_version`; identifiers get `rule_id` / `source_id`. |
| Reason | The reader populated `reason` from `evaluator_version` for evaluations and from `rule_id` for findings, so the UI printed `Recorded reason: BDJ-RULESET-0.2-CAND` and `Recorded reason: BDJ-M2V1-R03`. A version is not a reason; a rule id is not a reason. |
| Evidence | `m2_repository.py` `read_activity` per-kind projection; `test_activity_projection.py::test_evaluation_version_is_not_reported_as_a_reason`; `activity_event_presentation_test.dart` |
| Implementation | `IMPLEMENTED`, `VERIFIED` |
| Rejected | Keeping the overload and relabelling the UI (the field would still lie to any other consumer) |
| Open questions | none |
| Owner approval | `NOT RECORDED` |
| Date | 2026-11-17 |

---

## AH-D-05 — Assessment revision and engine version are separate

| Field | Value |
|---|---|
| Component | Detail panel → Processing details |
| Requirement | Two rows: *Assessment revision* (always known) and *Engine version* (or `Not recorded on this event`). |
| Reason | One row labelled *Version* showed the assessment revision, so a ruleset evaluation displayed "Version 12" — a revision presented as a version. |
| Evidence | `activity_history_page.dart` detail rows; `snapshots/02_detail_answer_saved.png` shows `Engine version: Not recorded on this event` |
| Implementation | `IMPLEMENTED`, `VERIFIED` |
| Rejected | Hiding the version row when unknown (loses the distinction between "no version" and "not displayed") |
| Open questions | none |
| Owner approval | `NOT RECORDED` |
| Date | 2026-11-17 |

---

## AH-D-06 — An unknown status never reads as success

| Field | Value |
|---|---|
| Component | Status badge |
| Requirement | Tones map from explicit substrings; anything unrecognised is neutral. Absent outcome renders `Recorded — outcome not supplied`. |
| Reason | A status the build cannot classify must not be coloured as success; that would be a fabricated outcome. |
| Evidence | `activity_history_page.dart` `_tone()` and its comment; `activity_history_availability_test.dart` (FAILED survives, PERSISTED distinct) |
| Implementation | `IMPLEMENTED`, `VERIFIED` |
| Rejected | Default-to-success; default-to-warning |
| Open questions | `AH-Q-02` — should `PERSISTED` use the success tone at all? |
| Owner approval | `NOT RECORDED` |
| Date | 2026-11-17 |

---

## AH-D-07 — `source_is_current` means revision equality

| Field | Value |
|---|---|
| Component | Event envelope + detail panel |
| Requirement | The flag is `event.assessment_revision == assessment.revision`, rendered as one of two fixed sentences. |
| Reason | It answers "was this written against the revision that is current now", which is answerable from one row. |
| Evidence | `m2_service.py` `activity()`; `snapshots/02_detail_answer_saved.png` shows the matching-revision sentence |
| Implementation | `IMPLEMENTED`, `VERIFIED` |
| Rejected | Renaming it to imply answer validity without changing the computation (a label that outruns its referent) |
| Open questions | `AH-Q-03` — an answer at revision 3, never superseded, reports `false` at revision 13. Whether to compute "still in force" needs a decision, because it changes what the flag asserts. |
| Owner approval | `NOT RECORDED` |
| Date | 2026-11-17 |

---

## AH-D-08 — No substitute records, ever

| Field | Value |
|---|---|
| Component | Whole page |
| Requirement | A failed or empty source renders its own message. No placeholder, sample, cached-from-another-assessment or synthesised event is rendered. |
| Reason | A substitute record is indistinguishable from a real one at the point of reading, and this page is evidence. |
| Evidence | `m2_activity_panel.dart` error copy ("No substitute activity records are shown."); `snapshots/09_unavailable_source.png` |
| Implementation | `IMPLEMENTED`, `VERIFIED` |
| Rejected | Sample data for demos; stale-data fallback |
| Open questions | none |
| Owner approval | `NOT RECORDED` |
| Date | 2026-11-17 |

---

## AH-D-09 — Coverage lines instead of empty sections

| Field | Value |
|---|---|
| Component | Workflow history coverage |
| Requirement | Every engine without a read API gets an explicit `NOT_VERIFIED — <reason>` line, and the block states that coverage is not execution. |
| Reason | Absence of a record must not read as absence of an event. |
| Evidence | `m2_activity_panel.dart` `sourceCoverage`; `snapshots/01_activity_history_overview.png` |
| Implementation | `IMPLEMENTED`, `VERIFIED` |
| Rejected | Omitting unavailable engines (reads as "not applicable") |
| Open questions | none |
| Owner approval | `NOT RECORDED` |
| Date | 2026-11-17 |

---

## AH-D-10 — BCB is shown as latest snapshots, not attempt history

| Field | Value |
|---|---|
| Component | Latest BCB status snapshots block |
| Requirement | Render one row per confirmation with status, attempts, `last_code`, context id, and currentness; state that earlier attempts may have been overwritten. |
| Reason | The BCB store keeps mutable latest state. Presenting it as a sequence would invent history. |
| Evidence | `read_activity_supplement` docstring; `m2_activity_panel.dart` `currentSnapshots`; live row `HELD` / `BCB_BINDING_AUTHORITY_UNVERIFIED` |
| Implementation | `IMPLEMENTED`, `VERIFIED` (state only; no attempt history exists) |
| Rejected | Deriving an attempt timeline from `attempt_count` (fabricates events) |
| Open questions | none |
| Owner approval | `NOT RECORDED` |
| Date | 2026-11-17 |

---

## AH-D-11 — The JSON record contains only displayed fields

| Field | Value |
|---|---|
| Component | Event record dialog |
| Requirement | The dialog serialises the event record the page already shows. No private answers, business text or model payloads. |
| Reason | A "full log" that exposes more than the page would leak data the projection was designed to withhold. |
| Evidence | `m2_activity_panel.dart` `_openJson` + dialog copy |
| Implementation | `IMPLEMENTED`, `VERIFIED` |
| Rejected | Dumping the raw row |
| Open questions | none |
| Owner approval | `NOT RECORDED` |
| Date | 2026-11-17 |

---

## AH-D-12 — Six events per page

| Field | Value |
|---|---|
| Component | Timeline pagination |
| Requirement | `pageSize = 6`, `Page N of M`, Previous/Next. |
| Reason | Keeps the detail panel visible beside the list at common viewport heights. |
| Evidence | `activity_history_page.dart` `pageSize`; `snapshots/01_activity_history_overview.png` shows `Page 1 of 3` for 17 events |
| Implementation | `IMPLEMENTED`, `VERIFIED` |
| Rejected | Infinite scroll (loses position on selection) |
| Open questions | none |
| Owner approval | `NOT RECORDED` |
| Date | 2026-11-17 |

---

## AH-D-13 — History reads persisted receipts only

| Field | Value |
|---|---|
| Component | Backend read path |
| Requirement | Every event corresponds to a row that exists. The service computes no events, derives no state transitions, and back-fills nothing. |
| Reason | A computed event cannot be audited and cannot be corrected by a new authorized record. |
| Evidence | `read_activity` + `read_activity_supplement`; `scope: PERSISTED_M2_ACTIVITY`; `test_activity_projection.py` |
| Implementation | `IMPLEMENTED`, `VERIFIED` |
| Rejected | Deriving `ASSESSMENT_UPDATED` from revision deltas |
| Open questions | none |
| Owner approval | `NOT RECORDED` |
| Date | 2026-11-17 |

---

## AH-D-14 — `authorization_decisions_included` is a constant false

| Field | Value |
|---|---|
| Component | Envelope |
| Requirement | Always `false`, and the client rejects a response where it is not `false`. |
| Reason | A consumer must be able to tell "this source does not carry decisions" from "no decisions were made". |
| Evidence | `m2_service.py`; `api_m2_repository.dart` validator |
| Implementation | `IMPLEMENTED`, `VERIFIED` |
| Rejected | Omitting the field (silently implies completeness) |
| Open questions | none |
| Owner approval | `NOT RECORDED` |
| Date | 2026-11-17 |

---

## AH-D-15 — The confirmed-review contract was not widened

| Field | Value |
|---|---|
| Component | `project1-confirmed-review/1` |
| Requirement | The shared reader now returns per-kind enrichment; the confirmed-review projection filters it back to its declared fields. |
| Reason | `ReviewActivity` is `extra='forbid'` and the contract is frozen. Enriching History must not silently change a second contract. |
| Evidence | `confirmed_review_service.py` projection comment; `tests/project1` 164 passed |
| Implementation | `IMPLEMENTED`, `VERIFIED` |
| Rejected | Adding optional fields to `ReviewActivity` (a contract change with no consumer asking for it) |
| Open questions | none |
| Owner approval | `NOT RECORDED` |
| Date | 2026-11-17 |

---

## AH-D-16 — Enrichment is versioned by `history_extension`, not by the envelope

| Field | Value |
|---|---|
| Component | Versioning |
| Requirement | `workflow-history-metadata/2` carries per-kind fields. The envelope stays `m2-activity/1`. The client accepts `/1` and `/2`. |
| Reason | No field was removed or retyped, so the envelope version is unchanged; but a reader must be able to tell the legacy shape (where `status` is null for every answer) from the enriched one. |
| Evidence | `m2_service.py`; `api_m2_repository.dart` accepted-set; `ACTIVITY_HISTORY_CONTRACT_V1.md` §9 |
| Implementation | `IMPLEMENTED`, `VERIFIED` |
| Rejected | Bumping `contract_version` (would force every consumer to change for an additive change); leaving the version at `/1` (a reader could not distinguish the shapes) |
| Open questions | none |
| Owner approval | `NOT RECORDED` |
| Date | 2026-11-17 |

---

## AH-D-17 — History never calculates report findings (V2 rule, pre-committed)

| Field | Value |
|---|---|
| Component | Future reporting section |
| Requirement | When R01–R12 reporting arrives, History references the same versioned evidence and decision records the report uses. History must not independently compute a finding. |
| Reason | Two calculators over one evidence set will disagree, and the disagreement will be invisible. |
| Evidence | Directive §7; no implementation exists yet |
| Implementation | `CONTRACT_DEFINED` only |
| Rejected | Letting History summarise report content from raw events |
| Open questions | `AH-Q-04` — which store is authoritative for a report claim reference? |
| Owner approval | `NOT RECORDED` |
| Date | 2026-11-17 (pre-commitment) |

---

## AH-D-18 — Design tokens must reach the JSON dialog

| Field | Value |
|---|---|
| Component | `sitewise_report_activity.css`, `.sr-json-backdrop` |
| Requirement | The token block (`--sr-ink`, `--sr-white`, `--sr-soft`, …) applies to `.sr-workspace` **and** `.sr-json-backdrop`. Layout properties stay on `.sr-workspace` alone. |
| Reason | The dialog is rendered as a sibling of the workspace so a `position: fixed` overlay is not clipped by the workspace box. Outside that scope every token resolved to the empty string, so `background: var(--sr-white)` was invalid and the dialog painted fully transparent — measured `rgba(0, 0, 0, 0)` for both the dialog and its `<pre>`. |
| Evidence | DOM probe: `dialog_bg = rgba(0,0,0,0)`, `--sr-white = ""`; before/after captures |
| Implementation | `IMPLEMENTED` and `VERIFIED` (shot 06 renders opaque) |
| Rejected | Duplicating the token values on the backdrop (two sources of truth); moving the dialog inside `.sr-workspace` (a fixed overlay inside a `max-width` box is a layout hazard, and the markup change was not necessary) |
| Open questions | none |
| Owner approval | `NOT RECORDED` — this is a defect fix, not a design change; the visual result is unchanged from the intended design |
| Date | 2026-11-17 |

---

## AH-D-19 — A capture must assert the state it claims

| Field | Value |
|---|---|
| Component | `backend/scripts/cp03f_history_screenshots.py` |
| Requirement | Before writing a PNG, the script asserts the DOM is in the state the shot claims. For the dialog: `.sr-json-dialog` must exist. If it does not, no PNG is written and the manifest records `captured: false` with the reason. |
| Reason | An earlier run shipped a screenshot labelled *"Read-only event record dialog"* that contained no dialog. The selector `startsWith('View full log')` could never match, because the button's `textContent` is `codeView full log (JSON)` — the material icon is a ligature text node inside the same `<button>`. The note was false and the image proved nothing. |
| Evidence | `capture_manifest.json` now carries `dialog_open`, `filters`, and `sha256` per shot; `duplicate_shots: []` |
| Implementation | `IMPLEMENTED` and `VERIFIED` |
| Rejected | Trusting the script's intent; recording the note from the code path rather than from the observed DOM |
| Open questions | none |
| Owner approval | not applicable (verification method) |
| Date | 2026-11-17 |

---

## AH-D-20 — The actor binding is per transaction, not per connection

| Field | Value |
|---|---|
| Component | `backend/tests/m2_bcb/test_activity_projection.py` |
| Requirement | Bind `project1.actor_id` on SQLAlchemy's `begin` event with `is_local = true`, and assert the binding is in force before asserting anything about the data. |
| Reason | PostgreSQL's `SET` is transactional. A binding made on `connect` is undone when the pool rolls back on return, so the next `Session` sees nothing. The failure is silent: the projection returns an empty list and every loop-shaped assertion passes vacuously. The module reported `5 skipped` against a database holding 61 answers. |
| Evidence | `6 passed` against the live `Dss` with the runtime DSN; `1 skipped` at module level without it |
| Implementation | `IMPLEMENTED` and `VERIFIED` |
| Rejected | Using a superuser DSN to sidestep RLS — it bypasses the policies and so would not exercise the posture the service actually runs under |
| Open questions | none |
| Owner approval | not applicable (test method) |
| Date | 2026-11-17 |

---

## AH-D-21 — Activity History is desktop only; no mobile presentation

| Field | Value |
|---|---|
| Component | Whole page (`activity_history_page.dart`, `sitewise_report_activity.css`) |
| Requirement | Activity History is presented at desktop widths only. There is no mobile layout, no mobile acceptance criterion, and no mobile screenshot in the evidence set. |
| Reason | Owner instruction, 2026-11-17: *"i donot want mobile actually"*. A mobile presentation was never designed for this page; the narrow-width rules exist only because they were inherited with the stylesheet. |
| Evidence | `snapshots/` contains **9** captures, all desktop; the 390×844 capture from an earlier run was **withdrawn**, not retained. `ACTIVITY_HISTORY_PRESENTATION_SPEC_V1.md` §10 now reads `OUT_OF_SCOPE`. |
| Implementation | No code change. The inherited `@media (max-width: 1170px / 850px / 600px)` rules remain in place, unreviewed and unsupported. |
| Rejected | Keeping the mobile capture as "harmless extra evidence" — it would have implied a supported presentation and invited a future checkpoint to preserve it; deleting the inherited media queries in this pass — a shared-stylesheet change that was not asked for and could affect other routes |
| Open questions | none — `AH-Q-09` was raised and **answered** in the same session: leave the inherited narrow-width rules in place, unreviewed and unsupported. No code change was made. |
| Owner approval | **RECORDED** — direct Owner instruction, 2026-11-17. Not a signed document; recorded from the Owner's own message. |
| Date | 2026-11-17 |

---

## Outstanding questions

| ID | Question | Blocks |
|---|---|---|
| `AH-Q-01` | Does a high-volume engine need its own filtered view within History? | nothing today |
| `AH-Q-02` | Should `PERSISTED` (stored, not authorized) use the success tone? | a tone change |
| `AH-Q-03` | Should `source_is_current` mean "still in force" rather than "written at the current revision"? | the flag's meaning |
| `AH-Q-04` | Which store is authoritative for a report claim reference? | V2 |
| `AH-Q-05` | Should `ANSWER_SAVED` store the acting user? The table has no actor column, so 61 records say "Actor not stored". | a schema change |

### Resolved in this session

| ID | Question | Answer |
|---|---|---|
| `AH-Q-09` | Should the inherited narrow-width `@media` rules be deleted from `sitewise_report_activity.css`? | **No — leave them in place.** Owner decision, 2026-11-17. Mobile is out of scope (`AH-D-21`) either way; the rules are unreviewed dead weight, not a specification. No code change. |
