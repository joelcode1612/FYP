# CP08 — Source-bound business explanations: verification checkpoint V0.1

Date: 11 November 2026, Asia/Kuala_Lumpur. Target: existing `FYP/backend`, branch `merge_main_jed`, HEAD `bd386a7c203ea3688ce4df3838570eda325f0734` plus preserved working changes.

## Feasibility verdict

The proposed division can work as a bounded explanation pipeline. Deterministic BDJ identifies only supported candidate conditions; reviewed knowledge supplies general guidance; retrieval chooses permitted references; a separate Explanation Context Builder pins the evidence; an optional cloud model proposes wording; validators and reviewers control acceptance. BCB preserves qualified business context and never promotes a candidate explanation into a fact.

Three limits are essential:

1. `PENDING_PROJECT_REVIEW` is not reviewed evidence. Fetching an official page, assigning an ID or testing a model does not approve the reference. Pending/revoked/expired/wrong-purpose references must be excluded before model invocation in the reviewed-evidence path.
2. Exact citations and valid JSON do not prove semantic entailment. Code can verify IDs, versions, excerpt integrity, approved claims and explicit prohibited claims. Unrestricted paraphrases still require semantic adjudication; the same model cannot independently approve itself. Controlled, reviewed template wording can be released under its own existing policy; no such production template policy is invented here.
3. General U.S. guidance does not establish a Malaysian café's expenses, profitability, local conditions, or viability. No financial value is inferred from M2 bands, missing values or model knowledge.

## Reconcile and reuse before implementation

| Component | Current evidence | Action / verification |
|---|---|---|
| M2 source and UC | CP07 existing M2Service, repository, JWT and UC gateway/history | REUSE; repeat private PostgreSQL regression. Do not duplicate confirmation or uncertainty. |
| Deterministic BDJ | Domain `BDJ-EXPLICIT-FORMAT-0.1-CANDIDATE` vs db `BDJ-RULESET-0.2-CAND`; service imports incompatible symbols | Preserve both; diagnostic tests may expose differences, but runtime adoption still requires an exact selected ruleset/version. New responsibility split does not resolve this specific conflict. |
| Research Evidence Library | No canonical reviewed-reference store/interface found in scoped current source inventory | CREATE missing adapter/storage only within the approved architecture after its owner, review event, rights and schema are pinned. Pending sample below remains pending. |
| Retrieval | No owning business-reference retrieval implementation found | Prefer deterministic rule/category + relevance/purpose/version filters first. Similarity can select candidates; it cannot grant review/rights. |
| Explanation Context Builder | Business-evidence explanation packet not found in current backend | Add this distinct responsibility using existing M2/BCB ports when authority is reconciled; do not call it another BCB or pass all M2 fields to the provider. |
| Existing ExplanationService | `src/sitewise/services/explanation_service.py` currently performs property-assessment SHAP explanations with additivity checks and existing persistence | Preserve it. Business-finding explanation is a different use case; do not replace the SHAP path or claim free-text persistence proves business-evidence support. This current inspection supersedes older descriptions of this class. |
| Existing BCB | External `BusinessContextBuilderV1`, `business-context-package/1.0`, `BCB-V1-1.0.0-SANDBOX` | ADAPT existing candidate after adoption/bindings. It has `packet_hash` and snapshot identity, not a persisted canonical `context_id` lookup. Do not rename confirmation ID to context_id or silently add fields to a frozen schema. |
| Cloud execution / durable audit | No adopted shared backend LLM runner or attempt ledger found | The qualification tool below is test code, not a new production LLM service. Later reuse one shared adapter/ledger; no migrations or duplicate runtime in this checkpoint. |

## Reference-record contract to verify

The user example `FIN-BREAK-EVEN-001` stays `PENDING_PROJECT_REVIEW`. Extend the proposed reference record with version, exact canonical URL and locator, retrieved/content hash, excerpt IDs/hashes, reviewed claim IDs/text, prohibited claims, jurisdiction/applicability, rights/allowed purposes, review actor/event/time, valid-from/expiry/revocation and supersession. An approval flag from request JSON or a model is not authority.

The SBA legacy page gives a cost/price-based break-even formula and describes estimates. Its general guidance can support cost/price dependencies; it does not provide this café's inputs or establish its outcome. Official-source verification and Project1 review are separate states.

Sources checked:

- [SBA break-even guidance](https://legacy.sba.gov/business-guide/plan-your-business/calculate-your-startup-costs/break-even-point).
- [TokenHarbor chat API](https://tokenharbor.ai/docs/api/curl).
- [TokenHarbor callable-model listing](https://tokenharbor.ai/docs/api/models).
- [TokenHarbor free-route privacy terms](https://tokenharbor.ai/privacy).

Only public source identity and the narrow relevant guidance are used here. A fresh authenticated model listing returned the exact requested `mimo-v2.6-flash:free` ID. This proves catalog access at that time, not successful inference or guaranteed future availability.

Free-route terms allow retention and provider-specific use, potentially including provider training; account opt-in may be required. Therefore the requested cloud tests use fictional records and an explicitly synthetic test reference, never actual entrepreneur/customer data. No account setting is changed, paid fallback selected or model substituted.

## Workflow: input → output → exit criterion

| Step | Input | Output | Exit criterion / expected failure |
|---|---|---|---|
| CP08-00 Source/auth | Verified actor, permitted purpose, current confirmed M2/version and disclosure scope | Exact source references and minimized facts | Ownership/currentness/integrity pass; otherwise zero calls. Existing CP07 APIs remain the source owner. |
| CP08-01 BDJ | Authorized M2 + declared source records, exact adopted deterministic rules | Candidate finding ID/rule version/source answer IDs, or bounded no-issue/abstention | No rewritten M2, invented input or claim that all business risks were detected. Adoption conflict stays explicit. |
| CP08-02 Library | Existing reference/version plus independent review/rights/applicability | Eligible reviewed reference or no eligible evidence | Pending/revoked/stale/wrong-purpose excluded; no automatic approval because publisher is official. |
| CP08-03 Retrieval | Candidate rule/category and eligible references | Minimal excerpt/claim set with selection reason and exact versions | Relevance and permitted claim scope established; no missing evidence fabricated. |
| CP08-04 Explanation context | Exact finding and answer records, permitted excerpts, trust labels, rule/policy/template versions | Separate immutable explanation packet + fingerprint | Single scope/version; source text stays data. Candidate explanation is not mixed into business facts. |
| CP08-05 Optional LLM | Fixed system instructions + minimized serialized data packet | Candidate statements with claim IDs, exact citations and limits | Only requested endpoint/model; no tools/writes/authority. HTTP200 alone is not a pass. |
| CP08-06 Validator | Raw output + frozen input + allowed claim/excerpt IDs | Engineering checks + semantic-review-required, rejection or fallback | Schema/citations/source integrity and explicit boundaries checked. Semantic entailment is not fully automated. |
| CP08-07 BCB/consumer | Authorized source context + separately marked candidate metadata where contract permits | Business core remains source-bound; advisory explanation remains separately pending | No unapproved explanation becomes fact; no QJ, science, Owner, fielding or report permission inferred. |
| CP08-08 Audit/reuse | Source/reference/prompt/model/validator identities and result | Reproducible attempt evidence, invalidation and bounded reuse | Reauthorize on every reuse; source/reference/rights changes invalidate dependent output. A test run log is not the approved production ledger. |

## Planned tests and acceptance thresholds

Offline gate/validator tests must all pass before live qualification. Include a valid packet; pending/revoked/expired/wrong-purpose reference; cross-owner; stale source; missing disclosure; injection data; unknown citation; altered quote; invented approval; explicit profit verdict; malformed output; omitted limitations; raw source preservation; distinct unknown/not-applicable/absent states; exact fingerprints; changed reference invalidation and separate advisory storage.

Live design: fixed model and prompt, **three cases × two fresh requests = six completion requests maximum**, no automatic repair calls or paid fallback. Cases: a bounded break-even explanation; injection-like M2 data; a source explicitly marked `NOT_APPLICABLE` which must not be described as missing. Same requested settings are recorded, but temperature zero is not a guarantee of deterministic output. Every response is retained, including failures. Compare contract checks, citations, unsupported additions, limitations, output variation and human-readable meaning. Semantic review here is author inspection only, not independent scientific acceptance.

The test runner records an attempt before each POST. A timeout/unknown outcome or auth/rate-limit/provider error stops that run; do not blindly retry. This finite experiment log does not implement the still-missing durable shared production ledger or alter the CP07 global execution contract.

Results must report actual n/N for completed outputs and test checks, with unknown/failed/untested cases visible. One model, six authored prompts and synthetic tests do not establish population reliability, comprehensive injection resistance or scientific validity. Expected outputs in examples are not actual model outputs.

## Expected example, not a live result

Input: entrepreneur declares “We calculated break-even in three months”; no cost/pricing calculation supplied; candidate finding linked to M2-04; an eligible SYNTHETIC test reference discusses cost/price dependencies.

Expected candidate explanation: “You stated a three-month break-even estimate. The supplied record does not verify that calculation. A break-even estimate depends on cost and pricing inputs. This does not establish whether the café will be profitable.” Required citations and scope limitations remain attached. Wording may vary; changing the conclusion or inventing inputs is a failure.

For the real `FIN-BREAK-EVEN-001` while its review is pending: expected outcome is no admitted reference and zero model calls on that reviewed-evidence path, with a neutral message that the supporting reference is awaiting review.

## What is needed from the user

The requested key was supplied and is used only transiently for authorized tests; never included in source, prompts, logs or deliverables. No further key is needed unless it fails or expires. Remaining decisions for real integration: exact BDJ adoption; reference-review owner and allowed purpose/rights; BCB ownership/bindings/context identity; approved shared execution/audit storage and retention. The checkpoint can qualify synthetic behavior while these stay unresolved. Dss changes, migrations, scientific acceptance, respondent fielding and report release remain unauthorized.

## Deliverables and current scope

`tests/cp08/qualification.py` is a runnable qualification tool, not production implementation. It produces raw requests/responses, validation outcomes and run evidence. `RESULTS.md` records actual executed outcomes separately. The existing backend application services/routes, BDJ rules, UC gateway and BCB candidate are preserved during this checkpoint.
