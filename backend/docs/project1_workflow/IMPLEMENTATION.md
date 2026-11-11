# PROJECT1 candidate implementation — 2026-11-11

Local branch `merge_main_jed`, baseline HEAD `5cf1db7`. This implementation is
default-off and has not been deployed. No existing database was modified.
The user selected **Dss**, alongside M2, as the workflow migration proposal target.

## What executes

- `project1/projection.py`: owner-scoped, locked draft-M2 source read, exact item
  and answer versions, detached values and SHA-256 membership fingerprint. It
  runs before confirmation; it does not invent a confirmed source.
- `project1/bdj.py`: five checkpoints: source integrity, independent consistency
  rules, optional model interpretation, independent candidate validation, then
  version recheck and source-linked explanation. Rule module version, exact file
  hash and an actual adoption receipt must be configured; neither conflicting
  candidate ruleset is selected by default. Model proposals cannot suppress
  reproducible rules or introduce unsupported rule findings. No M2 writes.
- `services/business_context_v1.py` and its port: the existing deterministic
  `BCB-V1-1.0.0-SANDBOX` is reused byte-for-byte. It is distinct from QJ. Its
  trusted tenant/concept/GEO/purpose/source adapters are still required.
- `project1/research.py`: separate confirmed uncertainty, independent authority
  and currentness checks, strict four-route QJ output, complete measurement
  metadata, approved-bank-first lookup, explicit drafting permission, and
  protected QG metadata/wording validation. All outputs remain candidates.
- `project1/prompts.py`: versioned role, few-shot, grounded-source and concise
  structured-justification prompts. Configure trusted `Prompt` objects in the
  server composition; hashes cover the actual role/instructions/examples.
- `project1/provider.py`: pinned TokenHarbor endpoint/model, server-only secret,
  bounded streaming response read, strict JSON/schema/envelope validation,
  no redirect, no automatic POST retry or silent structured-mode downgrade.
- `project1/ledger.py`: restricted PostgreSQL connection, serialized reservation
  committed before dispatch, append-only result receipts, restart duplicate
  prevention and metadata-only audit. One dispatch per stage is deliberately
  stricter than the proposed six-call ceiling; automatic repair/retry is absent.
- `api/v1/project1_workflow.py`: separate gated source/review API reusing existing
  JWT, active-account and role dependencies, explicit assessment ownership and
  admin AAL2 for technical audit. Extra caller approval fields are forbidden.
  Production model/research orchestration is not exposed through HTTP.
- Jaspr review panel is inserted in the existing M2-20 review summary. It checks
  server setup availability and separates friendly status from staff audit.

## Observed database authority

Read-only catalog checks on PostgreSQL 16.14 found:

| Target | Observation |
|---|---|
| Current application connection | `Final_Location_Analysis`, `postgres` superuser with RLS bypass |
| Current analytics connection | Same database and privileged login |
| `Final_Location_Analysis` | No `m2_*`, `project1_uc` or `project1_ai` tables found |
| `Dss` | Nine existing M2 tables, all RLS-enabled; no UC/AI schema found |

The environment overrides the repository's default application URL. It was not
edited. Pointing a flag at the current environment would not integrate M2.
New review configuration rejects the analytics database and elevated principals
before authentication can provision a profile. Existing RLS enforcement is not
claimed for a connection using `postgres`.

## Contract reconciliation and activation holds

Existing M2 states and UC boundaries are unchanged. The proposed shared taxonomy
is not an adopted deployed contract. No `WF_*`, `ST_*`, `FD_*`, `SCI_*`, `OWN_*`
or `FIELD_*` proposal was silently persisted as a new database enum. Existing
reason codes retain their scope; local technical outcomes are explicitly marked
as an unreconciled candidate proposal. Exact adopted WF/E registries were not
found in the inspected current sources/database. Do not invent mappings.

Two BDJ candidate modules conflict: narrow `BDJ-EXPLICIT-FORMAT-0.1-CANDIDATE`
and broader `BDJ-RULESET-0.2-CAND`. Existing legacy BDJ imports/dependency wiring
are unresolved. This candidate surface does not activate the legacy M2 write
router or select an unadopted rule version. The narrow identifier is also longer
than the existing 32-character finding column; it is not written/truncated here.

The HTTP review deliberately has no cloud runner until adopted durable work
identity/storage, disclosure and source contracts exist. `configured_runner`
provides server composition, not activation. Research authority, bank receipts,
current UC admission and BCB binding ports have **no fabricated production
adapter**. Controlled test doubles do not supply production authorization.

The Jaspr M2 form is already an unsaved browser preview. Its web assessment ID
is not an M2 assessment ID; no authoritative mapping was found. The new panel
reports this hold. It does not upload browser answers or claim Stage 2 completion.
M2-20/21 remain governance events; M2-11 deferred and M2-15 privacy-pending are
excluded from analysis. The three-section Business Description and P1–P7 freeze
are preserved. No question bank is seeded, published or fielded.

## Provider and private key

Official sources checked on 2026-11-11:

- https://tokenharbor.ai/privacy (updated 2026-11-10)
- https://tokenharbor.ai/docs/api/curl
- https://tokenharbor.ai/docs/api/models

The free route may retain/analyse content, staff may read it, upstream providers
may train on it, and shared free-route archives may last up to 24 months. This is
not a zero-retention route. Public docs did not establish schema support for the
exact model. An unauthenticated `/v1/models` read returned 401, so catalog support
and real structured response compliance remain **NOT_VERIFIED**.

No live model call was made. The key was absent in this Work process. The user
will configure it locally; this session provides no native secure-secret tool.
In a private PowerShell terminal, from `backend`, run:

```powershell
. ./scripts/project1_tokenharbor_setup.ps1
.venv/Scripts/python.exe scripts/project1_probe_tokenharbor.py --synthetic-only
```

The masked setup keeps the secret only in that terminal and its child processes;
it does not persist a key, modify `.env`, enable flags or send a key to chat.
Restart the backend from that same private environment when authorized. Clear
the variable or close the terminal when finished. Do not put it in a command,
source, browser build flag, Jaspr or logs. A running Work process cannot inherit
environment changes made later in another terminal.

The probe uses a hardcoded empty synthetic declaration packet only. Its default
`json_schema` mode must succeed; it does not automatically downgrade. Explicit
`--mode json_object` is a separate capability experiment and is not proof of
schema-constrained generation. Local validators remain necessary in both modes.

## Versioned migration and rollback

`migrations/project1_ai/20261111_01_candidate_ledger.sql` is an explicit operator
proposal. It requires exact database identity and a reviewed change receipt;
refuses preexisting schema/role collisions; has transaction/lock timeouts; creates
separate no-login owner/runtime/audit roles; forces RLS; grants limited metadata
rights; enforces immutable history and attempt constraints. It does not alter
M2, UC/security-definer functions, existing grants or analytics. It neither
provisions runtime passwords nor seeds scientific/Owner decisions.

It is **not yet a complete adopted workflow persistence schema**: run creation,
source/currentness admission, candidate-event storage, prompt archival, production
retention and canonical review decisions need integration with their owners.
Runtime run insertion is a trusted-server capability and is not an approval.
No model credential or client can access that capability. Restricted source
grants and authoritative work creation must be reviewed before any live use.

Do not execute it against Dss yet. Obtain the database/schema/role review and
verified backup first. No automatic startup migration or down migration exists.
Safe operational rollback: disable `PROJECT1_WORKFLOW_ENABLED` and
`TOKENHARBOR_ENABLED`, restart the backend, revoke new runtime/audit access under
DBA control, preserve all append-only records. Do not drop production history.
Code rollback should reverse only this task's patch, preserving prior user edits.

## Validation

From `backend`:

```powershell
.venv/Scripts/python.exe -m pytest tests/project1 --confcutdir=tests/project1 -q
.venv/Scripts/python.exe tests/project1/run_isolated.py
.venv/Scripts/python.exe tests/cp07/run_isolated.py
.venv/Scripts/python.exe -m pytest tests/test_security.py tests/test_rbac_domain.py tests/test_metadata_startup.py -q
```

The two isolated runners create new private PostgreSQL 18 clusters at free
loopback ports (55439 / 55437), restore recorded schema-only synthetic fixtures,
run tests and stop the clusters in `finally`. They do not migrate existing
databases. Temp evidence is retained; no recursive deletion is performed.

Actual results are recorded in the delivery report. Test JWTs/doubles and private
database roles establish scoped engineering checks, not real Supabase acceptance,
scientific validity, provider privacy approval or release authority.
