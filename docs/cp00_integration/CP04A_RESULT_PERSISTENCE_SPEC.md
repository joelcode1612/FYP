# CP-04A Result Persistence Spec (A3)

**Status:** engineering spec. Depends on A1 (`result_contracts.py`, landed).
**Blocked in part:** key custody (B3) and grants (B1/B2). Build the parts that are independent.

---

## 1. What exists, and what the gap actually is

A3 is **not** "build storage". The storage already exists and is verified.

| Layer | State |
|---|---|
| Schema — `bdj_results`, `bdj_result_sources`, `bdj_result_validations`, `bdj_result_findings`, `bdj_raw_responses` | **exists**, applied to the clone, 26/26 security checks PASS |
| Contract — `project1/result_contracts.py` `classify()` | **exists**, 36 tests, no branch can emit a row the DB refuses |
| **Writer — anything that calls `classify()` and persists** | **absent** — `result_contracts` has zero importers outside its own test |

So the gap is one service. Do not create a second storage design; do not add columns.

---

## 2. `BdjResultStore`

New file: `backend/src/sitewise/project1/result_store.py`.

```python
class BdjResultStore:
    def __init__(self, engine, actor_id: UUID, run_id: UUID, cipher: KeyCipher | None = None): ...
    def persist(self, attempt_no: int, review_result: dict | None,
                execution_outcome: str, *, output_digest: str | None,
                sources=(), validations=(), findings=(), raw_output: bytes | None = None) -> UUID: ...
    def read(self, result_id: UUID) -> dict: ...
```

### 2.1 Atomicity

`persist()` must write the result row and its children **in one transaction**, in this order,
because the children have FKs to `bdj_results(result_id)`:

`bdj_results` → `bdj_result_sources` → `bdj_result_validations` → `bdj_result_findings` →
`bdj_raw_responses` (last, and only when a cipher is present).

Derive `result_id` deterministically from `(run_id, attempt_no)` — e.g.
`uuid5(NAMESPACE_URL, f"sitewise:bdj:{run_id}:{attempt_no}")` — so a retry of the same attempt is
idempotent rather than creating a second row. The `one_per_attempt` unique constraint is the
backstop; the deterministic id is what makes a duplicate write a no-op instead of an error.

### 2.2 It must go through `classify()`

Never construct the row body by hand. `classify(review_result, execution_outcome,
output_digest=...)` owns the mapping from engine verdict to columns, and it is the only thing
that keeps the writer and the constraints in agreement. If `classify()` raises
`RESULT_OUTCOME_UNCLASSIFIED`, let it propagate — that is the correct failure, and swallowing it
would produce a row the contract does not define.

### 2.3 Principal

Execute under the same restricted principal as the ledger: reuse the `_scope()` pattern from
`ledger.py:14-40` (fail closed on superuser/BYPASSRLS, `SET LOCAL ROLE p1ai_runtime`, then bind
`project1.actor_id` transaction-locally). Do not open a second, differently-scoped connection —
a writer that runs as a different role than the ledger would make `attempts` and `bdj_results`
disagree about who acted.

### 2.4 The raw-response asymmetry is deliberate

`bdj_raw_responses` grants `INSERT` to `p1ai_runtime` but **not** `SELECT`. The runtime can
record a completion and cannot read it back. Consequences you must respect:

- `persist()` may write `raw_output`; it must never attempt to read it back in the same flow.
- `read(result_id)` must **not** select from `bdj_raw_responses`. A test asserting that it does
  not is worth more than a comment.
- Anything that needs to read model text requires the audit role (`p1ai_auditor`) and an
  explicit access decision that does not exist yet. Do not add a read path "for completeness".

### 2.5 Encryption — port now, key later

`KeyCipher` is a Protocol in `core/` with two methods (`encrypt(bytes) -> (ciphertext, key_id)`,
`decrypt(ciphertext, key_id) -> bytes`). Rationale: key custody is `B3`, undecided, so the store
must not hard-code a key or a key location.

- Ship **no production cipher**. `BdjResultStore(..., cipher=None)` must persist the result
  **without** a `bdj_raw_responses` row, and say so — an unencrypted fallback that writes
  plaintext must not exist.
- For tests only, a `Fernet` cipher constructed from a per-run random key generated in-process.
  Never a literal key, never a key read from an env var with a default.
- Add `cryptography` to `backend/pyproject.toml` explicitly. It is currently reachable only
  transitively via `pyjwt[crypto]>=2.9`; a transitive dependency that silently disappears on a
  version bump would break decryption of historical rows.

### 2.6 `read()` and the projection allow-list

`bdj_results.result_payload` **contains entrepreneur answer text** — `source_refs[].quote` is a
verbatim substring of the M2 answer. `read()` must therefore return an explicit allow-list:

| Include | Exclude |
|---|---|
| `result_id`, `run_id`, `attempt_no`, `assessment_id`, `assessment_revision`, `execution_outcome`, `review_outcome`, `review_reason`, `validation_status`, `finding_authority`, `finding_count`, `prompt_version`, `model_requested`, `model_returned`, `output_digest`, `created_at` | `result_payload.source_refs[].quote`, and any raw completion |

Per-finding fields that may be projected — **the payload stores the `Finding` model's keys, not the
`m2_bdj_findings` column names**. Corrected against `project1/contracts.py:41-49`:

| Include (payload key) | Exclude |
|---|---|
| `rule_id`, `kind`, `observed_condition`, `counterargument`, `justification`, `next_action` | `source_refs[].quote` |

An earlier revision of this spec listed `issue_type`, `explanation`, `not_proven` — those are
`m2_bdj_findings` columns and do not exist in the payload. A projection built from that list
would have silently returned nothing. `review_state` and `authority` are also not payload fields:
`review_state` lives on `m2_bdj_findings`, `authority` on `bdj_result_findings`.

Note the two distinct authority tokens, which must not be interchanged:
`bdj_results.finding_authority = 'candidate_only'` (result level) and
`bdj_result_findings.authority = 'candidate'` (per finding). The per-finding CHECK rejects
`'candidate_only'` — verified.

This matters because `bdj_raw_responses` encryption does **not** protect answer text — the same
words sit in plaintext in `result_payload`. A reader that returns the payload wholesale bypasses
the encryption entirely.

### 2.7 Two more leakage surfaces — found by review, not by me

`result_payload` is not the only place entrepreneur answer text can land. Two free-text columns
in the same migration have no warning and no CHECK preventing it:

| Column | Definition | Why it is a risk |
|---|---|---|
| `bdj_result_sources.locator` | `text CHECK (locator IS NULL OR length(locator) BETWEEN 1 AND 512)` (`_03:247`) | a writer holding a `SourceRef` will naturally write `quote` here, because that is the text it has in hand |
| `bdj_result_validations.detail` | `text CHECK (detail IS NULL OR length(detail) BETWEEN 1 AND 1024)` (`_03:262`) | free text; the obvious message is "quote X did not match", which reprints the quote |

Neither is protected by the encryption on `bdj_raw_responses` — they are plaintext in different
tables. Constrain both at the writer boundary so the schema's permissiveness is never exercised:

- **`locator` is a pointer, never prose.** Accept only `f"{item_key}@{item_version_id}"` or
  `None`, built from the `SourceRef` fields — never from `quote`. The item_key must match
  `contracts.py:29`, whose pattern is the **single source of truth**:

  ```
  ^(?:M2-(?:\d{2}|O-0[12])|M2V1-(?:0[1-9]|1[01]))$
  ```

  Copy it from that literal; never retype it. Three variants were transcribed by hand on
  2026-11-17 and two were wrong — `0[01]|1[01]` (this file, now corrected) and `0[01]|1[11]`
  (never installed anywhere). `0[01]` accepts `M2V1-00`, which is not a key, and rejects
  `M2V1-02` through `M2V1-09`, which are. A transcription error here is silent: it refuses a
  legitimate key or admits an illegitimate one, and no existing test notices. A parity test must
  assert that the SQL pattern (`_03:269`) and the Pydantic pattern accept and reject the same
  corpus.

  Reject anything else by name; never truncate silently. Note what the pattern does **not** do:
  `M2-04@We-are-takeaway-only` passes it, because a hyphenated quote contains no whitespace. The
  pattern is a floor against accident, not protection against intent — the protection is that the
  writer constructs `locator` from structured fields and never from `quote`.

- **`detail` is a fixed sentence, never interpolated text.** It is *not* a code: `check_code`
  already carries the code, and constraining `detail` to `^[A-Z][A-Z0-9_]{0,63}$` would make the
  two columns the same thing. Instead the writer selects `detail` from a catalogue the module
  defines, keyed by `check_code` (`SOURCE_QUOTE_NOT_FOUND` → "The quoted span was not found in
  the item value."). Never format the offending quote, value or provider message into it.
  Identify the item through a structured field, not through prose.

  The schema cannot enforce this and should not try: a pattern would either duplicate
  `check_code` or exclude the explanation the column exists for. The control is the catalogue,
  plus a test asserting that no catalogue entry interpolates a variable.

Without this, `bdj_raw_responses` encryption is theatre: the same answer text is written in
plaintext in the same transaction, and any report citing encryption-at-rest would be false.

---

## 3. Tests

`backend/tests/project1/test_result_store.py`. Use a disposable clone or the isolated lab; a
restricted principal is required and a superuser session must be refused (`RESTRICTED_WORKFLOW_PRINCIPAL_REQUIRED`).

1. **round trip** — persist a `reviewed` result with 2 findings and 3 sources; read it back;
   assert `validation_status='valid'` (generated), `finding_count=2`, `finding_authority='candidate_only'`.
2. **idempotency** — persist the same attempt twice → one row, second call a no-op, no error.
3. **rejected** — `classify` produces `review_outcome='rejected'`; assert `result_payload IS NULL`
   and that no finding row is written.
4. **transport failure** — `execution_outcome='unknown_outcome'`, `review_outcome NULL`,
   `validation_status='not_validated'`; assert no payload and no findings.
5. **unclassified** — an engine outcome of `'held'` (or any unknown string) raises
   `RESULT_OUTCOME_UNCLASSIFIED` and writes **nothing** (assert row count unchanged).
6. **no raw write without a cipher** — `cipher=None` + `raw_output=b'...'` must raise, not
   silently drop the bytes. Silent dropping is how evidence disappears.
7. **raw is write-only** — with a test cipher, `persist(raw_output=...)` writes a row;
   `read()` does not return it; a direct `SELECT` on `bdj_raw_responses` as `p1ai_runtime`
   is refused by privileges.
8. **projection** — persist a finding whose `source_refs[].quote` contains a distinctive marker
   string; assert `read()` output does not contain that marker anywhere in its serialised form.
9. **atomicity** — force a failure on the findings insert (e.g. a `finding_id` that does not
   exist); assert no `bdj_results` row survives.

---

## 4. Non-goals

- Do not modify the migrations; they are verified and frozen for this checkpoint.
- Do not add a production key, key file, env default or KMS call.
- Do not expose `result_payload` wholesale anywhere, including in a debug helper.
- Do not connect as a superuser to make a test pass; the refusal is the contract.
- Do not write to `Dss`.

---

## 5. Status this will produce

`IMPLEMENTED_NOT_VERIFIED` on `Dss` (no grants — `MIG-AUTH-01`), `VERIFIED` on the clone for
everything except raw-response decryption, which is `BLOCKED` on `B3`.
