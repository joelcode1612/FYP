# PROJECT1 — Structure Change Register

**Generated** by `backend/scripts/cp03f_structure_snapshot.py` + `cp03f_structure_report.py`. Every number below is derived from the working tree and `git`; none is hand-counted.

## Provenance

| Field | Value |
|---|---|
| Branch | merge_main_jed |
| HEAD | `ba30035ecb24b80fa155cc7049cf3cdf94a67844` |
| HEAD (short) | ba30035 |
| Working tree | 171 entries in `git status --porcelain` |
| Snapshot taken | 2026-11-17 12:11:38 +0800 |
| Files before (HEAD) | 1708 |
| Files after (working tree) | 1832 |
| Added | 125 |
| Removed | 1 |
| Modified | 51 |

> **AFTER is labelled `CURRENT STRUCTURE — REORGANIZATION PENDING`.** No module was relocated in this checkpoint beyond the single `m2_rules.py` move that predates it. The delta below is the CP-03F working set, not a completed architectural migration.

## Exclusions

The tree excludes `.git`, `.venv`, `.dart_tool`, `build`, `.gradle`, `ephemeral`, `.fvm`, `__pycache__`, `.pytest_cache`, `*.egg-info`, `backend/var`, `out`, `analysis_output`, `deliverables`, and `*.zip`. The same filter is applied to the BEFORE and AFTER trees — filtering only one side made an earlier run report 483 spurious removals.

`.env*` file **names** appear in the tree; contents were never read and are not reproduced anywhere.

## Added — by kind

| Kind | Count | What it is |
|---|---|---|
| SOURCE | 37 | application code |
| TEST | 20 | tests and fixtures |
| TOOLING_SCRIPT | 31 | verification / snapshot scripts |
| MIGRATION | 8 | SQL migrations (see below) |
| DOCUMENTATION | 17 | reports and registers |
| EVIDENCE_BACKUP | 12 | restored backup copies |

### Added — migrations

| File |
|---|
| `backend/migrations/cq/20261116_03_synthetic_import_boundary.sql` |
| `backend/migrations/cq/20261116_04_synthetic_interactive.sql` |
| `backend/migrations/m2/20261117_04_workflow_trigger_grant.sql` |
| `backend/migrations/m2/20261117_05_workflow_view_read_scope.sql` |
| `backend/migrations/m2/20261117_06_workflow_cq_read_scope.sql` |
| `backend/migrations/project1_ai/20261116_02_m2_runtime_role.sql` |
| `backend/migrations/project1_ai/20261117_01_execution_principal.sql` |
| `backend/migrations/project1_ai/20261117_02_finding_provenance.sql` |

### Added — application source

| File |
|---|
| `backend/.env.env.bak.execprincipal` |
| `backend/.env.local` |
| `backend/src/sitewise/api/v1/synthetic_execution.py` |
| `backend/src/sitewise/api/v1/synthetic_inspection.py` |
| `backend/src/sitewise/domain/bdj_m2v1_candidate_rules.py` |
| `backend/src/sitewise/modules/__init__.py` |
| `backend/src/sitewise/modules/decision_engine/__init__.py` |
| `backend/src/sitewise/modules/decision_engine/domain/__init__.py` |
| `backend/src/sitewise/modules/decision_engine/domain/m2_rules.py` |
| `backend/src/sitewise/project1/disclosure.py` |
| `backend/src/sitewise/services/synthetic_case_setup.py` |
| `backend/src/sitewise/services/synthetic_dss_import.py` |
| `backend/src/sitewise/services/synthetic_execution_service.py` |
| `backend/src/sitewise/services/synthetic_inspection_service.py` |
| `backend/src/sitewise/services/synthetic_preview_boundary.py` |
| `backend/startup.stderr.log` |
| `backend/startup.stdout.log` |
| `fyp_jaspr_web/lib/components/customer_questionnaire_step5.dart` |
| `fyp_jaspr_web/lib/components/m2_workflow_panel.dart` |
| `fyp_jaspr_web/tool/nav_labels.dart` |
| `fyp_jaspr_web/web/sitewise_assessment_entry.css` |
| `fyp_jaspr_web/web/sitewise_cq_step5.css` |
| `fyp_mobile_app/.flutter-plugins-dependencies` |
| `fyp_mobile_app/android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java` |
| `fyp_mobile_app/android/gradle/wrapper/gradle-wrapper.jar` |
| `fyp_mobile_app/android/gradlew` |
| `fyp_mobile_app/android/gradlew.bat` |
| `fyp_mobile_app/android/local.properties` |
| `fyp_mobile_app/flutter_01.log` |
| `fyp_mobile_app/flutter_02.log` |
| `fyp_mobile_app/ios/Flutter/Generated.xcconfig` |
| `fyp_mobile_app/ios/Flutter/flutter_export_environment.sh` |
| `fyp_mobile_app/ios/Runner/GeneratedPluginRegistrant.h` |
| `fyp_mobile_app/ios/Runner/GeneratedPluginRegistrant.m` |
| `fyp_mobile_app/lib/features/assessment/view/synthetic_inspection_page.dart` |
| `fyp_mobile_app/lib/features/assessment/view/synthetic_session_host.dart` |
| `shared_logic/lib/src/data/repositories/api_synthetic_inspection_repository.dart` |

## Modified — by kind

| Kind | Count |
|---|---|
| SOURCE | 42 |
| TEST | 9 |

### Modified — application source

| File |
|---|
| `backend/ml_reference/recommender_eval/model_selection_report.json` |
| `backend/src/sitewise/api/v1/m2.py` |
| `backend/src/sitewise/api/v1/m2_route.py` |
| `backend/src/sitewise/api/v1/router.py` |
| `backend/src/sitewise/core/config.py` |
| `backend/src/sitewise/db/m2_session.py` |
| `backend/src/sitewise/dependencies.py` |
| `backend/src/sitewise/domain/m2_rules.py` |
| `backend/src/sitewise/main.py` |
| `backend/src/sitewise/ml/pu_expanded.py` |
| `backend/src/sitewise/project1/bdj.py` |
| `backend/src/sitewise/project1/contracts.py` |
| `backend/src/sitewise/project1/ledger.py` |
| `backend/src/sitewise/project1/projection.py` |
| `backend/src/sitewise/project1/prompts.py` |
| `backend/src/sitewise/project1/provider.py` |
| `backend/src/sitewise/repositories/catalog_repository.py` |
| `backend/src/sitewise/repositories/fyp_property_repository.py` |
| `backend/src/sitewise/services/bdj_service.py` |
| `backend/src/sitewise/services/business_context_v1.py` |
| `backend/src/sitewise/services/confirmation_service.py` |
| `backend/src/sitewise/services/ee01_service.py` |
| `backend/src/sitewise/services/m2_service.py` |
| `fyp_jaspr_web/lib/app.dart` |
| `fyp_jaspr_web/lib/data/assessment_api.dart` |
| `fyp_jaspr_web/lib/data/navigation.dart` |
| `fyp_jaspr_web/lib/main.client.options.dart` |
| `fyp_jaspr_web/lib/pages/entrepreneur/ai_recommendations_page.dart` |
| `fyp_jaspr_web/lib/pages/entrepreneur/assessment_workspace_page.dart` |
| `fyp_jaspr_web/lib/pages/entrepreneur/dashboard_page.dart` |
| `fyp_jaspr_web/lib/pages/entrepreneur/explore_page.dart` |
| `fyp_jaspr_web/lib/pages/entrepreneur/property_detail_page.dart` |
| `fyp_jaspr_web/lib/pages/entrepreneur/recommendations_page.dart` |
| `fyp_jaspr_web/lib/pages/owner/dashboard_page.dart` |
| `fyp_jaspr_web/web/index.html` |
| `fyp_mobile_app/lib/features/assessment/view/cq_invitations_page.dart` |
| `fyp_mobile_app/lib/features/assessment/view/cq_session_page.dart` |
| `fyp_mobile_app/lib/features/assessment/view/questionnaire_screen.dart` |
| `fyp_mobile_app/lib/features/assessment/viewmodel/cq_view_model.dart` |
| `shared_logic/lib/shared_logic.dart` |
| `shared_logic/lib/src/data/repositories/api_customer_questionnaire_repository.dart` |
| `shared_logic/lib/src/data/repositories/api_m2_repository.dart` |

## Removed

| File | Reason |
|---|---|
| `fyp` | untracked stub / superseded |

## Legacy paths and compatibility re-exports

79 files remain at legacy paths under `backend/src/sitewise/{domain,services,repositories}/`.

| Legacy directory | Files |
|---|---|
| domain | 13 |
| repositories | 18 |
| services | 48 |

**Compatibility shims: 1 of 79.**

| Legacy path | Lines | Migrated counterpart |
|---|---|---|
| `backend/src/sitewise/domain/m2_rules.py` | 17 | `backend/src/sitewise/modules/decision_engine/domain/m2_rules.py` |

> The shim has **zero importers**: all seven call sites already import `sitewise.modules.decision_engine.domain.m2_rules` directly. It is kept because `tests/test_architecture.py::test_legacy_m2_rules_reexport_same_objects` asserts it exists, not because anything depends on it.

The remaining 78 legacy files are **not** shims — they are still the only implementation. Moving `m2_rules.py` did not migrate the module; it created one migrated leaf plus one re-export.

## Modules still missing or mixed

`backend/src/sitewise/modules/` contains exactly one module, and only its domain layer:

```
modules/decision_engine/domain/m2_rules.py
modules/decision_engine/domain/__init__.py
modules/__init__.py
```

No `application/`, `infrastructure/`, or `api/` layer exists for any module. `services/` (53 files) and `repositories/` (19 files) are shared across every feature rather than owned by a module, so the modular boundaries the architecture calls for are **not yet expressed in the tree**.

## Generated evidence vs application code

| Path | Classification |
|---|---|
| `backend/var/` | runtime evidence (excluded from tree) |
| `backend/backups/` | 12 restored files — evidence, not code |
| `backend/ml_reference/` | model reference artifacts — data, not code |
| `backend/tests/**/fixtures/*.sql` | test schema fixtures — not migrations |
| `docs/cp00_integration/snapshots/` | these artifacts |

## Label summary

| Label | Files |
|---|---|
| ADDED | 125 |
| MODIFIED | 51 |
| REMOVED | 1 |
| MOVED | 0 in this checkpoint |
| RETIRED | 0 in this checkpoint (module retired earlier, see D02) |
| UNCHANGED | 1656 |
