# CUST03 backend candidate

Target: `C:\Users\HP\OneDrive\Desktop\sport-marketplace\FYP\backend`.
Feature branch: `codex/cust03-backend-candidate-20261107` from `new-jed` at `f430a3d`.
Status: PROPOSED; scientific acceptance and Owner adoption remain pending.

This implements a synthetic-only customer backend using the frozen CUST03 contract
SHA-256 `ec2b5494ecf82447076e0d7a2bfb57599a24f049bbcc925a9ecbea6e833bce59`.
The reference A2 library and its original specification are copied without edits;
the successor supplies explicit versioned gate data to the existing evaluator.
It does not use the retired Java backend or replace the existing M2 work.

From this backend folder, run the isolated tests in PowerShell:

```powershell
$env:PYTHONPATH = 'src'
.venv\Scripts\python.exe -m unittest discover -s tests\candidate -p test_customer_candidate.py -v
```

Use the existing Python environment; no LLM or provider is involved. `unittest`
avoids the existing pytest conftest that imports the application and its database
configuration. Tests use a private SQLite in-memory database and FastAPI TestClient.
The candidate service rejects persistent SQLite and all non-SQLite databases.
Nothing is registered in `main.py`, the API router, Alembic, or Supabase migrations.

To regenerate the review-only PostgreSQL DDL without connecting to a database:

```powershell
$env:PYTHONPATH = 'src'
.venv\Scripts\python.exe candidates\cust03_vnext\compile_schema.py
```

The SQL is an inactive draft, outside migration discovery. PostgreSQL execution,
concurrency, RLS, deployment and production migration have not been validated or
authorized. The tested schema is the isolated in-memory candidate schema.

## Policies implemented for synthetic review

- Q01: reject terminal-plus-affiliation and every multiple-terminal selection;
  preserve failed raw inputs. This is a proposed alternative to frozen
  terminal-wins routing. Its 512 subsets yield 63 substantive, 3 non-substantive,
  445 invalid and 1 skipped outcome. These are option-set counts, not respondents.
  All six affiliation codes, including PASS_THROUGH, remain source-faithful and
  scientifically unresolved for real eligibility.
- Q02: preserve NONE/DAYS_1_3/DAYS_4_10/DAYS_11_20/DAYS_GT_20/PNTA source codes.
  DAYS_GT_20 displays as 21–28 distinct days within four weeks. Both SHOW_ALL and
  ELIGIBLE_ONLY can be selected for synthetic comparison; UNDECIDED withholds it.
  It follows Q01 and never adds a days-based eligibility threshold.
- Q05: require a version/hash-bound concept fixture review record and a recorded
  stimulus exposure. A boolean approval claim does not unlock it.
- Q09: require eligible synthetic qualification, concept exposure and an occasion
  bank record. It is independent of Q04 purchases and Q05 positivity. These are
  hypothetical occasions, never demand or actual future visits.
- Q10: require concept exposure and a nonempty reviewed feature-bank fixture;
  allow source-coded per-feature responses only. No feature rows are invented for
  real use and no composite is computed.
- Additional conservative candidate overlays: Q03 requires concept exposure;
  Q06 requires concept exposure plus a menu bank. Other gates reuse the source
  table, with optional items off by default. These overlays are also proposals.
- C0 is Q01/Q02; C1 is the remaining bank. The route preview is not a display
  event. Actual displays, responses, stimulus exposures and closed pretest
  records are stored separately.

Source original IDs, exact option codes, source/successor question versions,
option-bank/cohort/policy versions, stimulus hashes and review metadata accompany
history events. Retries are idempotent, stale writes are refused and route edits
append invalidations. Reopening a route cannot revive old answers or exposures.
Database triggers prevent update/delete of history tables.

I stays UNKNOWN_NOT_ENUMERABLE; Q_pre/Q_post are explicitly candidate names.
Item-specific S/A/V use the effective current snapshot. Invalid/refused and
non-substantive states remain separate, skips are outside A, and V=0 is
NOT_ESTIMABLE. Q10 counts are per feature. No report or accepted population is
authorized. The synthetic qualification fixture is not a real consent,
deduplication, recruitment, age or geographic validation system.

## Structured EN/BM pretesting

Cover every retained administered question and each retained option bank in both
languages, including Q10 feature rows. Every respondent follows their applicable
route; they do not all answer every question. Use a planned set of structured
profiles to cover eligible/ineligible/unknown/invalid Q01, both Q02 policies,
every Q04 code, missing/present stimuli and banks, optional on/off, refusal,
skip and edits that enter/exit routes. Check each expected show/hide outcome and
its reason, and verify exposures, histories and per-item denominators.

For human comprehension testing, use fixed-choice meaning/recall/option matching
and expected-route tasks; record CORRECT/INCORRECT/UNSURE/NOT_APPLICABLE. Review
unexpected patterns through a new versioned structured probe. The metadata and
storage exist for all Q01–Q13; BM stems and option labels remain MISSING_NOT_APPROVED.
The test BM stimuli are explicit synthetic placeholders. No human bilingual
pretest, translation review or scientific acceptance has occurred.

## Authorization evidence inspected

The original Project1 CUST08 handover grants no authority and leaves SD-A–SD-Q
open. The 2026-11-05 OWNER_DECISIONS_REQUIRED record leaves OD-CQ-01–12 pending,
including Q01, Q02, Q05, Q09/Q10, V mapping, fail-closed adoption and a named human
reviewer. The current user request permits this feature-branch candidate and its
offline synthetic tests; it does not adopt those policies or permit a live
migration. Earlier ChatGPT recommendations are context, not signed approvals.

Blocked: real fielding/API activation, scientifically accepted Q02 policy and
eligibility rules, real approved concept/menu/occasion/feature/offer assets,
EN/BM review, human pretesting, qualified scientific review, Owner adoption,
privacy/ethics/identity decisions, PostgreSQL verification and migration approval.
The existing dirty M2/backend/frontend work has been preserved; no commit or push.
