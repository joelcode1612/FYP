# BDJ Live Execution — Verdict

**Task:** `PROJECT1-BDJ-LIVE-UI-INTEGRATION-V1.4`
**Date:** 2026-11-23
**Final verdict:** `BLOCKED`

---

## Verdict

**`BLOCKED`** — at checkpoint **BDJ-P01 (Execution and disclosure authorization)**.

No real TokenHarbour request was made. Zero outbound HTTP calls were issued. No
proposal was generated, relabelled or fabricated. The three historical
`SIMULATED` proposals were not touched.

---

## Why it is blocked, precisely

The directive requires an **exact assessment-bound cloud-disclosure
authorization** before any entrepreneur source is sent to a cloud model, and
forbids bypassing it. The repository contains that mechanism:

| Component | Location | Role |
|---|---|---|
| `RegisteredSyntheticBdjDisclosure` | `project1/disclosure.py:127` | Requires a server-side registry record for the exact `run_id`, matching owner, assessment, revision, confirmation, source fingerprint, endpoint, model, `rules_sha256`, `prompt_fingerprint`, `request_sha256`, `decision='APPROVED'`, `max_attempts=1` |
| `PrivateSyntheticTrialRegistry` | `project1/synthetic_trial_registry.py:13` | The registry that `get_server_authorization()` reads |
| `bdj_synthetic_execution.py` | `services/bdj_synthetic_execution.py:38` | The one caller that actually consults the registry |

The **objective-proposal route does not use any of it.** At
`api/v1/project1_objective_proposals.py:570` it composes:

```python
provider   = TokenHarbor(...)
disclosure = ObjectiveSimulationDisclosure.for_tokenharbour(model=provider.model, ...)
```

`ObjectiveSimulationDisclosure` binds *model*, *endpoint*, *schema version*,
*source fingerprint* and *context packet hash*. It performs **no**
assessment-bound registered authorization and consults **no** registry. That is
a source-binding check — and the directive states explicitly that a
source-binding check alone is not permission to disclose entrepreneur data
externally.

Two independent facts therefore hold the checkpoint:

1. `TOKENHARBOR_ENABLED` is unset, so `TokenHarbor` raises
   `PROVIDER_NOT_CONFIGURED` and the route returns a truthful 503 hold.
2. Even with the provider enabled, the route would dispatch on a source-binding
   check without an assessment-bound authorization. Enabling it would have
   **bypassed a governance control**, which the directive forbids.

I did not enable the provider, did not relax the disclosure gate, and did not
create a 19-question assessment whose data could not lawfully be dispatched.

---

## What was completed in this session

- **N01-GAP-01 link correction (done, verified).** `37bf879a` was bound to
  `032d3dde` (M2 V1, revision 17, 0 proposals). The stale link was revoked with
  a recorded reason and `053b3768` (M2 V2, revision 20, 3 proposals) was
  associated instead. Resolved link now reports `M2V2`, `identity_check=VERDICT`.
- **Instrument-aware binder (§C2).** `AssessmentLinkService._instrument_id()`
  selects through the audited `instrument_is_usable` gate instead of hardcoding
  `M2V1`; `resolve(instrument_code=...)` defaults to M2V1 so production is
  unchanged; `associate()` binds an existing record with ownership and
  instrument verification, refusing reassignment. 11/11 verification cases pass.
- **Versioned policy identity (§A2).** `objective_policy_fingerprint(provider=None)`
  reproduces the historical payload byte-for-byte; `provider='tokenharbor'` adds
  `objective-policy/2` plus `model_provider` and the pinned model, so a cloud run
  can neither reuse nor collide with a simulated run.
- **Provenance fallback (§A3, partial).** `_execution_block` no longer falls back
  to `simulated-objective-v1`; the last-resort label is `tokenharbor`.

---

## Second defect found (independent, still open)

On the historical assessment, Stage 3 now resolves the correct M2 V2 record but
the objectives panel refuses at its third gate:

> *No persisted business context is current for this confirmation (status PERSISTED).*

`persisted_business_context_service.py:303` computes
`source_is_current = compatible and revision == context_revision == confirmed_revision`.
Revisions agree (20/20/20), so `compatible` is false: `_reproduces()` cannot
rebuild context `fa3cb714` under the current builder (`BCB-V1-1.2.1`). The
context was harness-authored, not builder-produced. The governed refusal is
correct.

This is why the three proposals are still not visible, and it is the next thing
to fix: rebuild the BCB context for revision 20 through the real builder.

---

## Regression

| Suite | Result |
|---|---|
| `tests/project1` | 1526 tests, **25 failures, 0 errors, 3 skipped** — identical to the documented pre-existing baseline |
| `tests/project1/test_objective_proposal_route.py` | 25 passed |

`tests/api` reported 79 failures / 100 setup errors; no baseline for that suite
could be established in this session, so no claim is made about it.

---

## Required to unblock

1. ~~Compose a registered disclosure on the objective-proposal route.~~ **DONE**
   — `RegisteredObjectiveDisclosure` (`project1/disclosure.py`) is composed via
   `_compose_disclosure` behind `project1_objective_live_dispatch_enabled`
   (default **false**), and runs *in addition to* the source-binding gate
   through `_BothGates`. Neither gate replaces the other.
2. Record an owner decision for the exact synthetic assessment / revision /
   confirmation / source fingerprint / context packet hash / prompt / model,
   with `decision='APPROVED'`, `data_class='SYNTHETIC_NONHUMAN'`,
   `max_attempts=1`, `stage='BDJ_OBJECTIVE'`, in
   `project1_ai.synthetic_trial_authority`.
   **NOT DONE, deliberately.** That row *is* the owner's authorisation. Writing
   it myself would manufacture the very decision the control exists to require,
   so it must be provisioned by the operator through their own process.
3. Set `TOKENHARBOR_ENABLED=true` for the isolated process only. **NOT DONE** —
   pointless until (2) exists, and enabling a provider ahead of its
   authorisation is the bypass the directive forbids.
4. Rebuild the BCB context through the real builder so `_reproduces()` passes.
   **NOT DONE** — this is the blocking defect for the UI and for the route's
   own BCB gate.
5. Then run the 19-question journey and the single authorized dispatch.

### Why the findings-trial disclosure was not reused verbatim

`RegisteredSyntheticBdjDisclosure` binds `rules_sha256` and `request_sha256`.
The objective route runs `rules=None` by design and builds its body from a
prompt plus packet, so satisfying those two terms would have required inventing
a rules artefact and a pre-computed body hash. `RegisteredObjectiveDisclosure`
therefore binds only terms that genuinely exist — owner, assessment, revision,
confirmation, source fingerprint, context packet hash, prompt version, prompt
fingerprint, endpoint, model — and adds the receipt and live-current-source
re-checks. It is not a weaker gate; it is the same gate with truthful terms.

## Governance status (unchanged)

`POLICY_ADOPTED = False` · scientific measurements approved **0/6** · no
objective admission · no Direct-QG authorization · no customer fielding · no
production activation · no access to `Dss@5432` or `Final_Location_Analysis@5432`.
