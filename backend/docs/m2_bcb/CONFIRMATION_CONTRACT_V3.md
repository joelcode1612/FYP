# M2 declaration confirmation — version 3

The existing review and confirmation endpoints confirm saved entrepreneur declarations before BDJ. They grant no scientific, cloud-execution, uncertainty-review, fielding or report-release authority. QJ is retired.

## Existing HTTP contracts

`POST /api/v1/m2/assessments/{id}/review` takes `expected_revision`. It checks authenticated ownership, authorized instrument, item/answer membership, current revision, applicable input validity and required-answer completion, then returns the real persisted review event. No evaluation is executed or required.

`POST /api/v1/m2/assessments/{id}/confirm` takes the same revision. `acknowledged_issue_ids` remains accepted as an optional empty list for wire compatibility; a nonempty list is refused. BDJ finding review is a later, independently governed action. The current revision must have a real owner-bound declaration review. Row locking and the existing compare-and-set prevent duplicate or stale confirmations.

The response retains the existing confirmation UUID, assessment/revision, `snapshot_json`, and canonical SHA-256 `snapshot_digest` envelope. The new snapshot has:

- `snapshot_contract_version: m2-confirmation/3`
- `confirmation_scope: M2_DECLARATIONS_ONLY`
- Persisted `review_event_id` and hash of its identity, assessment, revision and actor.
- Exact instrument identity/version/digest, saved answer revision IDs and values, item-definition hashes, derived selections and inactive-answer keys.
- Empty `unresolved_candidate_findings` and `finding_decision_event_refs`; these assert no BDJ-review authority.
- No BDJ evaluation ID, rules version or finding hashes.
- Existing false uncertainty/QJ-authority flags preserved for compatibility; they do not execute QJ.

Errors include named `M2_REVISION_STALE`, `M2_REQUIRED_DECLARATIONS_MISSING`, `M2_DECLARATION_INVALID`, `M2_DECLARATION_REVIEW_REQUIRED`, `M2_DECLARATION_REVIEW_BINDING_INVALID`, `M2_DECLARATION_FINDING_ACK_NOT_ALLOWED` and `M2_ALREADY_CONFIRMED_OR_CHANGED`. The UI uses typed HTTP failures and safe codes; raw server/provider exceptions are not shown.

## Read compatibility and invalidation

The existing `m2-confirmation/2` format keeps its evaluation/review/ruleset/finding pins and its original validation. Its JSON, digests and historical rows are never rewritten. Unknown versioned formats fail closed. The existing unversioned compatibility branch remains constrained by its original source-integrity rules; persisted BCB still requires pinned provenance.

`M2Service.locked_confirmed_source`, the confirmed-review reader and persisted BCB's frozen-source adapter use the version-aware pin validator. Version 3's declaration projection reports `NOT_EVALUATED`, with no BDJ findings. Later model findings cannot retroactively become part of a declaration snapshot.

An answer edit preserves the old immutable snapshot, but the old revision cannot be retrieved as the current confirmed source or used for current BCB/BDJ/QG processing. Current-confirmation lookup checks both assessment and confirmed revisions, then validates the source.

## Downstream boundaries

The legacy deterministic `/bdj/evaluate` route remains registered for compatibility, but does not execute retired rules. It refuses an unconfirmed source and holds a confirmed source pending the separately authorized cloud path. The cloud BDJ source adapter now validates and fingerprints the current confirmation before provider composition; this does not enable the route or change provider/adoption/budget gates.

A declaration-only snapshot is not a reviewed uncertainty. New objectives remain held until a compatible source-bound post-confirmation uncertainty/objective review adapter exists. Existing historical objectives keep their old provenance. The current strict BDJ model contract emits findings and an overall note; model-proposed research objectives and entrepreneur approve/reject decisions are an identified integration gap, not a fabricated working path.

## PostgreSQL compatibility

No migration is required by this change. The existing snapshot JSON and acknowledgement JSON columns store the new format; current relational constraints bind assessment/actor/revision and contain no mandatory BDJ evaluation-ID column. Disposable PostgreSQL tests verify real write/readback, frozen BCB consumption, revision invalidation, ownership, concurrency and rollback. No live schema change is authorized or applied.
