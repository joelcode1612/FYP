# Entrepreneur M2 → persisted BCB

This extension completes the independently testable persistence path around the
existing `BCB-V1-1.0.0-SANDBOX`. It does not adopt that sandbox or authorize any
production instrument/binding. UI and downstream execution are unchanged.

## Runtime and authority

The M2 router remains default-off (`M2_UPSTREAM_ENABLED`). The BCB operations also
require `M2_BCB_PERSISTENCE_ENABLED`, default false. The production binding resolver
deliberately returns `BCB_BINDING_AUTHORITY_UNVERIFIED`: no authoritative tenant,
concept-version, GEO, or purpose registry was found in the inspected Dss schema.
Neither owner UUID nor questionnaire self-reported role is a tenant/access grant.
The current read-only Dss inspection found no registered M2 instrument or items.

The backend-folder `.env` currently selects `Final_Location_Analysis` for the main
application. M2/BCB now use `db/m2_session.py`: an explicit `M2_DATABASE_URL`, or the
existing application URL only when it already matches `M2_EXPECTED_DATABASE`
(default `Dss`) and the existing psycopg2 driver. A mismatch fails before source
access as `M2_DATABASE_TARGET_UNVERIFIED`. No `.env` or main application target was
changed. Disposable runners explicitly set their private target and expected name.
Production also requires a verified UUID relationship between authenticated profiles
and Dss.users; no profile mirror or tenant ID is invented or written here.

`BusinessContextBuilderV1`, its schema identifier and frozen packet contract are
reused unchanged. It requires trusted scope/access decisions before opening the
source content snapshot. No HTTP body can provide owner/role/tenant, grants, GEO,
concept approval or source bindings. The test binding resolver reads explicit
synthetic receipts from a table present only in the disposable test cluster.

## API and application sequence

All paths below are under `/api/v1/m2` and use the existing authenticated active
entrepreneur/owner checks. Administrators still require the existing AAL2 check.

- Existing assessment/instrument/answer/evaluate/review/confirm APIs remain owners
  of those operations. M2 request DTOs now reject extra identity/authority fields
  and non-integer revision values.
- `POST /assessments/{id}/findings/{finding_id}/decisions` exposes the existing
  append-only clarification service, with expected revision, request UUID and
  `KEEP_ORIGINAL`/`REVIEW_LATER`. These never mean a finding is scientifically fixed.
- `GET /assessments/{id}/confirmations/{confirmation_id}?expected_revision=N`
  reuses `M2Service.read_confirmed_source`; the confirmed-review API remains intact.
- `POST /assessments/{id}/business-context` accepts only `confirmation_id` and
  `expected_revision`. First persistence returns 201; an identical packet retry
  returns 200 and the same context ID/creation timestamp.
- `GET /assessments/{id}/business-contexts/{context_id}` reauthorizes and rebuilds
  against current exact source bindings before returning the stored packet. A
  stored hash is not an access token. Stale revisions, expiry or changed source
  packets fail safely.
- `GET /assessments/{id}/confirmations/{confirmation_id}/business-context-status`
  reports durable generation state, attempts, last safe code, latest context ID
  and whether the source revision is still current. Historical status is scoped
  to the current assessment owner; it is not a grant to consume stale content.

API → application services → repository ports → PostgreSQL adapter is preserved.
The dedicated BCB unit of work uses a non-autoflush REPEATABLE READ transaction.
It holds the owner-scoped M2 assessment lock through source capture, the unchanged
builder, context INSERT and status UPDATE. All six builder M2 reads and governed
bindings are captured in that same transaction; the builder sees a detached object
graph after authorization. No evaluator, confirmation writer or provider fills a
missing BCB input. Read operations roll back rather than commit business writes.

## Confirmation provenance

New snapshots use the engineering envelope `m2-confirmation/2`, retaining the prior
source fields and JSON SHA256 algorithm. Additional fields pin actual BDJ version
and evaluation ID, review-event ID, exact finding content hashes and item-definition
hashes. Current-source reads validate those pins. Legacy snapshots are not rewritten;
existing legacy reads retain their prior behavior, but new persistence refuses them
as `M2_CONFIRMATION_PROVENANCE_UNPINNED`. The BCB packet contract is not expanded.

Confirmation also validates persisted answer values/item versions and finding
answer references. Answer edits require a currently authorized instrument.
Uncertainty confirmation is serialized against edits and remains a separate,
explicit entrepreneur declaration, never an interpretation of M2-17.

## Persistence and transactions

The proposed additive migration adds the missing `m2_clarification_events`,
`m2_business_contexts`, and `m2_business_context_builds`. No existing context store
was found, and no duplicate M2/source-authority tables are created.

`m2_business_contexts` is append-only. It stores the exact builder packet as JSONB,
canonical body text, SHA256, deterministic UUID5 identity derived from the complete
packet hash, source/owner/confirmation/revision, schema/builder/purpose/tenant/concept
versions, creation time and `PERSISTED` lifecycle. Database checks compare canonical
text with JSONB, verify SHA256 and source metadata, and require all existing denied
downstream permissions. UUID5 is an identity convention, not an authorization token.

Construction is a **separate idempotent operation after confirmation**. A database
trigger creates `PENDING` status atomically with every confirmation. The migration
also backfills PENDING for historical confirmations without claiming they were built.
Context creation and PERSISTED status commit together. HELD records a missing or
refused binding without inserting a packet. A database failure rolls back packet and
status together; a separate transaction records FAILED where storage is available.
During an outage, the prior durable state remains and HTTP still reports failure.

Identical packet requests converge on one context ID. Changed legitimate source or
access bindings produce a different immutable version. Only PostgreSQL serialization
or deadlock failures are retried, at most three transactions; every retry rechecks
authority/source. No external/provider call is retried or made by this operation.

The migration strengthens composite source/owner foreign keys, freezes in-use item
definitions, preserves approval withdrawal, and prohibits mutation/deletion of
versioned answers, findings, evaluations, reviews, confirmations, uncertainties,
clarifications and contexts. RLS remains default-deny without fabricated production
policies/grants. A restricted production role/policy still needs explicit review;
the inspected live application role was privileged postgres.

## Safe verification

From backend, with the existing virtual environment:

```powershell
.venv\Scripts\python.exe tests\m2_bcb\run_isolated.py --output <new-external-evidence-directory>
```

The runner verifies a free loopback port, initializes a new private PostgreSQL
cluster, restores only the captured Dss users/M2 schema (no data), proves the
migration guard rejects an absent receipt, and applies the proposed migration
only there. It enables only the test process's M2/BCB flags, uses real FastAPI/JWT/
profile checks and PostgreSQL, and disables normal startup lifespan. It always
stops that cluster. Independent connections verify rows, revisions, provenance,
canonical bytes/digests, idempotency, default-deny RLS and rollback. Test bindings
and instrument approvals are explicitly synthetic, not production acceptance.

Do not run the raw SQL on live Dss as part of this task. The migration requires
an exact target and operator receipt, is not automatically discovered by startup,
and has no destructive down migration. For rollback, disable the feature and
restore the reviewed source delta; retain persisted history. Any live schema/data
rollback needs its own backup, review and separate authorization.

## Remaining authority gates

`M2_INSTRUMENT_AUTHORITY_UNVERIFIED`: CAND-02 and later author-review material do
not establish final adoption. Candidate cardinality, primary-selection, Other-text,
privacy and deferred-field choices are not silently implemented as adopted rules.
The current Flutter prototype's item meanings also conflict with the documentary
backend candidate; no UI remapping is attempted in this phase.

Tenant relation, confirmed-concept version/receipt, exact approved GEO binding and
business-understanding purpose authority remain missing/candidate/conflicting.
The frozen builder's EXPLANATION/QJ_CONTEXT/EE01_CONTEXT purpose labels do not
authorize those modules. Production remains held until governing sources, real
adapters, reviewed migration/permissions and deployment verification are approved.
Stop after verified persistence; no QJ, QG, customer fielding, EE-01, Explanation or
reporting implementation is part of this extension.
