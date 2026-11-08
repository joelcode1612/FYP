# `GEOHD-03` — the 88 documentary checks and the 41 unexecuted Jaspr tests, measured

**Package:** `GEOH_INDEPENDENT_CHALLENGE_DELTA_20261030` · **Date:** 2026-10-30
**Status:** `PROPOSED_FOR_OWNER_ADOPTION` — documentary analysis only.
**Signatures in this file:** 0. **Jaspr acceptance tests executed:** 0 of 41 (now 49 — see §8). **Readiness level reached: L0** (`GEOH-05` AC-00: L0 does not imply L1).
**Every number in this file is machine-derived** from the reproduced harness log and the two CSVs in `data/`. No number here is quoted from a Markdown file. Recomputation commands: §9.

---

## 1. Why this file exists

The independent challenge register (`inputs/GEOH_INDEPENDENT_CHALLENGE_AND_TARGETED_RETURN.md`, SHA-256 `9db48f4af954ce2c0a995d27a008df1a045db484182a5cf6815df5813749d005`) says, in `GEOH-REV-07`:

> Supply fixtures/harness/log to independent QA; verify 9/9 and rerun 88 selectively … no unnecessary re-run of 20 earlier geometry experiments

and the Owner's directive repeats the requirement as a bullet:

> Preserve the distinction between 88 documentary-harness checks and the 41 unexecuted Jaspr acceptance tests.

The distinction is real, but the predecessor never measured *how* the two populations relate. This file measures it: which harness checks a test actually cites, which checks no test cites, which checks are cited only by a glob that could not detect a single-case regression, and how many of the 88 verdicts are independent propositions. The answer weakens the headline "88" without weakening the contract — and the contract was already refusing the claims that mattered.

**What this file is not:** it is not a test report. `0` of the 41 (49 after §8) acceptance tests have been executed against any application. The application does not exist.

---

## 2. The two populations, defined from bytes

| | documentary harness check | Jaspr acceptance test |
|---|---|---|
| where it lives | `_verify/harness/geoh_contract_check.py` (digest `d0c834c4…`) | `GEOH-05` §4 table, 41 rows |
| what it reads | `fixtures/GEOH_SYNTHETIC_FIXTURES.json` (`2c937661…`) + the contract's own text | nothing yet — no application |
| verdict vocabulary | `HOLDS` / `VIOLATED` | `NOT_EXECUTED` / `NOT_VERIFIABLE` / `BLOCKED_SOURCE` / `ABSENT_INPUT` (`GEOH-05` AC-01, AC-02) |
| emitted count | **88** | **41 specified, 0 executed** |
| final line of its log | `VERDICT: PASS (contract self-check only; adopts nothing)` | — (no log exists) |

Both live numbers are in `_verify/logs/geoh_contract_check.log:166-167`: `checks: 88   HOLDS: 88   VIOLATED: 0` and the `PASS` line above. The two are **different kinds of object** and a reader who merges them gets a false assurance — the reproduced log's literal `PASS` token is the mechanism by which that merger happens (recorded as `D-R-24` in `GEOHD-01` §8.3).

---

## 3. The 88 are not 88 propositions

`data/HARNESS_CHECK_TO_TEST.csv` has 88 rows, one per emitted id. Grouping each id by its `G-<n>` prefix:

| family | instances | what varies per instance | cited by a specific id? |
|---|---|---|---|
| `G-06-*` | 7 | centre class (`CC-1`…`CC-7`) | **0 of 7** |
| `G-07-*` | 9 | requested radius (400 / 500 / 800 / 1200 / 5000 / 5000.5 / 6000 / 0 / −800 m) | **0 of 9** |
| `G-09-*` | 5 | measured distance × tolerance (the float boundary case) | 5 of 5 |
| `G-11-*` | 5 | `(R, tolerance)` pair → venue count admitted | **0 of 5** |
| `G-13-*` | 9 | competitor snapshot → state (S1…S7) | 2 of 9 |
| `G-16-*` | 5 | S1…S5 body: "contains no digit" | **0 of 5** |
| `G-17-*` | 5 | S1…S5 body: "carries no banned phrase" | **0 of 5** |
| `G-23-*` | 5 | cross-candidate comparison case → permit/refuse | 3 of 5 |
| `G-24-*` | 11 | administrative resolution case (`ADM-A1`…`ADM-P`, `ADM-OUTSIDE-PILOT`) | **0 of 11** |
| `G-30-*` | 3 | display-vs-study radius case (`DR-1`…`DR-3`) | **0 of 3** |
| **subtotal parameterised** | **64** | from **10** families | — |
| **standalone assertions** | **24** | one `check()` call each | — |
| **total emitted** | **88** | `64 + 24 = 88` | — |

**Consequence (asserted as `D-C-21`, `GEOHD-01` §8.3):** adding one row to `admin_resolutions` would make the headline "89" while changing **no rule**. The number 88 is an *emission* count. The count of distinct propositions is bounded below by 34 (24 standalone + 10 families collapsed) and above by 88 (each fixture instance counted separately); **this package does not decide which**, and says so rather than quoting 88 as if it were 88.

---

## 4. Which checks no test cites

`GEOH-05` §4's Today column cites harness ids. Parsing every citation against the reproduced log, **77 of 88** checks are cited by at least one test and **11 are cited by none**:

| check id | verdict | what it proves | why the gap matters |
|---|---|---|---|
| `G-10` | HOLDS | an unset tolerance is refused rather than defaulted | the exact behaviour `ODR-3-tolerance-policy` hinges on has no test row |
| `G-11-R400-T0_0` | HOLDS | R=400, tol=0.0 admits 2 venues | the 5 venue-count rows are all uncited |
| `G-11-R500-T0_0` | HOLDS | R=500, tol=0.0 admits 3 venues | ditto |
| `G-11-R800-T0_0` | HOLDS | R=800, tol=0.0 admits 7 venues | ditto |
| `G-11-R800-T0_5` | HOLDS | R=800, tol=0.5 admits 7 venues | ditto — and this is the row `REV-02` reads as the 0.5 m example |
| `G-11-R1200-T0_0` | HOLDS | R=1200, tol=0.0 admits 9 venues | ditto |
| `G-12` | HOLDS | list size is monotonic in R at fixed tolerance | monotonicity is untested by any acceptance row |
| `G-15` | HOLDS | state derived from coverage, not list length | `GEOH-05` AC-03 calls this "the anti-cheat" — no test cites it |
| `G-21` | HOLDS | **F-4 reproduced**: frozen S4 copy carries a digit under the S1–S5 rule | the defect `ODR-3-copy-option` decides is uncited |
| `G-31` | HOLDS | no provenance date appears in an S1–S5 body | directly relevant to `REV-06` / Option B — uncited |
| `G-33` | HOLDS | an unset tolerance recorded as `UNSET`, not a number | `ODR-3-tolerance-value` residue — uncited |

`G-15` and `G-21` are the two worth reading twice: the predecessor's own AC-03 names `G-15` as the assertion that catches the empty-array-becomes-zero defect, and `G-21` is the reproduction of the GM-12 wording defect — yet neither appears in any of the 41 test rows. A QA reviewer working from `GEOH-05` §4 alone would not run them.

---

## 5. Which tests cite nothing

**30 of 41** tests cite at least one harness check; **11 cite none**. Their Today cells carry a *status word* where an id belongs:

| test | finding | Today cell, verbatim | status word type |
|---|---|---|---|
| `GEOH-T-05` | N1-a `at` vs `queried` | `specified` | specified |
| `GEOH-T-07` | N1-c block boundary undefined | `OPEN - no option adopted` | open |
| `GEOH-T-08` | UI-01 numeral/qualifier widget | `not executed` | not executed |
| `GEOH-T-22` | C-R2 forbidden output forms | `specified` | specified |
| `GEOH-T-31` | ODR-V21A-04 unverifiable location | `specified` | specified |
| `GEOH-T-32` | R-1…R-8 adapter | `BLOCKED_SOURCE` | blocked source |
| `GEOH-T-33` | GM-GEO-22 polygon vs circle | `specified` | specified |
| `GEOH-T-34` | GM-GEO-20 union not sum | `specified` | specified |
| `GEOH-T-35` | GEO-TILE attribution and viewport | `not executed` | not executed |
| `GEOH-T-37` | GM-GEO-19 de-duplication | `specified` | specified |
| `GEOH-T-40` | SA-1/SA-3/DP shared-area figure | `ABSENT_INPUT` | absent input |

Six of the eleven (`T-05`, `T-22`, `T-31`, `T-33`, `T-34`, `T-37`) are ordinary rules with **no harness coverage at all**; `AC-05` correctly reserves `BLOCKED_SOURCE` for `T-32` alone and `ABSENT_INPUT` for `T-40`. Nothing here is a misstatement — it is an unmetised gap, and it is the part of the 88-vs-41 distinction that a reader counting only the big numbers cannot see.

---

## 6. Citation precision, and the one dangling token

Every citation form found, and the count of checks whose coverage is *only* imprecise:

| measure | value |
|---|---|
| checks cited by at least one test | **77** |
| cited by a **specific** emitted id | **31** |
| covered **only** by a shared glob / range / dangling prefix | **46** |
| distinct checks referenced in total | **77** (= 88 − 11 unreferenced) |
| dangling citation tokens | **1** |

The dangling token: `GEOH-T-23` cites `` `G-24, G-25` `` — but `G-24` is not an emitted id. It expands to **11** children, so the row's resolved evidence set is 12 checks. The intended citation is ambiguous between "`G-24-ADM-P-PARTIAL-GEOMETRY` specifically" and "the whole family".

**Three computable consequences of imprecise citation** (all derived from `data/`, all `HOLDS`-free statements of fact):

1. **`GEOH-T-12`, `GEOH-T-14`, `GEOH-T-15` resolve to the *identical* 9-check set** (`G-13-*`). Those three rows are supposed to cover S2 (query failed), S4 (zero, coverage UNKNOWN) and S5 (zero, coverage PARTIAL) — three states whose *differences* are the whole point of AC-04. A regression in S4 alone cannot be attributed to `T-14` by this citation, because `T-12` and `T-15` cite the same nine verdicts.
2. **`GEOH-T-24`'s evidence set (11) is a strict subset of `GEOH-T-23`'s (12).** Intersection = 11. `T-24` (Case A1/A2 — the *identity* axis) and `T-23` (`S_PARTIAL` geometry — the *source* axis) are therefore indistinguishable by harness output. This is `GEOH-REV-08`'s S/I conflation, visible in the citation table before any code exists.
3. **`GEOH-T-24`'s glob includes `G-24-ADM-P-PARTIAL-GEOMETRY`** — the very fixture that enforces the `partial`-drawn behaviour which `REV-01` reports as contradicting `DC-21`. A green `G-24-*` today therefore *includes* the assertion of the contradiction. Fixing `REV-01` must change that fixture's expectation, and `T-24`'s cell must be re-pointed at emitted ids (`GEOHD-07.4`).

---

## 7. The 41 tests by evidence tier

`data/TEST_EVIDENCE_TIER.csv` — one row per test, `evidence_tier` derived by the rules in §7.1, `executed_against_an_application` = **no** for all 41 (`D-C-22` verifies both columns are populated and that no row can read as a pass).

**7.1 tier rule (proposed as `AC-12`, §8):** `SPECIFIC_CITATION` if ≥1 resolved id exactly matches an emitted check id; else `IMPRECISE_CITATION_ONLY` if the row cites only globs/ranges/prefixes; else `NO_HARNESS_EVIDENCE`.

| tier | tests | ids |
|---|---|---|
| `SPECIFIC_CITATION` | **23** | `T-01`, `-02`, `-03`, `-04`, `-06`, `-11`, `-13`, `-16`, `-17`, `-19`, `-20`, `-21`, `-23`, `-25`, `-26`, `-27`, `-28`, `-29`, `-30`, `-36`, `-38`, `-39`, `-41` |
| `IMPRECISE_CITATION_ONLY` | **7** | `T-09`, `-10`, `-12`, `-14`, `-15`, `-18`, `-24` |
| `NO_HARNESS_EVIDENCE` | **11** | `T-05`, `-07`, `-08`, `-22`, `-31`, `-32`, `-33`, `-34`, `-35`, `-37`, `-40` |
| **total** | **41** | `23 + 7 + 11 = 41` |
| executed against an application | **0** | every row |

Full table (verbatim Today cells from `GEOH-05` §4; `n` = checks the citation resolves to):

| test | finding | Today cell verbatim | citation form(s) | n | tier |
|---|---|---|---|---|---|
| GEOH-T-01 | D-1 silent 5 km clamp | `G-07-*, G-08` | exact, shared_glob | 10 | SPECIFIC_CITATION |
| GEOH-T-02 | F-2 float-decided boundary | `G-09-1…-5` | range | 5 | SPECIFIC_CITATION |
| GEOH-T-03 | F-3 banned substring inside S4/S5 | `G-17-*, G-20, G-22` | exact, shared_glob | 7 | SPECIFIC_CITATION |
| GEOH-T-04 | F-4 / N1 digit ban vs a date | `G-16-*, G-18` | exact, shared_glob | 6 | SPECIFIC_CITATION |
| GEOH-T-05 | N1-a `at` vs `queried` | `specified` | — | 0 | NO_HARNESS_EVIDENCE |
| GEOH-T-06 | N1-b qualifier banned phrase | `G-22` | exact | 1 | SPECIFIC_CITATION |
| GEOH-T-07 | N1-c block boundary undefined | `OPEN - no option adopted` | — | 0 | NO_HARNESS_EVIDENCE |
| GEOH-T-08 | UI-01 numeral/qualifier widget | `not executed` | — | 0 | NO_HARNESS_EVIDENCE |
| GEOH-T-09 | centre class refusals | `G-06-*` | shared_glob | 7 | IMPRECISE_CITATION_ONLY |
| GEOH-T-10 | GM-GEO-16 display vs study radius | `G-30-*` | shared_glob | 3 | IMPRECISE_CITATION_ONLY |
| GEOH-T-11 | S1 data unavailable | `G-13-SNP-S1` | exact | 1 | SPECIFIC_CITATION |
| GEOH-T-12 | S2 query failed / unanswered | `G-13-*` | shared_glob | 9 | IMPRECISE_CITATION_ONLY |
| GEOH-T-13 | S3 zone unresolved | `G-13-SNP-S3` | exact | 1 | SPECIFIC_CITATION |
| GEOH-T-14 | S4 zero, coverage UNKNOWN | `G-13-*` | shared_glob | 9 | IMPRECISE_CITATION_ONLY |
| GEOH-T-15 | S5 zero, coverage PARTIAL | `G-13-*` | shared_glob | 9 | IMPRECISE_CITATION_ONLY |
| GEOH-T-16 | S6 attested zero | `G-14` | exact | 1 | SPECIFIC_CITATION |
| GEOH-T-17 | S7 records returned | `G-19` | exact | 1 | SPECIFIC_CITATION |
| GEOH-T-18 | C-R1 count gate | `G-23-*` | shared_glob | 5 | IMPRECISE_CITATION_ONLY |
| GEOH-T-19 | E-1 unequal geometry | `G-23-CMP-4-DIFFERENT-GEOMETRY` | exact | 1 | SPECIFIC_CITATION |
| GEOH-T-20 | E-2* equal labels | `G-23-CMP-2-BOTH-UNKNOWN-LABELS` | exact | 1 | SPECIFIC_CITATION |
| GEOH-T-21 | E-3* shared window | `G-23-CMP-3-DIFFERENT-WINDOW` | exact | 1 | SPECIFIC_CITATION |
| GEOH-T-22 | C-R2 forbidden output forms | `specified` | — | 0 | NO_HARNESS_EVIDENCE |
| GEOH-T-23 | S_PARTIAL geometry | `G-24, G-25` | bare_prefix, exact | 12 | SPECIFIC_CITATION |
| GEOH-T-24 | Case A1 / A2 | `G-24-*` | shared_glob | 11 | IMPRECISE_CITATION_ONLY |
| GEOH-T-25 | Case B no polygon | `G-24-B` | case_shorthand | 1 | SPECIFIC_CITATION |
| GEOH-T-26 | Case C name reuse | `G-24-C` | case_shorthand | 1 | SPECIFIC_CITATION |
| GEOH-T-27 | Case D no area | `G-24-D, G-29` | case_shorthand, exact | 2 | SPECIFIC_CITATION |
| GEOH-T-28 | Case E non-uniform hierarchy | `G-26` | exact | 1 | SPECIFIC_CITATION |
| GEOH-T-29 | Case F bandar/pekan row | `G-27` | exact | 1 | SPECIFIC_CITATION |
| GEOH-T-30 | Case G district median | `G-28` | exact | 1 | SPECIFIC_CITATION |
| GEOH-T-31 | ODR-V21A-04 unverifiable location | `specified` | — | 0 | NO_HARNESS_EVIDENCE |
| GEOH-T-32 | R-1…R-8 adapter | `BLOCKED_SOURCE` | — | 0 | NO_HARNESS_EVIDENCE |
| GEOH-T-33 | GM-GEO-22 polygon vs circle | `specified` | — | 0 | NO_HARNESS_EVIDENCE |
| GEOH-T-34 | GM-GEO-20 union not sum | `specified` | — | 0 | NO_HARNESS_EVIDENCE |
| GEOH-T-35 | GEO-TILE attribution and viewport | `not executed` | — | 0 | NO_HARNESS_EVIDENCE |
| GEOH-T-36 | synthetic reaching an evidence path | `G-01…G-04` | range | 4 | SPECIFIC_CITATION |
| GEOH-T-37 | GM-GEO-19 de-duplication | `specified` | — | 0 | NO_HARNESS_EVIDENCE |
| GEOH-T-38 | R01 area vs search footprint | `G-32, G-34` | exact | 2 | SPECIFIC_CITATION |
| GEOH-T-39 | NOT_APPLICABLE vs UNRESOLVED | `G-25` | exact | 1 | SPECIFIC_CITATION |
| GEOH-T-40 | SA-1/SA-3/DP shared-area figure | `ABSENT_INPUT` | — | 0 | NO_HARNESS_EVIDENCE |
| GEOH-T-41 | R-plus convention distances | `G-05` | exact | 1 | SPECIFIC_CITATION |

---

## 8. Proposed additions to `GEOH-05`'s acceptance-criteria list

`GEOH-05` runs `AC-00` … `AC-10`. Two more rows continue that sequence; they are proposals, not adoptions (`AC-D3` / `DC-46`).

> **`AC-11` — two numerators, never merged.** Every GEOH output states `documentary_checks / acceptance_tests_executed` as an ordered pair — `88/0`, `62/0`, `49/0`. A single number is not permitted anywhere a count appears, including chat and commit messages. Reason: `88` and `41` differ only by a digit in casual retelling, and one of them names an executed application test while the other names a script reading its own fixtures.
>
> **`AC-12` — a documentary check id is not a test result; a family glob is not a citation.** An acceptance row may claim harness support only by naming **emitted check ids**, and its tier is set by §7.1. A shared glob (`G-13-*`, `G-24-*`) may appear in a table cell **only with the count it expands to** — `G-24-ADM-* (11)` — and never as the sole support for a row that tests one member of the family. Reason: §6 shows three tests resolving to one identical 9-check set, and one test's entire evidence set being a subset of another's; under those citations a single-state regression is unattributable.
>
> **`AC-13` (companion, wording only) — the harness never says `PASS`.** Its final line becomes `VERDICT: <n> HOLDS / <m> VIOLATED — documentary contract self-check only; no Jaspr test executed; nothing adopted`. This is `GEOHD-07.2`, restated as an acceptance criterion because AC-00 already forbids writing `PASS` without the level's evidence.

These three rules change **no rule, no refusal, and no fixture expectation**. They change only how results are counted and cited. Adopting them is `ODR-R-07` (bucket `ADOPT_NOW`) in `GEOHD-02`.

**Test population after this overlay: 41 → 49** (`GEOH-T-42`…`T-49`, specified in `GEOHD-01` §2–§9), **executed: 0**. The 41 + 8 rows stay `NOT_EXECUTED`; the evidence for this file is **11 pin checks** — `D-P-01`…`D-P-10` plus `D-P-07b` — inside `_verify/geoh_delta_check.py` (62 emitted, 62 HOLDS, exit 0).

---

## 9. Provenance of every number above

| number | derived from | recompute |
|---|---|---|
| 88, 77, 11 uncited, 31 specific, 46 imprecise-only, 1 dangling token | `data/HARNESS_CHECK_TO_TEST.csv` (88 rows) | `python -B _build/build_split.py` |
| 64 fan-out + 10 families + 24 standalone; per-family instance counts | same CSV, `G-<n>` prefix grouping | `python -B _verify/geoh_delta_check.py` → `D-C-21` prints `fan-out=` and `singletons=` |
| 41 tests, 30 cited, 11 uncited, tiers 23 / 7 / 11 | `data/TEST_EVIDENCE_TIER.csv` (41 rows) | same script; `D-C-22` asserts both new columns are populated |
| `consistent: true`, all cross-totals | `data/split_summary.json` | `D-R-20` re-parses and compares |
| 88 checks / 88 HOLDS / 0 VIOLATED / exit 0 | `_verify/logs/geoh_contract_check.log:166` and the scratch rerun | `D-P-08` runs the harness in a temp tree; `D-P-09` re-hashes the pinned log |
| `GEOH-T-12`/`-14`/`-15` identical 9-check set; `T-24` ⊂ `T-23` (11 of 12) | `data/TEST_EVIDENCE_TIER.csv` `resolved_harness_checks` column | set comparison over that column |
| predecessor 9/9 manifest verify, exit 0 | `GEOH_ODR3_TO_JASPR_20261030/SHA256_MANIFEST.txt` | `D-P-04`; also run `sha256sum -c` in that directory |

Nothing in this file is transcribed from a prose claim. Where the predecessor's prose and the machine-derived count could differ, the machine value is used and the prose is quoted as the object under test.

---

## 10. What this file does not establish

- It does **not** show that any acceptance test passed. **0 of 41 (49) executed.** No application exists (L1 not reached).
- It does **not** ratify the 88 HOLDS as correctness of the contract. A `HOLDS` means the script's assertion about its own fixtures and its own reading of the contract text is true. `GEOH-05` AC-00 and DC-46 remain in force; three of the contradictions in `GEOHD-01` (§2) are *inside* the 88 HOLDS block — `G-24-ADM-P-PARTIAL-GEOMETRY` HOLDS while the same package forbids what the fixture asserts.
- It does **not** adopt `AC-11`/`AC-12`/`AC-13`. It proposes them; `ODR-R-07` signs or declines.
- It does **not** appoint the independent QA reviewer. The register requires that reviewer be neither the challenge's author nor the implementer; that is a personnel decision only the Owner can make, and `ODR-2` remains blank.
- It does **not** re-run the 20 earlier ODR-3 geometry experiments. They stay reused under their own pins (`D-P-06` reports them as `{'designed_not_run': 6, 'executed': 20, 'holds': 18, 'violated': 2}` — the 2 `VIOLATED` are the predecessor's own recorded falsifications, `C-2` and `C-6`, not new failures).

**AC-D10 (carried from `GEOHD-01` §12):** *the split is measured, not asserted — 88 emitted verdicts of which 64 come from 10 parameterised families, 77 cited by tests and 11 not, 41 tests of which 0 have run; and the count that reads largest is the one that proves least.*
