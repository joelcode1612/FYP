# ACTIVITY_HISTORY_V1_TO_V2_TEST_PLAN

**Purpose.** The ten mandatory checks, applied per History version, with the
result recorded against evidence rather than intent.

**Date:** 2026-11-17 · **Contract:** `m2-activity/1` + `workflow-history-metadata/2`

---

## The ten checks

| # | Check | What would make it fail |
|---|---|---|
| T1 | The database event exists | The API returns a record with no corresponding row |
| T2 | The authorized HTTP API returns the correct event | Right status, wrong payload; or a record that only exists in the API layer |
| T3 | Dart parses the event correctly | A field silently coerced, defaulted, or dropped |
| T4 | Jaspr displays the expected format | Correct data, wrong label or wrong slot |
| T5 | Browser reload preserves the same record | The record disappears or changes on refresh |
| T6 | Backend restart does not alter historical evidence | A computed or volatile field changes between processes |
| T7 | Cross-owner access is rejected | A second authenticated principal reads the history |
| T8 | Missing data remains visibly unavailable | A placeholder, sample, or "success" appears where data is absent |
| T9 | Source revision and decision status are accurate | A revision or decision shown that the record does not carry |
| T10 | Reporting reads the correct shared source references | History and reporting disagree, or History computes a finding |

---

## V1 — M2, deterministic BDJ, review, confirmation

| # | Result | Evidence |
|---|---|---|
| T1 | **PASS** | Direct SQL: 61 answers, 2 evaluations, 2 reviews, 2 confirmations, 1 uncertainty in `Dss` |
| T2 | **PASS** | `cp03f_history_http_verify.py` — 12/12 checks over HTTP against a real uvicorn; 17 events for `da90aa4a-…` |
| T3 | **PASS** | `activity_event_presentation_test.dart` — 9 cases; `api_m2_repository.dart` rejects mistyped optional fields rather than coercing |
| T4 | **PASS** | 10 browser captures; `02_detail_answer_saved.png` shows *Answer saved* / `ANSWERED` / *Answer for M2V1-11 recorded at revision 12* |
| T5 | **PASS** | Every capture is a fresh `Page.navigate`; all report `17 matching activities` |
| T6 | **PASS** | Two independent uvicorn processes returned the same 17 events and the same digest `8cfc90dd…` |
| T7 | **PASS** | Different entrepreneur → `404`; no token → `401`; `test_reader_is_owner_scoped` passes |
| T8 | **PASS** | `09_unavailable_source.png` → *Timeline unavailable*, 0 rows; `08_empty_filter_result.png` → *No matching activities* |
| T9 | **PASS** | Revision 12 rendered from `assessment_revision`; `Engine version: Not recorded on this event` where no version exists; decisions render only where stored |
| T10 | **N/A** | No reporting exists. `NOT_IMPLEMENTED` — not a failure of History |

**V1 verdict: `VERIFIED`** for everything except the three kinds with no rows
(finding decisions, candidate findings, persisted context), which are
`NOT_EXERCISED` and are not claimed.

### T1–T10 for the unexercised kinds

| Kind | T1 | T2 | T3 | T4 | Rationale |
|---|---|---|---|---|---|
| `CLARIFICATION_RECORDED` | `NOT_EXERCISED` | `NOT_EXERCISED` | `PASS` (unit) | `NOT_EXERCISED` | 0 rows; the retired ruleset produced no finding |
| `CANDIDATE_FINDING_RECORDED` | `NOT_EXERCISED` | `NOT_EXERCISED` | `PASS` (unit) | `NOT_EXERCISED` | 0 rows |
| `CONTEXT_PERSISTED` | `NOT_EXERCISED` | `NOT_EXERCISED` | `PASS` (unit) | `NOT_EXERCISED` | BCB build is `HELD`; no context was ever persisted |

The finding-decision lifecycle was **not** exercised in production, and this
plan does not claim it was.

---

## V1.1 — Cloud BDJ

| # | Result | Reason |
|---|---|---|
| T1–T10 | **BLOCKED** | `project1_ai` is frozen against every application principal (`MIG-AUTH-01`); there is no owner-scoped read API |

Additional checks that must be added for V1.1 before it can pass:

| # | Check |
|---|---|
| T11 | A rejected attempt, a timed-out attempt and an unknown-outcome attempt are three distinct rendered outcomes |
| T12 | An execution receipt is never rendered as an accepted finding |
| T13 | A retry appends a new attempt; the previous attempt remains readable |
| T14 | The attempt's input fingerprint and model/prompt versions match the stored receipt |

---

## V1.2 — BCB, QJ, QG

| Engine | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 |
|---|---|---|---|---|---|---|---|---|---|---|
| BCB state | `PASS` | `PASS` | `PASS` | `PASS` | `PASS` | `PASS` | `PASS` | `PASS` | `PASS` | N/A |
| BCB attempts | `BLOCKED` | — | — | — | — | — | — | — | — | — |
| QJ | `BLOCKED` | — | — | — | — | — | — | — | — | — |
| QG | `BLOCKED` | — | — | — | — | — | — | — | — | — |

BCB state evidence: live row `confirmation 698ae3eb… · revision 12 · HELD ·
attempts 1 · reason BCB_BINDING_AUTHORITY_UNVERIFIED`, rendered in
`01_activity_history_overview.png` under the heading *Latest BCB status
snapshots — not attempt history*.

Additional checks required for V1.2:

| # | Check |
|---|---|
| T15 | A generated QG candidate and an approved question are visually and structurally distinct |
| T16 | A QG rejection and its revision history are both readable |
| T17 | A QJ judgment is bound to an exact input context version |
| T18 | A BCB `HELD` state names its HOLD reason and does not read as success |

---

## V2 — Publication and reports

| # | Result | Reason |
|---|---|---|
| T1–T10 | **BLOCKED** | No manifest builder, no publication authorization API, no R01–R12 implementation |

Additional checks required for V2:

| # | Check |
|---|---|
| T19 | A report version and its `ReportAdmission` decision are separately visible |
| T20 | History's claim reference resolves to the same evidence the report used |
| T21 | An invalidated report remains readable as a historical snapshot |
| T22 | History never computes a finding the report did not admit |

---

## How to run the V1 suite

```bash
# 1. Read-only projection over the live database
cd backend
ACTIVITY_HISTORY_DB_URL="postgresql+psycopg2://postgres:<pw>@localhost:5432/Dss" \
  ./.venv/Scripts/python.exe -m pytest tests/m2_bcb/test_activity_projection.py -q
# -> 5 passed

# 2. HTTP layer with real ES256 tokens (starts its own uvicorn + JWKS)
./.venv/Scripts/python.exe scripts/cp03f_history_http_verify.py
# -> verdict: PASS (12 checks, 0 failed)

# 3. Browser evidence (requires a fresh `dart run jaspr_cli:jaspr build`)
./.venv/Scripts/python.exe scripts/cp03f_history_screenshots.py
# -> 10 shots + capture_manifest.json

# 4. Dart parsing and page behaviour
cd ../fyp_jaspr_web
dart test test/activity_event_presentation_test.dart      # 9 passed
dart test test/activity_history_availability_test.dart    # 4 passed
```

## Results summary

| Version | Verdict |
|---|---|
| V1 | **`VERIFIED`** (3 kinds `NOT_EXERCISED`, declared) |
| V1.1 | **`BLOCKED`** |
| V1.2 | **BCB state `VERIFIED`; QJ/QG/attempts `BLOCKED`** |
| V2 | **`BLOCKED`** |
