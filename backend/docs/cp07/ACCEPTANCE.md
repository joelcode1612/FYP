# CP07 integration acceptance — PARTIAL / FULL WORKFLOW NOT ACCEPTED

Executed 11 November 2026 in the actual FYP backend. Final isolated run: **14 tests passed in 5.34 seconds**, PostgreSQL **18.6**, fresh private cluster, loopback **55437**, database **project1_cp07_tests**. Actual loopback Uvicorn HTTP server, existing JWT verifier using local test JWKS, actual PostgreSQL reads/writes; no authentication/DB dependency overrides. The cluster was stopped after the run.

## Verified scope

- Existing M2Service extended with persisted confirmed-source retrieval, owner/currentness/instrument/digest/answer-projection checks and transaction release. No duplicate M2 service or tables.
- 200 source response; exact Unicode/M2-04 preservation despite injection-like authored text; downstream authority remains false.
- 401 absent/expired/forged JWT; 403 wrong role/suspended profile; 404 cross-owner/unknown confirmation; 409 stale revision, tampered digest/answer fact and unauthorized instrument.
- Existing UC history query and HTTP bridge: persisted exact uncertainty and decision history, cross-owner denial, withdrawal history, cursor behavior, no QJ authority.
- Existing UC SQL V2 function through a real `p1uc_stage_human` non-superuser login: cross-owner SQLSTATE42501 denial; atomic confirmation creates one canonical uncertainty plus one event; exact replay on a fresh connection creates no duplicate; changed payload and stale source fail with P0001; failed requests leave neither partial event nor canonical uncertainty. Later withdrawal adds history without deleting canonical history.
- Restricted role denied direct table INSERT, cannot be superuser/BYPASSRLS/CREATEROLE. Existing gateway untouched.
- CP07 configuration guard precedes authentication and rejects Dss; missing restricted UC configuration fails closed; extra actor/approval fields rejected with 422. Unapproved high-port UC HTTP writes return 503.

Final persisted counts: **1 M2 confirmation fixture, 1 canonical uncertainty, 2 UC events (confirmation + withdrawal), 1 candidate version**. All are synthetic controlled test records in the private cluster. Six direct SQL attempts are separately labeled in `sql_function_traces.json`; HTTP evidence does not present them as successful HTTP writes.

## Ten required demonstrations

| Directive demo | Outcome |
|---|---|
| 1 Authenticated M2 retrieval and confirmation | PARTIAL: retrieval verified; confirmation fixture seeded; real BDJ/review/confirmation path blocked by conflicting rules and integration/schema prerequisites |
| 2 UC uncertainty retrieval and decision history | VERIFIED within private-clone/admin-read/test-JWT scope; production read grants and real Supabase credentials NOT_TESTED |
| 3 Existing BDJ source-linked review | BLOCKED_AUTHORITY / broken imports; both files preserved |
| 4 Canonical BCB from versioned records | BLOCKED_ADOPTION / missing owning bindings and target adapters; candidate builder located |
| 5 Survey QJ routing | DOCUMENTED_NOT_IMPLEMENTED; no substitute activated |
| 6 Financial/non-survey QJ routing | DOCUMENTED_NOT_IMPLEMENTED; no profit-survey substitution |
| 7 Bank-unverified withholding | Bank authority absent; no bank/QG/fielding call made, but executable bank gate itself not implemented |
| 8 Permitted candidate-only QG | DOCUMENTED_NOT_IMPLEMENTED; no drafting grant |
| 9 Invalid/stale source with zero provider calls | VERIFIED at source bridge; structurally no provider adapter is invoked; not a live-model test |
| 10 Cross-owner, rollback, idempotency, revision invalidation | VERIFIED source HTTP and UC SQL scopes above; successful UC HTTP persistence and full workflow attempt ledger NOT_TESTED |

## Security findings and limits

1. BDJService imports three nonexistent symbols from the narrow domain file. Selecting the broader file would change rule behavior and lineage; not repaired without adoption.
2. Narrow BDJ ID has 33 characters against VARCHAR32; recorded stage schema lacks the source's clarification table. No shortening or migration executed.
3. Canonical BCB adapter, approved bank, QJ/QG, live LLM adapter/ledger and shared durable audit are absent in the target. Source/history APIs cannot bypass them.
4. Positive source/history reads used the private-cluster administrator. This proves query/HTTP behavior, not production least privilege or approved UC read grants. New code grants no database permission.
5. Existing UC gateway permits only exact B4 stage tuples. Both approved ports were occupied; no process was stopped or existing stage changed. The private high port is deliberately refused. To verify successful HTTP decisions, supply an approved isolated B4 target with restricted credentials and controlled real-JWT fixtures, or separately approve a successor target policy; do not monkeypatch the gateway.
6. Real Supabase account credentials and live TokenHarbor are **NOT_TESTED**. **0 provider calls**. No provider consent/disclosure or schema/production approval inferred.
7. History is an audit read, not the authoritative current `read_qj_input` gate. Do not use a historical CONFIRMED action as admission; withdrawal/supersession/source integrity must be checked by the owning function when QJ is implemented.
8. Model-attempt accounting, independent state persistence, canonical audit logs and complete R01–R10 execution are not implemented. Test JSON files do not satisfy those requirements. No raw application source logging was added.

## Failure and revision lineage

The first setup run found both approved low ports unavailable; no existing server was changed. First high-port setup found the schema dump already contained `users`; duplicate test setup was removed. Two harness runs initially used the parent fake-JWKS fixture / incorrect issuer configuration; the runner now isolates conftest scope and uses the existing derived issuer contract. A later UC fixture failed source hashing because PostgreSQL row JSON was created outside UTC; seeding now matches the existing UTC contract. Failed run evidence is retained separately, not relabeled as passing. No production verifier, UC hash rule or database function was changed to accommodate tests.

Ruff was unavailable in the backend environment; no lint result is claimed. Python execution/pytest, syntax parsing of seven changed/new Python files and `git diff --check` completed for the changed scope. A separate application import/OpenAPI check verified the new endpoints are absent with the flag off, without DB access or lifespan. No broad existing suite was run because its root fixtures target a different database. No automatic commit, existing dirty-file reset, production migration or fielding occurred.

## Decision queue

See RECONCILIATION.md: exact BDJ adoption; BCB adoption plus binding owners; governing QJ/QG and bank authority; approved shared durable storage/privacy contracts; production UC reads and an approved target for HTTP write verification. Missing implementation should be built within this architecture once those established behaviors/authorities are pinned; it does not require redesigning the workflow.
