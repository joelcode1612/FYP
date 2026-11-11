# Inputs, outputs and exit criteria in real workflow order

This document separates the current executable source/UC bridge from the intended remaining workflow. All example source values and approvals in the lab are synthetic fixtures. They are not the adopted M2 questionnaire or research authorization.

| Step | Required input | Output and exit criterion | Current implementation / observed result |
|---|---|---|---|
| 1. Authenticate | Bearer JWT with verified signature, issuer, audience, expiry; active local entrepreneur profile | Verified actor UUID and authoritative role/status. Missing/expired/forged token → 401; wrong role/suspended → 403. | Existing JWT and profile code reused. Actual HTTP tests verify these outcomes with local signed test tokens. Client metadata claiming admin does not grant authority. |
| 2. Retrieve confirmed M2 | Server actor + assessment ID + explicit confirmation ID + expected revision | Current owner-scoped database record, authorized instrument, exact answer IDs/item versions/values, correct snapshot SHA256. Cross-owner → 404; stale/digest/source mismatch → 409; absent confirmation → 404. | New method on existing M2Service/repository; actual PostgreSQL/HTTP verified. Source text, including Unicode and injection-like text, remains byte-equivalent JSON data. No LLM. |
| 3. BDJ | Version-pinned relevant source, adopted rules/prompt/validator | Source-linked candidate concerns, bounded no-material-issue or abstention; original M2-04 unchanged | BLOCKED_AUTHORITY/CONFLICTING_IMPLEMENTATIONS. No arbitrary ruleset selection. This run seeded a confirmation fixture; it did not establish the full BDJ→review→confirmation path. |
| 4. Business Understanding / UC | Existing candidate version and explicit entrepreneur event/action/receipt | Existing SQL function atomically records canonical uncertainty and UC event; exact idempotent replay returns the same ID; changed replay, stale source or wrong owner leaves no partial writes | Real restricted SQL function verified on private clone, including replay on a new connection. New HTTP write bridge is wired but returns 503 on the deliberately unapproved private high port. Successful HTTP decision persistence on an approved B4 target is NOT_TESTED. |
| 5. Inspect UC history | Verified owner and explicit candidate-version UUID; event cursor | Historical version, canonical confirmed text and ordered events. A later withdrawal is visible; an old CONFIRMED event never grants current QJ authority | Actual HTTP reads verified after SQL confirmation and withdrawal. `history_only=true`, `qj_admission_status=NOT_EVALUATED`, `qj_handoff_authorized=false`. M2-17 and BDJ findings are not substituted. |
| 6. BCB | Current confirmed M2 + explicit confirmed UC + authoritative tenant/concept/GEO/source/purpose bindings and policy receipt | Existing builder emits minimal version-pinned/digested context, or scoped HOLD; no fabricated missing facts | Existing external BCB candidate identified; target adapters/adoption/purpose authority absent. Source retrieval above is not renamed BCB. |
| 7. QJ | Authorized BCB packet, separate confirmed uncertainty and adopted measurement contract | CUSTOMER_SURVEY_CANDIDATE with complete measurement fields, SCENARIO_ANALYSIS_REQUIRED, EXTERNAL_EVIDENCE_REQUIRED or HOLD. Profit uncertainty cannot become survey proof | DOCUMENTED_NOT_IMPLEMENTED in target. Required behavior exists in V1.1/V1.3/security V0.1; confirm governing adoption, then implement within current service architecture. No route fabricated here. |
| 8. Bank | Exact candidate measurement + real steward's item/version/equivalence/approval register | Verified equivalent version or BANK_UNVERIFIED withholding | Authority SOURCE_NOT_FOUND. Synthetic Q01–Q13/bank records confer no reuse or fielding permission. |
| 9. QG | Drafting permission + valid frozen QJ metadata + BCB/bank outcome | Candidate draft preserving stimulus/construct/population/timeframe/source/codes/routing, or rejection/abstention; independent science/Owner pending | DOCUMENTED_NOT_IMPLEMENTED. Never called here. |
| 10. Shared execution/audit | Adopted policy/prompt versions, work identity, disclosure approval and approved durable storage | Independent state axes; raw-output redaction; restart-safe idempotency and max six total BDJ/QJ/QG attempts | Missing target implementation and approved storage/adoption. No ephemeral substitute advertised as durable. Local test traces are evidence files, not canonical audit persistence. |
| 11. Scientific / Owner / publication / fielding / report | Independent disposition and explicit versioned authoritative grants | Each authority separately verified before its consequential action | NOT_AUTHORIZED. No automatic promotion from test success, model output, history, source confirmation or elapsed time. |

## Actual first successful source response (selected fields)

```json
{
  "assessment_revision": 1,
  "source_status": "CURRENT_CONFIRMED_SOURCE",
  "trust_class": "T2_AUTHENTICATED_ENTREPRENEUR_DECLARATION",
  "qj_handoff_authorized": false
}
```

The full executed input URL, exact source snapshot, digest, actor and actual response are in `http_traces.json`; the viewer displays them without executing source text. This excerpt omits synthetic identifiers for readability, not as a replacement for raw evidence.

## Entrepreneur messages to use when the future UI is connected

- Source retrieved: “Your confirmed business details are available for review.”
- Stale revision: “Your business details changed. Review and confirm the latest version first.”
- UC history: “Your uncertainty and decision history are available.” A withdrawn version should say “You withdrew this uncertainty.”
- Missing downstream prerequisite: “The next research step is waiting for its required review or setup.”

These are proposed presentation messages. No entrepreneur UI was changed by this backend checkpoint. Debug view should separately expose reason codes, source versions, validator outcomes and unresolved authority, without tokens, credentials or unnecessary raw customer data.
