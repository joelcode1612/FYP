# ACTIVITY_HISTORY_IMPLEMENTATION_REGISTER

**Purpose.** For each History version, what is defined, what is built, what is
proven, and what is blocked. A defined presentation is not evidence of a working
backend; the columns below are kept separate for that reason.

**Date:** 2026-11-17 · **Contract:** `m2-activity/1` + `workflow-history-metadata/2`

---

## Classification vocabulary

| Label | Means |
|---|---|
| `PRESENTATION_DEFINED` | The UI form is written down in `ACTIVITY_HISTORY_PRESENTATION_SPEC_V1.md`. |
| `CONTRACT_DEFINED` | The wire shape is written down in `ACTIVITY_HISTORY_CONTRACT_V1.md`. |
| `IMPLEMENTED` | Code exists in the repository. |
| `VERIFIED` | Exercised against real data and observed — database row, HTTP response, browser render. |
| `BLOCKED` | Cannot proceed; the blocker is named. |
| `OWNER_DECISION_REQUIRED` | Needs a product/scientific decision this checkpoint may not take. |

---

## V1 — M2, deterministic BDJ, review, confirmation

| Dimension | State | Evidence |
|---|---|---|
| Presentation | `PRESENTATION_DEFINED` | `ACTIVITY_HISTORY_PRESENTATION_SPEC_V1.md` |
| Contract | `CONTRACT_DEFINED` | `ACTIVITY_HISTORY_CONTRACT_V1.md` |
| Implementation | `IMPLEMENTED` | `m2_repository.py`, `m2_service.py`, `api_m2_repository.dart`, `m2_activity_panel.dart`, `activity_history_page.dart` |
| Verification | **`VERIFIED`** | 12/12 HTTP checks; 6/6 projection tests (live DB, RLS-bound); 9/9 presentation tests; 4/4 page tests; 9 distinct desktop browser captures |

### What was proven, and how

| Claim | Method | Result |
|---|---|---|
| Events exist in PostgreSQL | direct SQL over `Dss` | 61 answers, 2 evaluations, 2 reviews, 2 confirmations, 1 uncertainty |
| The repository surfaces the stored outcome | `tests/m2_bcb/test_activity_projection.py` (read-only, live DB, actor bound per transaction) | 6 passed |
| The authenticated API returns them | real uvicorn + ES256 token minted against local JWKS, over HTTP | 12/12 checks |
| A non-owner is refused | same endpoint, different entrepreneur | `404` |
| An unauthenticated caller is refused | no bearer token | `401` |
| Dart parses the payload | `activity_event_presentation_test.dart` | 9 passed |
| The page renders the expected format | Chrome via CDP against the served build | 9 captures, each with observed title/badge/timeline recorded in `snapshots/capture_manifest.json` |
| Reload preserves the record | every capture is a fresh navigation | all show `17 matching activities` |
| Restart does not alter history | two independent uvicorn processes | identical 17 events and identical digest `8cfc90dd…` |
| Missing data stays visibly unavailable | navigate to an unresolvable assessment | `09_unavailable_source.png`, `Timeline unavailable`, 0 rows |

### Not verified

| Item | Why |
|---|---|
| Finding decisions (`CLARIFICATION_RECORDED`) | 0 rows exist; no authorized finding has been produced by the retired ruleset. The lifecycle was **not** exercised in production, and this register does not claim it was. |
| `CANDIDATE_FINDING_RECORDED` | 0 rows exist. |
| `CONTEXT_PERSISTED` event | No context row exists; the BCB build is `HELD`, so a persisted context was never produced. |
| Truncation behaviour | `limit` was never exceeded in these runs. |
| **Any LLM / cloud-BDJ output** | 9 real attempts exist in `project1_ai`, but History cannot read them (`MIG-AUTH-01`), and the ledger stores `output_digest` rather than model text. **There is no LLM response to display, and none is displayed.** See `ACTIVITY_HISTORY_VISUAL_ACCEPTANCE_REPORT.md` §2.1. |

**Screenshot provenance, per-image observations, and the three defects the visual
pass found are recorded in `ACTIVITY_HISTORY_VISUAL_ACCEPTANCE_REPORT.md`.** All
nine captures are actual desktop browser evidence; no mockups are included, and
no mobile capture is included because mobile is out of scope (`AH-D-21`).

---

## V1.1 — Cloud BDJ

| Dimension | State |
|---|---|
| Presentation | `PRESENTATION_DEFINED` (extension of the V1 detail panel; no new section) |
| Contract | `CONTRACT_DEFINED` (below) — **not implemented** |
| Implementation | `BLOCKED` |
| Verification | `BLOCKED` |

**Required linkage, defined but not built:** `project1_ai` run → attempt →
attempt receipt → input source fingerprint → model and prompt versions → output
validation result → admitted/rejected finding → assessment revision.

**Blocker.** The `project1_ai` schema is frozen against every application
principal (`MIG-AUTH-01`): `p1ai_owner` has no members, and every ledger login is
`NOINHERIT` with `USAGE` only. There is no owner-scoped read API, so History
cannot read an attempt without a governance decision and a reviewed grant.

**Rules that must hold when it is built** (recorded now so they are not
negotiated later):

1. A rejected, timed-out and unknown-outcome attempt must remain mutually
   distinguishable. No outcome may be collapsed into another.
2. An execution receipt is **not** proof that a finding was accepted. The
   receipt event and the acceptance event are different events.
3. The attempt timeline is append-only; a retry is a new attempt, never an
   overwrite of the previous one.

**Status: V1.1 is incomplete. No part of it may be presented as working.**

---

## V1.2 — BCB, QJ, QG

| Engine | Presentation | Contract | Implementation | Verification |
|---|---|---|---|---|
| BCB state | `PRESENTATION_DEFINED` | `CONTRACT_DEFINED` | `IMPLEMENTED` (state + snapshot block) | `VERIFIED` (state only) |
| BCB attempt history | `DECISION_REQUIRED` | — | `BLOCKED` (store keeps latest state) | — |
| QJ | `DECISION_REQUIRED` | — | `BLOCKED` (no history API) | — |
| QG | `DECISION_REQUIRED` | — | `BLOCKED` (no history API) | — |

### QJ — required record format (defined, not implemented)

Research objective · input context version · judgment · validation status ·
approved-bank matching result · authorization and review references.

### QG — required record format (defined, not implemented)

Candidate question identifier · exact question version · response type and
options · source research objective · validation results · scientific-review and
Owner decisions · rejection and revision history.

**Preserved distinction:** a generated candidate and an approved question are
different records with different identifiers. History must never present a
candidate as an approved question, and the QG section must show the transition
explicitly rather than inferring approval from presence.

**No completed QJ or QG execution record is claimed, because none exists.**

---

## V2 — Publication and final reports

| Dimension | State |
|---|---|
| Presentation | `PROPOSED` |
| Contract | `PROPOSED` |
| Implementation | `BLOCKED` |
| Verification | `BLOCKED` |

Required content, defined for later: approved questionnaire release and manifest
· publication authorization · questionnaire and routing version · consent and
authorized-respondent evidence status · EE-01 evidence calculations and source
snapshots · explanation and deterministic-fallback outcomes · R01–R12 report
versions · `ReportAdmission` decisions · claim-level evidence references ·
invalidation, revalidation and historical snapshots.

**Hard rule (`AH-D-17`):** History must not independently calculate or invent a
report finding. Reporting and History must reference the same versioned evidence
and decision records.

---

## Source changes made in this pass

| File | Change |
|---|---|
| `backend/src/sitewise/repositories/m2_repository.py` | `read_activity` rewritten as five explicit per-kind projections; `include_metadata` flag removed; `read_activity_supplement` finding/context fields corrected |
| `backend/src/sitewise/services/m2_service.py` | `history_extension` → `workflow-history-metadata/2`; call site updated |
| `backend/src/sitewise/services/ports/m2_repository_port.py` | port signature aligned |
| `backend/src/sitewise/services/confirmed_review_service.py` | enrichment projected back to `ReviewActivity`'s declared fields, so `project1-confirmed-review/1` is unchanged |
| `shared_logic/lib/src/data/repositories/api_m2_repository.dart` | accepts `workflow-history-metadata/1` and `/2`; validates the new optional fields |
| `fyp_jaspr_web/lib/data/activity_event_presentation.dart` | **new** — pure per-kind title/summary/version mapping |
| `fyp_jaspr_web/lib/components/m2_activity_panel.dart` | uses the mapping; coverage branch accepts both extension versions |
| `fyp_jaspr_web/lib/pages/entrepreneur/activity_history_page.dart` | `revision` added, `version` nullable, detail rows split |
| `fyp_jaspr_web/web/sitewise_report_activity.css` | design tokens now also scoped to `.sr-json-backdrop`; without them the JSON dialog painted fully transparent (`AH-FMT-16`, `AH-D-18`) |
| `fyp_jaspr_web/test/activity_event_presentation_test.dart` | **new** — 9 cases |
| `fyp_jaspr_web/test/activity_history_availability_test.dart` | repaired (was asserting text the page never rendered) |
| `backend/tests/m2_bcb/test_activity_projection.py` | **new** — 6 read-only live-DB cases; binds the actor on `begin` with `is_local = true` and asserts the binding (`AH-FMT-18`, `AH-D-20`) |
| `backend/scripts/cp03f_history_http_verify.py` | **new** — HTTP-layer verification |
| `backend/scripts/cp03f_history_screenshots.py` | **new** — browser capture with an observation manifest; asserts the dialog is open before capturing and records a SHA-256 plus a duplicate check (`AH-FMT-17`, `AH-D-19`) |

**No schema change. No migration. No endpoint added. No contract field removed
or retyped.**

---

## Standing blockers that limit this work

| ID | Blocker | Effect on History |
|---|---|---|
| `OD-3` | `M2V1-01` (REQUIRED, `GEO`) is unreachable in the panel | the authenticated M2 journey cannot be completed through the UI, so a fresh confirmation cannot be produced from the browser; History was verified against existing records instead |
| `MIG-AUTH-01` | `project1_ai` frozen against application principals | V1.1 blocked |
| — | No QJ/QG history API | V1.2 blocked |
| — | No reporting implementation | V2 blocked |
