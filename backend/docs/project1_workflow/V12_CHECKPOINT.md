# V1.2 checkpoint — 13 November 2026

Implementation authorization comes from the current user request. It does not
adopt missing instruments, scientific contracts, database permissions or fielding
decisions. Full V1.2 completion is held.

Read-only discovery selected Dss through both application and M2 configuration.
The connection is postgres with superuser/bypass-RLS privileges. Nine M2 tables
exist, but no instrument versions are registered. The proposed BCB/CQ/AI stores
are absent from the inspected catalog. All inspected research/provider flags are
false. No existing database was migrated or written.

Existing M2 evaluation runs candidate deterministic rules on explicit submission;
it is not the separately held cloud BDJ orchestration. Do not describe its passing
tests as completion of cloud BDJ, durable asynchronous submission or QJ/QG/CQ
integration. Preserve the existing projection, review, confirmation, BCB and CQ
implementations and their independent authority checks.

This checkpoint changes only the existing shared TokenHarbor adapter and its
offline regression tests. Its monotonic acceptance budget covers preparation,
stream checkpoints and structured validation. HTTP socket timeouts use the
remaining budget. A late result is rejected, including a slow stream or slow
local validation. This is cooperative deadline enforcement: it cannot forcibly
interrupt arbitrary blocking transport or validation code. It is not a durable
task deadline, circuit breaker, latency benchmark or cancellation guarantee.

401/403, 429 and 5xx now have separate safe failure codes. No response body is
logged. No retry, model switching, token-budget change or deterministic substitute
was added. Retry-After does not authorize another POST. Unknown dispatch outcomes
remain unknown; the existing one-reservation ledger is unchanged. Existing ledger
receipts retain their narrower returned/rejected/unknown outcome vocabulary.

Remaining gates: adopted M2 instrument and BDJ output/rules contracts; trusted
tenant/concept/GEO/purpose and confirmed-uncertainty bindings; reviewed restricted
database principal and migration receipts; durable submitted-source/task contract;
approved-bank adapter and assignment receipts; independent scientific/Owner and
fielding/consent authority. No approval is inferred from synthetic fixtures.

Prompt refinement/evaluation promotion and secondary-model qualification have not
been completed. Existing prompt bytes and primary-model configuration are unchanged.
EE-01, Explanation, A10, ReportComposition, ReportAdmission and Saved Reports are
outside this checkpoint and have not been modified or integration-tested here.

Verification: guarded offline workflow suite 57 passed; disposable PostgreSQL
M2/BCB suite 38 passed/4 skipped; disposable PostgreSQL CQ suite 41 passed/1 skipped.
The skipped tests cover Jaspr/browser/device and Flutter widget acceptance. Both
private clusters stopped. These are scoped engineering tests using synthetic
authority, not production or scientific acceptance. Delivery evidence and the
changed-file inventory are in the current chat's outputs folder.
