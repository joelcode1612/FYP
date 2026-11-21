# CP13 V2 review and technical preparation

No approval is conveyed by these files. The rules and prompt remain proposed,
unregistered and unadopted. See:

- `artifacts/cp13_v2_20261119/CP13_V2_OWNER_DECISION_PACKAGE.md`
- `artifacts/cp13_v2_20261119/decision_manifest.json`
- `artifacts/cp13_v2_20261119/CP13_LIVE_CLOUD_VERIFICATION_REPORT.md`

From the actual FYP root, use the existing Python environment:

```powershell
& .\backend\.venv\Scripts\python.exe -B -m pytest `
  backend/tools/cp13_verification/test_v2_proposal.py `
  backend/tools/cp13_verification/test_v2_observability.py `
  backend/tools/cp13_verification/test_v2_validity_and_handoff.py `
  --confcutdir=backend/tools/cp13_verification -q

# NEW nonhuman source only; actual signed-test HTTP and private PostgreSQL.
# Creates/stops its own private cluster, never writes original Dss.
& .\backend\.venv\Scripts\python.exe -B backend/tests/m2_bcb/run_isolated.py `
  --suite cp13-v2-prep --output artifacts/cp13_v2_reproduction

# Read-only current roles/schema/config/budget; no provider dispatch.
& .\backend\.venv\Scripts\python.exe -B backend/tools/cp13_verification/resolve_blockers.py `
  --output artifacts/cp13_v2_readonly_reproduction
```

Reproduction generates new IDs; inspect and re-pin them explicitly. The final
record set from this execution is retained as a guarded synthetic-only data
snapshot for later approved private replay. Do not restore it into original Dss.
No cloud call is enabled by these commands, and no adoption/operator receipt
is generated. The old QG source authorization is not overwritten.

The package's current live-evidence verifier recognizes `provider_execution`
metadata. This improves future acceptance checks; it does not establish actual
provider identity or persistence without a real authorized call and readback.
