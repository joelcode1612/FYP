# P2 — Question-Bank Authority Evidence and BD-01 Decision Proposal

- **Workstream:** PROJECT1 / CP-00 integration, P2 (question-bank authority)
- **Generated:** 2026-11-17T14:06:38Z
- **Repo:** `C:\Users\HP\OneDrive\Desktop\sport-marketplace\FYP` (backend `FYP/backend`, `PYTHONPATH=backend/src`)
- **Companion machine-readable record:** `FYP/artifacts/p2_bank_authority/verdict.json`
- **Decision ID:** `BD-01`

> **Line-number basis.** Every `file:line` citation below was re-verified against the working tree at `2026-11-17T14:06:38Z`. The tree is being edited concurrently by other workstreams, so line numbers may drift. Where they do, the **anchors are authoritative** — the named function, the exact quoted string, or the SQL object. The quoted block in §4 was re-read immediately before publication and matches byte-for-byte.

## 0. Scope, and what this document is not

This is an investigation and a governance decision proposal. It is **not** a feature build.

Constraints observed while producing it:

| Constraint | How it was observed |
|---|---|
| No provider/model calls, no network dispatch | Nothing in this workstream imports `sitewise.project1.provider` or invokes a runner. Only source reads, greps, and one read-only SQL session were used. |
| No writes to live `Dss` | One successful `Dss` connection, opened with `conn.set_session(readonly=True)` plus `SET TRANSACTION READ ONLY`, verified `transaction_read_only=on` before any query, `SELECT` only, terminated with `rollback()`. No DDL, no DML, no migration. |
| No modification of `backend/src/`, `backend/migrations/`, `backend/tests/` | No file under those trees was written. This document and `verdict.json` are the only new files. |
| No git commits | None made. |
| Credentials never printed | `backend/.env` was parsed in-process; only host/port/database/username were emitted, never passwords or the DSN. |

---

## 1. Verdict

> ### `ZERO_APPROVED_ENTRIES`
>
> **and** `production_composition: NOT_COMPOSED`

There is no approved question bank anywhere in this repository or in the live `Dss` database. There is no bank port, no bank implementation, no receipt issuer, no receipt verifier, and no schema object capable of storing an approved QG item. The `ResearchWorkflow` that would consume such a bank is never instantiated outside `backend/tests/`, and no HTTP route reaches it.

Consequently both bank-dependent branches of `ResearchWorkflow._evaluate` are unreachable in production:

- `verified_equivalent` → the approved-item reuse path (no bank can return it);
- `verified_no_equivalent` → the QG drafting path (no bank can return it either, and `authority.require_drafting` has no implementation).

The only `lookup` implementations in the tree are test doubles that return hard-coded receipt strings. They are correctly labelled as synthetic and must not be mistaken for authority.

---

## 2. Evidence table

Every row was verified directly in this session. No row is inherited from another agent's report.

| # | Claim | Evidence (file:line) | How verified |
|---|---|---|---|
| E1 | The only bank contract in the tree is a duck-typed constructor argument. There is no `Protocol`, no ABC, no type annotation for the bank. | `backend/src/sitewise/project1/research.py:74-76` — `class ResearchWorkflow: def __init__(self, builder, authority, bank, runner): self.builder, self.authority, self.bank, self.runner = builder, authority, bank, runner` | Direct read of the file |
| E2 | `backend/src/sitewise/services/ports/` contains exactly four port modules and none of them is a bank port. | `ls backend/src/sitewise/services/ports/*.py` → `business_context_store_port.py`, `business_context_v1_port.py`, `cq_store_port.py`, `m2_repository_port.py` | Directory listing, then header read of all four |
| E3 | No class named `*Bank` and no `lookup`/`verify_receipt` definition exists in production source. | `grep -rn "class .*Bank\|def lookup\|def verify_receipt" backend/src/` → **zero matches** | Ripgrep over `src/` |
| E4 | The only two `lookup` implementations are test doubles returning hard-coded receipts. | `backend/tests/project1/test_workflow.py:210-215` (`approval_receipt='SYN-ONLY'`); `backend/tests/m2_bcb/connected_chain_checks.py:123-129` (`approval_receipt='SYNTHETIC-PRIVATE-LAB-ONLY'`) | Direct read of both ranges |
| E5 | `ResearchWorkflow` is never instantiated in production code. | `grep -rn "ResearchWorkflow" backend/src/` → only the definition at `research.py:74` (plus a stale `.pyc`). All five instantiations are in `backend/tests/` (`test_workflow.py:226`, `connected_chain_checks.py:336` and `:383`, `test_adopted_m2_v1.py:187` and `:444`). | Ripgrep over `src/` and `tests/` |
| E6 | No HTTP route reaches research/QG. The workflow module exposes seven routes, none of which is research or QG. | `grep -n "@router" backend/src/sitewise/api/v1/project1_workflow.py` → `/source`, `/setup`, `/business-understanding`, `/business-understanding/model-assisted`, `/results`, `/technical-audit`, `/technical-audit/runs/{run_id}`. `grep -n "QG\|qg"` on the same file → **zero matches**. | Ripgrep + route enumeration |
| E7 | Production code itself declares the approved bank register **unresolved**. | `backend/src/sitewise/api/v1/project1_workflow.py:220-222` — `'unresolved': ['shared_status_adoption', 'BCB_live_authority_adapters', 'approved_bank_register', 'provider_disclosure', 'restricted_database_grants']` | Direct read of `/technical-audit` handler |
| E8 | `approval_receipt` exists only as a **consumer** in production and as a **literal** in tests. There is no producer, no issuer, and no schema column of that name anywhere. | `grep -rn "approval_receipt"` over `*.py|*.sql|*.md|*.json` (excluding `.venv`) → `research.py:160` plus four test literals (`test_workflow.py:211`, `connected_chain_checks.py:126`, `test_adopted_m2_v1.py:216`, `:438`). **Zero** hits in `migrations/`. | Ripgrep across the tree, then confirmed by the migration grep in E9 |
| E9 | No migration defines any approval or equivalence column for a question bank. | `grep -rn -i "approv" backend/migrations/ backend/supabase/` → only prose comments, `m2_item_versions.approval_state` (see E14), and `decision IN ('APPROVE_FOR_REVIEW','REJECT')` (see E13). No `approved_question`, no `equivalence`, no `receipt` column on any bank-like table. | Ripgrep over all SQL |
| E10 | The only `QUESTION_BANK_VERSION` in the tree belongs to the CQ Q01–Q13 successor instrument and is self-declared synthetic. | `backend/src/sitewise/cq_successor/contracts.py:4-18` — module docstring "SYNTHETIC ONLY. This module is a successor CANDIDATE, not an approved replacement…"; `QUESTION_BANK_VERSION = "SYN-QBANK-V1"` at `:17` | Direct read of the header |
| E11 | The CQ repository's authority adapter refuses production fielding by construction. | `backend/src/sitewise/repositories/cq_repository.py:17-19` — `class UnverifiedCqAuthority: def authorize(...): raise CqRefused('PRODUCTION_FIELDING_HOLD',503)` | Direct read |
| E12 | The only persisted "bank" table in `Dss` stores the CQ **source** bank (Q01–Q13), not approved QG items. Its column set has no construct, population, timeframe, stimulus, response-code or routing field. | `backend/migrations/cq/20261114_01_source_bank_only.sql:9-14` — `cq_bank_versions(version varchar(100) PK, content_hash varchar(64), questions_json jsonb, created_at timestamptz)`. Intent recorded at `backend/docs/cq_runtime/SOURCE_BANK_STORAGE.md:1-12`: "This authorization covers the source bank only. It does not adopt a questionnaire, approve fielding…" | Direct read of migration + doc |
| E13 | The only question-assignment table is structurally restricted to the 13 CQ questions, so it cannot hold a QG item. | `backend/migrations/cq/20261115_04_runtime_from_source_bank.sql:33-37` — `question_id varchar(3) NOT NULL CHECK(question_id ~ '^Q(0[1-9]\|1[0-3])$')` | Direct read |
| E14 | `m2_item_versions.approval_state` is the **M2 instrument** approval field, not a QG bank. | `backend/supabase/migrations/20261107133000_m2_upstream_foundation.sql:56` — `approval_state VARCHAR(24) NOT NULL`; immutability trigger preserves it at `backend/migrations/m2/20261113_01_confirmed_context_persistence.sql:140-142` | Direct read of both |
| E15 | The only generated-question store is a **per-objective candidate** table, not an approved bank. | `backend/migrations/m2/20261114_02_research_objective_sources.sql:35-39` — `m2_review_question_versions(id, objective_id, source_receipt, question, options, supersedes)` | Direct read |
| E16 | Candidates are written per assessment/objective, keyed by a content hash — not merged into any global approved set. | `backend/src/sitewise/services/confirmation_service.py:299-310` (`persist_candidate`, `version = uuid5(NAMESPACE_URL, digest(receipt))`) and `backend/src/sitewise/repositories/m2_repository.py:497-507` (`INSERT INTO public.m2_review_question_versions … ON CONFLICT(id) DO NOTHING`) | Direct read of both |
| E17 | Owner review of a candidate authorises **review only**, and the service response explicitly denies fielding and scientific acceptance. | `backend/src/sitewise/services/confirmation_service.py:315-324` — returns `{**row, "fielding_authorized": False, "scientific_acceptance": False}`; decision vocabulary at `backend/migrations/m2/20261115_01_candidate_owner_review.sql:16` — `decision IN ('APPROVE_FOR_REVIEW','REJECT')` | Direct read of both |
| E18 | The workflow's own "no authority" vocabulary denies fielding and scientific acceptance on every path. | `backend/src/sitewise/project1/contracts.py:84-88` — `no_authority()` returns `scientific_acceptance: False, owner_authorization: False, publication_authorized: False, fielding_authorized: False, report_release_authorized: False` | Direct read |
| E19 | The QG prompt itself states the precondition: no drafting without a verified no-equivalent receipt. | `backend/src/sitewise/project1/prompts.py:58-61` — `'QG': Prompt('QG-FROZEN-1-CAND', … 'The bank must have a verified no-equivalent receipt before drafting. …')` | Direct read |
| E20 | Live `Dss` contains no relation matching `%approved%` or `%equivalence%`, and only three relations matching `%question%`/`%bank%`. | Read-only catalog query (see §3) → `public.cq_bank_versions`, `public.cq_question_assignments`, `public.m2_review_question_versions`. `m2_review_question_versions` row count = **0**. | Single read-only `Dss` session |

### 2.1 Classification of every candidate store found

Each hit is classified as the brief requires: **(a)** CQ successor instrument, **(b)** M2/M2V1 instrument items, **(c)** generated question candidate/version storage, **(d)** a genuine approved QG bank.

| Candidate | Class | Why | Evidence |
|---|---|---|---|
| `public.cq_bank_versions` | **(a)** CQ successor instrument (source bank) | Stores the 13 original Q01–Q13 source records as one immutable `SOURCE_ONLY:`-prefixed row. Columns are `version/content_hash/questions_json/created_at` only — no construct, population, timeframe, stimulus, codes or routing. The registration doc states explicitly that it "does not adopt a questionnaire, approve fielding, create a release/campaign, register M2, or authorize downstream research/reporting." | E12 |
| `public.cq_question_assignments` | **(a)** CQ successor instrument | `question_id` is `CHECK(question_id ~ '^Q(0[1-9]\|1[0-3])$')` — cannot hold a QG item by construction. | E13 |
| `public.cq_manifest_releases` | **(a)** CQ successor instrument | Release/manifest container with `source_class IN ('ADOPTED','CANDIDATE','SYNTHETIC_FIXTURE')`. It releases CQ manifests; it does not approve QG items. | `migrations/cq/20261115_04_runtime_from_source_bank.sql:26-32` |
| `QUESTION_BANK_VERSION = "SYN-QBANK-V1"` (`cq_successor/contracts.py:17`) | **(a)** CQ successor instrument | Self-declared "SYNTHETIC ONLY … successor CANDIDATE, not an approved replacement". Consumed only by `cq_successor/policy.py` and its tests. | E10 |
| `public.m2_item_versions` (`approval_state`) | **(b)** M2/M2V1 instrument items | This is the assessment instrument's own item/approval field for M2 items, unrelated to QG research questions. | E14 |
| `public.m2_instrument_versions` | **(b)** M2/M2V1 instrument items | Instrument version registry; read granted to `p1_m2_runtime` as reference data. | `migrations/project1_ai/20261116_02_m2_runtime_role.sql:45,105` |
| `public.m2_review_question_versions` | **(c)** generated question candidate/version storage | Per-objective row written by `persist_candidate` with `source_receipt` = the full context+evaluation+candidate receipt; `supersedes` chains versions; **0 rows in `Dss`**. | E15, E16, E20 |
| `public.m2_desired_options` | **(c)** generated question candidate/version storage | The entrepreneur's desired option for one candidate version. Not an approval artefact. | `migrations/m2/20261114_02_research_objective_sources.sql:40-43` |
| `public.m2_candidate_owner_reviews` | **(c)** generated question candidate/version storage | Decision vocabulary is `APPROVE_FOR_REVIEW` / `REJECT`; service returns `fielding_authorized: False`. Approval-to-review ≠ approval-of-equivalence. | E17 |
| `public.m2_candidate_review_assignments` | **(c)** generated question candidate/version storage | Assignment of reviewers to a candidate; no approval semantics. | `migrations/m2/20261115_01_candidate_owner_review.sql:8-12` |
| `project1_ai.attempt_receipts` | none of the four | Provider-attempt outcome ledger (`returned`/`rejected`/`unknown_outcome`). Named "receipt" but is an execution receipt, not an equivalence receipt. | `migrations/project1_ai/20261111_01_candidate_ledger.sql:55-63` |
| `public.cq_submission_receipts` | none of the four | Respondent submission receipt for a CQ session. | `migrations/cq/20261115_04_runtime_from_source_bank.sql:96` |
| **(d) genuine approved QG bank** | — | **No instance found.** | E20 |

---

## 3. Live `Dss` read-only check

One successful connection was made. Safety was enforced before any query was issued.

```
database=Dss user=p1_m2_runtime transaction_read_only=on
```

- Session opened with `psycopg2.connect(...)` then `conn.set_session(readonly=True, autocommit=False)`, followed by `SET TRANSACTION READ ONLY` and `SET LOCAL statement_timeout = '20s'`. The code asserts `current_database() = 'Dss'` **and** `current_setting('transaction_read_only') = 'on'` before proceeding, and aborts otherwise.
- Only `SELECT` was executed. The session ended with `conn.rollback()`; nothing was committed.

Catalog result (`pg_class` / `pg_namespace`, `relkind IN ('r','p','v','m')`, excluding system schemas), matching `%question%`, `%bank%`, `%approved%`, `%equivalence%`:

| Relation | Kind | Row count | Note |
|---|---|---|---|
| `public.cq_bank_versions` | table | `InsufficientPrivilege` | Exists; `p1_m2_runtime` has no `SELECT` on it — the least-privileged runtime role cannot read the CQ source bank at all. |
| `public.cq_question_assignments` | table | `InsufficientPrivilege` | Exists; same privilege position. |
| `public.m2_review_question_versions` | table | **0** | Exists and is readable; contains zero candidate rows. |

Relations matching `%approved%` or `%equivalence%`: **none**.
Total base tables: `public` = 68, `project1_ai` = 10.

Two consequences worth recording:

1. The three matching relations are exactly the CQ source bank, its assignment table and the M2 candidate store — i.e. classes (a) and (c) from §2.1. There is no fourth relation.
2. Even if `cq_bank_versions` were reinterpreted as an approved bank, the production runtime principal could not read it. Authority that the runtime cannot exercise is not authority.

### 3.1 Correction to the briefing's connection instructions

The brief stated that credentials live in `backend/.env` under key `DATABASE_URL`. They do, but **`DATABASE_URL` does not point at `Dss`**:

| Key | Database | Role |
|---|---|---|
| `DATABASE_URL` | `Final_Location_Analysis` | `postgres` |
| `ANALYTICS_DATABASE_URL` | `Final_Location_Analysis` | `postgres` |
| `M2_DATABASE_URL` | **`Dss`** | `p1_m2_runtime` |
| `PROJECT1_RUNTIME_DATABASE_URL` | **`Dss`** | `p1ai_engine` |
| `PROJECT1_AUDIT_DATABASE_URL` | **`Dss`** | `p1ai_auditor` |

The first connection attempt used `DATABASE_URL`, observed `current_database() = 'Final_Location_Analysis'`, and aborted immediately — before any catalog or data query. That attempt executed only `SET` statements and a single `SELECT current_database(), current_user, current_setting(...)`. No row was read or written in that database. The `Dss` check above used `M2_DATABASE_URL`, the least-privileged of the three `Dss` roles.

Any downstream task that assumes "`DATABASE_URL` = `Dss`" should be re-checked.

---

## 4. The contract exactly as implemented

Quoted verbatim from `backend/src/sitewise/project1/research.py:156-171`:

```python
        lookup = self.bank.lookup(qj.measurement.model_dump(), packet)
        self.bank.verify_receipt(lookup, digest(qj.measurement.model_dump()), packet)
        result['bank'] = lookup['outcome']
        if lookup['outcome'] == 'verified_equivalent':
            if not lookup.get('item_version') or not lookup.get('approval_receipt'):
                raise WorkflowHeld('BANK_EXACT_APPROVAL_REQUIRED')
            # Reuse is a candidate assignment; no QG model invocation.
            result['qg'] = {'decision': 'REUSE_CANDIDATE',
                            'item_version': lookup['item_version']}
        elif lookup['outcome'] == 'verified_no_equivalent':
            self.authority.require_drafting(packet, task, lookup)
            raw = self.runner('QG', {'context': packet,
                'frozen_measurement': qj.measurement.model_dump(), 'bank_receipt': lookup}, QGOutput)
            result['qg'] = validate_draft(raw, qj.measurement).model_dump()
        else:
            raise WorkflowHeld('BANK_AUTHORITY_UNVERIFIED')
```

The contract, stated plainly:

| Element | Requirement | Failure mode |
|---|---|---|
| `lookup(measurement: dict, packet: dict) -> dict` | Must return a mapping containing `outcome`. | `KeyError` on `lookup['outcome']` if absent — not a governed code. |
| `outcome` value | `verified_equivalent`, `verified_no_equivalent`, or anything else. | Anything else → `WorkflowHeld('BANK_AUTHORITY_UNVERIFIED')`. |
| `verified_equivalent` preconditions | `item_version` **and** `approval_receipt` both truthy. | `WorkflowHeld('BANK_EXACT_APPROVAL_REQUIRED')`. |
| `verify_receipt(lookup, digest(measurement), packet)` | Called immediately after `lookup`, **before** `outcome` is inspected — so it runs on every branch, including the unverified one. Must raise on an unverifiable receipt. | Whatever the adapter raises; there is no adapter, so this is undefined. |
| `verified_no_equivalent` precondition | `authority.require_drafting(packet, task, lookup)` must succeed before the QG runner is invoked. | Whatever `require_drafting` raises; no implementation exists. |
| Ordering guarantee | `verify_receipt` precedes branch selection, so a receipt is verified even when the outcome is a no-equivalent claim. | — |

Two properties of this ordering matter for `BD-01`:

1. **`verify_receipt` is not optional and is not conditional on `verified_equivalent`.** A `verified_no_equivalent` claim must also carry a verifiable receipt. Whatever object the bank returns on the drafting branch must therefore be verifiable under the same function signature.
2. **`lookup` is the only source of `outcome`.** There is no second opinion, no quorum and no independent cross-check inside the workflow. The bank adapter is a single point of authority. This is why the port must be a trusted server adapter (the module docstring at `research.py:3-4` says so: "Authority/bank/disclosure ports must be trusted server adapters. There is no HTTP payload accepting grants and no production implementation inventing missing owners.").

---

## 5. What a genuine receipt must contain to be verifiable

**Current status: undefined.** `verify_receipt` has no implementation anywhere in the tree, and `approval_receipt` has no schema column. There is therefore no existing definition of "verifiable" to conform to. What follows is derived from the call signature and the `Measurement` contract, and is offered as input to `BD-01` — it is a proposal, not a description of deployed behaviour.

From `verify_receipt(lookup, measurement_digest, packet)`, a verifier receives three things and must be able to establish that the receipt in `lookup` genuinely covers this measurement in this context. That implies the receipt must bind, at minimum:

| Dimension | Must be bound because | Source of the value |
|---|---|---|
| Exact frozen measurement digest | The digest is passed in explicitly; a receipt not bound to it is replayable against any other measurement. | `digest(qj.measurement.model_dump())` |
| Construct | Equivalence is construct-specific; a question about price acceptability is not equivalent to one about purchase intent. | `Measurement.construct_name` (alias `construct`), `contracts.py:57` |
| Population | Same wording to a different population is not the same measurement. | `Measurement.population`, `contracts.py:58` |
| Reference period / timeframe | Same question over a different period is not equivalent. | `Measurement.timeframe`, `contracts.py:59` |
| Exact stimulus | `validate_draft` already treats stimulus as contract-bearing (`research.py:52-54`); an equivalence claim must too. | `Measurement.stimulus`, `contracts.py:60` |
| Response codes **and** labels, positionally paired | `validate_measurement` requires `len(codes) == len(options)` and uniqueness of both (`research.py:39-42`); a receipt matching codes but not labels is not equivalent. | `Measurement.response_codes`, `response_options`, `contracts.py:61-62` |
| Routing | Routing is part of the frozen contract and is keyed by every code (`research.py:42`). | `Measurement.routing`, `contracts.py:63` |
| Denominator | A different denominator changes the estimand. | `Measurement.denominator`, `contracts.py:64` |
| Instrument version | The bank item must be identified by a version that can be revoked; `item_version` is already required on the equivalent branch. | `lookup['item_version']`, `research.py:160` |
| Approval identity and scope | Someone must be accountable for the claim, and for exactly which of the dimensions above. | Not present in any schema |
| Issuance and validity metadata | Needed to revoke and to detect expiry. | Not present in any schema |
| Context binding | The `packet` is passed in; without binding to assessment identity, confirmation id/revision and `packet_hash`, a receipt issued for one entrepreneur could be replayed for another. | `packet` (`research.py:157`), `packet_hash` (`research.py:15`) |

Because the workflow verifies the receipt on **every** branch, the same envelope must also be able to carry a `verified_no_equivalent` claim. That is a strictly harder claim: it asserts an absence, over a defined search space, at a defined time. It cannot be satisfied by "the table was empty" — see §7(iii).

---

## 6. `BD-01` — the smallest governed decision

### 6.1 The question

> Who, if anyone, may assert that a frozen PROJECT1 measurement is (a) equivalent to an approved question-bank item, or (b) without equivalent in an authoritative snapshot — and what store records that assertion?

### 6.2 Options

#### Option A — Hold: no bank, no QG

- **Authorises:** nothing new. It records that `ZERO_APPROVED_ENTRIES` is the accepted state and that QG remains uncomposed.
- **Does not authorise:** creation of any bank store; issuance of any equivalence or no-equivalence receipt; QG drafting; fielding; scientific acceptance; publication.
- **Who must sign:** PROJECT1 business owner (accepts the capability gap) and PROJECT1 research lead (accepts that no QG capability exists until a later decision).
- **Artefact recording the signature:** this document plus `artifacts/p2_bank_authority/verdict.json`, countersigned in the CP-00 blocker register; a `BD-01/A` decision line stating `QG: NOT_COMPOSED — ACCEPTED`.
- **What becomes unblocked:** nothing. It removes the ambiguity, which has value: downstream work stops asking whether a bank exists.
- **Cost:** `verified_equivalent` and `verified_no_equivalent` both stay permanently unreachable; no customer-survey research path exists.

#### Option B — Governed store and issuer, with drafting still held **(recommended)**

- **Authorises:** creation of one authoritative, append-only approved-item store in `Dss`, owned by a new `qgb_owner` role, read by a new least-privilege `qgb_reader` role; and designation of a named **equivalence issuer** (a human role, not a model) who may write approved items and issue equivalence receipts. It authorises the `verified_equivalent` branch only.
- **Does not authorise:** the `verified_no_equivalent` branch; QG drafting; fielding; scientific acceptance; publication; report release. `verified_no_equivalent` stays held behind a separate decision (`BD-02`) requiring an accepted snapshot, a comparison policy and an authorised verifier.
- **Scope of a receipt (explicit):** one receipt covers exactly one (construct, population, reference period, exact stimulus, response codes with labels, routing, denominator, instrument version) tuple, bound to the frozen measurement digest and to the packet context. A receipt that does not match all of those is not valid. Any change to any field voids the receipt.
- **Who must sign:** PROJECT1 research lead (scientific content and equivalence standard), PROJECT1 business owner (scope — what the business will accept as equivalent), and the DBA (schema, roles, grants, RLS). Three signatures, no delegation.
- **Artefact recording the signature:** a signed `BD-01/B` decision record naming the issuer role and the equivalence standard; the migration's `project1.migration_receipt` value; the role-provisioning receipt; and a register entry naming the first approved item and its approver.
- **What becomes unblocked:** the `verified_equivalent` reuse branch — an approved item can be reused as `REUSE_CANDIDATE` with no QG model invocation. Also unblocked: an honest answer to "does the bank contain anything?" for the first time.
- **Why recommended:** it is the smallest decision that creates real, revocable authority. It does not require inventing a comparison policy, does not require an accepted snapshot, and does not open the QG drafting path — the three things the repository is least ready for. It is also the only option that produces a positive test: once one approved item exists, `verified_equivalent` becomes reachable end-to-end, and every downstream assumption about the bank can be falsified against a real record rather than a stub.

#### Option C — Full enablement including `verified_no_equivalent`

- **Authorises:** everything in B, plus an accepted authoritative snapshot, a documented comparison policy, and an authorised verifier, such that `verified_no_equivalent` may be asserted and QG may draft.
- **Does not authorise:** fielding, scientific acceptance, publication, or report release — those remain separate gates regardless of this option.
- **Who must sign:** all three signatories from B, plus an independent scientific reviewer who accepts the comparison policy and the completeness argument for the snapshot.
- **Artefact recording the signature:** `BD-01/C` decision record with the accepted snapshot identity and its hash, the comparison policy version, the named verifier, and the `BD-02` record.
- **What becomes unblocked:** the QG drafting path.
- **Why not now:** none of its three prerequisites exist. There is no snapshot, no comparison policy, and no verifier. Accepting this option today would mean asserting absence from an empty set — precisely the error §7(iii) forbids.

### 6.3 The four mandatory questions, answered

| # | Question | Answer |
|---|---|---|
| (i) | Is an authoritative approved-question store created, and where? | **Under B and C, yes — one store, in `Dss`**, owned by a dedicated non-login role, append-only, RLS-enabled, default-deny, with a separate least-privilege read role for the runtime. **Under A, no store is created.** Under no option is the store `cq_bank_versions` (it is the CQ source bank, structurally unable to hold the fields an equivalence claim requires), and under no option is it `m2_review_question_versions` (a per-assessment candidate store whose only review decision is `APPROVE_FOR_REVIEW`). |
| (ii) | Who may issue an equivalence receipt, and with what scope? | **A named human equivalence issuer, not a model and not the runtime principal.** The runtime principal may only *read* receipts; it must not be able to mint one. Scope is one receipt per (construct, population, reference period, exact stimulus, response codes + labels, routing, denominator, instrument version) tuple, bound to the measurement digest and the packet context. See §5 for the full field list. |
| (iii) | May an empty authoritative snapshot ever support `verified_no_equivalent`? | **No.** An empty set is indistinguishable from an unpopulated, partially migrated, or mis-scoped set, and "no equivalent exists" is an absence claim that requires a defined search space, a comparison policy and an authorised verifier to be meaningful. The repository's own baseline states this: `P1_INTAKE_RECORD_20261117.md:91` — "It does not establish bank authority, equivalence, or that an empty bank proves no equivalent." This holds under **every** option, including C. Under C it is satisfied only once a non-empty accepted snapshot, a comparison policy and a named verifier all exist. |
| (iv) | Does QG stay uncomposed until then? | **Yes, under A and B.** QG remains uncomposed, and `verified_no_equivalent` is unreachable. Only C composes QG, and only after its prerequisites are signed. No option composes QG "provisionally". |

### 6.4 Recommendation

**Adopt Option B.**

Reasoning, in one paragraph: the repository is blocked not by a missing algorithm but by a missing *authority*. `ResearchWorkflow` is complete and tested against doubles; what does not exist is anyone entitled to say "this measurement is equivalent to that approved item". Option B creates exactly that entitlement and nothing more. It deliberately leaves the harder claim — absence — unasserted, because absence cannot be established from an empty set, and because QG drafting is the single highest-consequence action in the workflow: it is the only branch where a model writes new customer-facing research wording. Option B also produces the first real evidence the programme needs, since one approved item makes the `verified_equivalent` branch testable end-to-end for the first time.

---

## 7. What this blocks

| Blocked capability | Why it is blocked | Where it stops |
|---|---|---|
| **QG drafting** (`verified_no_equivalent` → `self.runner('QG', …)`) | Requires a bank that can return `verified_no_equivalent`, plus an `authority.require_drafting` implementation. Neither exists. Even with both, `verify_receipt` must pass first, and it has no implementation. | `research.py:165-169` |
| **`verified_no_equivalent` branch specifically** | Cannot be asserted from an empty or absent snapshot without a comparison policy and an authorised verifier. Under `BD-01` this stays true even after Option B is adopted; it needs `BD-02`. | `research.py:165-166`; §6.3(iii) |
| **Approved-item reuse** (`verified_equivalent` → `REUSE_CANDIDATE`) | Requires a bank returning `item_version` + `approval_receipt` that survives `verify_receipt`. No store, no issuer, no verifier. Unblocked by `BD-01/B`. | `research.py:159-164` |
| **Any production bank lookup at all** | `ResearchWorkflow` is never instantiated in `src/`, and no route reaches it. This is an independent blocker: even a perfect bank would not be called. | E5, E6 |
| **Scientific acceptance / fielding / publication of any QG output** | Denied by `no_authority()` on every path and by `validate_draft` returning a `DRAFT` candidate, never an approval. | E18; `research.py:46-62` |

Two of these blockers are structural and will survive `BD-01`: production composition (E5/E6) and the fielding/scientific-acceptance denial (E18). `BD-01` addresses only the authority gap.

---

## 8. What this document does not establish

- It does not establish that any measurement is scientifically valid, or that any construct is worth measuring.
- It does not establish that the CQ Q01–Q13 source bank is unsuitable for its own purpose — only that it is not a QG bank.
- It does not establish that `cq_bank_versions` is empty or populated; the runtime role was denied `SELECT`. Its contents are unverified from the runtime identity, by design.
- It does not establish provider reliability or model behaviour. No model was called in this workstream.
- It does not resolve the `DATABASE_URL` → `Final_Location_Analysis` discrepancy beyond recording it (§3.1); which database that URL is *intended* to name is a configuration question for the owner.

## 9. Reproduction

```powershell
# Contract and composition
Select-String -Path backend\src\sitewise\project1\research.py -Pattern "lookup|verify_receipt"
Select-String -Path backend\src -Pattern "class .*Bank|def lookup|def verify_receipt" -Recurse
Select-String -Path backend\src -Pattern "ResearchWorkflow" -Recurse

# Classification sweep
Select-String -Path backend\migrations\**\*.sql -Pattern "CREATE TABLE"
Select-String -Path backend -Pattern "approval_receipt" -Recurse -Include *.py,*.sql,*.md,*.json

# Dss (read-only, M2_DATABASE_URL) — see §3 for the exact session setup
```
