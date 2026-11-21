# CP-13 live-cloud verification and blocker resolution

Date: 19 November 2026, Asia/Kuala_Lumpur. Actual checkout: `merge_main_jed`,
HEAD `ba30035ecb24b80fa155cc7049cf3cdf94a67844`. Existing uncommitted work preserved.
CP-12 prerequisite is supported by `../cp12_20261118/g4_final_verdict.json` and
its final acceptance report. That historical result is separate from this CP-13 run.

**Final CP-13 verdict: BLOCKED. No live BDJ or Direct-QG provider call was made.**
One source-routing defect was corrected and deterministic BCB persistence was
verified in disposable PostgreSQL. The running application was not restarted or
activated. No original database records, runtime flags, approval artifacts,
migrations or provider budgets were changed. QJ was not dispatched or reactivated.

## Gates

| Gate | Result | Evidence / remaining prerequisite |
| --- | --- | --- |
| Actual implementation/configuration/schema inventory | PASS | `blocker_resolution/blocker_evidence.json`, `final_readonly/implementation_inventory.json` |
| Dedicated M2 source routing | PASS in source/tests; activation NOT EXECUTED | Corrected `project1_workflow.py` to use `get_m2_db` and authenticated `m2_session_for`; retained restricted-principal, database, driver, feature, rules and disclosure checks |
| BDJ rules adoption for current M2V1 | BLOCKED | D02 retires M2V1 rules; no applicable adopted replacement decision/version/hash/receipt |
| BDJ cloud dispatch | BLOCKED | Workflow router and provider disabled; no approved source-bound synthetic admission; no actual request or returned model |
| Deterministic BCB algorithm | PASS | Source hashes, confirmation, exact declarations, no cloud; controlled package assertions |
| BCB PostgreSQL persistence | PASS in disposable PostgreSQL | Six real HTTP/JWT/PostgreSQL tests; canonical packet readback, idempotency, stale/cross-owner/validity refusals |
| BCB for protected Fiesta in original Dss | BLOCKED / NOT EXECUTED | No validity policy configured; existing build PENDING, attempt_count 0, no context row. Protected assessment was not written |
| Direct-QG candidate engine and negative validation | PASS under controlled fixtures | Candidate-only authority, no invented numbers/routing drift; timeout/malformed/invalid-output tests |
| Direct-QG cloud dispatch and persisted candidate | BLOCKED | Provider disabled; exact new context/objective authorization unavailable; existing authorization belongs to another synthetic assessment |
| Current database/runtime-role compatibility | PASS for inspected requirements | Both restricted connections work; required tables present; inspected runtime grants true |
| Cloud model identity, usage, billing and live error handling | BLOCKED / NOT OBSERVED | Strict configured identity known; no new provider response. Controlled failure handling passes; token usage/cost unknown |

## What was actually fixed

The candidate workflow originally checked `DATABASE_URL` and used `get_db` for
M2 projection. The actual application keeps marketplace/auth in
`Final_Location_Analysis`, with M2 in dedicated `Dss`. Retargeting the main database
would have broken that separation.

The patch changes only this candidate router's source connection to existing
`get_m2_db` and owner-bound `m2_session_for(user.user_id)`. The latter rebinds the
same authenticated actor after rollback/commit. Exact `postgresql+psycopg2`, Dss,
non-superuser and non-BYPASSRLS checks remain. Existing model-assisted route tests
now override the new source dependency explicitly rather than opening original
Dss for a synthetic packet test. Source-routing and gate regressions are included
in **48 passing package tests**. Original authenticated live-cloud acceptance
remains unexecuted; changing source on disk does not prove server activation.

The reusable isolated runner gained one additive `--suite cp13-bcb` choice.
Existing default suites remain unchanged. No product endpoint, engine, table or
questionnaire wording was introduced.

## Exact BDJ authorization requirement

`api/v1/project1_workflow.py::model_assisted_gate` requires all of:

- `TOKENHARBOR_ENABLED` true;
- nonempty `PROJECT1_RULES_VERSION`;
- matching `PROJECT1_RULES_SHA256`;
- nonempty `PROJECT1_RULES_ADOPTION_RECEIPT`.

`project1/bdj.py::load_rules` additionally requires the version to exist in
`RULE_MODULES` and its source bytes to match the supplied SHA-256. A nonempty
string technically satisfies the receipt-presence predicate; it is **not proof
of Owner approval**, so no such string was manufactured.

Current loadable candidate modules:

| Version | Source SHA-256 | Applicability |
| --- | --- | --- |
| `BDJ-EXPLICIT-FORMAT-0.1-CANDIDATE` | `b2138e53fdd04429ed9225b1e97770e2d735cbc415350966c5e988dcd70d4836` | Legacy candidate; not an adopted M2V1 replacement |
| `BDJ-RULESET-0.2-CAND` | `42f7fef3bf2bb48255ab8eac406dfb8232923b76789dd065d693732e8bf2a061` | Legacy M2-* candidate used only by explicitly synthetic tests |

`docs/cp00_integration/PROJECT1_D02_RULESET_RETIREMENT_DECISION_20261117.md`
(SHA-256 `c9b7030b6ff7b2079f69b8ca3eabb7dff24e9d0f5b4fcfb66b9e9de733d01174`)
records **DECIDED—RETIRE**. It says M2V1 contradictions are structurally prevented,
the proposed gaps are not contradictions, and reopening requires a new decision.
Both retired M2V1 versions still fail `BDJ_RULE_ADOPTION_REQUIRED` in this check.

Required Owner evidence: an explicit, reviewed decision identifying which
instrument and finding behavior CP-13 may use, the applicable non-retired rules
version and exact file hash, scope (synthetic diagnostic versus adopted product),
and an approval/decision reference. To change M2V1 behavior beyond D02 requires a
reviewed contract/rule decision and implementation; merely naming a retired
version or approving a cloud call does not reopen it. A legacy synthetic
diagnostic cannot be represented as a successful current-M2V1 workflow.

`run_model_assisted` also requires an exact fingerprint-bound synthetic disclosure
packet. Normal `M2SourceProjection` supplies entrepreneur declarations but no
synthetic class marker. The verifier does not relabel saved records or bypass
this refusal. These missing admissions are not ERD failures.

## Effective configuration, provider and budget

- Main application: PostgreSQL / psycopg2, `Final_Location_Analysis`, role `postgres`.
- M2: PostgreSQL / psycopg2, `Dss`, role `p1_m2_runtime`.
- Workflow: PostgreSQL / psycopg2, `Dss`, login `p1ai_engine`, permitted restricted
  role `p1ai_runtime`; non-superuser and non-BYPASSRLS verified.
- `M2_UPSTREAM_ENABLED=true`; `M2_BCB_PERSISTENCE_ENABLED=true`.
- `PROJECT1_WORKFLOW_ENABLED=false`; `TOKENHARBOR_ENABLED=false`.
- Rules version/hash/receipt absent; BCB validity basis unset.
- These relevant cloud overrides are absent from the inspected backend environment
  files; effective false flags/empty approval fields come from current settings
  defaults. The running OpenAPI also omits the cloud-BDJ router.
- Provider implementation: `https://tokenharbor.ai/v1/chat/completions`, single
  `mimo-v2.6-flash:free`; strict model identity, no identity exception, structured
  JSON schema, temperature 0, maximum 4000 output tokens, current timeout 30s.
- Credential configured privately. Its validity was **not tested**, because no
  dispatch was permitted. No credential bytes were exported.
- Prompts: `BDJ-SOURCE-3-CAND`; `QG-PROPOSE-6-CAND`. BCB makes no cloud call.
- Cumulative budget: 50 authorized, 15 previously spent, **35 remaining**. CP-13
  spent **0**. The local policy's zero-dollar ceiling is not verified billing;
  actual usage and estimated cost are unavailable, not asserted as zero.

Existing QG authorization file binds assessment
`da90aa4a-f9cf-4145-9acf-7de36c9d6fad`, source fingerprint
`2857ede693a94be4c7f1ba17fa9df7540445b8d93b135badbe99427bb842230b`,
purpose `SYNTHETIC_QG_RESEARCH_EVALUATION`, max_attempts 1. Its presence does not
authorize another assessment/context/objective. It was not overwritten. A new
valid authorization must bind the actual selected synthetic facts and actor.

The current QG API/candidate projection does not expose an independent returned-model
receipt or provider token/cost envelope. That is an observability limitation for
the requested acceptance evidence. Configured model identity cannot substitute
for a returned identity.

## Actual BCB persistence proof

Evidence: `isolated_bcb/cp13_bcb_persistence.json`, `pytest.log`, `pytest.xml`,
HTTP exchange capture and `run.json`. Cluster: private port **55441**, database
`project1_m2_bcb_test`, created by existing infrastructure and stopped afterward.
Original Dss was never the write target. The source schema fixture and explicit
test-only validity/authentication inputs are identified in the evidence.

- Assessment: `ff82227b-4983-4fd7-babf-63b751555303`, revision **3**.
- Confirmation: `7ef18838-ff5b-4958-972a-6e34e4271214`.
- Confirmed uncertainty: `4297de09-301a-4147-9a0a-f8e11f5fa043`.
- Context: `5494c004-8cde-5890-9c3c-ecbfee267221`, builder `BCB-V1-1.1.0`.
- Packet hash: `9d3bb67143b47b68a517bf6ec205d253cca8ac5014674bf8f7fa606c6a579ebf`.
- HTTP **201** create; repeat **200** with same context ID; cross-owner **404**.
- SQL readback matches canonical packet, confirmation, revision and all effective
  answer references. Stale revision, absent validity policy and stale confirmation
  refusals pass. Cloud calls **0**.

These are actual PostgreSQL operations through the existing production builder,
binding resolver and store. Accounts, instrument, JWKS and the 90-day validity
basis are synthetic test fixtures. No production validity policy was adopted.

## Protected Fiesta: corrected observation

Marketplace `ad723b3f-5937-44f3-bb94-3d0f3048c034` remains actively linked to M2
`b28cd847-89f6-4994-adad-f79846f77c2e`. Current state is **revision 12, confirmed
revision 12, 12 answer rows**—not blank. This was already present in the first
package database snapshot at 03:53 local. Answer timestamps span approximately
03:12–03:40 local, before that snapshot. No actor/cause is inferred.

Confirmation `f653bbb8-de20-4d72-b321-f174b0e1c6fd` has snapshot digest
`1633bc59b115bcff5db2010aa0bc0e974ff4861c94f92d7b96d2c54a55c2762a`.
BCB build row is `PENDING`, attempt_count **0**, with no context row. This verifier
did not build/persist a context for it. Earlier commentary calling it revision 0
was incorrect and is superseded by the actual SQL evidence.

Read-only before/after fingerprints of **31 Dss tables plus the marketplace
assessment table** match within the captured verification windows. This proves
the observed state was preserved during those windows, not that it remained blank
since CP-12. GM Klang and historical Fiesta were not written, reset or repurposed.

## HTTP, failures and schema evidence

Read-only running API probes: `/health` **200**; unauthenticated M2 instruments
**401** (expected without a token); cloud-BDJ setup **404** (router absent).
Direct actual gate probes yield **503 WORKFLOW_CONFIGURATION_REQUIRED**,
`PROVIDER_NOT_CONFIGURED`, and `VALIDITY_BASIS_UNAUTHORIZED` without dispatch.
Controlled timeout, malformed/schema-invalid response, fabricated source quote,
unsupported question/amount, stale packet, and missing authorization are tested
against actual validators. They are not live provider failures.

All inspected required M2/BCB/workflow tables and runtime grants exist. The
recorded foreign keys include `project1_ai.runs.assessment_id → m2_assessments.id`
and the objective → confirmation → assessment chain for review candidates.
**No failing live INSERT/UPDATE or FK violation was observed; no ERD defect is
claimed.** BCB private INSERT/readback succeeds.

`project1_ai.attempts.attempt_slot` is absent in current Dss. Existing ledger code
supports the legacy first slot and explicitly refuses slot >1 without that
column. This is a schema-version limitation for multiple attempts, not proof of
a blocker for CP-13's one-attempt calls. No migration was applied and no failing
live slot-2 INSERT is claimed.

## Remaining prerequisites and acceptance

1. Resolve D02/applicable BDJ policy through a genuine Owner-reviewed decision;
   no implementer-authored receipt can substitute for it.
2. Establish exact-source synthetic disclosure for a separate permitted test
   assessment. Preserve the protected Fiesta and other named records.
3. Supply an adopted BCB confirmation-validity policy for live use. The test-only
   90-day value is not a default or approval.
4. After those requirements, activate the existing provider/workflow settings in
   the permitted environment and restart the relevant server to load the source
   fix. Do not retarget marketplace/auth to Dss.
5. Bind Direct-QG authorization to the actual persisted BCB facts and confirmed
   objective, with a bounded attempt count. Complete live provider response,
   candidate persistence and returned-model audit verification then.

Required sequence remains **M2 confirmation → cloud BDJ → deterministic BCB →
Direct-QG**, with explicit objective confirmation where required. The existing
deterministic pre-confirmation M2 validation is not represented as that cloud
BDJ call. No downstream fielding or report authority is granted.

**CP-13 remains BLOCKED, with source-routing correction and isolated BCB
persistence completed.** No cloud or report acceptance is fabricated.
