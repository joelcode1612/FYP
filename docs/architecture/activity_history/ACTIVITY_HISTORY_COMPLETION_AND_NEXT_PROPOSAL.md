# Activity History — Completion and Next Proposal

**Date:** 2026-11-25
**Verdict:** the authorized metadata-history improvements are **implemented and
tested against real PostgreSQL**. One source gap (BCB attempt history) is
reported and proposed, not built. No unauthorized database change was made.

## Final acceptance, item by item

| Requirement | Result | Evidence |
|---|---|---|
| M2 History preserved | **PASS** | `read_activity` untouched (`git diff -U0` hunks at 6, 30–124, 265, 342, 378; `read_activity` is 127–253). 5 of 6 pre-existing projection tests still pass; the sixth fails on an empty table, pre-existing. |
| Verified metadata is accurate | **PASS** | Every projected column exists on the source; two statements that selected non-existent columns were found and fixed before shipping. |
| No duplicate storage | **PASS** | Zero migrations, zero new tables. The projection reads existing rows only. |
| BCB current state vs historical state not conflated | **PASS** | `bcb_statuses` is labelled a snapshot; `CONTEXT_PERSISTED` is the history. `PERSISTED` is never rendered as `COMPLETED`. |
| Missing BCB attempt history explicitly reported | **PASS** | `LATEST_STATE_ONLY` in the matrix; DD-090; `BCB_APPEND_ONLY_ATTEMPT_HISTORY_PROPOSAL.md`; the panel states it in the BCB caveat. |
| Unsupported modules visibly unavailable | **PASS** | `source_states` drives the coverage lines; CQ/EE-01/Reports/Cloud-BDJ report `BLOCKED_AUTHORIZATION` with a reason. |
| Ownership and privacy tests pass | **PASS** | Cross-owner returns zero governance events; no `cq_*` query; no model output; no raw AI payload. |
| No unauthorized DB change | **PASS** | No `GRANT`/`REVOKE`/`CREATE POLICY`/RLS change; no write to `Dss` or `Final_Location_Analysis`. |
| Every claim evidenced | **PASS** | Each assertion maps to a named test, a captured payload, or a catalogue query. |

## What the owner can see now

Restart 8093 was performed, so the running application serves the current code
(verified: the previous process returned 2 events and no `source_states`; the
current one returns 12/37/9 events across three assessments with `source_states`
present).

On the richest assessment (`f063b4c6…`, revision 19) the History page now shows
the objective proposal, the objective admission, five question candidates and
three candidate reviews alongside the M2 and BCB records — each labelled with
what it actually is, and the five newer kinds carrying an explicit
"not an approved questionnaire item" / "only established once an admission is
recorded" note where that distinction matters.

## Honest limitations of this pass

1. **No browser visual acceptance.** The wire contract is validated at HTTP and
   the mapping is unit-tested, but the rendered layout was not inspected.
2. **One pre-existing test still fails** on this target because
   `m2_bdj_evaluations` is empty. Not a regression; cannot pass here.
3. **`backend/tests/` is gitignored**, so the new test file is untracked. It runs
   from disk; it is not committed.
4. **A synthetic fixture stores a non-hash digest.** The reader now survives it,
   but the fixture should be corrected at source (DD-091).
5. **CQ remains entirely unavailable** to this endpoint by policy, not by
   oversight.

## Defects raised

| ID | Status | Summary |
|---|---|---|
| DD-090 | OPEN | BCB build state is latest-state-only; no append-only attempt history. Proposal written; implementation requires Owner approval. |
| DD-091 | OPEN | `m2_confirmation_snapshots.snapshot_digest` holds `synthetic-snapshot-digest-stage5`, which the client's 64-hex check rejects. The projection now degrades safely; the fixture is still wrong. |

## Next separately approvable proposal

Three items are ready to be approved independently. They are listed in the order
I would take them.

### Proposal A — BCB append-only attempt history (largest value, needs a decision)

Build `m2_business_context_build_attempts` exactly as specified in
`BCB_APPEND_ONLY_ATTEMPT_HISTORY_PROPOSAL.md`: one migration, one
`record_attempt()` write path, `SELECT`/`INSERT` to `p1_m2_runtime`, RLS
`owner_scope`, append-only trigger, no backfill.

*Why it matters:* it is the only way to distinguish "the build succeeded on the
first attempt" from "it failed twice and recovered", which is currently
unknowable.
*What I need:* approval of the table, and answers to the three questions in §8
of that document.

### Proposal B — CQ assessment-level campaign metadata (needs a policy decision)

Add a `SELECT` policy on `cq_campaigns`/`cq_manifest_releases` keyed on
`owner_user_id = project1_actor()`, so the entrepreneur's own campaign and
release metadata can appear in their timeline.

*Why it matters:* the entrepreneur currently cannot see that a questionnaire was
published for their own assessment, which is the single most requested fact in
this history.
*Why it is separate:* it is an RLS policy change, which this directive forbids
without separate authorization. It exposes **no** respondent identity and **no**
answer — only campaign/release metadata.
*Alternative if policy change is unwanted:* a read-only view owned by the CQ
module, exposing the same three columns, granted to `p1_m2_runtime`. This is the
narrower option and I would recommend it.

### Proposal C — visual acceptance and the fixture digest (smallest, no approval needed)

Correct the synthetic fixture digest to a real SHA-256 and run a browser
acceptance pass on the History page. This closes DD-091 at source and the one
remaining evidence gap (B). It requires no schema change and no policy change,
so it can proceed on the existing authorization — it is listed here only so the
owner knows it is outstanding.

## Standing position on everything else

* AI Ledger expansion remains **STOPPED**; removal remains **REJECTED**.
* Real customer fielding remains **disabled**.
* `Dss` and `Final_Location_Analysis` were not read or written.
* E4 is **not** claimed. No LIVE provider call was made.
* DD-086 (respondent evidence path has no `INSERT` grant) is **unchanged** and
  still blocks the synthetic respondent lifecycle.
