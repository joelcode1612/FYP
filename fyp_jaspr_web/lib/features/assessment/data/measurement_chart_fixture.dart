// GENERATED FILE — do not edit by hand.
//
// Regenerate with:
//   cd backend && ./.venv/Scripts/python.exe scripts/build_measurement_chart_preview.py
//
// The payload below is a real `chart-spec/1` built from the persisted
// FC4-D EE-01 measurement snapshot for Q05 by the production adapter
// `sitewise.project1.chart_spec.from_ee01`. Its render state is
// WITHHELD_NOT_AUTHORIZED and its admission block is HELD, so it
// discloses no count and no percentage. It is a diagnostic readback of
// a synthetic measurement, never an admitted customer-demand finding.
library;

/// SHA-256 of the canonical chart payload (content identity).
const String measurementChartContentHash =
    '7ec2b33e2605308b3312ab01ec6655dcf521a8e85bcbed1fe909e6f3d0bc62db';

/// The `chart-spec/1` payload, verbatim.
const String measurementChartPayloadJson = r'''{
  "schema_version": "chart-spec/1",
  "chart_id": "chart:e31bc304-c616-4277-aef2-664fc5dd1c1d:R03",
  "chart_type": "HORIZONTAL_BAR",
  "source_provenance": "SYNTHETIC_TEST",
  "evidence_context_hash": "b78d672cee55720da0c047c9f272e71eda06e52cf53a2203bc7f17c114535b02",
  "campaign_id": "f261c9b8-709d-4d00-8348-93e8c364c95f",
  "question_id": "Q05",
  "construct_id": "D01_CONCEPT_INTENT",
  "report_sections": [
    "R03"
  ],
  "question_version": "FC4D-50-REAL-SERVICE-20261123:A3:LANGUAGE-CANDIDATE-01:Q05",
  "option_bank_version": "FC4D-50-REAL-SERVICE-20261123:A3:BANK-1",
  "stimulus_hash": "810d1f41bdbbe15f5a2ef1691d33d6fc3e31e9a389ac3e7f8b2647cb84ab93e2",
  "concept_version": "FC4D-50-REAL-SERVICE-20261123:A3:INSTRUMENT-1",
  "cohort_scope": "DEVELOPER_PREVIEW / qualification FC4D-SYNTHETIC-QUALIFICATION-1",
  "cutoff": "2026-11-22T16:49:10.005660Z",
  "measurement": {
    "I": "UNKNOWN_NOT_ENUMERABLE",
    "Q": 28,
    "S": 28,
    "A": 28,
    "V": 24
  },
  "denominator_scope": "V = substantive answers to Q05 at this version and stimulus",
  "limitation": "The stem compounds a time horizon with an at-least-once event; which clause drives the answer is untested. UNSURE is substantive per the applicable A10 worked example and is counted in V; CANNOT_JUDGE is not. Horizon and event interpretation are referred to WS2.",
  "title": "Q05 · D01_CONCEPT_INTENT",
  "question_text": "If the café described in [concept_card_version] opened in [named area], how likely would you be to visit it at least once during its first three months?",
  "response_kind": "ORDINAL",
  "options": [
    {
      "code": "DEF_NO",
      "label": null,
      "label_source": "CODE_FALLBACK",
      "ordinal_value": 1,
      "count": 5,
      "percentage": null,
      "percentage_status": "WITHHELD_NOT_AUTHORIZED"
    },
    {
      "code": "PROB_NO",
      "label": null,
      "label_source": "CODE_FALLBACK",
      "ordinal_value": 2,
      "count": 5,
      "percentage": null,
      "percentage_status": "WITHHELD_NOT_AUTHORIZED"
    },
    {
      "code": "UNSURE",
      "label": null,
      "label_source": "CODE_FALLBACK",
      "ordinal_value": 3,
      "count": 5,
      "percentage": null,
      "percentage_status": "WITHHELD_NOT_AUTHORIZED"
    },
    {
      "code": "PROB_YES",
      "label": null,
      "label_source": "CODE_FALLBACK",
      "ordinal_value": 4,
      "count": 7,
      "percentage": null,
      "percentage_status": "WITHHELD_NOT_AUTHORIZED"
    },
    {
      "code": "DEF_YES",
      "label": null,
      "label_source": "CODE_FALLBACK",
      "ordinal_value": 5,
      "count": 2,
      "percentage": null,
      "percentage_status": "WITHHELD_NOT_AUTHORIZED"
    }
  ],
  "derived_lines": [
    {
      "code": "TOP_TWO_STATED_INTEREST",
      "label": null,
      "numerator_codes": [
        "DEF_YES",
        "PROB_YES"
      ],
      "count": 9,
      "percentage": null,
      "percentage_status": "WITHHELD_NOT_AUTHORIZED",
      "formula": "100 * (x[DEF_YES] + x[PROB_YES]) / V",
      "output_label": "stated first-three-month interest",
      "combination": "DISJOINT_SINGLE_SELECT"
    }
  ],
  "highest_options": [
    "PROB_YES"
  ],
  "limitations": [
    "The stem compounds a time horizon with an at-least-once event; which clause drives the answer is untested. UNSURE is substantive per the applicable A10 worked example and is counted in V; CANNOT_JUDGE is not. Horizon and event interpretation are referred to WS2.",
    "Calibrated probability; predicted visits; customers; revenue; demand score; any conversion to a rate",
    "Only a Juster-type 0-10 scale carries a validated probability interpretation (Juster 1966; Brennan & Esslemont, Marketing Bulletin 1994/95, on accuracy for fast-moving consumer goods). A five-point labelled intention scale does not, so every figure from Q05 is ordinal and sample-scoped."
  ],
  "render_state": "WITHHELD_NOT_AUTHORIZED",
  "admission": {
    "status": "HELD",
    "authority": "AUTHORITY_UNVERIFIED",
    "gates": [
      "A10_ADAPTER_UNVERIFIED",
      "EXPLANATION_TEMPLATE_AUTHORITY_UNVERIFIED",
      "REPORT_ADMISSION_REQUIRED",
      "SYNTHETIC_DATA_NOT_REPORTABLE"
    ],
    "real_reportable": false
  }
}''';

/// Provenance of that payload: which run, campaign, assessment and
/// snapshot produced it, and how many respondents reached each funnel
/// stage.
const String measurementChartProvenanceJson = r'''{
  "source": "EE-01 persisted measurement snapshot, built by from_ee01",
  "mapping_record": "artifacts/cq_fc4d_report_integration_v2/runs/rp02_mapping.json",
  "mapping_record_sha256": "bf0617ed40cb9deb0c1ce7e1d1a5084307959545f0867723610ab32ada04d405",
  "test_run_id": "FC4D-50-REAL-SERVICE-20261123",
  "campaign_id": "f261c9b8-709d-4d00-8348-93e8c364c95f",
  "assessment_id": "37f20705-cd31-5b53-b792-9b30cb49c465",
  "slot": "Q05",
  "rule": "CUST03_CURRENT_ATTEMPT_DIAGNOSTIC",
  "policy_version": "CUST03-C0C1-CANDIDATE-20261107.1",
  "contract_spec_version": "P3-01C-VNEXT-0.6.1-CUST-REC",
  "evidence_context_hash": "b78d672cee55720da0c047c9f272e71eda06e52cf53a2203bc7f17c114535b02",
  "content_hash": "7ec2b33e2605308b3312ab01ec6655dcf521a8e85bcbed1fe909e6f3d0bc62db",
  "qualified": 28,
  "shown": 28,
  "answered": 28,
  "substantive": 24,
  "render_state": "WITHHELD_NOT_AUTHORIZED",
  "admission_status": "HELD",
  "gates": [
    "A10_ADAPTER_UNVERIFIED",
    "EXPLANATION_TEMPLATE_AUTHORITY_UNVERIFIED",
    "REPORT_ADMISSION_REQUIRED",
    "SYNTHETIC_DATA_NOT_REPORTABLE"
  ]
}''';
