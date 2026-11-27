# CP-04A A2 — Isolated Clone Verification Report

**Status:** schema-level verification complete on the isolated clone. Service path NOT verified.
**Author:** a1-builder, 2026-11-17
**Scope:** `project1_ai` migrations `20261117_02` and `20261117_03`, applied only to
`project1_workflow_tests`. Nothing was applied to `Dss`.

> **Verdict, stated precisely.** The 36/36 matrix is a **schema-level** result: it proves the
> constraints refuse bad states written by direct SQL. It does **not** prove the service path
> produces valid rows — that requires the persistence writer and the route, which did not exist
> when this ran. Nothing in `src/` writes `bdj_results`, `bdj_result_findings`,
> `bdj_result_sources`, `bdj_result_validations` or `finding_provenance`, and
> `result_contracts.classify()` has no production caller.

---

## 1. Files applied

| file | pre-ruling draft (WITHDRAWN) | applied |
|---|---|---|
| `20261117_02_finding_provenance.sql` | `50e23a8560cbe2f3eb26272c70311d500eefbc51381f871fed42b3e8762ef974` | `fb71d0b416633c3b3d3384ee2f4b2c92a781575e91c83859553acfad19b4b185` |
| `20261117_03_bdj_result_persistence.sql` | `4d0f902c52b2a0a8be0c33afe0662ab39612953b01229b6a9294aa6ab22326e0` | `e099f133cc4b1f4179c61448ddae3928c8bc28031263b0e53d65ed082cb8d955` |

`_03` passed through several superseded states, and **this list is not exhaustive**. Known ones,
all withdrawn: `a54aa52b…` (after the `authority` rename and C8, before `reason` was dropped),
`048f38bb…` (before the `locator` CHECK and the `detail` comment), `83ca1936…` (a transient
on-disk state between those two edits — locator CHECK present, `detail` comment not yet — never
applied to any database), and `17367dfe…` (before C9). Only the hash in the right-hand column is
claimed as the applied, verified state; the clone was dropped and recreated from
`TEMPLATE "Dss"` after each change, so hash and clone state stay in correspondence. Intermediate
and transient states are not enumerated beyond these, because a hash of a file mid-edit describes
nothing anyone ran.

## 2. Clone pre/post inventory

| | `project1_ai` tables | receipts | `bdj_*` rows |
|---|---|---|---|
| before any work (withdrawn draft applied) | 10 | 3 | 1 |
| baseline, recreated from `TEMPLATE "Dss"` | 4 (`runs`, `attempts`, `attempt_receipts`, `schema_versions`) | 1 | 0 |
| after `_02` + `_03` + reconciliation | 10 | 5 | 0 |

`Dss` re-checked after all work: 4 `project1_ai` tables, 1 receipt (`20261111_01`), 9 attempts —
unchanged. No role was created in `Dss`; `attempts`, `attempt_receipts` and every historical
`outcome` value were left alone.

Recreating the clone is the restorable baseline: `Dss` is authoritative and the clone is
derived. The withdrawn pre-change schema is preserved for evidence at
`backend/backups/cp04a/clone_pre_cp04a_project1_ai_schema.sql`. Recreate cost: 15 MB, ~2 s.

## 3. Dependency order

`_02` → `_03`. They do not conflict: disjoint objects, and each requires only `_01` (ledger,
`deny_mutation()`). `_03` additionally requires `public.m2_assessments` and
`public.m2_bdj_findings`. Re-running `_03` is refused:
`bdj result tables already exist: reconcile version before migrating`.

**Purely additive is true of `_02` and `_03` only** — `DROP`/`TRUNCATE`/`DELETE FROM`/`ALTER …
DROP` grep returns 0 matches across both. It does not generalise to the migration set: `_01`
creates cluster-level roles, which are a different kind of change and do not roll back with the
clone.

## 4. Resulting schema (the parts the contract governs)

`project1_ai.bdj_results` — `execution_outcome` text NOT NULL in
(`returned`,`rejected`,`unknown_outcome`); `review_outcome` text NULL in
(`reviewed`,`rejected`,`stale`); `validation_status` GENERATED ALWAYS … STORED from
`review_outcome` (`not_validated` / `invalid` / `valid`); `finding_authority` text NOT NULL
`= 'candidate_only'`; `finding_count` integer NOT NULL `>= 0`; `review_reason` text NULL.

Constraints: C1 `digest_matches_outcome`, C2 `payload_requires_valid`, C3
`review_requires_validation`, C4 `one_per_attempt`, C6 `finding_authority_check`, C7
`unreviewed_has_no_payload`, C8 `returned_requires_review`, C9
`findings_require_review_check`, plus `finding_count >= 0`, `execution_outcome_check`,
`review_outcome_check`, `review_reason_check`, the composite `attempt_fk` and
`assessment_id_fkey`. C5 is service-level by design: the row's `execution_outcome` is copied
from the ledger, never derived from the review.

C9 is `CHECK (finding_count = 0 OR review_outcome IN ('reviewed','stale'))`. It closes the one
state `classify()` refused but the schema used to allow — a rejected attempt carrying
candidate-authority findings, which is the state the directive forbids. `NULL` and `'rejected'`
are absent from the list on purpose; `'stale'` is present because the engine stores the findings
it had already validated.

`project1_ai.bdj_result_findings` — four columns: `result_id`, `finding_id`, `owner_user_id`,
`authority text NOT NULL CHECK (authority = 'candidate')`; PK `(result_id, finding_id)`. No
free-text column.

`project1_ai.bdj_result_sources` — `locator` is constrained by
`bdj_result_sources_locator_pointer_check` to an `item_key` (`@version` optional, no whitespace),
so a verbatim answer quote cannot be stored there by accident.

`project1_ai.finding_provenance` — `authority text NOT NULL CHECK (authority = 'candidate')`.

`project1_ai.bdj_result_validations.detail` — legitimately prose (`check_code` is the code), so
constrained by comment and by a writer-side catalogue, not by a pattern.

## 5. Check matrix — 36 checks, `VERDICT=PASS`, 0 failed

Covers: runtime write/read scoping and cross-actor invisibility; RLS WITH CHECK; append-only
trigger for UPDATE and DELETE; raw response write-only for runtime and readable only by audit;
audit role read-only; unbound actor sees nothing; C1, C2/C3, C4, C6, C8 and C9 refusals
**asserted by constraint name** so they cannot pass for an unrelated reason; the generated
`validation_status` for each review outcome; `authority='ADMITTED'` refused and `'candidate'`
accepted on both authority tables; `locator` accepting a real pointer and refusing a verbatim
quote; the migration receipt present.

The last check is a **parity test**, and it exists because the item_key pattern was hand-retyped
three times in one afternoon with two wrong copies. It extracts the pattern from the *installed*
constraint (`pg_get_constraintdef`), evaluates one corpus against it and against
`SourceRef.item_key` (contracts.py:29), and requires the two acceptance sets to be equal **and**
equal to a hard-coded expected set — equality alone would pass if both copies were wrong the same
way. Corpus, both directions:

- accept: `M2-04`, `M2-12`, `M2-O-01`, `M2-O-02`, `M2V1-01`, `M2V1-02`, `M2V1-09`, `M2V1-10`, `M2V1-11`
- reject: `M2V1-00`, `M2V1-12`, `M2-4`, `M2-O-3`, `m2-04`, `"M2-04 "`, `" M2-04"`, `M2-04@x`

The check is sensitive to the actual historical defect: replayed read-only against the two
withdrawn variants it reports `M2V1-00`, `M2V1-02`, `M2V1-09` for `0[01]|1[01]`, and those plus
`M2V1-10` for `0[01]|1[11]` — so the two variants fail differently, which is why both ends and
the middle of the range are in the corpus.

`backend/tests/project1` — 200 passed, 1 skipped, 7 subtests (includes the 36 Python contract
tests over the D1 × D3 product).

## 6. Meta-check: is the matrix load-bearing?

- `bdj_results_finding_authority_check` — **VERIFIED** by drop-and-observe: constraint dropped
  inside a savepoint, the insert it should refuse was accepted, savepoint rolled back, the same
  insert was then refused.
- `bdj_result_findings_authority_check`, `finding_provenance_authority_check`,
  `bdj_results_returned_requires_review`, `bdj_result_sources_locator_pointer_check`,
  `bdj_results_findings_require_review_check` — **NOT_RUN**, blocked by a sandbox security
  policy, not by a failure. Not retried and no equivalent route attempted.
- **Substitute evidence only** for those five: refusals reported by exact constraint name;
  `pg_get_constraintdef` showing the installed expressions verbatim; C8 evaluated over the four
  `(execution_outcome, review_outcome)` shapes with `returned` + NULL the only rejection; the
  authority predicate accepting `'candidate'` and rejecting `'ADMITTED'`, `'VERIFIED'`,
  `'candidate_only'`; the locator pattern accepting `M2-04`, `M2-04@iv-0001`, `M2-O-01@x`,
  `M2V1-02@x`, `M2V1-09@x`, `M2V1-11@x` and rejecting `M2V1-12@x`, `M2-4`, `"We are
  takeaway-only."`, `"M2-04@two words"`, `" M2-04"`; C9 refusing `('rejected', finding_count=5)`
  while C1, C2, C3, C7 and C8 all pass on that same row, so only C9 can be the refuser.
- What the substitute evidence does **not** establish: that those five constraints are
  load-bearing rather than incidentally satisfied. This report must not be summarised as "all
  constraints meta-verified".

## 7. Receipt reconciliation

`project1_ai.schema_versions` is `(version text PRIMARY KEY, receipt text NOT NULL, applied_at
timestamptz DEFAULT now())`. `20261116_02_m2_runtime_role` and `20261117_01_execution_principal`
were applied without writing a receipt.

`backend/scripts/cp04a_receipt_reconcile.py` verifies the objects each migration creates (role
attributes, `MEMBER`-but-not-`USAGE` membership, schema/table grants, absence of direct grants,
12 RLS policies — 7 checks each) and only then records a receipt reading:

> `RECONCILED <date> by object inspection (7/7 checks): <version> objects verified present. No
> receipt was written when this migration was originally applied, so its application date is
> unknown and is not claimed here.`

Idempotent: a version that already has a receipt is reported and left untouched; existing
receipts are never updated or re-dated. `Dss` still lacks both receipts — the script is for an
operator to run there, and nothing was written to `Dss` here.

## 8. Known gaps and open items

1. **No service path.** The schema is proven against direct SQL only. `classify()` has no
   production caller; the writer and the route are the remaining work. `WorkflowHeld` also has no
   FastAPI handler, so every unclassified combination would surface as an opaque 500.
2. **The Python/SQL halves are no longer perfectly coincident — C9 closed the only reachable
   divergence.** `classify()` refuses a `rejected` verdict carrying findings; C9 now refuses the
   equivalent row, so no reachable state differs between them. C1 and C8 remain redundant with
   `classify()` by design (Python refuses first, SQL second); that redundancy is defence in depth,
   and it also means a constraint-only test cannot detect a `classify()` regression or the
   reverse. Both layers are needed.
3. **Five constraints have no drop-and-observe proof** (see §6).
4. **`result_payload` contains entrepreneur answer text** — each finding embeds
   `source_refs[].quote`, a verbatim answer substring. The table comment records that a History
   reader must project only the non-quote fields and treat the quotes as protected content.
5. **The specs live in an untracked directory.** `docs/cp00_integration/` is untracked, so
   `git grep` — which searches the index, not the working tree — cannot see it. Absolute path:
   `C:\Users\HP\OneDrive\Desktop\sport-marketplace\FYP\docs\cp00_integration\`. This report is in
   that directory too, so it is invisible to index-based search until it is staged. Anyone told
   to read a spec from a "missing" file should check the working tree first.
6. **Named residual — a rejected result can still *own* finding rows.** C9 stops a rejected or
   unreviewed result from *counting* findings, but `bdj_result_findings` has an FK to `result_id`
   and nothing stops a writer attaching rows to a rejected parent whose `finding_count` is 0.
   That residual is closed by a **read-path precondition, not by the schema**: any reader of
   `bdj_result_findings` must join `bdj_results` and filter `review_outcome IN
   ('reviewed','stale')`. A trigger was deliberately not added — it would have to read the parent
   under RLS, would be the first invoker-rights trigger in this schema reading a row it did not
   create, and its failure mode is silent rather than loud. The obligation therefore passes to the
   author of the reader.

## 9. Independent verification of the central claim

**Added by the team lead, 2026-11-17.** Not authored by `a1-builder`. The sections above are the
builder's own account; this section is a separate party reading the live catalogue rather than the
builder's output, because the report's load-bearing claim is not "a script printed PASS" but "these
constraints are installed in this database and not in that one".

Method: direct `psql` against both databases using the project's own credentials, reading
`pg_constraint`. Not the builder's script, not the report's text.

```sql
select conname, pg_get_constraintdef(oid) from pg_constraint
 where conname in ('bdj_results_findings_require_review_check',
                   'bdj_result_sources_locator_pointer_check') order by 1;
```

| Database | Result |
|---|---|
| `project1_workflow_tests` | **both present** |
| `Dss` | **neither present** |

Installed definitions, verbatim:

```
bdj_result_sources_locator_pointer_check ::
  CHECK (((locator IS NULL) OR (locator ~ '^(?:M2-(?:[0-9]{2}|O-0[12])|M2V1-(?:0[1-9]|1[01]))(@[^[:space:]]{1,128})?$'::text)))

bdj_results_findings_require_review_check ::
  CHECK (((finding_count = 0) OR (review_outcome = ANY (ARRAY['reviewed'::text, 'stale'::text]))))
```

Inventory, same method:

| | `project1_ai` tables | receipts | `attempts` | `bdj_*` tables |
|---|---|---|---|---|
| `project1_workflow_tests` | 10 | 5 | 21 | 5 |
| `Dss` | 4 | 1 | 9 | **0** |

What this establishes, and what it does not:

- **Establishes:** the two constraints exist in the clone with the definitions the report quotes;
  `Dss` has none of the `bdj_*` tables and its table/receipt/attempt counts are the pre-CP-04A
  baseline. "Nothing was applied to `Dss`" is therefore a measured fact, not a promise.
- **Does not establish:** that the 35 checks are load-bearing. That remains §6's problem — five
  constraints, including both above, have no drop-and-observe proof, and the substitute evidence
  there is labelled as substitute. This section must not be read as upgrading §6.
- **Does not establish:** anything about the service path. §8.1 stands unchanged.

The durable anchor for future verification is the constraint **name** plus
`pg_get_constraintdef`, not the file hash. A hash says which text was on disk at a moment; the
catalogue says what the database will enforce now. Where the two disagree, the catalogue wins.
