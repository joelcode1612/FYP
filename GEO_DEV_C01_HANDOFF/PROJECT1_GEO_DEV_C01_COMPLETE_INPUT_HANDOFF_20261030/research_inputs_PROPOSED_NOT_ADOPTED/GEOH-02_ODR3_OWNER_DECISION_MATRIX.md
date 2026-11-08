# GEOH-02 — ODR-3 Owner decision matrix

**Directive:** `PROJECT1-ODR3-RESEARCH-FIRST-GEO-CONTRACT-20261030` (R1, R2)
**Custodian:** `HC-01`
**Status:** `PROPOSED_FOR_OWNER_ADOPTION`
**Signatures recorded in this document: zero.** Every signature field is blank. No row is marked approved, adopted, accepted or closed.
**Outcome token:** `RESEARCH_HANDOVER_READY — 16 DECISIONS PROPOSED, 0 SIGNED`

---

## 1. The three buckets, defined before they are used

The directive asks for decisions to be separated into *synthetic demonstration*, *descriptive production policy*, and *scientific validation*. Three buckets, defined so a row cannot drift between them:

| Bucket | Means | Test for membership |
|---|---|---|
| **`ADOPT_NOW`** | the decision can be taken today on documentary evidence alone. No new dataset, licence, coordinate, fielding or field measurement is required. Adopting it **removes** an output or fixes a definition; it cannot manufacture a claim. | *Would adopting this change any number that appears in a report?* If no — it belongs here. |
| **`DEMONSTRATION_ONLY`** | the decision may be exercised inside the isolated synthetic prototype, visibly labelled, but may not reach a real rental, a real report or a real source. | *Could a reader mistake the output for a finding?* If yes and the data are synthetic — it belongs here. |
| **`LATER_REAL_DATA`** | the decision cannot honestly be taken until a named real artefact exists (certified coordinate, licensed source, completeness statement, rights act, fielded sample). | *Is the missing input named in the decision itself?* If yes — it belongs here. |

A row is never promoted between buckets by this package. Promotion is an Owner act.

**Status vocabulary** (each row carries exactly one): `OPEN` (not yet decided) · `PROPOSED` (this package recommends a specific answer, unadopted) · `CONDITIONAL` (adoptable only once a named precondition holds) · `DEFERRED` (Owner has postponed the subject).

---

## 2. The matrix

Read the **Recommendation** column as a proposal, never as a decision. `Evidence` names what exists today; `Missing` names what would be needed for a different answer.

### 2.1 Radius and footprint

| ID | Decision | Bucket | Status | Recommendation | Evidence today | Missing |
|---|---|---|---|---|---|---|
| **`ODR-3a-dev`** | May the prototype expose 400 / 500 / 800 / 1200 m as *experimental preview* radii? | `DEMONSTRATION_ONLY` | `PROPOSED` | **Yes**, visibly labelled `EXPERIMENTAL — NOT A STUDY RADIUS`, display radius locked equal to the selected study radius, no ranking or comparison derived from the choice. None of the four is a default. | `P1` §2.3 sensitivity sweep (5→7→9→12 venues; ranking reversal at S-10) proves the choice is consequential and that no value is privileged | nothing for the demonstrator; a real value needs `ODR-3a-prod` |
| **`ODR-3a-prod`** | May a **descriptive geometric convention** be adopted as the production study radius, without claiming an optimal catchment? | `LATER_REAL_DATA` | `OPEN` | **Not yet.** A convention *can* be declared without a scientific optimality claim — but its honest declaration requires naming the centre rule, the source, the coverage class and the tolerance it is paired with, and today none of those four has a value. Declaring `R` alone would be a number recorded as a finding. | `P1` §2.4: five independent blockers, any one sufficient. `P7` §2.1: *"`R` is an Owner parameter and has no proposed value here"` | a certified premises centre (`R-4`, `R-8`, `S_PARTIAL`), a licensed displayable source (`ODR-4`), a completeness class, an adopted tolerance, and at least one executed measurement at a real value (the only probe, 600 m, is recorded *"as untested, not as zero"*) |
| **`ODR-3b`** | Must the **display** radius equal the **study** radius? | `ADOPT_NOW` | `PROPOSED` | **Yes, mandatory equality.** A mismatch is a report defect, not a styling choice: it makes the drawn circle describe a different query than the one executed. | `P1` S-09 (`study 800 / display 1200 → REJECTED`); `P19` currently validates only the study radius, so the invariant is **unenforced** (`GEOH-05` `GEOH-T-10`) | nothing |

### 2.2 Centre eligibility

| ID | Decision | Bucket | Status | Recommendation | Evidence today | Missing |
|---|---|---|---|---|---|---|
| **`ODR-3c-exclusions`** | Are `AREA_ONLY` and `LISTING_PIN` centres **ineligible** for a premises circle? | `ADOPT_NOW` | `PROPOSED` | **Yes, both refused.** `AREA_ONLY` has no point; a `LISTING_PIN` is a map artefact whose relation to the premises is unverified. Refusing costs nothing — the rental still renders, without a circle. | `P1` S-03: a `LISTING_PIN` centre shifts one venue across the boundary at 760 m; S-04: `AREA_ONLY` → S7-style unresolved state, no invented circle | nothing |
| **`ODR-3c-grants-policy`** | Under what conditions may `PREMISES` / `BUILDING` centres be granted? | `ADOPT_NOW` | `PROPOSED` | **Policy only:** `PREMISES` requires a coordinate, a named provenance, and a numeric positional accuracy; `BUILDING` additionally requires a documented entrance-offset bound. Coordinates without provenance, or without accuracy, are refused — not defaulted. | `P19` `classifyCentre` already implements exactly this shape; `GEOH-04` §6 states it as machine-checkable error codes | nothing for the *policy* |
| **`ODR-3c-grants-satisfaction`** | Does a **particular real rental** satisfy that policy? | `LATER_REAL_DATA` | `OPEN` | **Not answerable today, for any rental.** This is the separation the directive asks for: the rule is decidable, the fact is not. | `P6` §1.1 `S_PARTIAL`: 5,973/6,334 rows carry coordinates; 4,209 record a shift; 336 substitute a district median; `COORD_SHIFT_SEMANTICS_NOT_DOCUMENTED` | `R-4` (precision) and `R-8` (provenance) answers from the rental teammate; `H-F` unblocked |

### 2.3 Output boundary

| ID | Decision | Bucket | Status | Recommendation | Evidence today | Missing |
|---|---|---|---|---|---|---|
| **`ODR-3d`** | What may a geographic/competitor section assert? | `ADOPT_NOW` | `PROPOSED` | **Only:** recorded businesses within a stated straight-line distance of a stated centre, on a stated date, from a stated versioned source, with a stated coverage class and its limitations. **Never:** demand, suitability, ranking, walking time, catchment, saturation, density-as-score, or a cross-rental count outside `E-1 ∧ E-2 ∧ E-3`. | `P7` C-R2 and §3's four independent reasons; `P16` `PROHIBITED_OPERATIONS` (10 terms) and `PROHIBITED_TERMS` (9 terms); `P1` §1.2's four refusals | nothing |

### 2.4 Geometry correctness

| ID | Decision | Bucket | Status | Recommendation | Evidence today | Missing |
|---|---|---|---|---|---|---|
| **`ODR-3-maxradius`** | What happens to a radius request above the supported maximum? | `ADOPT_NOW` | `PROPOSED` | **Explicit refusal.** Never a silent clamp. A surface that draws a 6 km circle while executing a 5 km query is the exact failure the display/study equality rule exists to catch. | `P1` C-2 `VIOLATED`; `P15` L180–181 clamps without signal, and `P15`'s own suite codifies the clamp as expected. `P19` already refuses — the Python component was **not** fixed | nothing |
| **`ODR-3-tolerance-policy`** | Must a boundary tolerance be declared, and must it be explicit rather than defaulted? | `ADOPT_NOW` | `PROPOSED` | **Yes on both.** A venue at exactly `R` is decided by floating-point noise (~3.6 × 10⁻¹² m reproduced); the contract must require a tolerance argument and reject a missing one. | `P1` C-6 `VIOLATED`; measured again in `GEOH-01` §5 and `GEOH-04` §6 (`E_TOLERANCE_UNSET`) | nothing for the *requirement* |
| **`ODR-3-tolerance-value`** | What **number** is the adopted tolerance? | `LATER_REAL_DATA` | `OPEN` | **No number proposed.** `0.5 m` appears in `P19` labelled *"an example only"*; this package keeps it in exactly that status. The value must be derived from the rental's positional accuracy and published beside `R`. | `P1` §3.4 F-2 recommends only *"publish a boundary tolerance"* | `R-4` positional accuracy; an adopted `R` |

### 2.5 Coverage and freshness reconciliation (R2)

| ID | Decision | Bucket | Status | Recommendation | Evidence today | Missing |
|---|---|---|---|---|---|---|
| **`ODR-3-clarification`** | Does `E-2` ("equal coverage") mean *equal labels* or *documented completeness*; and does `E-3` need **two** dates or **one shared window**? | `ADOPT_NOW` | `PROPOSED` | **Tighten both, and correct one erratum** (detail in §3). `E-2` is satisfied only by a shared versioned snapshot **and** a written completeness statement for each footprint — equal `UNKNOWN` labels do **not** satisfy it. `E-3` is satisfied by **one shared snapshot/window**; a *second* date is required only for temporal-change analysis, not for cross-candidate comparability. | `P7` §3 already defines `E-2` as *"the same sources … the same coverage class"* while marking it failed because *"no source has a completeness statement"* — two different tests in one row. `P19` `mayDisplayCrossCandidateCounts` already requires `bothHaveDocumentedCompleteness` and `sameObservationWindow` | nothing. Note the direction: this **only refuses more**, so it removes no output that exists today |

### 2.6 GM-12 wording and semantics

| ID | Decision | Bucket | Status | Recommendation | Evidence today | Missing |
|---|---|---|---|---|---|---|
| **`ODR-3-label-semantics`** *(was `ODR-V21A-07`)* | Which quantity does the provenance date denote — `QUERY_TIME`, `RETRIEVAL_TIME` or `SOURCE_VINTAGE`? | `ADOPT_NOW` | `PROPOSED` | **`RETRIEVAL_TIME`**, with `SOURCE_VINTAGE` shown separately as `as_of <date>` where a banked snapshot is read — exactly the split `GM_12` §4 S7 already makes. It is the only one of the three the freshness rule can be evaluated against. | `P14a` §8 (three semantics, `D16`–`D19`); `P5` §4 S7 already separates `queried` from `as_of` | nothing |
| **`ODR-3-copy-option`** *(was `ODR-V21A-08`, part 1)* | Option A (one exempt provenance timestamp) or Option B (no timestamp in the block; dates in the R12 audit row)? | `ADOPT_NOW` | `PROPOSED` | **Option B.** It does not weaken the prohibition that stops a competitor count appearing, and it removes a validation special case instead of institutionalising one. Cost: ~5 % more text and a reader hop to R12. | `P14a` §6–7 (full texts, readability measures, and hazard `D38`: under A a whole-clause validator reports N−1 false `E_DIGIT`); `P19` already behaves as B | nothing for the wording; B's audit row needs `ODR-3-r12-fields` |
| **`ODR-3-surfaces`** *(was `ODR-V21A-08`, part 2)* | Does the §4.1 phrase ban reach a **negated warning**, **quoted source text**, an **a11y label** and the **provenance line**? | `ADOPT_NOW` | `PROPOSED` | **The ban reaches every surface a reader can read, including all four.** A negated warning is lawful only if its wording carries no banned span — which the replacement sentence in §4 delivers. Quotation is not a licence to import a banned claim. | `P14a` §13 (governed / implied / silent surfaces; `E08` records the screen is stricter than the contract on the a11y surface); `GM_12` §2 names four positions and is silent on three others | nothing |
| **`ODR-3-qualifier`** | The S4/S5 qualifier currently contains the phrase §4.1 bans (`…not evidence that no competitors exist`). What replaces it? | `ADOPT_NOW` | `PROPOSED` | **`This is an empty result, not a finding about the area.`** It keeps both load-bearing clauses (the empty-result statement and the denial) and carries no banned span. Rejected alternative: truncating to *"This is an empty result."*, which drops the denial and with it the reason the qualifier exists. | `P1` §3.4 F-3; `P14a` §4 (`E01`–`E04`); reproduced as a measurement in `GEOH-01` `G-20` | nothing |
| **`ODR-3-blockboundary`** *(was `ODR-V21A-09`)* | Does a per-rental block include the **rental label**? A real label like `No. 12, Jalan Contoh` makes every S1–S5 block numeral-unlawful under both options. | `ADOPT_NOW` | `PROPOSED` | **Reading (i): the block begins at the component; the rental label is outside it.** Smallest change, and the only one that does not require §2 to grow a fifth named position. Readings (ii) *(label inside, addresses exempt)* and (iii) *(no rental label; identity in a governed heading)* are lawful and recorded. | `P14a` §5 (`D36`, `D37`); `P1` §3.4 | nothing — but the rental teammate's `R-2` answer decides whether labels carry house numbers at all |
| **`ODR-3-r12-fields`** *(new)* | What fields does the R12 evidence-snapshot audit row carry? Option B depends on it. | `ADOPT_NOW` | `PROPOSED` | **`source` · `queried` · `retrieved` · `vintage` · `coverage` · `snapshot_id` · `licence_id` · `rights_state`**, one row per source per query. Recorded explicitly as **new fields**: `P11` §2.3.2 describes R12 only as *"evidence snapshot … audit rows per candidate"* and `ODR-V21-04` asked whether a `queried` field exists and was never answered. | `P14a` §6 Option B; `P11` §2.3.2 | an Owner record that adopts the field list — until then Option B has nowhere to put its dates |

### 2.7 Report structure and integration

| ID | Decision | Bucket | Status | Recommendation | Evidence today | Missing |
|---|---|---|---|---|---|---|
| **`ODR-3-r01-area`** *(was `ODR-V21A-04`)* | When `R01` prints *"the address and its area"*, **which** area? | `ADOPT_NOW` | `PROPOSED` | **(a) the rental's administrative area**, not the competitor search zone. This keeps `R01` independent of the footprint — the Finding-B correction — and puts the search circle where it belongs, in `R09`/`R12`. If the report ever shows both, they are labelled separately. | `P14b` §7 (the three-way question and its `B16` tripwire) | nothing |
| **`ODR-3-mukim-navigation`** | May mukim be offered as a **map navigation level**? | `LATER_REAL_DATA` | `CONDITIONAL` | **Yes, as navigation only** — `named` state, class filter applied, no statistic attached. Not as a report claim unit, not as a respondent-facing question. | `P6` §7 (three surviving uses, four measured reasons mukim is not yet a measurement unit); `GM_12`-adjacent count risk: 76.3 % of the "Mukim" layer is bandar/pekan | the name-source decision `O-1`/`O-1a` (below) |
| **`ODR-3-name-reuse`** | May the open district **name list** be used (OpenDOSM, CC BY 4.0, geometry-free)? | `LATER_REAL_DATA` | `OPEN` | **Conditional on the Owner recording `O-1`/`O-1a`.** Name reuse is a materially weaker ask than boundary use and does not require a polygon. Attribution must travel into any export. | `P6` §4 (`CLOSED_FOR_NAME_LEVEL_USE_ONLY`, `STUDY_AREA_LABEL = CONDITIONAL`); `WG_08` records 0 signatures | the Owner's `O-1`/`O-1a` record |
| **`ODR-3-rental-interface`** *(was `R-1`…`R-8`)* | What does the rental side expose: revision, address shape, area, coordinates, change signal, withdrawal, shared addresses, provenance? | `LATER_REAL_DATA` | `OPEN` | **Ask, do not assume.** `GEOH-04` §8 defines the six objects so that *every* one of the eight can be absent and the report still degrades to withholding rather than to a default. | `P14c` §3 (eight questions, each with its "if not available" fallback) and §6 (one-line answer format) | the teammate's reply; this package does not speak for them |

---

## 3. The R2 reconciliation, stated once and precisely

`E-2` and `E-3` are the two contradictions the directive names. Both are reconciled here as *proposed interpretations*, and one of them carries an **erratum against my own earlier package**, which is recorded rather than quietly fixed.

### 3.1 `E-2` — equal coverage

The frozen text carries two different tests in one row (`P7` §3):

> **Test column:** *"the same sources answered for each footprint, with the same coverage class"*
> **Status column:** *"**fails** — `S1` for all three; **no source has a completeness statement**"*

The test, read literally, is **label equality**. The status judges by **completeness**. Those are not the same predicate, and the difference is not cosmetic: two footprints both labelled `UNKNOWN` satisfy the label test and prove nothing about equal observation — the exact inference `P7` §2.1 forbids two paragraphs earlier (*"equal geometry is not equal coverage"*).

**Proposed interpretation `E-2*`:**

> A cross-rental count requires that **both** footprints were answered from **one versioned snapshot** (`snapshot_id` + `source_release`) **and** that each footprint carries a **written completeness statement naming its area scope and date**. A coverage **label** is a precondition, not satisfaction. Two footprints labelled `UNKNOWN` fail `E-2*`.

**Consequences, stated plainly:**

- This is **stricter** than `P7`'s literal test and **equal** to what `P19` `mayDisplayCrossCandidateCounts` already enforces (`bothHaveDocumentedCompleteness`).
- It makes cross-rental counts **unreachable today**, because no examined source states completeness (`P5` §3.1). It does not remove an existing output; there is no existing output.
- **Descriptive per-rental lists remain fully available.** `E-2*` governs only the *cross-rental count*. Each rental still renders its own list under its own state (`S1`…`S7`) — that is what `S7` is for.
- `C-R1`'s refusal sentence is unchanged and still printed.

### 3.2 `E-3` — equal freshness, and the erratum

`P7` §3 defines `E-3` as *"the same `osm_data_base` and the same `query_utc` window"* — already one shared window. **My earlier ODR-3 delta** (`P1` §8) listed *"a second observation date"* among the `E-3` blockers. That is **wrong**, and this is the correction:

> **Erratum `GEOH-E1`.** `E-3` for **cross-candidate comparability** is satisfied by **one shared snapshot window**. A **second** observation date is required only for *temporal-change* analysis (comparing a footprint against itself over time). `P1` §8 item P-6 mis-stated this and is superseded by this paragraph. No other conclusion in `P1` depends on it.

**Proposed metadata rule `E-3*`:**

| Field | Where it lives | Rule |
|---|---|---|
| `snapshot_id` | `ReportGeoProvenance` (R12) | identical for every footprint in a comparison |
| `source_release` | R12 | identical for every footprint in a comparison |
| `queried_at` | R12 | may differ per footprint; recorded, not asserted equal |
| `retrieved_at` | R12 | **the** comparability anchor — must fall inside one declared window |
| `source_as_of` | R12 | recorded; a difference triggers `as_of` display per footprint, not a refusal |

**Required approval:** because `E-2*` and `E-3*` change which outputs are reachable, they are `PROPOSED_FOR_OWNER_ADOPTION` and cannot be applied to a frozen report contract until recorded. They are safe in the sense that they only refuse — but "only refuses" is a safety property, not an adoption.

---

## 4. What the Owner can sign in one sitting

Fourteen of the twenty-one rows need nothing but a decision. They are listed together because taking them together removes every contradiction this package found, and none of them can manufacture a claim.

| Sign together | Rows | Effect |
|---|---|---|
| **Geometry correctness** | `ODR-3b`, `ODR-3-maxradius`, `ODR-3-tolerance-policy` | the drawn circle always describes the executed query; no silent clamp; no defaulted tolerance |
| **Refusal set** | `ODR-3c-exclusions`, `ODR-3c-grants-policy`, `ODR-3d` | what may never be drawn and never be asserted |
| **GM-12 wording** | `ODR-3-label-semantics`, `ODR-3-copy-option`, `ODR-3-qualifier`, `ODR-3-blockboundary`, `ODR-3-surfaces`, `ODR-3-r12-fields` | F-3, F-4, N1-a, N1-b, N1-c and `ODR-V21A-07/-08/-09` all close |
| **Structure** | `ODR-3-clarification`, `ODR-3-r01-area` | E-2/E-3 and R01's "area" are decided |

The remaining seven wait on a real artefact: `ODR-3a-prod`, `ODR-3c-grants-satisfaction`, `ODR-3-tolerance-value`, `ODR-3-mukim-navigation`, `ODR-3-name-reuse`, `ODR-3-rental-interface` — and `ODR-3a-dev`, which is not blocked but is demonstration-only by nature.

---

## 5. Sequencing, and why the order is not free

```text
ODR-3d + ODR-3c-exclusions        (what may never be shown)
        ↓
ODR-3b + ODR-3-maxradius + ODR-3-tolerance-policy   (the circle is honest)
        ↓
ODR-3-label-semantics → ODR-3-r12-fields → ODR-3-copy-option  (there is somewhere to put the date)
        ↓
ODR-3-qualifier + ODR-3-blockboundary + ODR-3-surfaces        (the block is lawful end to end)
        ↓
ODR-3-clarification               (the count gate is defined)
        ↓
ODR-3c-grants-satisfaction ← R-4 / R-8 ← ODR-4 / H-F          (a real rental could be drawn)
        ↓
ODR-3a-prod + ODR-3-tolerance-value                            (a real radius exists)
```

The arrow that matters: **`ODR-3-copy-option` cannot be implemented before `ODR-3-r12-fields`**, because Option B's dates have nowhere to live until the audit row is defined. That is the one ordering constraint a reviewer should check first.

---

## 6. Gate residues — not decisions, and not moved by this package

These are recorded so the matrix is not read as clearing them. **None is a decision this package is entitled to propose.**

| Gate | State | Why this package does not touch it |
|---|---|---|
| `H0` | `FAIL (D)` | business-completeness gate; out of scope |
| `H3` | `REVIEW_NOT_EXECUTED` | needs a nominated independent reviewer (`ODR-2`, blank) |
| `H4b` | `WITHHELD` | report-acceptance gate |
| `H-F` | `BLOCKED` | no banked/authorised real footprint work |
| `ODR-4` | blank | four-way source rights; a legal act |
| `ODR-1` | blank | H0 scope |
| `ODR-2` | blank | H3 reviewer |
| `SGD-25` | `NOT GRANTED` | scientific release; explicitly not self-grantable |
| `FRG-G08` | `FAIL` | geographic checkpoint |
| `T03/T06/T07` | constants, `HOLDS` unreachable | research-harness defect (`P12` §1); not a geographic output, and not fixed here |

**A green `GEOH` package changes none of them.** `GEOH-05` §7 states the four readiness levels that must not be conflated with this one.
