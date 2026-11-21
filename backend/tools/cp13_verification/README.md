# CP-13 independent Python verification

This package imports the actual Project1 services. It does not replace them,
mount new endpoints, start the application, migrate/seed a database, activate
fielding or dispatch QJ. The blank Fiesta, GM Klang and historical Fiesta IDs
are explicitly refused by the live writer. Configuration files are never edited.

**Three modes have different meanings:**

| Mode | Executes | Evidence claim |
| --- | --- | --- |
| `inspect` | Real source/configuration, registered OpenAPI, safe GET probes, optional read-only PostgreSQL hashes | `LIVE` inspection, **zero cloud calls**; inspection PASS is not workflow acceptance |
| `controlled` | Actual BDJ engine/validator, deterministic BCB builder and Direct-QG service, with synthetic repository/confirmation/policy ports and `httpx.MockTransport` provider replies | Always `MOCKED`; no cloud and no DB persistence claim |
| `live` | Existing authenticated FastAPI POST endpoints against prepared isolated records, then real PostgreSQL readback | `LIVE` only when HTTP calls ran; prerequisites or insufficient evidence produce `BLOCKED` |

No mocked output can satisfy live acceptance. The complete controlled scenario
explicitly creates an in-memory confirmation fixture; it does not pretend a
model authorizes a human confirmation. Failure scenarios test modules independently
with valid prerequisites; a downstream negative case does not imply that a
failed BDJ was accepted upstream.

## Environment and installation

Run in PowerShell from the original checkout:

```powershell
Set-Location 'C:\Users\HP\OneDrive\Desktop\sport-marketplace\FYP'
$cp13Python = Join-Path (Get-Location) 'backend\.venv\Scripts\python.exe'
& $cp13Python --version
& $cp13Python -m pip check
```

Use the existing environment; no dependency upgrade is required by this package.
Dependencies are those already declared by `backend/pyproject.toml`: FastAPI,
Pydantic/settings, SQLAlchemy/SQLModel, psycopg2, HTTPX and pytest. If the existing
environment is missing, restore it using the repository's normal installation
instructions. Do not install another PostgreSQL driver to run these scripts.
`bootstrap.py` resolves imports and reads the existing backend environment files
by absolute path, so commands also work from another directory.
If extracting the archive outside the checkout, set `CP13_PROJECT_ROOT` to the
existing FYP repository before running. No independent application is installed.

## Interactive execution

```powershell
& $cp13Python backend/tools/cp13_verification/cp13_manual_verify.py
```

Choose Inspect, BDJ, BCB, Direct-QG or Full workflow; then select a case and
`controlled` or `live`. A live menu choice with no prepared IDs prints the exact
missing prerequisites and saves a BLOCKED result. It never creates records to
fill missing authorizations. Live record identifiers are supplied through the
CLI below. `--help` lists all arguments.

## Exact reproducible commands

```powershell
# Read the real running API and protect the original records with before/after hashes.
& $cp13Python backend/tools/cp13_verification/cp13_manual_verify.py --mode inspect --database-readback --quiet

# Print exact sanitized input, output, prompt messages and validation assertions.
& $cp13Python backend/tools/cp13_verification/cp13_manual_verify.py --mode controlled --module bdj --case conflicting
& $cp13Python backend/tools/cp13_verification/cp13_manual_verify.py --mode controlled --module bcb --case complete
& $cp13Python backend/tools/cp13_verification/cp13_manual_verify.py --mode controlled --module direct-qg --case invalid-question
& $cp13Python backend/tools/cp13_verification/cp13_manual_verify.py --mode controlled --module all --case complete
& $cp13Python backend/tools/cp13_verification/cp13_manual_verify.py --mode controlled --all-cases --quiet

# Executable assertions against the actual services and validators.
& $cp13Python -B -m pytest backend/tools/cp13_verification --confcutdir=backend/tools/cp13_verification -q

# Actual restricted-role BCB persistence through the existing private PG harness.
# This starts/stops its own cluster on 55441; never writes original Dss.
& $cp13Python -B backend/tests/m2_bcb/run_isolated.py --suite cp13-bcb --output artifacts/cp13_reproduction_bcb

# Read-only policy/config/credential-presence/role/FK/budget evidence; no dispatch.
& $cp13Python -B backend/tools/cp13_verification/resolve_blockers.py

# Demonstrate an honest live preflight: currently returns BLOCKED (exit code 2).
& $cp13Python backend/tools/cp13_verification/cp13_manual_verify.py --mode live --module all --case complete --quiet
```

Default results are in `backend/tools/cp13_verification/results/<UTC timestamp>/`.
Use `--output <directory>` for a specific new evidence folder. Use a new output
directory for each execution; an explicitly reused directory replaces same-named
JSON files. Exit codes: **0** executed assertions passed, **1** failed assertion,
**2** blocked. Inspection or controlled exit 0 does not mean CP-13 cloud PASS.

## Opt-in live execution

Live mode uses the existing model configuration and server-controlled disclosure,
rules, ledger, budget and owner checks. It does **not** invent a rules-adoption
receipt, BCB validity period, synthetic disclosure marker, objective, confirmation,
or QG authorization. Current genuine integration gaps are listed in the report.

Prerequisites:

1. A separately configured test FastAPI instance on a local port other than 8090,
   using existing authentication and an isolated PostgreSQL database named
   `project1_cp13_test`, `project1_workflow_tests` or `project1_m2_bcb_test`.
   Use the existing disposable infrastructure under `backend/tests/m2_bcb/` or
   `backend/tests/project1/`. This package does not run its migration/setup commands
   automatically. Never point that infrastructure at the original Dss.
2. Prepare synthetic M2 answers, complete the existing review/confirmation and
   objective actions through existing services/UI in that test environment.
   Its assessment UUID must be absent from original Dss. A copied real assessment
   is refused. Do not use the supplied new blank Fiesta UUIDs.
3. Legitimate configuration/adoption and disclosure requirements must already be
   satisfied in the test instance. Existing candidate rules only cover their named
   synthetic/legacy instrument; they are not newly adopted M2V1 rules.
4. Existing `backend/var/qg_synthetic_authorization.json` must already authorize
   the exact isolated source/owner with `max_attempts=1`. The verifier reads but
   never creates or overwrites this authority artifact. Missing authority blocks.
5. Set the isolated DB URL privately in the process environment and provide a test
   account token using `--prompt-token` (hidden input), or `CP13_BEARER_TOKEN`.
   Never put tokens or credentials into command arguments or committed files.

Example after those prerequisites are genuinely verified (replace symbolic IDs):

```powershell
# Configure CP13_TEST_DATABASE_URL privately. It is never printed.
$cp13TestAssessment = '<isolated-test-assessment-uuid>'
$cp13Confirmation = '<existing-test-confirmation-uuid>'
$cp13Objective = '<existing-confirmed-objective-uuid>'
& $cp13Python backend/tools/cp13_verification/cp13_manual_verify.py `
  --mode live --module all --case complete --api-base http://127.0.0.1:8091 `
  --assessment-id $cp13TestAssessment --revision 11 `
  --confirmation-id $cp13Confirmation --objective-id $cp13Objective `
  --allow-test-writes --prompt-token
```

For one module use `--module bdj`, `--module bcb` or `--module direct-qg`; the last
also needs `--context-id` for the existing persisted BCB. `--case` identifies the
intended prepared scenario; inspect saved `input` to verify its actual contents.
The live runner never overwrites input answers merely to match a selected case.
The controlled runner supplies the predefined inputs exactly; the live runner
uses **actual saved inputs**, whose case correspondence needs independent review.

BDJ dispatch is limited by its existing one-attempt ledger. QG server authorization
must limit attempts to one, even though the production composition supports up to
three validation-feedback attempts. No batch live run or live fault injection is
allowed. An HTTP/provider timeout has an unknown outcome: inspect existing receipts
before any further invocation. Do not change IDs to evade a consumed budget.

## What to inspect in JSON

- `implementation_inventory.json`: real source hashes, prompt identifiers,
  redacted connection identities, registered routes/schemas, current gate results.
- `run_*.json`: exact synthetic M2 values/revisions, findings, BCB packet/provenance,
  draft or refusal, sanitized messages, provider transport status, expected/actual
  assertions and objective action evidence. `cloud_dispatch_count=0` in controlled
  mode. `MOCKED` means test ports are present even though the engines are real.
- `database_before.json`, `database_after.json`, `database_integrity.json`: optional
  read-only original database fingerprints, real relationships and blank Fiesta
  revision/answer count. They are integrity evidence, **not new workflow writes**.
- Live output records authenticated HTTP requests/responses and isolated persisted
  rows/attempt receipts. BCB-only may pass when its immutable DB packet matches.
  BDJ needs matching persisted result/revision/source/model evidence. Direct-QG
  additionally requires independent returned-model evidence; the current API does
  not expose it, so HTTP 200 cannot establish that acceptance requirement.
- `summary.json`: command verdict with a separate cloud-acceptance limitation.

Token usage and cost are `null` when unavailable. The existing provider adapter
does not return those envelope fields; no zero-cost estimate is invented from
the model's `:free` suffix. Controlled reply token counters are not real billing.
The package does not access encrypted raw-response custody or scrape credentials.

## Existing implementation map

All paths below are under `backend/src/sitewise/`; exact installed API methods,
schemas and file hashes are generated by inspection, not invented here.

| Module | Existing entry points | Persistence / checks |
| --- | --- | --- |
| M2 deterministic BDJ | POST `/api/v1/m2/assessments/{id}/bdj/evaluate`; `services/bdj_service.py` | `m2_bdj_evaluations`, `m2_bdj_findings`; completeness, revision, owner, registered item validation |
| Cloud BDJ | POST `/api/v1/project1-workflow/assessments/{id}/business-understanding/model-assisted`; `project1/model_assisted.py`, `bdj.py` | `project1_ai.runs`, `attempts`, `attempt_receipts`, `bdj_results` and children; source/disclosure/rules/prompt pins and encrypted custody |
| Review / confirmation | Existing M2 `/review`, `/confirm`, `/confirmations/{id}/research-objectives`, `/research-objectives/{id}/confirmed-revisions` | `m2_confirmation_snapshots`, `m2_confirmed_uncertainties`, `m2_research_objective_sources`, `m2_research_revisions`; real CLARIFY needs existing unresolved limitation |
| Deterministic BCB | POST `/api/v1/m2/assessments/{id}/business-context`; `PersistedBusinessContextService`, `BusinessContextBuilderV1` | `m2_business_contexts`, `m2_business_context_builds`; current owner/confirmation/bindings, exact immutable canonical packet |
| Direct-QG | POST `/api/v1/m2/research-objectives/{id}/qg-candidate`; `QgCandidateService`, `DirectQgService.prepare_candidate` | `m2_review_question_versions` tied through objective → confirmation → assessment; source-bound live authorization, ledger, candidate schemas and deterministic validators |

Current prompts: `BDJ-SOURCE-3-CAND`, `QG-PROPOSE-6-CAND`. Current provider:
TokenHarbor, `mimo-v2.6-flash:free`, temperature 0, maximum 4000 output tokens,
strict structured output and model identity. BCB has **no provider or model**.
Direct-QG's proposals do not grant scientific, owner, publication, fielding or
report-release authority. Legacy-named internal data readers remain existing
implementation details; this package never dispatches the retired stage.

The source-routing correction uses `get_m2_db` for the configuration identity
probe and `m2_session_for` for actor-bound source reads. No live feature switch
was enabled. Load the corrected source only when the existing activation and
approval requirements are genuinely satisfied.

## Limits

The fixture base is copied, unchanged, from the repository's existing synthetic
BCB fixture (`backend/tests/project1/bcb/fixtures/valid_confirmed.json`). The
runner explicitly changes only test answers/options, findings, synthetic
confirmation bindings and the current GEO-excluded builder contract. These are
test fixtures, not production questionnaire registration or adoption evidence.
The separate M2V1 11-answer example in `cases.json` is not registered or written.
Lexical/reference validators do not prove that every natural-language business
claim is scientifically correct. Independent semantic review remains necessary.
No full live cloud acceptance or original-database workflow persistence was
demonstrated by the controlled tests; see the accompanying verification report.

The added `cp13-bcb` suite selects six BCB-only tests using the existing
disposable infrastructure. `postgres_checks.py` exports actual HTTP statuses,
SQL parameters/readback, generated IDs and the canonical packet. Its signed JWT
and 90-day validity basis are explicitly test-only; the production binding,
builder, store and PostgreSQL operations are actual. No QJ engine is executed.
The real cluster is stopped after evidence export. Re-run the command to obtain
fresh test records; use IDs from the new evidence with `verify_persistence.sql`.

The latest original Fiesta observation is revision **12**, confirmed **12**, with
**12 answer rows**, already present in the first package DB snapshot. It is
protected, regardless of earlier descriptions of it as blank. The verifier does
not reset or write that assessment. See the report for timestamps and correction.
