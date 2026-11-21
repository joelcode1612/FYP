# PROJECT1 — Module Dependency Map

**Generated** from static import analysis of every `.py` under `backend/src/sitewise` by `cp03f_structure_snapshot.py`. Edges are real import statements, including multi-line parenthesised `from … import (…)` and string-literal module paths used for dynamic loading.

## Package edges

| Package | Files | Imports (same-repo packages) |
|---|---|---|
| `api` | 35 | `core`, `db`, `dependencies`, `domain`, `ingestion`, `ml`, `modules`, `project1`, `repositories`, `services` |
| `db` | 27 | `core`, `domain` |
| `domain` | 14 | `modules` |
| `ingestion` | 12 | `db` |
| `ml` | 17 | `core`, `db`, `domain`, `services` |
| `project1` | 10 | `core`, `modules` |
| `repositories` | 19 | `core`, `db`, `domain`, `services` |
| `services` | 53 | `core`, `db`, `domain`, `ingestion`, `ml`, `modules`, `project1`, `repositories` |

## Layering assessment

| Rule | Result | Detail |
|---|---|---|
| `domain/` must not import frameworks | PASS | enforced by `test_domain_has_no_framework_dependencies` |
| `modules/*/domain/` must not import outer layers | PASS | enforced by `test_feature_domain_has_no_framework_or_outer_layer_dependencies` |
| `api/` may import anything inward | PASS | 35 files, no reverse edges |
| No package cycles | **FAIL** | `ml` ↔ `repositories` ↔ `services` |
| `domain/` depends only inward | **PARTIAL** | `domain` → `modules` exists solely because of the `m2_rules` compatibility shim |

### Package cycles

| Cycle |
|---|
| `ml`, `repositories`, `services` |

### File-level cycles (the authoritative check)

Package aggregation can report a cycle that no file actually forms, so the file graph is the one that matters:

| Cycle |
|---|
| `sitewise.ml.shap_explainer`, `sitewise.services.explanation_service`, `sitewise.services.explanation_worker`, `sitewise.services.property_insights_service` |
| `sitewise.services.location_analysis_service`, `sitewise.services.property_verification_service` |

**2 file-level cycles, both pre-existing** — they live in the property/explanation features, not in the M2 path this checkpoint touched. Neither was introduced here and neither is fixed here.

## Modules with no inbound reference from application source

25 modules are imported by nothing under `src/sitewise`. That is **not** the same as orphaned: 15 of them are still referenced by scripts or tests, so a src-only scan would have produced a false 'unused' claim. Only `repo referenced = no` is a deletion candidate.

| Module | Referenced elsewhere in repo | Note |
|---|---|---|
| `sitewise.api.v1.customer_candidate` | yes | used by scripts/tests only |
| `sitewise.cq_successor.app` | yes | used by scripts/tests only |
| `sitewise.cq_successor.contracts` | yes | used by scripts/tests only |
| `sitewise.cq_successor.policy` | yes | used by scripts/tests only |
| `sitewise.customer_contracts.reference.a2_router_lib` | **no** | no reference anywhere — verify before acting |
| `sitewise.db.base` | yes | used by scripts/tests only |
| `sitewise.db.bdj_rules` | yes | used by scripts/tests only |
| `sitewise.db.models.address` | **no** | no reference anywhere — verify before acting |
| `sitewise.db.models.user_tokens` | **no** | no reference anywhere — verify before acting |
| `sitewise.domain.bdj_m2v1_candidate_rules` | yes | retired by D02 — retained as evidence |
| `sitewise.domain.entities` | **no** | no reference anywhere — verify before acting |
| `sitewise.domain.m2_rules` | yes | compatibility shim; the only importer is its own contract test |
| `sitewise.ingestion.schema` | yes | used by scripts/tests only |
| `sitewise.ingestion.sources.osm_collector` | **no** | no reference anywhere — verify before acting |
| `sitewise.ingestion.sources.overture_collector` | **no** | no reference anywhere — verify before acting |
| `sitewise.ingestion.synchronizer` | yes | used by scripts/tests only |
| `sitewise.ml.cli` | **no** | no reference anywhere — verify before acting |
| `sitewise.ml.selected_pu_cli` | **no** | no reference anywhere — verify before acting |
| `sitewise.ml.shap_cli` | **no** | no reference anywhere — verify before acting |
| `sitewise.project1.disclosure` | yes | used by scripts/tests only |
| `sitewise.project1.ledger` | yes | used by scripts/tests only |
| `sitewise.project1.prompts` | yes | used by scripts/tests only |
| `sitewise.project1.research` | yes | used by scripts/tests only |
| `sitewise.services.geospatial_service` | **no** | no reference anywhere — verify before acting |
| `sitewise.services.synthetic_case_setup` | yes | used by scripts/tests only |

## Isolated packages

| Package |
|---|
| `cq_successor` |
| `customer_contracts` |

## Imports that prevent the planned structure

| Blocker | Why it blocks modularisation |
|---|---|
| `services/` is one 53-file package | feature behaviour lives in a shared package, so no module owns its application layer |
| `repositories/` ↔ `services/` cycle | a module cannot be extracted while its repository imports a service and that service imports the repository |
| `ml/` ↔ `services/` cycle | same problem for any inference-facing module |
| `domain/` → `modules/` (shim) | the legacy path depends on the new one, so deleting the shim is safe but the direction must not be reversed |
| `api/` imports 10 packages directly | routers reach past an application boundary, so a module cannot be moved without editing every router |
