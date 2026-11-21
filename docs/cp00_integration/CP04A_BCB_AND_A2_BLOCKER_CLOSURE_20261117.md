# CP-04A — BCB and A2 Blocker Closure

**Date:** 2026-11-17 · **Branch:** `merge_main_jed` · **Modules frozen, no redesign**
**Verdict:** all five corrections closed · **one new defect found** · **four residuals carried forward**

No `Dss` writes, no migration execution, no flag changes, no paid calls, nothing committed.

---

## 0. Correction to an earlier statement

In the previous report I told the Owner that `backend/migrations/m2/20261117_04`, `_05` and `_06` were
"untracked and not applied to `Dss`", and called them a new unauthorized deployment dependency.

**That was wrong.** They are untracked, but they *are* applied. Verified by object inspection on `Dss`
under `default_transaction_read_only = on`:

```
PRESENT assessment_workflow_projection.owner_scope     (created by _04)
PRESENT m2_review_question_versions.owner_scope        (created by _05)
PRESENT m2_research_objective_sources.owner_scope      (_05)
PRESENT m2_research_clarifications.owner_scope         (_05)
PRESENT m2_research_revisions.owner_scope              (_05)
PRESENT m2_desired_options.owner_scope                 (_05)
PRESENT m2_candidate_owner_reviews.owner_scope         (_05)
```

The error was in the inference, not the observation: I concluded "unapplied" from "untracked", which does
not follow. It is the mirror of the mistake the Owner warned about — deciding applied-state from a missing
receipt. Applied-state has to be decided from objects. There is no new migration dependency.

---

## 1. Results

| # | Task | Status | Evidence |
|---|---|---|---|
| 1 | BCB restricted-principal integration | **PASS** | RLS measured independently — see §2 |
| 2 | A2 result-payload protection at rest | **PASS** (residuals) | envelope v1, sealed both directions, `234 passed, 1 skipped` |
| 3 | M2V1 integrity | **PASS** | checkout artifact; digest untouched |
| 4 | Confirmation expiry | **PASS** | 90-day constant removed; absent basis fails closed |
| 5 | Connected workflow M2 → BDJ → BCB → QJ | **PASS** | CC1–CC6, `64 passed, 6 skipped, 4 xfailed` |

## 2. Task 1 — restricted principal

`bind_restricted_principal()` in `m2_context_bindings.py`: `SET LOCAL ROLE p1_m2_runtime` → verify the
effective role is not superuser and not BYPASSRLS → `set_config('project1.actor_id', …)`, mirroring
`ledger.py:31-38`. BCB composition now uses `M2_DATABASE_URL` only, with no `DATABASE_URL` fallback.

Independently measured against the clone (not taken from the worker's report, whose evidence file had been
deleted with the lab directory):

```
current_user/super/bypass: ('p1_m2_runtime', False, False)
  actor=real owner   m2_assessments=  1  m2_business_contexts=0
  actor=other uuid   m2_assessments=  0  m2_business_contexts=0
```

Same non-superuser role, different actor GUC, different visible rows. That is RLS evidence.
The worker reports 58 passed (was 51); no existing test weakened.

## 3. Task 2 — payload protection

Versioned envelope inside the existing jsonb column — **no migration**, deployed frozen files untouched:

```
{"__payload_envelope__":"v1","key_id":"payload-<result_id>",
 "ciphertext":"<fernet token>","plaintext_digest":"<sha256>","plaintext_bytes":N}
```

`key_id` is derived in the store, so a call site cannot choose a name retention could select. Payload keys
use a separate namespace from raw-response keys and are **never** on the retention clock — `bdj_results` is
retained indefinitely, only `bdj_raw_responses` expires. `run_retention()` provably destroys the raw key and
leaves the payload key live.

**Wired by the lead, not left opt-in.** The worker delivered it opt-in, with `model_assisted.py:131`
constructing the store without custody — so the next person to enable the workflow flag would have written
prose in plaintext. Custody is now passed unconditionally on both the write path and the History read path
(`project1_workflow.py:201`), and an unwritable custody root fails closed rather than degrading.

Real-database check on the clone: new rows `sealed=True`; 320 legacy plaintext rows remain, readable by
design.

## 4. Task 3 — M2V1 digest

```
blob in HEAD:   d09a7db532cbd2e41458d9776004de2830c67c91cacb0a264dc4cfbe5c432c6b
recorded:       d09a7db532cbd2e41458d9776004de2830c67c91cacb0a264dc4cfbe5c432c6b
working tree:   88c1ef07a142f55a58f64a406445e4426592e718a6430a79340e62845cb852d8
```

The committed blob hashes exactly to the manifest; the working tree differed only through LF→CRLF
conversion. Fixed at the cause, following the repo's existing `.gitattributes` convention:
`backend/src/sitewise/instruments/m2v1_20261114/source.txt -text`, then re-checkout. The file now hashes to
`d09a7db5…` with zero diff against HEAD. The digest was not edited and no value was overwritten.

## 5. Task 4 — confirmation expiry

`CONFIRMATION_VALIDITY = timedelta(days=90)` removed. `confirmation_horizon()` now requires an explicit
basis; `M2ContextBindings` raises `VALIDITY_BASIS_UNAUTHORIZED` when none is supplied, and the build is
`HELD` with zero contexts persisted. The harness sets 90 only as a declared **test value**.

Impact that made this necessary: `valid_until` drives three expiry refusals in `business_context_v1.py` —
`:178` decision → `ACCESS_DENIED`, `:277` concept → `CONCEPT_STALE`, `:364` source → `SOURCE_STALE`. An
unapproved constant was silently expiring every context 90 days after confirmation.

Preserved: `M2_CONFIRMATION_STALE`, `CONFIRMATION_NOT_CURRENT`, and all three `_fresh` refusals.

## 6. Task 5 — connected chain

| Check | Status | Evidence |
|---|---|---|
| CC1 confirmed M2 read | **PASS** | `current_user=p1_m2_runtime`, `rolsuper=false`, `rolbypassrls=false`; rev 3, 3 answer revisions, 1 finding |
| CC2 deterministic BDJ | **PASS** | real `bdj_candidate_rules`, sha256 `42f7fef3…a061` asserted; no model runner; `reviewed`, 1 finding `UNSUPPORTED_PROFIT_GUARANTEE`, equal to persisted `m2_bdj_findings`. Zero-finding control returns 0 — a real outcome |
| CC3 BCB | **PASS** | `BCB-V1-1.1.0`, `geography` null, no `GEO_V1`, `requires_geography is False`; context carries exactly the deterministic finding at `CANDIDATE` authority |
| CC4 QJ interface | **PASS** | `checked_context()` accepted the real persisted packet; QJ entered once; measurement passed `validate_measurement`. No research approval claimed |
| CC5 QJ fail-closed | **PASS** | 0 uncertainty rows → `UNCERTAINTY_NOT_CONFIRMED`, refused before the runner (`calls==[]`) |
| CC6 cross-owner isolation | **PASS** | other owner: 404 on assessment/context/build; `ACCESS_DENIED`; RLS 0/0/0/0/0 vs owner 1/3/1/1/1 |

Counts: **64 passed, 6 skipped, 4 xfailed** (baseline 58/6/4).

## 7. Residuals and one new defect

| Item | Status | Detail |
|---|---|---|
| **Runner timeout** | **NEW DEFECT** | The suite now takes 251s against the runner's internal 240s pytest cap and timed out 3×. The 64/6/4 counts were obtained by raising that subprocess cap 240→900 for the invocation only; the runner was not edited. CC1–CC6 themselves take ≈24s. The committed runner would fail as-is. Needs a reviewed change to the cap, and the runtime growth (178s → 251s) deserves a look. |
| Lab write path | **Lab-only gap** | In the lab, M2 **writes** run as the harness superuser (`M2_DATABASE_URL` = postgres). Production writes as `p1_m2_runtime`, so the lab cannot prove the write path's grant requirements. Reads and BCB persistence are proven; M2 writes are not. |
| Legacy payloads | **Residual** | 320 plaintext rows in the clone are not retro-sealed. A re-wrap job does not exist. |
| Windows key permissions | **Residual** | `chmod` sets only the read-only bit; the real control is directory ACL. |
| 51 legacy M2 tests | **Non-evidence** | They run as `postgres`, which bypasses RLS. Only PG49–PG55 and the chain checks are RLS evidence. |

## 8. Harness doubles, labelled

Production-real: all rows written through the real HTTP surface; RLS reads as `p1_m2_runtime`; the real
ruleset module; the real BCB builder and persistence; the real `checked_context`.

Doubles: the BDJ adoption-receipt string (identity rests on the sha256); QJ authority, bank and runner; the
QJ builder adapter over the persisted packet. No BDJ finding, authority receipt or research approval was
fabricated.

## 9. Next implementation dependency

1. **Review the runner cap** — 240s is below the suite's current runtime, so `run_isolated.py` fails as committed.
2. **Prove the M2 write path as `p1_m2_runtime`** — the one link the lab cannot exercise.
3. **Decide the re-wrap question** — whether legacy plaintext payloads get sealed.
4. **Owner decision on `result_payload` encryption scope** — prose still restates declaration text inside the
   sealed envelope's plaintext; sealing protects the column at rest, not the model's choice of words.
