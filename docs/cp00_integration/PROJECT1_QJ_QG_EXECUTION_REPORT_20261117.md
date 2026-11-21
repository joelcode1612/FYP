# PROJECT1 — QJ/QG Execution Report

**Directive:** `PROJECT1-QJQG-RESEARCH-EXEC-20261117-01`
**Date:** 17 November 2026
**Branch:** `merge_main_jed` (nothing committed; all changes in the working tree)
**Package verified:** 11/11 sha256 OK
**Provider budget after this work:** 5 of 6 used, **1 free call remaining**, ceiling USD $0.00

---

## 1. Status table

| Priority | True status | Source / version | Tests | Live calls | Actual output | Security / governance state | Blocker | Next action |
|---|---|---|---|---|---|---|---|---|
| **P1** Measurement baseline | `P1_PACKET_BUILT_AND_BOUND` — real `BCB-V1-1.1.0` packet from a synthetic confirmed M2V1 assessment; candidate bound to the live contract; estimator carried in a test-only versioned model | `contracts.py` `fc364ae9…`; packet `dac24066…a57dc736`; assessment `b654d7eb…`; confirmation `20779bda…` rev 8 | 25 passed (16 lab + 9 validator); isolated suite green incl. new check | 0 | Packet: `geography: null`, `permissions` all `false`, 8 real M2V1 answer revisions, `packet_hash` recomputes | `PROVISIONAL_TEST_ONLY_NOT_APPROVED`, `production_adoption: false`, no approval flags set | Estimator not expressible in the deployed `Measurement` (`numerator_codes`/`denominator_codes` absent) | Methodological review of population, offer, wording, codes and denominator; decide whether the estimator becomes a versioned contract field |
| **P2** Question-bank authority | `BLOCKED_BANK_AUTHORITY` — verdict `ZERO_APPROVED_ENTRIES` + `NOT_COMPOSED_IN_PRODUCTION` | `research.py:156-172` (duck-typed bank); `services/ports/` (no bank port); no bank table in `migrations/` | Static + read-only evidence; no new tests (no code to test) | 0 | No `lookup()`/`verify_receipt()` implementation exists in `src/`; only test doubles returning `'SYN-ONLY'` / `'SYNTHETIC-PRIVATE-LAB-ONLY'` | Cannot issue an equivalence receipt; no verifier authority exists | Decision `BD-01` unsigned: no authoritative store, no receipt issuer, no snapshot policy | Owner signs `BD-01` (3 options, recommendation recorded in `P2_BANK_AUTHORITY_EVIDENCE_20261117.md`) |
| **P3** QJ → conditional QG | QJ `LIVE_PROVIDER_PASS` with route `HOLD`; QG `NOT_CALLED` | `QJ-MEASURE-1-CAND`, model `mimo-v2.6-flash:free` | 122 passed (`tests/project1/llm_campaign`) | **1** (scenario `qj:price-rm13`) | HTTP 200, `HOLD`, `measurement: null`, 6 643 tokens, 14.0 s, deterministic validation `valid: true`, `codes: []` | Disclosure preflight accepted 8/8 checks; `authority: NONE`; `candidate_only: true`; `fielding_authorized: false`; `identity_verified: false` | `F-01`: `Measurement.uncertainty_version` has no declared source, so the survey branch is reachable only by guessing; bank blocked | Decide `F-01` (declare the uncertainty-version convention in `admit_qj` + prompt, or add a version field to the packet) before spending the last call |
| **P4** Independent evaluation | `DESK_REVIEW_ONLY` — 1 conforming case, 1 defect confirmed and remediated, 6 not evaluable | Prereg `P4-PREREG-20261117T140247Z`, sha256 `91a9a3b7…5fc46`; `RUBRIC-PRICE-0.1` | 67 passed (`test_workflow.py`) incl. new `D-01` regression | 0 (evaluation reads the P3 capture) | C1 conforming via the pre-registered valid alternate; C8 confirmed by static proof then fixed; C2–C7 `NOT_EVALUABLE_YET` | Reviewer `UNASSIGNED`; `independent_of_implementer: NOT_VERIFIED` | n = 1 output, no repeats; six cases unexercised | Repeat scenarios once `BD-01` and `F-01` are decided; assign an independent reviewer |

## 2. Status labels kept separate

| Label | State | Basis |
|---|---|---|
| `OFFLINE_REFERENCE_PASS` | **PASS** | Package reference suite 18/18 `OK`; manifest 11/11 |
| `ISOLATED_REPO_TEST_PASS` | **PASS for the touched suites** | `tests/project1` 389 passed / 3 skipped; `tests/project1/llm_campaign` 122 passed; new lab + validator tests 25 passed; isolated cluster suite green including the new P1 check |
| `LIVE_PROVIDER_PASS` | **PASS (transport) / `HOLD` (content)** | HTTP 200, one dispatch, one receipt, `outcome: returned`, raw capture written first |
| `SCIENTIFIC_ACCEPTED` | **NO** | No adopted measurement policy exists anywhere; `authority.validate_measurement` is a no-op in every existing test |
| `PRODUCTION_READY` | **NO** | `ResearchWorkflow` is never instantiated in `src/`; no bank port; no QG route |

## 3. What was actually executed, and what was refused

**Executed (1 call).** One QJ dispatch against the real P1 packet, after a zero-cost disclosure preflight and a catalogue-based free-route verification (`FREE_ROUTE_CONFIRMED`, all four price fields 0, status 200).

The model returned `HOLD` and named the missing fields itself:

> … no response options, response codes, routing rules, denominator, timeframe, or source refs are defined, and **no uncertainty_version identifier is provided for the confirmed uncertainty (only confirmation/assessment IDs)**.

**Refused, with reasons (0 calls each).**
- **QG** — route was not `CUSTOMER_SURVEY_CANDIDATE`, and bank authority is unverified. A correctly refused QG is a valid safety pass.
- **Second QJ / fallback / paid route** — not attempted. One call remains and is held.
- **Any bank lookup** — no port, no store, no approved entries.

## 4. Findings

**`D-01` (defect, HIGH, FIXED).** `validate_draft` compared **sets** of numbers, so a QG draft that rewrote RM13 as RM12 passed, because `12` already occurs in `12 oz`. Offer fidelity is a *Critical* rubric criterion. Fixed in `research.py` by comparing currency amounts as whole tokens (`QG_UNSOURCED_AMOUNT`), with a regression test that also proves the old rule still holds for the case. Pre-registered as `C8` before any QG output existed.

**`F-01` (design gap, HIGH, OPEN).** `Measurement.uncertainty_version` is required, `validate_measurement` demands it equal `authority.admit_qj(packet)`'s value (`research.py:35`, `:139-140`), the packet carries no version field, and no prompt states the convention. Every existing test passes because a stub returns `objective['id']` **and** a hand-written measurement uses the same string. A live model must guess. This is an input-contract gap, not model failure, and it explains both prior live HOLDs.

**`F-02` (inert control, HIGH, OPEN).** `authority.validate_measurement` is documented as the *"independent adopted validator"* (`research.py:154`) but is `lambda *_: None` in every test that exercises the survey branch. No adopted measurement policy exists in the tree.

**`F-03` (self-correction, LOW, FIXED).** My first version of the per-scenario budget guard still passed a hard-coded `'qj:single'` label to `reserve_budget`, so attempt 5 was mislabelled. The count was right; the label was false. Code fixed and the record corrected in place with `label_corrected` provenance — `n`, `at` and `spent` unchanged.

**`F-04` (environment, MEDIUM, pre-existing).** The wider branch suite reports 92 failures, 8 errors and 2 collection errors. None are in `tests/project1/` or `tests/m2_bcb/`. They are a geospatial DB schema drift (`psycopg2.errors.UndefinedColumn: column o.geom does not exist` on `fnb_a.fnb_outlet`) plus two ML import errors (`CATEGORY_BACKGROUND_CSV` absent from an unmodified `fnb_category.py`). Pre-existing on `merge_main_jed`; **not** caused by and **not** fixed in this work.

## 5. Security and governance state

- **Live database `Dss`: untouched.** No DDL, DML or migration. The only writes were to a disposable PostgreSQL 18 cluster on port 55441.
- **P2 corrected an assumption of mine:** `backend/.env` `DATABASE_URL` resolves to `Final_Location_Analysis`, not `Dss`; `Dss` is reached via `M2_DATABASE_URL` / `PROJECT1_RUNTIME_DATABASE_URL`. P2 asserted `current_database()` and aborted before any catalog query.

### Why `DATABASE_URL` is not `Dss` (and should not be)

Resolved from the live settings object (`Settings.model_config` reads `.env` then `.env.local`, later file wins):

| Setting | Database | Purpose |
|---|---|---|
| `database_url` | `Final_Location_Analysis` | **Application** DB — profiles, saved properties, recommendations (`config.py:17-20`, `.env.example:5-6`) |
| `analytics_database_url` | `Final_Location_Analysis` | DOSM statistics / geospatial features (read-only) |
| `m2_database_url` | `Dss` | M2/BCB runtime, `p1_m2_runtime` |
| `project1_runtime_database_url` | `Dss` | PROJECT1 engine runtime |
| `project1_audit_database_url` | `Dss` | `p1ai_audit` read-only ledger metadata |
| `ee01_database_url` | `Dss` | `p1_ee01_runtime` |
| `m2_expected_database` | `Dss` | the name `_verified_engine` requires |
| `project1_workflow_enabled` | `False` | business-review routes off |

This is a **two-database topology, documented and deliberate**, not a misconfiguration. `DATABASE_URL` is the rental-marketplace application database; every PROJECT1 target is a dedicated `Dss` login. `m2_session._verified_engine` rejects any URL whose database is not `Dss`, so a fallback to `DATABASE_URL` fails closed with `M2_DATABASE_TARGET_UNVERIFIED` (503) rather than silently reading the wrong database.

The consequence is deliberate: `project1_workflow.configuration_gate` (`:26-46`) requires the **application** session's database to be `Dss`, with its own comment stating that "the current `Final_Location_Analysis` configuration cannot be repurposed into application authority by a flag". In this shared development environment those routes therefore return `503 WORKFLOW_CONFIGURATION_REQUIRED` by design. Enabling them requires a separate PROJECT1 deployment whose `DATABASE_URL` is itself `Dss` behind a non-`postgres` role — not a change to this `.env`.

**Latent hazard worth recording:** `get_m2_engine` (`m2_session.py:37`) still falls back to `settings.database_url`, while its sibling `get_bcb_engine` (`:49`) deliberately refuses that fallback because the M2 transaction must run as the M2 runtime login. The fallback is harmless only because `_verified_engine` rejects the wrong database name; if `DATABASE_URL` were ever `Dss` under a privileged role, M2 reads would silently run as the application principal. Removing the fallback would make the two functions consistent.
- **Disclosure:** 8/8 checks accepted for the dispatch; `authority: NONE`, `candidate_only: true`, `fielding_authorized: false`, `publication_authorized: false`.
- **Identity:** every call, including this one, records `identity_verified: false` (`MODEL_IDENTITY_UNVERIFIED_TEST_EXCEPTION`) because the gateway returns `mimo-v2.6-flash` for a requested `mimo-v2.6-flash:free`. Model identity is **not** verified and must not be reported as if it were.
- **GEO:** excluded throughout; `geography: null` in every packet; D02 preserved.
- **No fabricated authority:** no Owner approval, scientific acceptance, bank equivalence, GEO authority or research approval is claimed anywhere.

## 6. Evidence index

| Artefact | Path |
|---|---|
| Intake record | `docs/cp00_integration/P1_INTAKE_RECORD_20261117.md` |
| P1 packet + assertions + field mapping | `artifacts/p1_price_measurement_20261117T140653Z/` |
| P2 bank authority evidence | `docs/cp00_integration/P2_BANK_AUTHORITY_EVIDENCE_20261117.md`, `artifacts/p2_bank_authority/verdict.json` |
| P4 pre-registration | `artifacts/p4_reference_judgments/PREREG_20261117T140247Z.{json,md,sha256}` |
| P4 comparison | `artifacts/p4_reference_judgments/COMPARISON_20261117T141500Z.md` |
| QJ preflight (0 cost) | `artifacts/p3_qj_preflight/` |
| Free-route verification | `artifacts/p3_free_route/free_route_check.json` |
| QJ live capture | `backend/var/llm_campaign/runs/qj-live-qj-price-rm13-20261117T141034Z/` |
| Budget ledger | `backend/var/llm_campaign/budget_state.json` |
| Full-suite failure list | `artifacts/full_suite_20261117.txt` |

## 7. The single next decision

`F-01` gates the last free call. Until the uncertainty-version convention is declared, another QJ call can only reproduce `HOLD`, so spending it would be spending to force an outcome the directive forbids. The decision is small and is not a scientific one:

> Either (a) `admit_qj` returns `uncertainty_version = confirmed_uncertainty.id` as an explicit, documented contract term that the QJ prompt states, or (b) the packet gains a versioned uncertainty field. Option (a) requires no schema change and matches the convention every existing test already assumes.

`BD-01` (bank authority) independently blocks QG, so no ordering between the two decisions can make QG reachable today.
