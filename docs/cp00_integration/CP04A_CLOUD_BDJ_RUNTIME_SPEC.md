# CP-04A Cloud BDJ Runtime Spec (A4)

**Status:** engineering spec. Implement + verify on the isolated clone; do not activate on `Dss`.
**Depends on:** A1 (`project1/project1/result_contracts.py`) — do not start before that lands.

---

## 1. What actually exists (verified, correcting the prior audit)

The prior audit said "`configured_runner()` has no production caller". That is **half true** and
the half that is false matters for the design.

| Symbol | Production caller? | Evidence |
|---|---|---|
| `configured_runner` | **No — zero.** | only `provider.py:144` (definition) and `tests/api/test_ee01_explanation.py:214` (a test asserting its absence) |
| `ModelRunner` | No | scripts `cp03d_bdj_execution.py`, `cp03d_bdj_uncertainty.py`, `cp03e_m2v1_live_admission.py`; test `test_workflow.py` |
| `BDJEngine` | **Yes** | `api/v1/project1_workflow.py:99` — but constructed as `BDJEngine(rules)` with **no** `model_runner` |

So the *deterministic* engine is already in production and working. What has no caller is the
**cloud** path. The route therefore must not replace the deterministic engine — it adds a
second, explicitly-labelled model-assisted entry point.

---

## 2. A framing correction that changes the code

The A4 inventory lists as a gap: *"Outcome vocabulary mismatch: engine emits
`held/reviewed/rejected/stale`; `finish()` accepts only `returned/rejected/unknown_outcome`.
Needs explicit mapping."*

**Do not map them.** They are not the same dimension, and mapping one onto the other is the
error `BLK-VOCAB` was about:

- `ledger.finish()` is called from `provider.py:138/140`, **inside dispatch**, before any
  validation or review. It records **D1 transport outcome**.
- `BDJEngine.review()` runs afterwards and returns **D3 review outcome**.

They are recorded in different tables (`attempt_receipts.outcome` vs `bdj_results.review_outcome`)
and neither is derived from the other. A single `'returned'` transport outcome can coexist with
`'reviewed'`, `'rejected'` or `'stale'` review outcomes — that is not an inconsistency, it is the
correct representation of "the call worked; the result was then judged". Any code that
translates one into the other will destroy that information.

---

## 3. Required execution path

```
confirmed M2 revision
  → authorize owner + flag + revision match
  → disclosure gate (synthetic only — see §5)          [AMENDED: moved before provisioning]
  → provision/reuse project1_ai.runs row (idempotent on work_identity)
  → build packet from the existing projection
  → configured_runner(...)  → ModelRunner → ledger.reserve → TokenHarbor → ledger.finish
  → BDJEngine(rules, model_runner=runner).review(packet, recheck_current=...)
  → result_contracts.classify(review_result, execution_outcome)   [A1]
  → persist bdj_results row
  → return {review outcome, findings, finding_authority, references}
```

### 3.0 Ordering: disclosure before persistence (amended 2026-11-17)

**Disclosure authorization is evaluated before any persistence. A refused disclosure must
leave no `runs`, `attempts` or `bdj_results` row.**

The earlier draft of this section provisioned the run first and gated afterwards. That is wrong
for two independent reasons:

1. `DISCLOSURE_*` (`disclosure.py:49-67`) is a pure predicate over the request. It needs no
   `runs` row, no attempt and no database read. Nothing it decides can depend on a provisioned
   run, so there is no reason to create one first.
2. `project1_ai.runs` is append-only — `deny_mutation()` refuses `DELETE`. A run created for a
   request that is then refused becomes an orphan that no later code can remove. Every disclosure
   refusal would permanently add a row whose only purpose was to be refused.

The test for this must assert the **absence of the row**, not merely that `WorkflowHeld` was
raised. A test written as `with pytest.raises(WorkflowHeld)` passes equally well when a row was
created and then abandoned, which is the exact failure this ordering exists to prevent. Query
`project1_ai.runs` by `work_identity` after the refusal and assert zero rows.

### 3.1 Run provisioning — currently absent and it is a hard blocker

`PostgresAttemptLedger.reserve()` does `SELECT ... FROM project1_ai.runs ... FOR UPDATE`
(`ledger.py:47-49`) and raises `WORKFLOW_RUN_NOT_FOUND` if there is no row. **No production code
creates a `runs` row** — only four scripts do. So the first live dispatch would fail before
reaching the provider.

`project1_ai.runs` requires (from `20261111_01_candidate_ledger.sql:36-45`):

| Column | Type | Constraint |
|---|---|---|
| `id` | uuid | PK — application-generated |
| `owner_user_id` | uuid | NOT NULL |
| `assessment_id` | uuid | NOT NULL, **FK → `public.m2_assessments(id)`** |
| `assessment_revision` | integer | `>= 0` |
| `source_fingerprint` | text | `~ '^[a-f0-9]{64}$'` |
| `policy_fingerprint` | text | `~ '^[a-f0-9]{64}$'` |
| `work_identity` | text | `~ '^[a-f0-9]{64}$'`, `UNIQUE(owner_user_id, work_identity)` |

Implement `ensure_run(engine, actor_id, assessment_id, revision, source_fingerprint) -> UUID`:

- `work_identity = sha256(canonical({"assessment_id","revision","policy_fingerprint"}))` — hex,
  64 chars. `policy_fingerprint` must be derived from the *effective* policy (rules version +
  prompt version + model), not from a constant, so that changing the model starts a new run
  rather than silently reusing one.
- Insert with `ON CONFLICT (owner_user_id, work_identity) DO NOTHING`, then `SELECT` the id.
  Idempotent by construction: a second call for the same revision returns the same run.
- **Must not** reuse a run whose `assessment_revision` differs from the packet's — assert it and
  raise `WORKFLOW_RUN_REVISION_MISMATCH` if the conflict resolved to a row with a different
  revision. `reserve()` does not compare revisions; the run row is the only place that binding
  exists, so this check is the only thing enforcing it.
- Executed under the same restricted principal as the ledger (`_scope` semantics). It must fail
  closed, not fall back to the app role.

### 3.2 The route

Add to `backend/src/sitewise/api/v1/project1_workflow.py` — **a new route, leaving the existing
deterministic one untouched**:

`POST /assessments/{assessment_id}/business-understanding/model-assisted`

Follow the existing file's conventions exactly:

- deps `Owner`, `Database` (`:46-48`); router-level `configuration_gate` (`:45`) already applies.
- a **second** gate requiring `settings.tokenharbor_enabled` and a non-empty
  `project1_rules_version` / `_sha256` / `_adoption_receipt`; on failure
  `HTTPException(503, detail={'code':'MODEL_ASSISTED_NOT_CONFIGURED','message':...})`.
- response must carry `status_contract`, `finding_authority: 'CANDIDATE_ONLY'`, and the
  `no_authority()` spread (`contracts.py:84-88`) so a caller cannot read success as authority.
- `Cache-Control: no-store`, as the sibling routes do.

### 3.3 Error mapping — currently a defect

`WorkflowHeld` subclasses `ValueError` (`contracts.py:20`) and has **no handler**;
`main.py:137-141` falls through to a generic 500. Every held reason — including
`DISCLOSURE_REAL_DATA_NOT_AUTHORIZED` and `RESTRICTED_WORKFLOW_PRINCIPAL_REQUIRED` — would
surface as an opaque 500.

Add a handler in `main.py` next to the existing ones: `WorkflowHeld` → HTTP 409 (or 503 for
infrastructure-class codes), body `{'detail': {'code': <code>, 'message': <static per-code
message>}}`. **Never** interpolate provider text, prompts, or answer content into the message.
Map codes to messages explicitly; unknown codes get a generic message plus the code.

**`exc.code` does not exist yet** — `WorkflowHeld` is a bare `ValueError` subclass
(`contracts.py:20-21`) and the handler above cannot be written against it as-is. Add to the class:

```python
@property
def code(self) -> str:
    return str(self)
```

`str(self)`, not `self.args[0]`: a bare `raise WorkflowHeld()` would make `args[0]` raise
`IndexError` inside the error handler, which is the worst possible place to raise. `str()` returns
`''` there, which the guard below turns into the fallback code.

The handler must guard the value before emitting it:

```python
code = exc.code if re.fullmatch(r'[A-Z][A-Z0-9_]{2,63}', exc.code or '') else 'WORKFLOW_HELD'
```

All 17 raise sites (`bdj.py` ×7, `disclosure.py` ×10, `explanation_contracts.py` ×1) pass a
literal, so today the guard never fires. It exists so that a future
`raise WorkflowHeld(f'BAD_{user_value}')` cannot turn this handler into a reflection channel. The
guard is three characters of regex and it makes the leak impossible by construction rather than by
review discipline.

---

## 4. What must be preserved

| Property | Mechanism already present | Do not weaken |
|---|---|---|
| one cloud-model policy | `TokenHarbor.MODEL`, `PROVIDER_MODEL_MISMATCH` | do not add a model parameter to the route |
| idempotency | `UNIQUE(run_id,stage)` + `MODEL_STAGE_ALREADY_RESERVED` (`ledger.py:54-57`) | do not retry inside the route |
| attempt budget | `<= 6`, `MODEL_ATTEMPT_BUDGET_EXHAUSTED` | do not loop |
| revision binding | `bdj.py:131-133` `stale` + run-row assertion (§3.1) | do not skip `recheck_current` |
| owner checks | `require_entrepreneur`, RLS on `project1_ai` | do not bypass with a superuser session |
| schema validation | `validate_candidates` (`bdj.py:33-59`) | do not catch and continue |
| source fingerprint | `verify_projection`, `disclosure.py:66-67` | do not re-derive loosely |
| deterministic vs model-assisted | separate routes, separate labels | do not merge them |

---

## 5. The synthetic-only boundary — and why that is correct, not a gap

`SyntheticBdjDisclosure.require_current` (`disclosure.py:46-67`) refuses any packet that is not
`data_class='SYNTHETIC_NONHUMAN'` and `purpose='SYNTHETIC_BDJ_DIAGNOSTIC'`
(`DISCLOSURE_REAL_DATA_NOT_AUTHORIZED`). There is no real-data disclosure adapter.

That is a **deliberate HOLD**, not missing code. The provider's retention terms for real
entrepreneur declarations are undecided (TokenHarbor's free route retains and staff may read,
up to 24 months, per `docs/project1_workflow/IMPLEMENTATION.md:95-99`). Sending real data would
be a data-protection decision, and it belongs to the Owner (B2/B3), not to this route.

**Therefore:** build and test the route against synthetic packets. Leave
`DISCLOSURE_REAL_DATA_NOT_AUTHORIZED` firing for real packets, and add a test asserting it
fires. Do not write a "real data" disclosure adapter. If you find yourself needing one to make
the demo work, that is the signal that the demo is out of scope.

---

## 6. Tests

`backend/tests/project1/test_model_assisted_route.py`, all with a **fixture provider** — no
network, no paid dispatch, no real `TokenHarbor`:

1. **happy path** — synthetic packet → fixture returns a valid `BDJOutput` → 200; assert
   `finding_authority='CANDIDATE_ONLY'`, `no_authority()` all false, and that a `bdj_results`
   row exists with `review_outcome='reviewed'`, `execution_outcome='returned'`,
   `validation_status='valid'` (generated), `finding_count` matching the findings.
2. **invalid model output** — fixture returns something that fails `validate_candidates` →
   `review_outcome='rejected'`, `validation_status='invalid'`, `result_payload IS NULL`, and
   **no finding is exposed**.
3. **transport failure** — fixture raises a timeout code → `execution_outcome='unknown_outcome'`,
   `review_outcome IS NULL`, `validation_status='not_validated'`.
4. **stale** — mutate the assessment between dispatch and `recheck_current` → `review_outcome='stale'`,
   findings dropped, and the API must not report them.
5. **real-data refusal** — packet with `data_class` ≠ synthetic → 409 with
   `DISCLOSURE_REAL_DATA_NOT_AUTHORIZED`, and assert **no** `runs` row was created and **no**
   provider call was attempted.
6. **idempotency** — two identical calls → one `attempts` row, second call does not dispatch a
   second attempt; assert `MODEL_STAGE_ALREADY_RESERVED` or a replayed result, and state which.
7. **revision mismatch** — run exists at revision N, packet at N+1 → `WORKFLOW_RUN_REVISION_MISMATCH`,
   no dispatch.
8. **owner isolation** — owner B requests owner A's assessment → 404/403, no run row created.
9. **flag off** — `tokenharbor_enabled=False` → 503 `MODEL_ASSISTED_NOT_CONFIGURED`.
10. **no leaked content** — assert the response body and the error body contain no prompt text,
    no answer values, and no raw completion.

Run against the isolated clone where a restricted principal exists. On `Dss` the route will fail
at `RESTRICTED_WORKFLOW_PRINCIPAL_REQUIRED` / `WORKFLOW_RUN_NOT_FOUND` because `p1_m2_runtime`
has no `USAGE` on `project1_ai` (`MIG-AUTH-01`, undecided). **Record that as
`IMPLEMENTED_NOT_VERIFIED` on `Dss`, not as a failure** — and do not "fix" it by connecting as
`postgres`.

---

## 7. Non-goals

- Do not modify the existing deterministic `business-understanding` route or its four-value
  message dict (`:99-105`).
- Do not create a `runs` row from a script path and call it done — the service must be reachable
  from the route.
- Do not dispatch a real provider call in any test.
- Do not add a real-data disclosure adapter.
- Do not connect to `Dss` as a superuser to make a test pass.
