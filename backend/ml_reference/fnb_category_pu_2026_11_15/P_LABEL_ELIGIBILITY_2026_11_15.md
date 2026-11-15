# P-Label Eligibility Record — Verified Three-Year Operating History

**Recorded:** 2026-11-15
**Applies to:** the 880 positive (P) records of `SiteWise_PU_1796_With_Known_Business_Types.xlsx`
**Status:** confirmed by the data owner; **not** derived from a supplied per-record date field.

## Definition applied

* **P** = verified F&B business with **at least three years of continuous operation**.
* **U** = unlabelled commercial property without a confirmed F&B operating outcome.
  U records are **not** confirmed failures and are never treated as negatives for the
  category model.

## What was verified, and on what basis

| Item | Result |
|---|---|
| Positive records retained | **880** (`business_type_status = KNOWN_FNB_CATEGORY`) |
| Unlabelled records retained | **916** (`business_type_status = UNKNOWN_UNLABELLED`) |
| Category label source | `Sitewise_FNB_Geospatial_Competitor_Analysis.xlsx / Competitor_Master` (recorded per row) |
| Category distribution | Restaurant 327 · Café/Coffee 253 · Bakery/Dessert/Beverage 183 · Fast Food/Takeaway 117 |
| Operating-duration evidence | **Data-owner confirmation (2026-11-15): all retained P outlets have operated more than three years continuously.** |

## What was NOT supplied, and is therefore NOT claimed

1. **Per-record opening dates, operating durations, current-status fields, verification
   dates or evidence references were not present in any supplied package**, and a
   read-only audit of the analytics database found no opening-date / duration / tenure
   column (the `fnb_a` schema holds `operating_status`, `operating_status_evidence` and
   `evidence.evidence_timestamp`, but no opening date).
2. No date, duration or status value has been invented or inferred to "fill" this gap.
   The eligibility basis is the data owner's explicit confirmation, recorded here once
   for the whole P set — not a fabricated per-row field.
3. The audit trail required for a stricter per-record review (business ID, opening date,
   duration, status, verification date, evidence source) remains **outstanding**; when
   supplied it should replace this record with a row-level eligibility file.

## Consequences recorded in the methodology

* Because the P set was already the 880 known operating F&B outlets used by the
  previous 64-feature experiment, the **training population is unchanged**
  (1,796 = 880 P + 916 U). The supplied 64-feature PU artifact is byte-identical to
  the integrated one (sha256 `0371f4e4…`), so no PU retraining is required.
* **Survivorship / selection bias:** learning from businesses that survived three
  years says nothing about why other businesses closed. The model cannot estimate
  survival probability without comparable failed-business outcomes, which these data
  do not contain.
* Three-year survival is **not** evidence of profitability, and the PU score remains an
  uncalibrated P-vs-U research association — never a commercial-success probability.
* Operating duration must never be used as an input feature; it is a label-eligibility
  criterion only.
