# CP08 business-explanation checkpoint

Read [CHECKPOINT.md](CHECKPOINT.md) for requirements, component reuse, workflow inputs/outputs/exits and acceptance tests. Read [RESULTS.md](RESULTS.md) for what actually ran and what failed.

This is the requested checkpoint plus a runnable, executed qualification tool in the actual backend. It does not install a second production LLM service, replace SHAP explanations, select an unadopted BDJ ruleset, or modify BCB's schema.

From `C:/Users/HP/OneDrive/Desktop/sport-marketplace/FYP/backend`:

```powershell
# Offline guards only; choose a fresh output directory.
.\.venv\Scripts\python.exe tests\cp08\qualification.py --output "$env:TEMP\Project1_CP08_NEW"

# Optional rerun with TOKENHARBOR_API_KEY already set in this process.
# This makes up to SIX real requests; use another fresh output name.
.\.venv\Scripts\python.exe tests\cp08\qualification.py --live --output "$env:TEMP\Project1_CP08_LIVE_NEW"

# Existing database/API regression; creates and stops a private cluster.
.\.venv\Scripts\python.exe tests\cp07\run_isolated.py
```

No key is embedded in code. Use a private local environment/secret mechanism; do not copy the key into these commands, documents or version control. Missing credentials stop live testing. The fixed destination/model and synthetic-only fixture scope are intentional. This tool never changes TokenHarbor account consent or chooses a paid fallback. Its run directory must not already exist; each request is recorded before POST, and auth/rate-limit/timeout/unknown errors stop without blind retries.

All model outputs—including the failed quote—are retained. Raw response, candidate validation, prompt, exact synthetic request, timestamps, hashes, provider model metadata and usage are available in the delivered `live_run_01/` directory. `CHECKPOINT.html` in the deliverable is a saved readable report, not a live dashboard.

Remaining real-integration decisions are the exact BDJ version; reviewed-reference owner/rights/purpose; adopted BCB identity/bindings; shared execution/audit schema and retention. Production semantic acceptance, respondent fielding and report release are separate. No further API key is required for this completed run.

Rollback of this checkpoint is limited to its new `docs/cp08/` and `tests/cp08/qualification.py` files after confirming they remain CP08-owned. Do not remove CP07, UC, dirty source or shared directories. No database rollback/migration is needed; no application route was activated.
