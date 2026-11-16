# CQ lifecycle and EE-01 database verification

Implemented in the original `merge_main_jed` checkout. PostgreSQL/psycopg2,
Supabase authentication, shared Dart DTOs and existing server routing remain.
No provider/LLM calls are required for these deterministic operations.

## Executed scope

- `POST /api/v1/cq/sessions/{session_id}/pause` and `/resume` accept the existing
  revision/manifest/request-id contract. Immutable lifecycle events derive
  `PAUSED`; existing physical session-state constraints remain intact.
- `POST .../rendered` records a version-bound client render acknowledgement.
  Prepared presentations alone do not establish S. This acknowledgement is
  technical display evidence, not proof a human read or understood a question.
- Invalid current attempts are audited separately from accepted revisions.
  Retries preserve request-body identity and do not duplicate events.
- `Ee01Service.build_diagnostic` reconstructs committed answers, consent,
  independent qualification, actual render acknowledgements, dependencies and
  stimuli at a fixed cutoff. It persists immutable snapshots, source units and
  category cells, then an immutable withheld report-context readback.
- The restricted `p1_ee01_runtime` role has no superuser/BYPASSRLS privileges;
  actor-scoped policies prevent cross-owner access. The app uses this role,
  not an administrator connection, for EE-01 reads/writes.
- Owner-authenticated GET paths under
  `/api/v1/cq/assessments/{assessment_id}/campaigns/{campaign_id}/measurements/{snapshot_id}`
  read saved diagnostics and `/report-readback` reads its saved context.
  No public endpoint starts an aggregate job or grants scientific authority.

## Physical chain

`m2_assessments -> cq_campaigns -> cq_sessions -> cq_consent_events /
cq_session_controls -> cq_presentations -> cq_render_events ->
cq_answer_revisions / cq_rejected_answer_events -> ee01_source_units ->
ee01_measurement_snapshots -> ee01_category_cells -> ee01_report_readbacks`.

Foreign keys bind the physical rows. A trigger also enforces that each source
unit belongs to the snapshot's campaign/question/session. Records are
append-only. Main property/analytics tables and their report model are separate.

The new readback table is **not an admitted R01-R12 report**. The existing
Jaspr template is marked Proposed V1.1; no adopted A10/ReportAdmission adapter
or approved explanation-template/source binding was verified. The application
therefore returns `REPORT_FINDINGS_WITHHELD_NO_AUTHORIZED_SOURCE`, no claims.

## Policy boundaries

The two explicitly diagnostic A policies are:

- `CUST03_CURRENT_ATTEMPT_DIAGNOSTIC`: latest current attempt; INVALID and
  REFUSED contribute to A, not V.
- `ACCEPTED_EFFECTIVE_DIAGNOSTIC`: latest accepted effective answer; an
  unaccepted invalid attempt does not contribute to A.

Neither is promoted to an adopted production policy. Official percentages
remain NULL. Synthetic diagnostic percentages are stored only for synthetic
releases; non-synthetic aggregation is refused until an authoritative adapter
exists. Cognitive-pretest/developer-preview and unqualified/withdrawn units
cannot contribute to demand Q. No qualification is inferred from geography,
Q01 connection, Q02 NONE or Q04 ZERO. No mean is inferred from Q04 bins.

## Reproduce in PowerShell

From the original repository root, choose a new evidence directory outside
`backend` (allow several GB for Flutter/Android builds):

```powershell
$proofDirectory = 'C:\Users\HP\Documents\Codex\cq-verification-new'
& '.\backend\.venv\Scripts\python.exe' -B '.\backend\tests\cq_runtime\run_isolated.py' --output $proofDirectory
& '.\backend\.venv\Scripts\python.exe' -B '.\backend\tests\cq_runtime\readback_saved.py' $proofDirectory
```

The runner creates/stops its own PostgreSQL 18 cluster on 127.0.0.1:55443.
It never seeds Dss. The second command reopens only that named private cluster,
executes all three supplied verification SQL files with exact saved scope IDs
as the restricted role, saves the outputs, then stops the cluster if it started
it. `private_pg_connection.json` contains private disposable test credentials:
keep it local and exclude it from shared bundles.

For the existing connected-phone harness, set `CQ_RUN_FLUTTER=1`,
`CQ_WIDGET_PROVIDER_INJECTION=1`, and `CQ_NATIVE_DEVICE` to the verified ADB
serial before the first command. The harness uses a separate test application
ID and a signed private JWT, without weakening normal authentication. English
production composition stays separate from the legacy BM compatibility fixture.

SQL names are actual physical names:
`VERIFY_EE01_SCHEMA.sql`, `VERIFY_EE01_AGGREGATES.sql`,
`VERIFY_CQ_TO_REPORT_LINEAGE.sql`. The latter deliberately reports the missing
A10/admission gate; it does not invent release records.

## Development Dss and rollback

The owner classified Dss as local development. Before additive application,
a custom-format Dss backup was restored in another private cluster; migration
apply/replay, transaction rollback and preservation of all existing table
counts passed. The migrations record their file hashes and operator receipt.
No synthetic response/aggregate rows were inserted into Dss.

Private machine overrides use ignored `backend/.env.local`; tracked `.env`
and property/analytics URLs are preserved. All activation flags remain false.
The old 8090 process still exposed 14 CQ operations. A read-only startup
preflight found no missing operational tables and zero pending explanation
jobs. It was then restarted normally: 19 CQ operations, including pause,
resume and rendered, were registered; unauthenticated calls returned 401.
Signed successful mutations were tested against the isolated backend, not
against real respondent records in development Dss.

For rollback, retain additive tables and immutable records. Restore changed
source from the external backups after checking for later edits; remove only
the newly added local override keys if reverting configuration. Restore the
database backup into a **new** database for comparison/recovery; do not restore
over Dss or drop its tables automatically. The executable disposable-clone
rollback evidence is in the task handoff, not a destructive live DOWN script.

## Remaining engineering acceptance

Full original-checkout acceptance remains PARTIAL: actual admitted
Explanation -> A10 -> ReportAdmission -> immutable R01-R12 rendering is not
implemented/verified from adopted contracts. Distinct multi-select units,
Q10 feature denominators and exact Q07 offer-source lineage have been tested.
Two independent synthetic early-screening policies and every required
cross-version/stimulus reporting vector are not comprehensively executed by
the three EE-01 checks. A diagnostic snapshot is not full report acceptance.
The old worktree must remain until all required checks succeed.
