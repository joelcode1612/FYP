# Defects and evidence gaps found during CP-01 → CP-04

Found 2026-11-25 while freezing the baseline and building the evaluation
workspace. Each entry states how it was verified. Nothing here is fixed by
weakening a check, and nothing is marked resolved.

Numbering is local to this workstream (`DEF-nn`) and is **not** the DD- numbering
in `backend/var/e2e/pg18/deferred_defects.md`. Where an entry belongs in that
register, it is cross-referenced.

---

## DEF-01 — Direct-QG cannot dispatch at all, regardless of credentials

| | |
|---|---|
| **Severity** | Blocking for CP-05 and CP-09 |
| **Status** | `OPEN` (pre-existing; not introduced here) |
| **Verification** | Code reading, confirmed at three call sites |

`qg_fixed_options.require_verified_respondent_path()` raises
`QG_FIXED_OPTION_ADMISSION_UNAVAILABLE` **unconditionally**. It is reached from:

- `DirectQgService.evaluate()` — called on every invocation;
- `DirectQgService.prepare_candidate()` — whenever `fixed_policy_resolver` is not
  callable, which is the default (`None`);
- `direct_qg_service.py` line 104 and 145.

Consequence: the production path refuses before any provider call. This is why
`max_tokens`, credentials and timeouts are all irrelevant to QG today, and why
CP-05 cannot measure the *application* Direct-QG latency without either a
registered `fixed_policy_resolver` or an authorised evaluation harness that
composes the same `qg_input`.

The hold is deliberate and is **not** to be removed to make a benchmark run. The
evaluation harness in this workspace therefore calls the prompt and the
validators directly and records that it is not exercising `DirectQgService`.

**Why it matters for this workstream:** any claim of the form "Direct-QG
generation works end to end" is false until this is resolved. CP-09 requires
integration, so this is on the critical path.

---

## DEF-02 — The prohibited-claim scan rejects the honest disclaimer

| | |
|---|---|
| **Severity** | Medium — pushes responses toward vaguer wording |
| **Status** | `OPEN` (production validator unchanged) |
| **Verification** | Reproduced deterministically, 0 network calls |

`qg_contract.PROHIBITED_CLAIM_PATTERNS` includes `\bwillingness[- ]to[- ]pay\b`
and is applied to `construct_interpretation + question +
denominator_specification`.

A response whose `construct_interpretation` reads

> Measures stated acceptability of one exact priced offer; does not measure
> maximum willingness to pay.

is refused with `PROHIBITED_WTP_CLAIM`. The sentence is the *correct* scientific
statement, and the validator rejects it for naming the thing it disclaims.

Observed in the fixture gate: `qg_complete_offer` golden output,
`FIXTURE_DEFECT_WRONG_CODE` → actual `PROHIBITED_WTP_CLAIM` where
`QG_FIXED_OPTION_MISMATCH` was expected (the claim check runs first and masked
the later check).

The same class of problem appears in the additive v2 BDJ contract, where the
first implementation scanned `interpretation_limitations` and rejected every
golden output for the same reason. That one was corrected inside this workspace
(limitations are no longer claim-scanned); the production QG validator was
**not** touched.

**Options, for the owner — not decided here:**

1. Exempt negated contexts (`not`, `does not`, `cannot`) from the scan.
2. Apply the scan only to affirmative claims, and require limitations to be
   non-blank instead.
3. Keep the check and accept that models will avoid the phrase — which means the
   most precise limitation wording is unavailable.

Option 3 is the status quo. It is defensible; it is also the reason a QG
limitation often reads vaguely.

---

## DEF-03 — Declaration context the prompt forbids using is still paid for

| | |
|---|---|
| **Severity** | Low–Medium (cost, not correctness) |
| **Status** | `OPEN`, **share unmeasured** |
| **Verification** | Code reading only |

`m2v2_projection` supplies `answer_display` and `response_meanings` on every
declaration. `BDJ-OBJECTIVE-4-M2V2-CAND` explicitly forbids quoting either:

> Never quote the question text, never quote `answer_display`, and never quote a
> label from `response_meanings`; those are readable renderings, not the declared
> value.

So the model is charged for context it is instructed not to use, and which
exists to make a *human* reading easier.

**The share is not quantified here.** The synthetic fixtures do not populate
these fields, so a fixture-based percentage (3.9%) measures only their empty
serialisation and would be misleading. A real-packet measurement is required
before this is claimed as a saving — see CP-06.

---

## DEF-04 — Direct-QG latency exceeds the proposed targets

| | |
|---|---|
| **Severity** | High for the acceptance criteria |
| **Status** | `OPEN` — measured, not remediated |
| **Verification** | Recorded live dispatches, n = 8 |

From `deliverables/phase2/CLOUD_AB_EVALUATION_RESULTS.json`:

| | BDJ (n=6) | Direct-QG (n=8) | Target |
|---|---|---|---|
| Median | 5 564 ms | **20 107 ms** | 15 000 / 10 000 ms |
| Max | 9 734 ms | **30 037 ms** | 30 000 / 25 000 ms |

The QG maximum is 30 037 ms against a 30 s configured timeout and was recorded as
`E_PROVIDER_TIMEOUT_OUTCOME_UNKNOWN`. Completion tokens track latency closely
(1 065 → 10.9 s; 3 818 → 27.3 s), so output volume is the dominant term.

Caveat: these runs used `QG-PROPOSE-6/7-CAND`, not `QG-FIXED-OPTION-4-CAND`. The
number is evidence about the task shape and the model, not about V4.

**Implication:** the 10 s / 25 s Direct-QG targets are not achievable at current
output verbosity. `QG-FIXED-OPTION-5-CAND` therefore carries explicit brevity
budgets, and CP-05 must measure whether they are enough. If they are not, the
target is the thing that is wrong, not the measurement.

---

## DEF-05 — Evidence cited by the prompt comments does not exist

| | |
|---|---|
| **Severity** | Low for behaviour, high for audit |
| **Status** | `OPEN` |
| **Verification** | Directory listing |

`prompts.py` cites four evidence files for the QG revision history:

```
artifacts/cp08_qg_live/live_qg_evidence_CP08-EVAL-7.json
artifacts/cp08_qg_live/live_qg_evidence_CP08-EVAL-8.json
artifacts/cp08_qg_live/live_qg_evidence_CP08-EVAL-9.json
```

`artifacts/cp08_qg_live/` exists but is **empty**. The revision rationale in the
code is therefore unbacked by the artifact it names. The rationale may still be
true; it cannot currently be checked.

---

## DEF-06 — The available A/B evidence is for different prompt versions

| | |
|---|---|
| **Severity** | Medium — a labelling trap |
| **Status** | `OPEN` (documented, so it cannot be mistaken) |
| **Verification** | Read of `CLOUD_AB_EVALUATION_RESULTS.json` |

That run compared `BDJ-OBJECTIVE-3-CAND` vs `4-CAND` and `QG-PROPOSE-6-CAND` vs
`7-CAND`. It did **not** compare `BDJ-OBJECTIVE-4-M2V2-CAND` against
`QG-FIXED-OPTION-4-CAND`, and neither V5 candidate existed then.

Every number taken from it is labelled `RECORDED_PRIOR_RUN_NOT_REMEASURED` in
`results/EXISTING_EVIDENCE_BENCHMARK_20261125.json`. Reusing those latencies as
if they described the V4/V5 pair would be a fabricated comparison.

---

## DEF-07 — Provider dispatch is disabled in the current environment

| | |
|---|---|
| **Severity** | Precondition, not a defect |
| **Status** | `OBSERVED` |
| **Verification** | `config.provider_*()` resolved at runtime |

```
tokenharbor_enabled      = False
structured_mode          = json_schema
model                    = deepseek-v4.1-flash-1017
timeout_seconds          = 30
max_tokens               = 4000
cost_ceiling_usd         = 0.50
model_identity_exception = False
```

Every dispatch path fails closed with `PROVIDER_NOT_CONFIGURED`. Enabling it is an
authorisation decision (control **C2** in the tracker's governance note), not a
configuration tweak, and was not done here.

---

## Self-caught during CP-04

One defect in this workspace's own code, recorded for transparency rather than
counted above:

`contracts_v5` compared `measurement_construct` against the registry constructs
without translating underscores to spaces, so
`STATED_ACCEPTABILITY_OF_AN_EXACT_SPECIFIED_PRICED_OFFER` would have passed the
collision check against the O3 construct. Fixed before the gate was accepted; the
fixture `bdj_priced_hypothesis` negative now proves the check fires.

---

## Summary

| ID | Subject | Blocking | Fixed |
|---|---|---|---|
| DEF-01 | Direct-QG dispatch hold | CP-05, CP-09 | No |
| DEF-02 | Claim scan rejects disclaimers | No | No (owner decision) |
| DEF-03 | Unused declaration context | No | No |
| DEF-04 | QG latency vs targets | Acceptance | No |
| DEF-05 | Missing cited evidence | Audit | No |
| DEF-06 | Prior A/B is a different pair | No | Documented |
| DEF-07 | Provider disabled | Live pilot | No (authorisation) |
