# Source-only Q01–Q13 storage in Dss

The user separately authorized saving the existing 13-question source in live
Dss on 14 November 2026. This authorization covers the source bank only. It
does not adopt a questionnaire, approve fielding, create a release/campaign,
register M2, or authorize downstream research/reporting.

The operator reuses the existing `cq_bank_versions` entity. It stores one
immutable versioned row containing all 13 original source records in
`questions_json`, plus the existing canonical CQ content hash. The source
records, wording, codes, dispositions and unresolved placeholders are preserved.
No translation candidate, fictional stimulus, respondent answer or approval is
inserted. The version begins `SOURCE_ONLY:` to distinguish it from a runtime
release bank. These raw source records are not a `cq-manifest/1` release DTO.

Source SHA-256:
`ec2b5494ecf82447076e0d7a2bfb57599a24f049bbcc925a9ecbea6e833bce59`.

## Operator

`scripts/register_cq_source_bank.py` defaults to read-only planning/verification.
It resolves the existing dedicated M2/CQ URL, requires PostgreSQL+psycopg2 and
the exact Dss target, verifies the frozen source and all Q01–Q13 IDs, and refuses
an immutable-version collision. `--apply` additionally requires a storage-scope
receipt referring to the user's actual instruction. This operator receipt is
not a scientific/fielding authorization adapter.

If the bank table is absent, the narrow
`migrations/cq/20261114_01_source_bank_only.sql` creates only that existing-model
table and its append-only/RLS protection. No other CQ table, role, grant,
policy, release, campaign, session or feature flag is provisioned. Table/row
creation is atomic. Repeating the same registration is idempotent.

The table has default-deny RLS and no PUBLIC privileges. A privileged database
owner may bypass RLS; this operation does not establish least-privilege runtime
identity. No startup seed or application endpoint invokes this operator.

Read-only verification from the FYP root:

```powershell
& .\backend\.venv\Scripts\python.exe backend/scripts/register_cq_source_bank.py --expected-database Dss --output C:\path\outside-backend\bank-readback.json
```

The explicit `--apply --authorization-record <receipt.json>` operation is for
authorized operators only. Its receipt must specify target Dss, scope
`Q01_Q13_SOURCE_BANK_STORAGE_ONLY`, the exact source SHA, and
`fielding_authorized: false`.

Matching-version disposable PostgreSQL 16 verification:

```powershell
& .\backend\.venv\Scripts\python.exe backend/tests/cq_runtime/run_source_bank_isolated.py --output C:\path\outside-backend\bank-tests
```

This verifies atomic rollback, exact JSON persistence, repeat registration,
conflict refusal, immutable UPDATE/DELETE denial, default-deny RLS and the
absence of release/campaign/response tables.

## M2-dependent blanks

The global source bank must remain immutable when an entrepreneur completes
M2. Exact approved values belong to the existing version-bound assessment
context/manifest/stimulus relationships, not an UPDATE of shared templates.

The existing sequence is saved M2 revision → BDJ review → entrepreneur
confirmation → confirmed BCB/context → CQ bindings. A setting category is not a
named GEO area; a price band is not an exact offer price; an unconfirmed
description is not an approved concept-card version. The current
entrepreneur-specific CQ adapter remains held until those bindings exist.
No placeholder fallback or Business Context Builder is introduced here.

## Future migration and rollback boundary

After source-only registration, the older all-at-once
`20261113_01_cq_runtime.sql` cannot be applied unchanged because
`cq_bank_versions` now exists. A separately reviewed rollout must reconcile and
reuse the existing bank and protections while adding only the genuinely missing
runtime entities. Do not drop the source bank or overwrite it to rerun the old
migration. Runtime grants and production authority remain separate gates.

The execution evidence contains a REVIEW_ONLY rollback script that refuses if
the sole bank row/version/hash changes and uses no CASCADE. It was not executed.
Any later dependency or additional version requires a new rollback review.
