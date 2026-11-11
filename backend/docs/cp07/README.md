# CP07 backend integration checkpoint

Applied in the actual `FYP/backend` checkout, 11 November 2026. **Partial development integration; full workflow NOT ACCEPTED.**

Read [ACCEPTANCE.md](ACCEPTANCE.md) for what ran, [RECONCILIATION.md](RECONCILIATION.md) for the reuse/adapt/create matrix and exact decisions, and [WORKFLOW_INPUTS_AND_EXITS.md](WORKFLOW_INPUTS_AND_EXITS.md) for stage-by-stage inputs and exit criteria.

## Run the isolated verification

From `C:/Users/HP/OneDrive/Desktop/sport-marketplace/FYP/backend`:

```powershell
.\.venv\Scripts\python.exe tests\cp07\run_isolated.py
```

Requires existing backend dependencies and PostgreSQL 18 binaries at `C:/Program Files/PostgreSQL/18/bin` (override with `CP07_PG_BIN`). Creates a NEW private cluster on loopback **55437**, database `project1_cp07_tests`, restores recorded stage **schema-only** snapshots and inserts conspicuously synthetic test records. Refuses an occupied port. No Dss connection, migration or existing-cluster change. The cluster is stopped in `finally`; its data/logs are retained in a unique temporary directory printed by the runner. No recursive cleanup is performed. The password file is deleted after initialization; credentials/tokens are not included in evidence.

Runs the actual `sitewise.main.app` on an ephemeral loopback HTTP port with lifespan disabled to avoid unrelated startup schema creation. It exercises real HTTP, existing JWT verification against a local test JWKS server, real application profile lookup and PostgreSQL persistence. It does not override FastAPI authentication/database dependencies. `--confcutdir` deliberately excludes the parent test suite's fake-JWKS fixture. Test JWTs are synthetic; real Supabase credential acceptance is NOT_TESTED.

Generated evidence: `pytest.log`, `pytest.xml`, `run.json`, `evidence/http_traces.json`, `evidence/sql_function_traces.json`, `evidence/persistence.json`, and cluster setup/server logs. The delivered evidence viewer and JSON are copies of the executed run, not live dashboards.

## API surface

Separately enabled by `PROJECT1_CP07_ENABLED=true`; **false by default**. The old `M2_UPSTREAM_ENABLED` remains false; its unresolved BDJ imports are not activated or replaced.

| Endpoint under `/api/v1/project1` | Behavior |
|---|---|
| `GET /assessments/{assessment_id}/confirmed-source?confirmation_id=...&expected_revision=...` | Verified active entrepreneur, owner-scoped persisted M2 snapshot, current confirmation, authorized instrument, recomputed digest, exact answer-reference/value projection. No new confirmation. |
| `GET /uncertainties/{candidate_version_id}/history?after_event_no=0` | Owner-scoped existing version and ordered append-only decision history, canonical confirmed text when bound to this actor/snapshot; 100-event pages. History never grants QJ admission. |
| `POST /uncertainty-decisions` | Verified actor only; strict JSON `{event_id,candidate_version_id,action,receipt}`; calls existing stage-only `UcDecisionGateway`. Extra actor/approval fields rejected. |

Main `DATABASE_URL` must be a permitted loopback stage target before authentication may provision any profile. Private read verification accepts PostgreSQL18/database `project1_cp07_tests`/55437 in addition to the existing B4 tuples. **UC writes retain the untouched gateway's existing `dss_uc_stage_tests`/5432/PG16 or /5433/PG18 allowlist**. They do not become allowed on 55437.

UC write configuration is server-only `PROJECT1_CP07_UC_DATABASE_URL`, held as a `SecretStr`, using the existing restricted `p1uc_stage_human` login on the exact same host/port/database as the app. Missing/mismatched configuration fails closed. No production permission is created by a feature flag. Production read grants/interface remain unverified: the positive source/history tests use the private-cluster administrator, while SQL decisions use the real non-superuser restricted login.

## Rollback

Disable `PROJECT1_CP07_ENABLED` and restart the application to remove all new routes. No database rollback or down migration is needed. Preserve existing UC gateway, dirty database/session files, tests/cp1 and other unrelated work. If code rollback is needed, reverse only the delivered tracked-files patch after checking it still applies; remove only the new files listed as CP07-owned in FILE_INVENTORY.json. Do not reset the checkout or delete shared directories. The snapshot SQL files are test fixtures, not deployment migrations.

No live model/provider call, six-attempt ledger, BCB construction, QJ route, QG draft, scientific approval, questionnaire fielding or report release is implemented or claimed by this checkpoint.
