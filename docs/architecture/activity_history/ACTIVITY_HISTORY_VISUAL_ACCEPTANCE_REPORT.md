# ACTIVITY_HISTORY_VISUAL_ACCEPTANCE_REPORT

**Purpose.** State what the Activity History screenshots actually are, what they
prove, and what they do not. The directive is explicit that a screenshot of a
fabricated record is not verification, and that the reader must be able to tell
real browser evidence from a proposed mockup. This report is that disclosure.

**Date:** 2026-11-17 · **Contract:** `m2-activity/1` + `workflow-history-metadata/2`
**Snapshot directory:** `docs/architecture/activity_history/snapshots/`
**Machine-readable companion:** `snapshots/capture_manifest.json`

---

## 1. How the images were produced

Every image is a screenshot of the **running application**, captured through the
Chrome DevTools Protocol. Nothing in the chain is stubbed.

| Layer | What was actually running |
|---|---|
| Client | The compiled Jaspr build (`build/jaspr/`) served by the application itself |
| Browser | Real headless Chrome, driven over CDP `Page.captureScreenshot` |
| Identity | A real ES256 token minted against a local P-256 JWKS, written into the Supabase session slot the client reads |
| API | Real `uvicorn` on `127.0.0.1:8011`, no test double |
| Database | Real PostgreSQL `Dss`, read through the runtime role `p1_m2_runtime` with `project1.actor_id` bound |
| Subject | Synthetic entrepreneur `11111111-1111-4111-8111-111111111111` |
| Assessment | `da90aa4a-f9cf-4145-9acf-7de36c9d6fad` (revision 12) |

The response behind the page is archived verbatim as `snapshots/activity_response.json`:
`contract_version = m2-activity/1`, `history_extension = workflow-history-metadata/2`,
`scope = PERSISTED_M2_ACTIVITY`, `17 events`, `truncated = false`,
`authorization_decisions_included = false`, `1 bcb_status`.

Each capture also records what the DOM said at the moment of the shot —
`document.title`, the timeline summary, the selected detail heading, the status
badge, the row count, the applied filter values, and a SHA-256 of the PNG. A
screenshot therefore cannot be silently relabelled as a different state.

---

## 2. Evidence classification

| Category | Count | Files |
|---|---|---|
| **ACTUAL BROWSER EVIDENCE** | **9** | all nine PNGs in `snapshots/` |
| Proposed mockup | 0 | — |
| Illustrative / synthetic record rendered as if production | 0 | — |
| Withdrawn capture | 1 | `10_mobile_overview.png` — deleted, not retained (see §3) |

**No mockups are included in this report or in `snapshots/`.** The reference
mockup named in the design discussion (`SiteWise_Activity_History_With_Assessment_Selector.html`)
is not present in the repository and was therefore not used, not copied, and not
reproduced. `ACTIVITY_HISTORY_PRESENTATION_SPEC_V1.md` §0 records that absence.

The records visible in the images are real rows. They belong to a **synthetic
entrepreneur created for testing**, not to a real user — this is stated here so
that the images are not mistaken for production traffic. Being synthetic is a
property of the *account*, not of the *rendering*: the same code path, the same
API, the same database, the same RLS posture.

### 2.1 These are real rows, but they are **not** LLM output

This distinction is easy to lose, so it is stated explicitly: **no screenshot in
this set shows an LLM response, and none can.** Three separate reasons, each
verified against the database:

| Reason | Evidence |
|---|---|
| The only BDJ event in History is a **deterministic ruleset**, not a cloud model call | `m2_bdj_evaluations` holds 2 rows, both `evaluator_version = BDJ-RULESET-0.2-CAND` |
| That table has **no output column at all** — only `id`, `assessment_id`, `assessment_revision`, `evaluator_version`, `created_at` | `information_schema.columns` |
| No `public.m2_*` table has any model / prompt / output / payload column | queried for `%model%`, `%prompt%`, `%completion%`, `%llm%`, `%output%`, `%payload%` — **none** |

Cloud BDJ executions *do* exist, in a separate schema that History cannot read:

| Fact | Value |
|---|---|
| `project1_ai.runs` / `attempts` / `attempt_receipts` | 9 / 9 / 9 rows, all for assessment `da90aa4a…` at revision 12 |
| `prompt_version` values | `BDJ-SOURCE-1-CAND` (4), `BDJ-SOURCE-2-CAND` (4), `BDJ-SOURCE-3-CAND` (1) |
| Receipt outcomes | `returned` 5 · `rejected` 2 · `unknown_outcome` 2 |
| Stored result | `output_digest` — a **SHA-256 digest**, never the model's text |
| Readable by History? | **No.** `MIG-AUTH-01`: the schema is frozen against every application principal, and there is no owner-scoped read API |

Two consequences that later work must not gloss over:

1. **Even when V1.1 is unblocked, History will show an execution receipt, not an
   LLM answer.** The ledger records that a run returned and what its output
   hashed to; it does not store the prose. Displaying "the LLM said X" would
   require a payload store that does not exist.
2. **Whether those 9 attempts are genuine model calls is `NOT VERIFIED`.** Some
   rows carry obviously placeholder fingerprints (`aaaa…`, `cccc…`, `dddd…`),
   which indicates harness fixtures. This report does not claim they are real
   model invocations.

What the screenshots therefore prove is a **real, working, auditable activity
record for deterministic M2 work** — not a working LLM pipeline.

---

## 3. Capture register

All nine were taken in one run against one build. `duplicate_shots: []` — no two
images are byte-identical, so each is distinct evidence.

| # | File | State exercised | Observed at capture |
|---|---|---|---|
| 01 | `01_activity_history_overview.png` | Default landing: picker, context stats, filters, coverage, timeline + detail | `17 matching activities · Newest first`; default selection `Uncertainty declared`; badge `Recorded — outcome not supplied`; 6 rows on page 1 of 3 |
| 02 | `02_detail_answer_saved.png` | `ANSWER_SAVED` detail | `Answer saved`; badge `ANSWERED`; *Answer for M2V1-11 recorded at revision 12*; Engine version `Not recorded on this event`; Recorded by `Actor not stored on this record` |
| 03 | `03_detail_bdj_evaluated.png` | `BDJ_EVALUATED` detail | `Candidate rule evaluation`; summary cites `BDJ-RULESET-0.2-CAND` |
| 04 | `04_detail_context_confirmed.png` | `CONTEXT_CONFIRMED` detail | `Business context confirmed`; digest `8cfc90ddd091…` shown truncated in the row |
| 05 | `05_detail_review_recorded.png` | `REVIEW_RECORDED` detail | `Review recorded`; *Review recorded at revision 12* |
| 06 | `06_json_record_dialog.png` | Read-only JSON dialog, opened from the selected `REVIEW_RECORDED` event | Dialog present (`dialog_open: true`), heading `Event record (JSON)`; body begins `assessment_id`, `event_id`, `kind: REVIEW_RECORDED`, `assessment_revision: 12`, `source_is_current: true`; actions `Copy JSON` / `Done` |
| 07 | `07_filtered_status_answered.png` | Status filter `ANSWERED` only | `10 matching activities` (from 17); filters observed `["", "", "ANSWERED"]` |
| 08 | `08_empty_filter_result.png` | Filters reset, then engine module `QJ` only | `0 matching activities`; filters observed `["QJ", "", ""]`; timeline `No matching activities — Try clearing some filters.`; detail `No activity selected` |
| 09 | `09_unavailable_source.png` | Unresolvable assessment id | `Timeline unavailable`; *Saved activity could not be loaded from the current service. No substitute activity records are shown.*; picker `No saved assessments`; 0 rows |

### Why these nine and not others

- **`UNCERTAINTY_CONFIRMED` has no dedicated detail shot.** It is the newest
  event and therefore the default selection in shot 01; a second capture would
  have been byte-identical to 01 and would have proved nothing new.
- **`CLARIFICATION_RECORDED`, `CANDIDATE_FINDING_RECORDED` and `CONTEXT_PERSISTED`
  have no shots at all**, because zero such rows exist in the database. Rendering
  them would have required fabricating records, which the directive forbids.
- **There is no mobile shot, deliberately.** An earlier run captured the page at
  390×844. That capture was **withdrawn on Owner instruction** (2026-11-17) and
  the PNG was deleted: Activity History is a desktop surface with no mobile
  requirement (`AH-D-21`, spec §10). Keeping it would have implied a supported
  presentation that does not exist. The narrow-width CSS inherited with the
  stylesheet is not evidence of mobile support.
- **`08` uses a single filter deliberately.** An earlier version left the
  `ANSWERED` status filter applied, which made the empty result over-determined —
  either filter alone would have produced zero rows, so the image would not have
  shown *which* filter caused it. Filters are now reset first, and the applied
  values are recorded in the manifest so the claim is checkable.

---

## 4. What these images do **not** prove

| Not proven | Why |
|---|---|
| That a finding decision was exercised in production | No authorized finding exists; 0 `CLARIFICATION_RECORDED` rows. The lifecycle is untested. |
| That candidate findings render | 0 `CANDIDATE_FINDING_RECORDED` rows. |
| That a persisted BCB context renders as an event | 0 `CONTEXT_PERSISTED` rows; the BCB build is `HELD`. |
| Truncation behaviour | `limit` was never exceeded; `truncated: false` in every response. |
| That the authenticated M2 journey completes end-to-end | Blocked by `OD-3`: `M2V1-01` (REQUIRED, `GEO`) is unreachable in the panel, so a *fresh* confirmation cannot be produced through the UI. History was verified against **existing** records instead. |
| Anything about QJ, QG, BCB attempt history, or reporting | Those sources have no history API; the page says `NOT_VERIFIED` for each. |
| Cross-owner or unauthenticated behaviour | Not visual. Proven at the HTTP layer instead: `404` for another owner, `401` without a token. |

**A defined presentation is not evidence of a working backend.** The reverse is
also true and is recorded here: a working backend is not evidence that the
presentation is acceptable — which is why shot 06 matters (see §5.1).

---

## 5. Defects this pass found and fixed

The visual pass was not a rubber stamp. It found three defects, two of them in
the evidence chain itself.

### 5.1 The JSON dialog painted fully transparent (`AH-FMT-16`)

**Symptom.** Shot 06 showed the page with no dialog at all. A DOM probe reported
the dialog was present (`1`), so the element existed but was invisible.

**Cause.** `.sr-json-dialog` sets `background: var(--sr-white)`. Those tokens are
declared on `.sr-workspace`, and the dialog is rendered as a **sibling** of the
workspace so a fixed overlay is not clipped by the workspace box. Outside that
scope, `--sr-white` resolved to the empty string, so `background: var(--sr-white)`
was invalid and painted nothing. Measured: `dialog_bg = rgba(0, 0, 0, 0)`,
`pre_bg = rgba(0, 0, 0, 0)`, `--sr-white = ""`.

**Fix.** The token block now applies to `.sr-workspace, .sr-json-backdrop`; the
layout properties stay on `.sr-workspace` alone, so the overlay's `inset: 0` is
unaffected. Rebuilt and re-captured: the dialog now renders opaque white with its
shadow, and the JSON is legible. No markup, contract, or schema change.

### 5.2 The capture script's selector never matched (`AH-FMT-17`)

**Symptom.** The manifest for shot 06 asserted *"Read-only event record dialog"*
while the PNG showed no dialog. The note was false.

**Cause.** The button's `textContent` is `codeView full log (JSON)` — the material
icon is a ligature text node inside the same `<button>` — so a prefix match on
`View full log` never fired, and the click was silently skipped.

**Fix.** Match on containment, verify `.sr-json-dialog` exists before capturing,
fall back to a real `Input.dispatchMouseEvent` press if the synthetic click is not
delivered, and record `dialog_open` in the manifest. If the dialog does not open,
the run now writes **no** PNG and records `captured: false` with the reason,
rather than shipping a picture of the wrong thing.

### 5.3 The live projection test was skipping, not passing

**Symptom.** `tests/m2_bcb/test_activity_projection.py` reported `5 skipped`
against the live database. Four of its five tests loop over a projected event
list, so an empty list would have made them **pass vacuously**.

**Cause.** Two independent mistakes. The fixture queried as `p1_m2_runtime` with
no actor bound, so row-level security hid every row; and the actor was bound on
`connect`, where PostgreSQL's transactional `SET` is undone by the pool's
rollback-on-return, so the subsequent `Session` saw nothing even when the
discovery query succeeded.

**Fix.** Bind on the `begin` event with `is_local = true`, so the binding is
re-applied to every transaction exactly as the service does per request. Added
`test_actor_binding_is_in_force`, which asserts `current_setting('project1.actor_id')`
equals the owner and that the projection is non-empty, so this failure mode can
never again be mistaken for "no data". Each remaining test now asserts its own
event set is non-empty.

**Result.** `6 passed` against the live database, `1 skipped` (module-level) when
`ACTIVITY_HISTORY_DB_URL` is unset, so the default suite stays hermetic.

---

## 6. Classification of each History version

Vocabulary required by the directive. `PRESENTATION_DEFINED` · `CONTRACT_DEFINED` ·
`IMPLEMENTED` · `VERIFIED` · `BLOCKED` · `OWNER_DECISION_REQUIRED`.

| Version | Presentation | Contract | Implemented | Verified | Overall |
|---|---|---|---|---|---|
| **V1** — M2 answers/revisions, BDJ, review, confirmation | `PRESENTATION_DEFINED` | `CONTRACT_DEFINED` | `IMPLEMENTED` | `VERIFIED` for six of nine kinds; the other three have no rows | **VERIFIED (partial by data availability)** |
| **V1.1** — Cloud BDJ linkage | `PRESENTATION_DEFINED` | `CONTRACT_DEFINED` | `BLOCKED` (`MIG-AUTH-01`) | `BLOCKED` | **BLOCKED** |
| **V1.2** — BCB / QJ / QG | BCB state `PRESENTATION_DEFINED`; attempt history, QJ, QG `OWNER_DECISION_REQUIRED` | BCB state `CONTRACT_DEFINED`; others undefined | BCB state `IMPLEMENTED` | BCB state only | **BLOCKED beyond latest-state snapshots** |
| **V2** — publication and reporting | `PROPOSED` | `PROPOSED` | `BLOCKED` | `BLOCKED` | **BLOCKED** |

Visual verification applies to **V1 only**. V1.1, V1.2 and V2 have no screenshots
because they have no records to screenshot; the page states their absence in the
workflow-coverage block rather than implying coverage.

---

## 7. Reproducing this evidence

```bash
cd backend
rm -f ../docs/architecture/activity_history/snapshots/*.png
NO_PROXY=localhost,127.0.0.1 HTTP_PROXY= HTTPS_PROXY= \
  .venv/Scripts/python.exe scripts/cp03f_history_screenshots.py
```

The run requires the local JWKS harness, PostgreSQL `Dss` reachable at the
configured `m2_database_url`, and a prior `dart run jaspr_cli:jaspr build` in
`fyp_jaspr_web`. It writes the PNGs, `activity_response.json`, and
`capture_manifest.json`, and fails loudly if the JSON dialog does not open or if
two shots collide.

---

## 8. Full SHA-256 of each capture

```
01_activity_history_overview.png    b1b016dbcd1874a6a8d192010f2e3509b366decd22cf811763d68729c1cf5564
02_detail_answer_saved.png          08058fa57a9a98cf6bbf4609d807ed0033844fd172d9f6779395e07f4b0b2e46
03_detail_bdj_evaluated.png         1f1914ce4b4b776c1cc63d5b59b6a31a79463d039429113546778c5008008c9c
04_detail_context_confirmed.png     9f435eaa92d77ae5e06de99214fae4ff099673ffe1d19d6d29a5c83d7d2be02f
05_detail_review_recorded.png       bfd731c08c78e5dd5cd9d207d8afb438e435c925d9dc9389077b00ad8779e255
06_json_record_dialog.png           d3b2412e020915ec029b7cd942bf1d03a6d49ec7df1423b5997f44df513cbb5e
07_filtered_status_answered.png     09a1782f0429450cab8089ba4499a13ade885e2b0bc10624ebff971e8e2332c1
08_empty_filter_result.png          bd77923841aad51dab626f54ec74ae66a9399644df29ff7ff48f63d0693dfab2
09_unavailable_source.png           90ea6186b105d6e497097a2e1176dbbac54edd38c17423fd2100b76c0b12cd3d
```

---

## 9. Status

| Item | State |
|---|---|
| Screenshots captured from the running application | **9 of 9** (desktop) |
| Mobile captures | **0** — withdrawn on Owner instruction (`AH-D-21`) |
| Mockups presented as evidence | **0** |
| Duplicate captures | **0** (`duplicate_shots: []`) |
| Presentation defects found by this pass | 3 (2 presentation, 1 evidence-chain) |
| Presentation defects fixed and re-verified | 3 |
| Owner approval of the visual design | **NOT RECORDED** — no approval artefact was available; see `ACTIVITY_HISTORY_DECISION_REGISTER.md` |
| History V1 visually accepted | **EVIDENCE COMPLETE, ACCEPTANCE PENDING** — the evidence exists and is reproducible; acceptance is an Owner act, not a checkpoint claim |

This report does not assert that the Owner has accepted the visual result. It
asserts only that the nine images are real, are distinct, are reproducible, and
are accompanied by the observations needed to check every claim made about them.
