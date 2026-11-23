# BDJ + QG runtime file surface

## BDJ

- closure size: **108** files (14 pipeline-specific, 94 shared app infrastructure)
- entry points (3):
  - `backend/src/sitewise/api/v1/project1_objective_proposals.py`
  - `backend/src/sitewise/services/bdj_service.py`
  - `backend/src/sitewise/project1/bdj.py`
- pipeline-specific modules (14):
  - `backend/src/sitewise/api/v1/project1_objective_proposals.py`
  - `backend/src/sitewise/api/v1/project1_workflow.py`
  - `backend/src/sitewise/core/cipher.py`
  - `backend/src/sitewise/project1/bdj.py`
  - `backend/src/sitewise/project1/bdj_discovery_candidate.py`
  - `backend/src/sitewise/project1/key_custody.py`
  - `backend/src/sitewise/project1/m2v1_inventory_candidate.py`
  - `backend/src/sitewise/project1/m2v2_projection.py`
  - `backend/src/sitewise/project1/model_assisted.py`
  - `backend/src/sitewise/project1/projection.py`
  - `backend/src/sitewise/project1/result_contracts.py`
  - `backend/src/sitewise/project1/result_store.py`
  - `backend/src/sitewise/project1/synthetic_trial_registry.py`
  - `backend/src/sitewise/services/bdj_synthetic_execution.py`

- runtime assets: `backend/migrations/sql/20261122_0600_measurement_and_qg_candidate.sql`, `backend/var/e2e/app.env`

## QG

- closure size: **98** files (4 pipeline-specific, 94 shared app infrastructure)
- entry points (6):
  - `backend/src/sitewise/api/v1/qg_candidate.py`
  - `backend/src/sitewise/services/qg_candidate_service.py`
  - `backend/src/sitewise/project1/qg_candidate_adapter.py`
  - `backend/src/sitewise/project1/direct_qg_service.py`
  - `backend/src/sitewise/project1/qg_authorization.py`
  - `backend/src/sitewise/project1/qg_fixed_options.py`
- pipeline-specific modules (4):
  - `backend/src/sitewise/api/v1/m2_route.py`
  - `backend/src/sitewise/api/v1/qg_candidate.py`
  - `backend/src/sitewise/project1/qg_authorization.py`
  - `backend/src/sitewise/project1/qg_candidate_adapter.py`

- runtime assets: `backend/migrations/sql/20261122_0600_measurement_and_qg_candidate.sql`, `backend/migrations/sql/20261122_0600_measurement_and_qg_candidate_rollback.sql`, `backend/migrations/project1_ai/20261118_03_qg_retry_slots.sql`, `backend/var/qg_synthetic_authorization.json`, `backend/var/qgb_evidence/bd01_qgb_evidence.json`
