# Project1 integration boundary

The five-stage integration is **partial; release and merge readiness remain held**.
The production application now reads authenticated availability instead of showing
synthetic review findings, questionnaires, reports, activity, or invitations.

## Read contract

`GET /api/v1/project1-read/readiness` returns collection availability.
`GET /api/v1/project1-read/assessments/{workspace_uuid}/readiness` first uses the
existing `AssessmentService.get_owned` and returns availability bound to that
workspace. Both return `project1-readiness/1`, `Cache-Control: no-store`, and
explicit holds for review, questionnaire, report, and research activity.

These are availability endpoints, **not completed research read APIs**. A property
assessment UUID is not an M2 assessment, confirmation, campaign or report binding.
No business POST/PUT/PATCH/DELETE or report-generation operation was added.
The shared Dart parser rejects another assessment, an unknown contract version,
or attempted promotion of fielding/report release. Transport failures remain
errors and expose retry rather than sample data or successful empty histories.

The CQ successor and customer candidate factories remain unregistered. Existing
M2, workflow and CP07 flags remain default-off. Synthetic authorization exists
only inside disposable test fixtures. No campaign or CQ_FORM_VERSION was added.

## Runtime repairs

- `scripts/cp04b/verify.py` is the reviewed V1.1 diagnostic with an explicit
  `postgresql+psycopg2` fake URL; application drivers/dependencies are unchanged.
- Its route walker handles eager and deferred FastAPI include contexts, including
  inherited dependencies and prefixes. Windows asyncio self-pipes are prepared
  before blocking all later connection attempts. It never runs app lifespan.
- Missing M2 BDJ/confirmation dependency providers now use the existing repository
  and request session. The existing 0.2 candidate rules were relocated unchanged
  into `domain/bdj_candidate_rules.py`; the old database path re-exports them.
  Hash validation resolves the actual rule implementation. Legacy 0.1 is unchanged.
- The standalone CQ successor rejects URL/body assessment mismatches before policy,
  principal or consent resolution and before writing its preview cache.

## Verification

From `backend/`, using its existing virtual environment:

```powershell
.venv\Scripts\python.exe scripts\cp04b\verify.py --backend . --output <new-external-output-directory> --probe-registration --probe-negative-auth
.venv\Scripts\python.exe scripts\run_project1_offline.py --output <external-output-directory>
.venv\Scripts\python.exe tests\integration\run_cross_app.py --output <external-output-directory>
```

The offline runner blocks external connections and permits only memory SQLite.
It bypasses the legacy root test fixtures, which otherwise target a configured
database. M2 is enabled only in its integration-test child process. `--suite`
selects integration, successor, candidate, workflow, bcb or domain.
The private HTTP runner exercises FastAPI, real token verification with a test
key, shared Dart transport/DTOs, and the held CA-01/CA-02 boundary. Database
dependencies point to private memory SQLite; lifespan is off. This does not
prove PostgreSQL locking/RLS or successful research acceptance journeys.

Existing `tests/cp07/run_isolated.py` and `tests/project1/run_isolated.py` create
and stop new private PostgreSQL clusters. Never substitute an existing database.
Their passing suites do not authorize the live schema or new fielding.

Jaspr fixtures and retired preview material are under `fyp_jaspr_web/test/fixtures`.
Flutter fixtures, old UI and the preview-only route harness are under
`fyp_mobile_app/test/assessment/fixtures`; normal application routes never use them.
Existing local drafts are preserved and never reclassified as customer evidence.

## Outstanding gates

- Adopted workspace/M2 confirmation, approved bank and campaign bindings.
- Scientific/fielding and consent authorization for Q01-Q13 and any successor.
- Restricted database identity and schema compatibility: the inspected app target
  was Final_Location_Analysis; M2 tables were in Dss, whose reviewed schema did not
  yet contain `m2_clarification_events`.
- Deterministic EE-01 lineage/aggregation, original research source bindings,
  A10/ReportAdmission and immutable R01-R12 persistence interfaces.
- Full CA-01 and CA-02 acceptance, broader deployment validation and main-branch
  reconciliation before separately authorized merge/migration/activation.

Do not substitute property ML/SHAP reports, a browser flag, a synthetic snapshot,
or a candidate report package for any of those contracts.
