# CP-04A — Live LLM Dispatch: Readiness Checkpoint

**Date:** 2026-11-17 (refreshed) · **Status:** `NOT_READY` — 4 of 10 gates unmet · **No paid call attempted**
**Purpose:** the exact, ordered list of what is still pending before one real TokenHarbor dispatch can run,
who owns each item, and what is already satisfied. Nothing here is a redesign; the modules are frozen.

---

## 1. Gate table (measured this run, not asserted)

`python scripts/cp04a_live_dispatch_probe.py --check` from `backend/`:

```
  FAIL  G1 PROJECT1_WORKFLOW_ENABLED  (not set or false)
  FAIL  G5 TOKENHARBOR_ENABLED  (not set or false)
  PASS  G5b TOKENHARBOR_API_KEY
  FAIL  G6a PROJECT1_RULES_VERSION  (empty)
  FAIL  G6b PROJECT1_RULES_SHA256  (not a 64-hex digest)
  FAIL  G6c PROJECT1_RULES_ADOPTION_RECEIPT  (empty)
  PASS  G7 packet is synthetic
  PASS  G8 resolved runtime database is the clone
  PASS  G9 DATABASE_URL present for the admin fixture rows
Overall: NOT READY   exit=1
```

| # | Gate | Required | Current (measured) | Layer |
|---|---|---|---|---|
| G1 | `PROJECT1_WORKFLOW_ENABLED` | `true` | **absent → `False`** | `core/config.py:72` ← env |
| G5 | `TOKENHARBOR_ENABLED` | `true` | **absent → `False`** | `core/config.py:79` |
| G5b | `TOKENHARBOR_API_KEY` | non-empty | **present** (73 chars, never printed) | `config.py:78` |
| G6a | `PROJECT1_RULES_VERSION` | a key of `RULE_MODULES` | **`""`** | `config.py:73`, `bdj.py:25` |
| G6b | `PROJECT1_RULES_SHA256` | `sha256` of that module's file | **`""`** | `bdj.py:28` |
| G6c | `PROJECT1_RULES_ADOPTION_RECEIPT` | non-empty governance receipt | **`""`** | `bdj.py:25` |
| G7 | packet `data_class` | `SYNTHETIC_NONHUMAN` | **PASS** — the probe builds it | `disclosure.validate_synthetic` |
| G8 | runtime URL resolves to the clone | `project1_workflow_tests` | **PASS** — rewritten, then re-measured | probe `clone_url` |
| G9 | admin `DATABASE_URL` present | non-empty | **PASS** | probe fixture insert |

Route-only gates, **not exercised by the probe** (they guard the HTTP surface, not the service):

| # | Gate | Current (measured) | Effect |
|---|---|---|---|
| G2 | `settings.database_url` database == `Dss` | **`Final_Location_Analysis`** | `WORKFLOW_CONFIGURATION_REQUIRED` |
| G3 | `database_url` username != `postgres` | **`postgres`** | same |
| G4 | session principal not superuser/BYPASSRLS | would raise | `SOURCE_PRINCIPAL_REVIEW_REQUIRED` |

Measured `.env` targets (no passwords read or printed):

| Key | host | database | user |
|---|---|---|---|
| `DATABASE_URL` (admin) | localhost | `Final_Location_Analysis` | `postgres` |
| `PROJECT1_RUNTIME_DATABASE_URL` | localhost | `Dss` | `p1ai_engine` |
| `PROJECT1_AUDIT_DATABASE_URL` | localhost | `Dss` | `p1ai_auditor` |

## 2. Applied state on `Dss` — measured, not assumed

Two different files are called `_02`. They are not the same migration:

| Migration | On `Dss`? | Receipt |
|---|---|---|
| `20261111_01_candidate_ledger.sql` | **applied** — `runs`/`attempts`/`attempt_receipts` exist | earlier session |
| `20261116_02_m2_runtime_role.sql` | **applied** — `p1_m2_runtime` + 12 RLS policies | `CP-01 2026-11-16T12:06:02Z`, backup `c50b84fd…` |
| `20261117_01_execution_principal.sql` | **applied** — `p1ai_engine`/`p1ai_runtime`/`p1ai_auditor` | **none — `BLK-MIG-RECEIPT`** |
| `20261117_02_finding_provenance.sql` | **NOT applied** | none |
| `20261117_03_bdj_result_persistence.sql` | **NOT applied** | none |

When §12 of the approval request says "`_02` / `_03`", it means the **2026-11-17** pair. The 2026-11-16
`_02` is a different migration and is already in `Dss`.

Evidence that today's pair is unapplied: the §12 approval block is blank (no Owner, no DBA, no checkbox
ticked), no `MIGRATION_RECEIPT_20261117*` exists anywhere in the repository, both files are untracked
(`git status` → `??`), and the last object check on `Dss` returned
`relation "project1_ai.bdj_results" does not exist`.

A pre-apply backup **was** taken — `backend/backups/cp04a/dss_pre_cp04a_20261117_155610.dump` (653 KB)
plus a PG16 re-dump `…_pg16_20261117_155626.dump`. That is the §12 "backup taken" material, not an apply.

### 2.1 The clone is ahead of `Dss` by exactly two migrations

`project1_workflow_tests` was created as a template copy of `Dss`, so it inherited `Dss`'s state, and then
today's pair was applied to the **clone only**. The clone's own `project1_ai.schema_versions` ledger says so:

| Recorded version | Ledger text (verbatim, abridged) | Written |
|---|---|---|
| `20261111_01_candidate` | `CP-01 2026-11-16: candidate ledger applied after verified backup c50b84fd…` | 2026-11-16 20:11 |
| `20261116_02_m2_runtime_role` | `RECONCILED 2026-11-17 by object inspection (7/7 checks) … No receipt was written when this migration was originally applied, so its application date is unknown and is not claimed here.` | 2026-11-17 15:13 |
| `20261117_01_execution_principal` | same reconciliation wording | 2026-11-17 15:13 |
| `20261117_02_finding_provenance` | `CP-04A 2026-11-17: bdj result persistence tested on isolated clone` | 2026-11-17 15:13 |
| `20261117_03_bdj_result_persistence` | same wording | 2026-11-17 15:13 |

The ledger therefore states, in its own words, that today's pair was **"tested on isolated clone"** — which
is not an application to `Dss`. `project1_ai` holds **10** tables on the clone and **4** on `Dss`; the
**six** that `Dss` does not have are `finding_provenance`, `bdj_results`, `bdj_result_sources`,
`bdj_result_findings`, `bdj_result_validations` and `bdj_raw_responses`.

> **Correction (2026-11-17, later the same day).** An earlier revision of this section listed only five
> missing tables and omitted `bdj_raw_responses`. That was wrong, and wrong for an instructive reason: the
> list was derived from the clone's inventory instead of from the migrations' own `CREATE TABLE`
> statements. Both files together create exactly six tables — `_02` one, `_03` five. Verified by
> `scripts/cp04a_migration_preflight.py` under read-only sessions. See
> `CP04A_MIGRATION_PREFLIGHT_RECONCILIATION_20261117.md` §1–2.

Divergence is **one-way**: writes to the clone never reach `Dss`, and rows written to `Dss` after the copy
are not in the clone. The clone is a test bench, not a staging environment.

**Known imprecision, not corrected.** The ledger text for `20261117_02_finding_provenance` reads
*"bdj result persistence tested on isolated clone"*, which describes `_03`'s purpose. The receipt string for
`_02` is a copy of `_03`'s. The row is left as written — editing an applied-state record to make it tidier
would be worse than the inaccuracy — but it should not be quoted as evidence of what `_02` did.

## 3. What is already done — do not redo it

| Item | Evidence |
|---|---|
| Provider key present, endpoint and model fixed | `provider.py`: `tokenharbor.ai/v1/chat/completions`, `mimo-v2.6-flash:free` |
| Clone database complete | `project1_ai.runs` 183 · `attempts` 173 · `attempt_receipts` 173 · `bdj_results` 124 · `bdj_result_sources` 168 · `bdj_result_findings` 16 |
| Findings/authority CHECK installed on the clone | `pg_get_constraintdef` → `finding_count = 0 OR review_outcome IN ('reviewed','stale')` |
| Restricted principal works, NOINHERIT enforced | querying `project1_ai` as bare `p1ai_engine` on `Dss` returns **`permission denied for schema project1_ai`** — privilege exists only after `SET LOCAL ROLE p1ai_runtime` |
| `p1ai_runtime` has `USAGE` on `project1_ai` | measured `true` on both databases; `p1_m2_runtime` correctly `false`. **`MIG-AUTH-01` does not block run provisioning.** |
| Fixture path | 246 passed, 1 skipped on the clone |
| History V1.1 readback | verified on the clone, quote sentinel absent from the projection |
| Harness | `backend/scripts/cp04a_live_dispatch_probe.py`, two-key gate, forces the clone |

## 4. What is still pending — in order

### P1 · Owner governance decision: adopt a ruleset (`BDJ-RULE-COVERAGE-01`, OPEN)

This is the **only** item that cannot be completed by editing configuration. `load_rules()` refuses unless
the version is a key of `RULE_MODULES` **and** an adoption receipt is supplied **and** the sha matches the
module file. `BDJ-M2V1-0.1-CAND` was retired on 2026-11-17 (D02) and is deliberately no longer loadable, so
two rulesets remain:

| `PROJECT1_RULES_VERSION` | module | `PROJECT1_RULES_SHA256` |
|---|---|---|
| `BDJ-RULESET-0.2-CAND` | `sitewise/domain/bdj_candidate_rules.py` | `42f7fef3bf2bb48255ab8eac406dfb8232923b76789dd065d693732e8bf2a061` |
| `BDJ-EXPLICIT-FORMAT-0.1-CANDIDATE` | `sitewise/domain/bdj_rules.py` | `b2138e53fdd04429ed9225b1e97770e2d735cbc415350966c5e988dcd70d4836` |

`BDJ-RULESET-0.2-CAND` is the pairing that matches the prepared probe: its
`SERVICE_FORMAT_EXPLICIT_CONFLICT` rule reads exactly `M2-04` + `M2-05`, which are the two declarations the
probe sends (`PROBE-TAKEAWAY-ONLY` vs `PROBE_DINE_IN`). `BDJ-EXPLICIT-FORMAT-0.1-CANDIDATE` does not.

Recompute the digest yourself before use — it must match the file at dispatch time:

```
sha256sum backend/src/sitewise/domain/bdj_candidate_rules.py
```

The **receipt** is not computable. It is a governance artifact. I will not invent one, and a placeholder
string would defeat the control it represents.

### P2 · Set two flags and the three rules values

```
PROJECT1_WORKFLOW_ENABLED=true
TOKENHARBOR_ENABLED=true
PROJECT1_RULES_VERSION=BDJ-RULESET-0.2-CAND
PROJECT1_RULES_SHA256=42f7fef3bf2bb48255ab8eac406dfb8232923b76789dd065d693732e8bf2a061
PROJECT1_RULES_ADOPTION_RECEIPT=<the P1 receipt>
```

`TOKENHARBOR_STRUCTURED_MODE` and `TOKENHARBOR_TIMEOUT_SECONDS` stay unset: their defaults
(`json_schema`, `30`) are the intended values.

### P3 · Approve or refuse the one paid call

Two keys, both required, neither stored:

```
cd backend
CP04A_LIVE_DISPATCH_APPROVAL=<your token> \
  ./.venv/Scripts/python.exe scripts/cp04a_live_dispatch_probe.py \
  --dispatch --confirm <your token>
```

Without the environment token, or with a mismatched `--confirm`, the script prints
*"No provider call was made"* and exits `2`. With any gate unmet it exits `1` before importing the
provider. **I will not run this without your explicit approval.**

### P4 · Only if you want the HTTP route tested, not just the service

The probe calls `run_model_assisted()` directly, so it proves provider → ledger → persistence → readback
but **not** `configuration_gate`. To exercise FastAPI end to end:

1. apply `20261117_02` + `_03` to `Dss` (Owner signature — `CP04A_CORRECTED_MIGRATION_DSS_APPROVAL_REQUEST.md` §12);
2. repoint `DATABASE_URL` at `Dss` under a non-superuser role (G2, G3, G4).

Doing (2) without (1) would spend the call and then fail at persist with `WORKFLOW_STORAGE_UNAVAILABLE`,
because `Dss` has `runs`/`attempts`/`attempt_receipts` but no `bdj_results`. **Order matters.**

### P5 · Independent of the test, but outstanding

Rotate `TOKENHARBOR_API_KEY`, `SUPABASE_SECRET_KEY`, `SECRET_KEY`, and the `p1ai_engine` / `p1ai_auditor`
passwords — they appeared in a backup file that matched no ignore rule until the whole `.env*` family was
ignored. Ignoring the file does not un-expose the values.

## 5. What the paid call will and will not prove

- One `POST`, `max_tokens: 4000`, `temperature: 0`, `stream: false`, model `mimo-v2.6-flash:free`
  (a free-tier routing marker). No retry: `ModelRunner` reserves the attempt before dispatch and
  `TokenHarbor` never repeats a POST.
- Synthetic packet only, literal values from the probe source, written to `project1_workflow_tests`.
  No entrepreneur answer leaves the machine and `Dss` is never touched.
- A successful response is **a candidate**. `finding_authority` stays `CANDIDATE_ONLY`, `no_authority()`
  flags stay false. It is not an authorised BDJ finding, not workflow acceptance, not scientific approval.
- It does **not** prove real-data dispatch is permitted. The production M2 projection emits
  `schema_version` but **no `data_class`** (`projection.py:59`), so `validate_synthetic()` refuses real data
  by construction. That is the guarantee, not a gap.

## 6. Checkpoint summary

| Stage | State | Remaining blocker | Owner |
|---|---|---|---|
| Fixture dispatch (clone) | `VERIFIED` — 246 tests | none | — |
| Harness gates | `VERIFIED` — refuses correctly | — | — |
| Live dispatch (synthetic, clone) | **prepared, not executed** | **P1** (receipt) + **P2** (flags) + **P3** (approval) | you |
| Live dispatch through FastAPI | `BLOCKED` | **P4** — migration signature + non-superuser `DATABASE_URL` | you / DBA |
| Live dispatch (real M2 data, `Dss`) | `BLOCKED` | G7 policy + P4 | you |
| Credential rotation | `OUTSTANDING` | **P5** | you |

**No provider failure is claimed.** No call was attempted, so none can have failed.

## 7. Changes to the harness made during this refresh

- `G7` and `G8` were labels that could not fail — `G7` was hardcoded `True` and `G8` passed on a merely
  non-empty URL. Both now measure the object they name: `G7` reads `data_class`/`purpose` off the packet
  that will be sent; `G8` re-parses the URL *after* rewriting and requires the database to be the clone.
  Added `G9` for the admin URL the fixture insert needs.
- `read_env()` parsed `.env` directly while `Settings` resolves `.env` relative to the working directory, so
  a gate could pass while the app loaded defaults. The merged view is now published into the process
  environment, where it takes precedence over `env_file`, so gates and settings cannot diverge from any
  working directory.
- `gates()` signature changed to `gates(env, packet)`; `build_packet()` runs once, before the gates.
