# BCB Append-Only Attempt History — Proposal

**Status: PROPOSED. NOT IMPLEMENTED. NO TABLE, MIGRATION OR WRITE PATH EXISTS.**
This document requires an explicit Owner decision before any of it is built.

**Date:** 2026-11-25
**Related:** `ACTIVITY_HISTORY_SOURCE_AVAILABILITY_MATRIX.md` (finding 4), DD-090.

---

## 1. The limitation, stated precisely

`public.m2_business_context_builds` is the only BCB build record.

```
PRIMARY KEY (confirmation_id)
confirmation_id      uuid  NOT NULL
assessment_id        uuid  NOT NULL
owner_user_id        uuid  NOT NULL
assessment_revision  int4  NOT NULL
status               varchar NOT NULL  CHECK IN (PENDING, HELD, PERSISTED, FAILED)
last_code            varchar NULL
context_id           uuid   NULL
attempt_count        int4   NOT NULL  CHECK >= 0
created_at           timestamptz NOT NULL
updated_at           timestamptz NOT NULL
CHECK ((status = 'PERSISTED') = (context_id IS NOT NULL))
```

On this target: **15 rows, 15 distinct confirmations.** One row per
confirmation, mutated in place. Consequences:

* A retry overwrites the previous attempt's `status`, `last_code` and
  `updated_at`. The previous outcome is gone.
* `attempt_count` survives as a **counter**. It proves that N attempts
  happened; it does not say when, what each returned, or whether an attempt
  recovered a previous failure.
* `created_at` is the row's insertion time, not any individual attempt's time.
  `updated_at` is the last write, not the last attempt's start.
* A `FAILED → PENDING → PERSISTED` sequence renders as a single `PERSISTED`
  row. The failure is invisible.

**What the Activity History therefore must not do:** derive attempts from
`attempt_count`, infer a failure from a non-null `last_code`, or present
`PERSISTED` as `COMPLETED`. The current projection reports the build row as
`bcb_statuses` — explicitly labelled a *snapshot* — and the panel states
"a latest-state snapshot, not an attempt history".

## 2. What is proposed

An append-only attempt ledger owned by the BCB module, written in the same
transaction as the build-row update, and read by Activity History as an
additional source. The build row stays exactly as it is; it remains the
current-state record and the FK target that `m2_business_contexts` depends on.

**Source-of-truth ownership stays with BCB.** Activity History gains a read
projection only. It does not own the table, does not write it, and does not
become the authority for BCB state.

## 3. Proposed data model

```sql
CREATE TABLE public.m2_business_context_build_attempts (
    attempt_id            uuid        PRIMARY KEY,
    confirmation_id       uuid        NOT NULL,
    assessment_id         uuid        NOT NULL,
    owner_user_id         uuid        NOT NULL,
    assessment_revision   int4        NOT NULL,
    attempt_no            int4        NOT NULL,   -- 1-based, monotonic per confirmation
    started_at            timestamptz NOT NULL,
    finished_at           timestamptz NULL,       -- NULL while PENDING
    outcome               varchar     NOT NULL
        CHECK (outcome IN ('PENDING','HELD','PERSISTED','FAILED')),
    reason_code           varchar     NULL,       -- a code, never prose
    builder_version       varchar     NULL,
    context_id            uuid        NULL,       -- set only when outcome='PERSISTED'
    supersedes_attempt_id uuid        NULL,       -- recovery linkage
    CHECK ((outcome = 'PERSISTED') = (context_id IS NOT NULL)),
    CHECK ((outcome = 'PENDING')   = (finished_at IS NULL)),
    CHECK (attempt_no >= 1),
    UNIQUE (confirmation_id, attempt_no),
    FOREIGN KEY (confirmation_id, assessment_id, assessment_revision, owner_user_id)
        REFERENCES public.m2_confirmation_snapshots
            (id, assessment_id, assessment_revision, actor_user_id),
    FOREIGN KEY (supersedes_attempt_id)
        REFERENCES public.m2_business_context_build_attempts (attempt_id)
);
```

Design notes:

* `attempt_no` is assigned by the writer under the existing confirmation lock,
  so `UNIQUE (confirmation_id, attempt_no)` makes duplicate numbering
  impossible rather than merely unlikely.
* `supersedes_attempt_id` records recovery without inventing a state machine.
  A retry after failure points at the attempt it replaced.
* `outcome` deliberately reuses the build row's four states so the two records
  cannot disagree about vocabulary. It does **not** add `COMPLETED`:
  `PERSISTED` is the terminal success state and must not be relabelled.
* No prose column. A reason is a code; the human sentence belongs in the UI.

## 4. Security

* `ENABLE ROW LEVEL SECURITY`; one `owner_scope` policy mirroring the existing
  `m2_business_context_builds` policy:
  `owner_user_id = project1_actor()`, plus the assessment-ownership `EXISTS`
  clause used by `m2_bdj_objective_proposals`.
* `p1_m2_runtime` gets `SELECT` and `INSERT`. **No** `UPDATE`, **no** `DELETE` —
  append-only is enforced by privilege, not only by convention.
* A `BEFORE UPDATE OR DELETE` trigger raising `ERRCODE 55000` as a second line
  of defence, matching `cq_immutable_record()`.
* No grant to `p1_ee01_runtime`. The CQ runtime has no BCB business.
* Activity History's projection reads `attempt_id, started_at, finished_at,
  outcome, reason_code, builder_version, attempt_no, supersedes_attempt_id`
  only — never a packet, prompt or payload.

## 5. Transaction and failure recovery

* The attempt row is inserted in the **same transaction** as the build-row
  update. A rollback leaves neither.
* `PENDING` is written on attempt start and updated to its outcome on
  completion, inside one transaction where possible; where the build spans
  transactions, the `PENDING` row is the durable marker and
  `finished_at IS NULL` is the honest "did not complete" signal.
* An abandoned `PENDING` row is **not** rewritten to `FAILED` by a later run.
  It stays as evidence that an attempt never completed. A recovery is a *new*
  row with `supersedes_attempt_id` set.
* Backfill: **not proposed.** Existing build rows have `attempt_count > 1` in
  some cases and no per-attempt data. Fabricating attempts to match the counter
  would invent history. The ledger starts empty and the UI states that history
  before the cut-over is not available.

## 6. Migration and rollback

* Forward: one new migration `backend/migrations/m2/2026____01_bcb_attempt_history.sql`
  — create table, indexes on `(confirmation_id, attempt_no)` and
  `(assessment_id, owner_user_id, started_at DESC)`, enable RLS, create policy,
  create trigger, grant `SELECT, INSERT` to `p1_m2_runtime`.
* Write path: a single `record_attempt()` in the BCB service. No other caller.
* Rollback: `DROP TABLE public.m2_business_context_build_attempts;` — it has no
  inbound foreign keys from any other table, so nothing else is affected. The
  build row is untouched throughout, so the module keeps working with the
  history switched off.
* Feature flag: the projection reads the table inside its own savepoint, so an
  absent table degrades to `BLOCKED_SOURCE` with no code change. Rollout order
  can therefore be migration → write path → projection.

## 7. Test requirements before this can be called implemented

1. Append-only proof: `UPDATE` and `DELETE` as `p1_m2_runtime` are refused
   (expect `42501`), and the trigger refuses them as a superuser (`55000`).
2. Two attempts on one confirmation produce two rows with `attempt_no` 1 and 2.
3. A failed attempt followed by a successful one yields
   `FAILED` (superseded) + `PERSISTED`, and the current build row still shows
   `PERSISTED` — current state and history are not conflated.
4. Cross-owner read returns zero rows under RLS.
5. `attempt_count` on the build row equals the number of attempt rows for that
   confirmation, for every row created after the cut-over.
6. A rolled-back build leaves no attempt row.
7. Activity History projects the attempts newest-first, and a `PENDING` row is
   never rendered as a completion.

## 8. Decision required from the Owner

This proposal is **not authorized** by the Activity History directive, which
explicitly forbids new tables, migrations and write-path changes without
separate approval. Three questions need an answer before any work starts:

1. **Approve, reject, or defer** the append-only ledger?
2. If approved, should the backfill stay empty (proposed) or should the
   `attempt_count` counter be reconciled by some other means?
3. Should `p1_m2_runtime` receive `INSERT` on the new table, or should the BCB
   write run under a narrower principal?

Until those are answered, the honest position in the UI is the one already
shipped: the build row is a latest-state snapshot, and the attempt history is
**not available**.
