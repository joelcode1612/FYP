# ACTIVITY_HISTORY_COMPATIBILITY_MATRIX

**Chain audited:** PostgreSQL → repository → FastAPI → Dart client → Jaspr
component → displayed record.

**Audited on:** 2026-11-17 against the live `Dss` database (18 assessments,
61 answer revisions, 2 evaluations, 2 reviews, 2 confirmations, 1 uncertainty,
0 findings, 0 clarifications) and a real uvicorn process.

**Contract version:** `m2-activity/1` + `workflow-history-metadata/2`

**Verdict vocabulary**

| Verdict | Meaning |
|---|---|
| `PASS` | Field is stored, transported, parsed, rendered, and observed in a real browser or a real HTTP response. |
| `FIXED` | Was broken; corrected in this pass; re-verified. |
| `INTENTIONAL_EXCLUSION` | The database holds the value and it is deliberately not exposed (private answer text, business text, model payload). |
| `GAP` | Stored but not surfaced, and no decision yet says it should be. |
| `NOT_EXERCISED` | The chain is implemented but this database has no row of that kind, so behaviour is unproven. |
| `NOT_IMPLEMENTED` | No source exists. |

---

## 1. Envelope

| DB field | API field | Dart field | UI element | Contract | Test | Verdict |
|---|---|---|---|---|---|---|
| `m2_assessments.id` | `assessment_id` | `activity['assessment_id']` | Header `Assessment <id>` | `/1` | `cp03f_history_http_verify.py` (12/12) | `PASS` |
| `m2_assessments.revision` | `assessment_revision` | same | Bound used by every event revision | `/1` | HTTP verify + `test_activity_projection.py` | `PASS` |
| — | `scope` | — | not displayed | `/1` | HTTP verify | `PASS` (declared, unused) |
| — | `truncated` | — | not displayed | `/1` | — | `GAP` — the page cannot tell a user the window is truncated |
| — | `history_extension` | same | Coverage branch (persisted vs legacy) | `/1`,`/2` | `api_m2_repository.dart` accepted-set | `PASS` |
| — | `authorization_decisions_included` | same | Coverage text "not supplied by this history source" | `/1` | HTTP verify (`False`) | `PASS` |
| `business_context_builds.confirmation_id` | `bcb_statuses[].confirmation_id` | map | BCB snapshot line | `/1` | live row `698ae3eb…` | `PASS` |
| `business_context_builds.status` | `bcb_statuses[].status` | map | BCB snapshot line | `/1` | live `HELD` | `PASS` |
| `business_context_builds.attempt_count` | `…attempt_count` | map | `attempts N` | `/1` | live `1` | `PASS` |
| `business_context_builds.last_code` | `…last_code` | map | `reason <code>` | `/1` | live `BCB_BINDING_AUTHORITY_UNVERIFIED` | `PASS` |
| `business_context_builds.context_id` | `…context_id` | map | `context <id>` | `/1` | live `None recorded` | `PASS` |
| `business_context_builds.updated_at` | `…updated_at` | map | `updated <ts>` | `/1` | live | `PASS` |
| — | `bcb_history_available` | map | Coverage line chooses persisted vs NOT_VERIFIED | `/1` | live `True` | `PASS` |
| — | `bcb_statuses_truncated` | map | "Only the latest BCB snapshots…" | `/1` | not triggered | `NOT_EXERCISED` |

---

## 2. Events — M2

| DB field | API field | Dart field | UI element | Contract | Test | Verdict |
|---|---|---|---|---|---|---|
| `m2_answer_revisions.id` | `event_id` | `eventId` (`kind:event_id`) | `Event ID` row | `/2` | HTTP verify; `02_detail_answer_saved.png` | `PASS` |
| literal | `kind` | `activityType` + `title` | Heading + Activity type | `/2` | `activity_event_presentation_test.dart` | `FIXED` — heading was the raw enum `ANSWER_SAVED` |
| `m2_answer_revisions.assessment_revision` | `assessment_revision` | `revision` | `Assessment revision` row | `/2` | `02_detail_answer_saved.png` shows 12 | `FIXED` — was rendered in a row labelled *Version* |
| `m2_answer_revisions.created_at` | `occurred_at` | `occurredAtIso` | `Recorded at`, list meta | `/2` | HTTP verify (UTC offset) | `PASS` |
| — (no actor column) | `actor_id: null` | `actor` | `Actor not stored on this record` | `/2` | `test_no_event_claims_a_field_it_does_not_store` | `PASS` (honest) |
| **`m2_answer_revisions.answer_state`** | **`status`** | `status` | Status badge | `/2` | `02_detail_answer_saved.png` shows `ANSWERED` | **`FIXED`** — was `null` for all 61 rows, rendering "outcome not supplied" |
| **`m2_item_versions.item_key`** | **`item_key`** | used in `summary` | "Answer for M2V1-11 recorded at revision 12." | `/2` | `02_detail_answer_saved.png` | **`FIXED`** — was not selected at all |
| `m2_answer_revisions.value_json` | *not exposed* | — | — | — | — | `INTENTIONAL_EXCLUSION` (private answer) |
| `m2_answer_revisions.item_version_id` | *not exposed* | — | — | — | — | `INTENTIONAL_EXCLUSION` (resolved to `item_key`) |
| — | `module` (default `M2`) | `engine` | `Engine / module` | `/2` | browser | `PASS` |
| — | `source_is_current` | `sourceIsCurrent` | One of two fixed sentences | `/2` | `02_detail_answer_saved.png` | `PASS` (see `AH-D-07` limitation) |
| — | `reason` | `reason` | `Recorded reason:` | `/2` | not set for answers | `PASS` (correctly absent) |

---

## 3. Events — BDJ and Business Understanding

| DB field | API field | Dart field | UI element | Contract | Test | Verdict |
|---|---|---|---|---|---|---|
| `m2_bdj_evaluations.id` | `event_id` | `eventId` | `Event ID` | `/2` | live `e19a8e10…` | `PASS` |
| **`m2_bdj_evaluations.evaluator_version`** | **`evaluator_version`** | `version` | `Engine version: BDJ-RULESET-0.2-CAND` | `/2` | `03_detail_bdj_evaluated.png` | **`FIXED`** — was put in `reason`, printed as "Recorded reason: BDJ-RULESET-0.2-CAND" |
| — | `status` | `status` | `Recorded — outcome not supplied` | `/2` | browser | `PASS` (no outcome column exists) |
| `m2_review_events.actor_user_id` | `actor_id` | `actor` | `Recorded by` | `/2` | live `11111111-…` | `PASS` |
| `m2_confirmation_snapshots.id` | `event_id` | `eventId` | `Event ID` | `/2` | live `698ae3eb…` | `PASS` |
| **`m2_confirmation_snapshots.snapshot_digest`** | **`snapshot_digest`** | used in `summary` | `digest 8cfc90ddd091…` | `/2` | `04_detail_context_confirmed.png` | **`FIXED`** — was not selected |
| `m2_confirmation_snapshots.snapshot_json` | *not exposed* | — | — | — | — | `INTENTIONAL_EXCLUSION` (private payload) |
| `m2_confirmation_snapshots.acknowledged_issue_ids` | *not exposed* | — | — | — | — | `GAP` — an acknowledged-issue list is evidence and is currently invisible (`AH-Q-06`) |
| `m2_confirmed_uncertainties.exact_text` | *not exposed* | — | — | — | — | `INTENTIONAL_EXCLUSION` (private business text) |
| `m2_confirmed_uncertainties.confirmation_id` | `source_id` | `inputReferences` | `Inputs` | `/2` | live | `PASS` |

---

## 4. Events — finding decisions (implemented, not exercised)

| DB field | API field | Dart field | UI element | Contract | Test | Verdict |
|---|---|---|---|---|---|---|
| `m2_clarification_events.decision` | `status` | `status` | Status badge | `/2` | unit only | `NOT_EXERCISED` — 0 rows in this database |
| `m2_clarification_events.finding_id` | `source_id` | `inputReferences` | `Inputs` | `/2` | unit only | `NOT_EXERCISED` |
| `m2_bdj_findings.rule_id` | `rule_id` | used in `summary` | "Candidate finding BDJ-…" | `/2` | unit only | `NOT_EXERCISED` — 0 rows |
| `m2_bdj_findings.rule_version` | `rule_version` | `version` | `Engine version` | `/2` | unit only | `NOT_EXERCISED` |
| `m2_bdj_findings.review_state` | `status` | `status` | Status badge | `/2` | unit only | `NOT_EXERCISED` |
| `m2_bdj_findings.explanation` / `not_proven` / `next_action` | *not exposed* | — | — | — | — | `GAP` — a finding's reasoning is not readable in History |
| `m2_bdj_findings.source_answer_ids` | *not exposed* | — | — | — | — | `GAP` — the link from finding to source answers is invisible |

---

## 5. Events — BCB

| DB field | API field | Dart field | UI element | Contract | Test | Verdict |
|---|---|---|---|---|---|---|
| `business_contexts.context_id` | `event_id` | `eventId` | `Event ID` | `/2` | not exercised (no context row) | `NOT_EXERCISED` |
| `business_contexts.lifecycle_status` | `status` | `status` | Status badge | `/2` | not exercised | `NOT_EXERCISED` |
| **`business_contexts.builder_version`** | **`builder_version`** | `version` | `Engine version` | `/2` | unit test | **`FIXED`** — was put in `reason` |
| `business_contexts.confirmation_id` | `source_id` | `inputReferences` | `Inputs` | `/2` | not exercised | `NOT_EXERCISED` |

---

## 6. Cross-cutting

| Requirement | Evidence | Verdict |
|---|---|---|
| Owner scoping | `test_reader_is_owner_scoped`; HTTP `404` for a different entrepreneur | `PASS` |
| Unauthenticated refusal | HTTP `401` | `PASS` |
| UTC timestamps with offset | client rejects a timestamp without `Z`/offset | `PASS` |
| Duplicate event identity | client rejects a repeated `kind:event_id` | `PASS` |
| Event revision ≤ assessment revision | client rejects a greater one | `PASS` |
| Backend restart does not change history | two independent uvicorn runs returned 17 events and digest `8cfc90dd…` identically | `PASS` |
| Reload preserves the record | every screenshot is a fresh navigation; all show `17 matching activities` | `PASS` |
| Missing data stays visibly unavailable | `09_unavailable_source.png` | `PASS` |
| No fabricated fallback | `AH-D-08` | `PASS` |
| Reporting reads shared source references | no reporting exists | `NOT_IMPLEMENTED` |

---

## 7. Defects found and their disposition

| ID | Defect | Class | Disposition |
|---|---|---|---|
| `AH-FMT-01` | `answer_state` never selected → every answer rendered "outcome not supplied" while the outcome was stored | backend projection | `FIXED` |
| `AH-FMT-02` | `item_key` never selected → an answer could not say which question it answered | backend projection | `FIXED` |
| `AH-FMT-03` | `evaluator_version` placed in `reason` → a version printed as a reason | semantic overload | `FIXED` |
| `AH-FMT-04` | `rule_id` placed in `reason` → an identifier printed as a reason | semantic overload | `FIXED` |
| `AH-FMT-05` | `builder_version` placed in `reason` | semantic overload | `FIXED` |
| `AH-FMT-06` | `snapshot_digest` never selected → the confirmation had no verifiable reference | backend projection | `FIXED` |
| `AH-FMT-07` | `kind` used as the record title → heading read `ANSWER_SAVED` | presentation | `FIXED` |
| `AH-FMT-08` | assessment revision shown in a row labelled *Version* | presentation | `FIXED` |
| `AH-FMT-09` | generic summary "Persisted M2 metadata at revision N." for every kind | presentation | `FIXED` |
| `AH-FMT-10` | `include_metadata` flag silently ignored — a caller passing `False` still received metadata | API shape | `FIXED` (flag removed) |
| `AH-FMT-11` | `activity_history_availability_test.dart` asserted strings the page never rendered, so the file could not pass and was not evidence | test integrity | `FIXED` (rewritten) |
| `AH-FMT-12` | `acknowledged_issue_ids` not surfaced | gap | `OPEN` (`AH-Q-06`) |
| `AH-FMT-13` | finding `explanation` / `not_proven` / `next_action` not surfaced | gap | `OPEN` (`AH-Q-07`) |
| `AH-FMT-14` | `truncated` not displayed | gap | `OPEN` (`AH-Q-08`) |
| `AH-FMT-15` | `source_is_current` is revision equality, not answer validity | semantic | `OPEN` (`AH-D-07`, `AH-Q-03`) |
| `AH-FMT-16` | The JSON dialog painted **fully transparent**: its tokens are declared on `.sr-workspace` but the dialog is a sibling of it, so `background: var(--sr-white)` resolved to nothing | CSS scope | `FIXED` (token block now also on `.sr-json-backdrop`) |
| `AH-FMT-17` | The capture script's `startsWith('View full log')` never matched, because the button's text is `codeView full log (JSON)` — the icon is a ligature text node. The manifest claimed a dialog the PNG did not show | evidence integrity | `FIXED` (containment match + pre-capture assertion) |
| `AH-FMT-18` | The live projection test skipped instead of running: the fixture queried under RLS with no actor bound, and the actor was bound on `connect`, where PostgreSQL's transactional `SET` is undone by the pool rollback | test integrity | `FIXED` (bind on `begin`, `is_local = true`; explicit binding assertion added) |

---

## 8. Verification commands

The runtime role is subject to row-level security, so the tests bind
`project1.actor_id` per transaction. Use the runtime DSN, not a superuser DSN: a
superuser bypasses the policies and would not exercise the posture the service
actually runs under.

```bash
cd backend
export ACTIVITY_HISTORY_DB_URL="$(
  ./.venv/Scripts/python.exe -c \
    "from sitewise.core.config import settings; print(settings.m2_database_url.get_secret_value())")"

./.venv/Scripts/python.exe -m pytest tests/m2_bcb/test_activity_projection.py -q   # 6 passed
./.venv/Scripts/python.exe scripts/cp03f_history_http_verify.py                    # 12/12 PASS
./.venv/Scripts/python.exe scripts/cp03f_history_screenshots.py                    # 9 distinct desktop shots

cd ../fyp_jaspr_web
dart test test/activity_event_presentation_test.dart    # 9 passed
dart test test/activity_history_availability_test.dart  # 4 passed
```

Unset `ACTIVITY_HISTORY_DB_URL` and the projection module skips at module level
(`1 skipped`), so the default suite stays hermetic.
