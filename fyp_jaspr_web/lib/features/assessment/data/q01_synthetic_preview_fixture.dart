// GENERATED FILE — do not edit by hand.
//
// Source: backend/scripts/build_q01_synthetic_preview.py
// Fixture: backend/src/sitewise/project1/q01_synthetic_preview.py
//
// Development-only synthetic Q01 demonstration. No fielded response, no
// real person and no authorized measurement is represented. The embedded
// chart is in the SYNTHETIC_PREVIEW_ONLY render state: it draws bars, but
// its admission block is HELD and it can never enter a report section.
//
// Regenerate rather than edit. A hand edit here would desynchronise the
// fixture from the records that produced it.
library;

const String q01SyntheticPreviewPayloadJson = r'''{
  "admission": {
    "authority": "AUTHORITY_UNVERIFIED",
    "gates": [
      "A10_ADAPTER_UNVERIFIED",
      "EXPLANATION_TEMPLATE_AUTHORITY_UNVERIFIED",
      "REPORT_ADMISSION_REQUIRED",
      "SYNTHETIC_DATA_NOT_REPORTABLE"
    ],
    "real_reportable": false,
    "status": "HELD"
  },
  "chart": {
    "admission": {
      "authority": "AUTHORITY_UNVERIFIED",
      "gates": [
        "A10_ADAPTER_UNVERIFIED",
        "EXPLANATION_TEMPLATE_AUTHORITY_UNVERIFIED",
        "REPORT_ADMISSION_REQUIRED",
        "SYNTHETIC_DATA_NOT_REPORTABLE"
      ],
      "real_reportable": false,
      "status": "HELD"
    },
    "campaign_id": "campaign-q01-synthetic",
    "chart_id": "chart:snap-q01-synthetic-0001:R02",
    "chart_type": "HORIZONTAL_BAR",
    "cohort_scope": "DEVELOPER_PREVIEW / qualification qual-q01-synthetic",
    "concept_version": "P3-01C-VNEXT-0.6.1-CUST-REC",
    "construct_id": "G01_AREA_AFFILIATION",
    "cutoff": "2026-11-22T09:00:00Z",
    "denominator_scope": "V = 40 valid Q01 answers at this version and stimulus, including 6 who selected only an exclusive alternative; affiliations overlap and sum to 53",
    "derived_lines": [],
    "evidence_context_hash": "a58cb0f5e08ccfa7461227762717319f792380d788a8af3ab085e36646dd619c",
    "highest_options": [
      "LIVE"
    ],
    "limitation": "Synthetic preview only. Forty fabricated respondents, aggregated by fixture arithmetic rather than by an EE-01 execution. No fielded response, no consent event and no real person is represented. Affiliation categories overlap, so counts sum above V; they are not a partition and not a census of residents. RARELY, NEVER and NOT_SURE are exclusive alternatives, counted separately and never treated as eligible or ineligible. Q01 has no declared numerator (Q01-NR-DEFAULT), so the shares shown are the mechanical 100*x/V demonstration and are not an authorized distribution.",
    "limitations": [
      "Synthetic preview only. Forty fabricated respondents, aggregated by fixture arithmetic rather than by an EE-01 execution. No fielded response, no consent event and no real person is represented. Affiliation categories overlap, so counts sum above V; they are not a partition and not a census of residents. RARELY, NEVER and NOT_SURE are exclusive alternatives, counted separately and never treated as eligible or ineligible. Q01 has no declared numerator (Q01-NR-DEFAULT), so the shares shown are the mechanical 100*x/V demonstration and are not an authorized distribution.",
      "Respondent residence; residential totals; demand counts; treating NOT_SURE as eligible or ineligible"
    ],
    "measurement": {
      "A": 40,
      "I": "UNKNOWN_NOT_ENUMERABLE",
      "Q": 44,
      "S": 41,
      "V": 40
    },
    "option_bank_version": "option-bank-q01-SYNTHETIC-PREVIEW",
    "options": [
      {
        "code": "LIVE",
        "count": 15,
        "label": "I live in this area",
        "label_source": "CONTRACT_OPTION_BANK_DRAFT",
        "ordinal_value": null,
        "percentage": "37.5000",
        "percentage_status": "SYNTHETIC_PREVIEW_ESTIMABLE"
      },
      {
        "code": "WORK",
        "count": 12,
        "label": "I work in this area",
        "label_source": "CONTRACT_OPTION_BANK_DRAFT",
        "ordinal_value": null,
        "percentage": "30.0000",
        "percentage_status": "SYNTHETIC_PREVIEW_ESTIMABLE"
      },
      {
        "code": "STUDY",
        "count": 6,
        "label": "I study in this area",
        "label_source": "CONTRACT_OPTION_BANK_DRAFT",
        "ordinal_value": null,
        "percentage": "15.0000",
        "percentage_status": "SYNTHETIC_PREVIEW_ESTIMABLE"
      },
      {
        "code": "RUN_BUSINESS",
        "count": 4,
        "label": "I operate a business in this area",
        "label_source": "CONTRACT_OPTION_BANK_DRAFT",
        "ordinal_value": null,
        "percentage": "10.0000",
        "percentage_status": "SYNTHETIC_PREVIEW_ESTIMABLE"
      },
      {
        "code": "VISIT_PURPOSE",
        "count": 9,
        "label": "I visit this area for activities or other purposes",
        "label_source": "CONTRACT_OPTION_BANK_DRAFT",
        "ordinal_value": null,
        "percentage": "22.5000",
        "percentage_status": "SYNTHETIC_PREVIEW_ESTIMABLE"
      },
      {
        "code": "PASS_THROUGH",
        "count": 7,
        "label": "I pass through this area",
        "label_source": "CONTRACT_OPTION_BANK_DRAFT",
        "ordinal_value": null,
        "percentage": "17.5000",
        "percentage_status": "SYNTHETIC_PREVIEW_ESTIMABLE"
      },
      {
        "code": "RARELY",
        "count": 3,
        "label": "Rarely",
        "label_source": "CONTRACT_OPTION_BANK_DRAFT",
        "ordinal_value": null,
        "percentage": "7.5000",
        "percentage_status": "SYNTHETIC_PREVIEW_ESTIMABLE"
      },
      {
        "code": "NEVER",
        "count": 2,
        "label": "Never",
        "label_source": "CONTRACT_OPTION_BANK_DRAFT",
        "ordinal_value": null,
        "percentage": "5.0000",
        "percentage_status": "SYNTHETIC_PREVIEW_ESTIMABLE"
      },
      {
        "code": "NOT_SURE",
        "count": 1,
        "label": "Not sure",
        "label_source": "CONTRACT_OPTION_BANK_DRAFT",
        "ordinal_value": null,
        "percentage": "2.5000",
        "percentage_status": "SYNTHETIC_PREVIEW_ESTIMABLE"
      }
    ],
    "question_id": "Q01",
    "question_text": "Which of the following describe your connection to [named area]? Select all that apply. If none apply, select one of: Rarely, Never, Not sure.",
    "question_version": "q01-v1-SYNTHETIC",
    "render_state": "SYNTHETIC_PREVIEW_ONLY",
    "report_sections": [
      "R02",
      "R08"
    ],
    "response_kind": "MULTI_SELECT",
    "schema_version": "chart-spec/1",
    "source_provenance": "SYNTHETIC_TEST",
    "stimulus_hash": "stimulus-q01-synthetic",
    "title": "Area connection — synthetic preview"
  },
  "chart_content_hash": "2bafb9513f73687d1c95341dcf24b70ce9a4259ea378afef8be5888a8a0ef3e3",
  "chart_variants": {
    "NOT_ESTIMABLE": {
      "admission": {
        "authority": "AUTHORITY_UNVERIFIED",
        "gates": [
          "A10_ADAPTER_UNVERIFIED",
          "EXPLANATION_TEMPLATE_AUTHORITY_UNVERIFIED",
          "REPORT_ADMISSION_REQUIRED",
          "SYNTHETIC_DATA_NOT_REPORTABLE"
        ],
        "real_reportable": false,
        "status": "HELD"
      },
      "campaign_id": "campaign-q01-synthetic",
      "chart_id": "chart:snap-q01-synthetic-0001-not-estimable:R02",
      "chart_type": "HORIZONTAL_BAR",
      "cohort_scope": "DEVELOPER_PREVIEW / qualification qual-q01-synthetic",
      "concept_version": "P3-01C-VNEXT-0.6.1-CUST-REC",
      "construct_id": "G01_AREA_AFFILIATION",
      "cutoff": "2026-11-22T09:00:00Z",
      "denominator_scope": "V = substantive answers to Q01 at this version and stimulus",
      "derived_lines": [],
      "evidence_context_hash": "d15c3eb41de9d29b621820eed986eb3ed716256c076782b5e56ad92d990c4b4f",
      "highest_options": [],
      "limitation": "Synthetic preview only. Forty fabricated respondents, aggregated by fixture arithmetic rather than by an EE-01 execution. No fielded response, no consent event and no real person is represented. Affiliation categories overlap, so counts sum above V; they are not a partition and not a census of residents. RARELY, NEVER and NOT_SURE are exclusive alternatives, counted separately and never treated as eligible or ineligible. Q01 has no declared numerator (Q01-NR-DEFAULT), so the shares shown are the mechanical 100*x/V demonstration and are not an authorized distribution.",
      "limitations": [
        "Synthetic preview only. Forty fabricated respondents, aggregated by fixture arithmetic rather than by an EE-01 execution. No fielded response, no consent event and no real person is represented. Affiliation categories overlap, so counts sum above V; they are not a partition and not a census of residents. RARELY, NEVER and NOT_SURE are exclusive alternatives, counted separately and never treated as eligible or ineligible. Q01 has no declared numerator (Q01-NR-DEFAULT), so the shares shown are the mechanical 100*x/V demonstration and are not an authorized distribution.",
        "Respondent residence; residential totals; demand counts; treating NOT_SURE as eligible or ineligible"
      ],
      "measurement": {
        "A": 40,
        "I": "UNKNOWN_NOT_ENUMERABLE",
        "Q": 44,
        "S": 41,
        "V": 0
      },
      "option_bank_version": "option-bank-q01-SYNTHETIC-PREVIEW",
      "options": [
        {
          "code": "LIVE",
          "count": 0,
          "label": "I live in this area",
          "label_source": "CONTRACT_OPTION_BANK_DRAFT",
          "ordinal_value": null,
          "percentage": null,
          "percentage_status": "NOT_ESTIMABLE"
        },
        {
          "code": "WORK",
          "count": 0,
          "label": "I work in this area",
          "label_source": "CONTRACT_OPTION_BANK_DRAFT",
          "ordinal_value": null,
          "percentage": null,
          "percentage_status": "NOT_ESTIMABLE"
        },
        {
          "code": "STUDY",
          "count": 0,
          "label": "I study in this area",
          "label_source": "CONTRACT_OPTION_BANK_DRAFT",
          "ordinal_value": null,
          "percentage": null,
          "percentage_status": "NOT_ESTIMABLE"
        },
        {
          "code": "RUN_BUSINESS",
          "count": 0,
          "label": "I operate a business in this area",
          "label_source": "CONTRACT_OPTION_BANK_DRAFT",
          "ordinal_value": null,
          "percentage": null,
          "percentage_status": "NOT_ESTIMABLE"
        },
        {
          "code": "VISIT_PURPOSE",
          "count": 0,
          "label": "I visit this area for activities or other purposes",
          "label_source": "CONTRACT_OPTION_BANK_DRAFT",
          "ordinal_value": null,
          "percentage": null,
          "percentage_status": "NOT_ESTIMABLE"
        },
        {
          "code": "PASS_THROUGH",
          "count": 0,
          "label": "I pass through this area",
          "label_source": "CONTRACT_OPTION_BANK_DRAFT",
          "ordinal_value": null,
          "percentage": null,
          "percentage_status": "NOT_ESTIMABLE"
        },
        {
          "code": "RARELY",
          "count": 0,
          "label": "Rarely",
          "label_source": "CONTRACT_OPTION_BANK_DRAFT",
          "ordinal_value": null,
          "percentage": null,
          "percentage_status": "NOT_ESTIMABLE"
        },
        {
          "code": "NEVER",
          "count": 0,
          "label": "Never",
          "label_source": "CONTRACT_OPTION_BANK_DRAFT",
          "ordinal_value": null,
          "percentage": null,
          "percentage_status": "NOT_ESTIMABLE"
        },
        {
          "code": "NOT_SURE",
          "count": 0,
          "label": "Not sure",
          "label_source": "CONTRACT_OPTION_BANK_DRAFT",
          "ordinal_value": null,
          "percentage": null,
          "percentage_status": "NOT_ESTIMABLE"
        }
      ],
      "question_id": "Q01",
      "question_text": "Which of the following describe your connection to [named area]? Select all that apply. If none apply, select one of: Rarely, Never, Not sure.",
      "question_version": "q01-v1-SYNTHETIC",
      "render_state": "NOT_ESTIMABLE",
      "report_sections": [
        "R02",
        "R08"
      ],
      "response_kind": "MULTI_SELECT",
      "schema_version": "chart-spec/1",
      "source_provenance": "SYNTHETIC_TEST",
      "stimulus_hash": "stimulus-q01-synthetic",
      "title": "Area connection — synthetic preview"
    },
    "SYNTHETIC_PREVIEW_ONLY": {
      "admission": {
        "authority": "AUTHORITY_UNVERIFIED",
        "gates": [
          "A10_ADAPTER_UNVERIFIED",
          "EXPLANATION_TEMPLATE_AUTHORITY_UNVERIFIED",
          "REPORT_ADMISSION_REQUIRED",
          "SYNTHETIC_DATA_NOT_REPORTABLE"
        ],
        "real_reportable": false,
        "status": "HELD"
      },
      "campaign_id": "campaign-q01-synthetic",
      "chart_id": "chart:snap-q01-synthetic-0001:R02",
      "chart_type": "HORIZONTAL_BAR",
      "cohort_scope": "DEVELOPER_PREVIEW / qualification qual-q01-synthetic",
      "concept_version": "P3-01C-VNEXT-0.6.1-CUST-REC",
      "construct_id": "G01_AREA_AFFILIATION",
      "cutoff": "2026-11-22T09:00:00Z",
      "denominator_scope": "V = 40 valid Q01 answers at this version and stimulus, including 6 who selected only an exclusive alternative; affiliations overlap and sum to 53",
      "derived_lines": [],
      "evidence_context_hash": "a58cb0f5e08ccfa7461227762717319f792380d788a8af3ab085e36646dd619c",
      "highest_options": [
        "LIVE"
      ],
      "limitation": "Synthetic preview only. Forty fabricated respondents, aggregated by fixture arithmetic rather than by an EE-01 execution. No fielded response, no consent event and no real person is represented. Affiliation categories overlap, so counts sum above V; they are not a partition and not a census of residents. RARELY, NEVER and NOT_SURE are exclusive alternatives, counted separately and never treated as eligible or ineligible. Q01 has no declared numerator (Q01-NR-DEFAULT), so the shares shown are the mechanical 100*x/V demonstration and are not an authorized distribution.",
      "limitations": [
        "Synthetic preview only. Forty fabricated respondents, aggregated by fixture arithmetic rather than by an EE-01 execution. No fielded response, no consent event and no real person is represented. Affiliation categories overlap, so counts sum above V; they are not a partition and not a census of residents. RARELY, NEVER and NOT_SURE are exclusive alternatives, counted separately and never treated as eligible or ineligible. Q01 has no declared numerator (Q01-NR-DEFAULT), so the shares shown are the mechanical 100*x/V demonstration and are not an authorized distribution.",
        "Respondent residence; residential totals; demand counts; treating NOT_SURE as eligible or ineligible"
      ],
      "measurement": {
        "A": 40,
        "I": "UNKNOWN_NOT_ENUMERABLE",
        "Q": 44,
        "S": 41,
        "V": 40
      },
      "option_bank_version": "option-bank-q01-SYNTHETIC-PREVIEW",
      "options": [
        {
          "code": "LIVE",
          "count": 15,
          "label": "I live in this area",
          "label_source": "CONTRACT_OPTION_BANK_DRAFT",
          "ordinal_value": null,
          "percentage": "37.5000",
          "percentage_status": "SYNTHETIC_PREVIEW_ESTIMABLE"
        },
        {
          "code": "WORK",
          "count": 12,
          "label": "I work in this area",
          "label_source": "CONTRACT_OPTION_BANK_DRAFT",
          "ordinal_value": null,
          "percentage": "30.0000",
          "percentage_status": "SYNTHETIC_PREVIEW_ESTIMABLE"
        },
        {
          "code": "STUDY",
          "count": 6,
          "label": "I study in this area",
          "label_source": "CONTRACT_OPTION_BANK_DRAFT",
          "ordinal_value": null,
          "percentage": "15.0000",
          "percentage_status": "SYNTHETIC_PREVIEW_ESTIMABLE"
        },
        {
          "code": "RUN_BUSINESS",
          "count": 4,
          "label": "I operate a business in this area",
          "label_source": "CONTRACT_OPTION_BANK_DRAFT",
          "ordinal_value": null,
          "percentage": "10.0000",
          "percentage_status": "SYNTHETIC_PREVIEW_ESTIMABLE"
        },
        {
          "code": "VISIT_PURPOSE",
          "count": 9,
          "label": "I visit this area for activities or other purposes",
          "label_source": "CONTRACT_OPTION_BANK_DRAFT",
          "ordinal_value": null,
          "percentage": "22.5000",
          "percentage_status": "SYNTHETIC_PREVIEW_ESTIMABLE"
        },
        {
          "code": "PASS_THROUGH",
          "count": 7,
          "label": "I pass through this area",
          "label_source": "CONTRACT_OPTION_BANK_DRAFT",
          "ordinal_value": null,
          "percentage": "17.5000",
          "percentage_status": "SYNTHETIC_PREVIEW_ESTIMABLE"
        },
        {
          "code": "RARELY",
          "count": 3,
          "label": "Rarely",
          "label_source": "CONTRACT_OPTION_BANK_DRAFT",
          "ordinal_value": null,
          "percentage": "7.5000",
          "percentage_status": "SYNTHETIC_PREVIEW_ESTIMABLE"
        },
        {
          "code": "NEVER",
          "count": 2,
          "label": "Never",
          "label_source": "CONTRACT_OPTION_BANK_DRAFT",
          "ordinal_value": null,
          "percentage": "5.0000",
          "percentage_status": "SYNTHETIC_PREVIEW_ESTIMABLE"
        },
        {
          "code": "NOT_SURE",
          "count": 1,
          "label": "Not sure",
          "label_source": "CONTRACT_OPTION_BANK_DRAFT",
          "ordinal_value": null,
          "percentage": "2.5000",
          "percentage_status": "SYNTHETIC_PREVIEW_ESTIMABLE"
        }
      ],
      "question_id": "Q01",
      "question_text": "Which of the following describe your connection to [named area]? Select all that apply. If none apply, select one of: Rarely, Never, Not sure.",
      "question_version": "q01-v1-SYNTHETIC",
      "render_state": "SYNTHETIC_PREVIEW_ONLY",
      "report_sections": [
        "R02",
        "R08"
      ],
      "response_kind": "MULTI_SELECT",
      "schema_version": "chart-spec/1",
      "source_provenance": "SYNTHETIC_TEST",
      "stimulus_hash": "stimulus-q01-synthetic",
      "title": "Area connection — synthetic preview"
    },
    "WITHHELD_NOT_AUTHORIZED": {
      "admission": {
        "authority": "AUTHORITY_UNVERIFIED",
        "gates": [
          "A10_ADAPTER_UNVERIFIED",
          "EXPLANATION_TEMPLATE_AUTHORITY_UNVERIFIED",
          "REPORT_ADMISSION_REQUIRED",
          "SYNTHETIC_DATA_NOT_REPORTABLE"
        ],
        "real_reportable": false,
        "status": "HELD"
      },
      "campaign_id": "campaign-q01-synthetic",
      "chart_id": "chart:snap-q01-synthetic-0001:R02",
      "chart_type": "HORIZONTAL_BAR",
      "cohort_scope": "DEVELOPER_PREVIEW / qualification qual-q01-synthetic",
      "concept_version": "P3-01C-VNEXT-0.6.1-CUST-REC",
      "construct_id": "G01_AREA_AFFILIATION",
      "cutoff": "2026-11-22T09:00:00Z",
      "denominator_scope": "V = 40 valid Q01 answers at this version and stimulus, including 6 who selected only an exclusive alternative; affiliations overlap and sum to 53",
      "derived_lines": [],
      "evidence_context_hash": "a58cb0f5e08ccfa7461227762717319f792380d788a8af3ab085e36646dd619c",
      "highest_options": [
        "LIVE"
      ],
      "limitation": "Synthetic preview only. Forty fabricated respondents, aggregated by fixture arithmetic rather than by an EE-01 execution. No fielded response, no consent event and no real person is represented. Affiliation categories overlap, so counts sum above V; they are not a partition and not a census of residents. RARELY, NEVER and NOT_SURE are exclusive alternatives, counted separately and never treated as eligible or ineligible. Q01 has no declared numerator (Q01-NR-DEFAULT), so the shares shown are the mechanical 100*x/V demonstration and are not an authorized distribution.",
      "limitations": [
        "Synthetic preview only. Forty fabricated respondents, aggregated by fixture arithmetic rather than by an EE-01 execution. No fielded response, no consent event and no real person is represented. Affiliation categories overlap, so counts sum above V; they are not a partition and not a census of residents. RARELY, NEVER and NOT_SURE are exclusive alternatives, counted separately and never treated as eligible or ineligible. Q01 has no declared numerator (Q01-NR-DEFAULT), so the shares shown are the mechanical 100*x/V demonstration and are not an authorized distribution.",
        "Respondent residence; residential totals; demand counts; treating NOT_SURE as eligible or ineligible"
      ],
      "measurement": {
        "A": 40,
        "I": "UNKNOWN_NOT_ENUMERABLE",
        "Q": 44,
        "S": 41,
        "V": 40
      },
      "option_bank_version": "option-bank-q01-SYNTHETIC-PREVIEW",
      "options": [
        {
          "code": "LIVE",
          "count": 15,
          "label": "I live in this area",
          "label_source": "CONTRACT_OPTION_BANK_DRAFT",
          "ordinal_value": null,
          "percentage": null,
          "percentage_status": "WITHHELD_NOT_AUTHORIZED"
        },
        {
          "code": "WORK",
          "count": 12,
          "label": "I work in this area",
          "label_source": "CONTRACT_OPTION_BANK_DRAFT",
          "ordinal_value": null,
          "percentage": null,
          "percentage_status": "WITHHELD_NOT_AUTHORIZED"
        },
        {
          "code": "STUDY",
          "count": 6,
          "label": "I study in this area",
          "label_source": "CONTRACT_OPTION_BANK_DRAFT",
          "ordinal_value": null,
          "percentage": null,
          "percentage_status": "WITHHELD_NOT_AUTHORIZED"
        },
        {
          "code": "RUN_BUSINESS",
          "count": 4,
          "label": "I operate a business in this area",
          "label_source": "CONTRACT_OPTION_BANK_DRAFT",
          "ordinal_value": null,
          "percentage": null,
          "percentage_status": "WITHHELD_NOT_AUTHORIZED"
        },
        {
          "code": "VISIT_PURPOSE",
          "count": 9,
          "label": "I visit this area for activities or other purposes",
          "label_source": "CONTRACT_OPTION_BANK_DRAFT",
          "ordinal_value": null,
          "percentage": null,
          "percentage_status": "WITHHELD_NOT_AUTHORIZED"
        },
        {
          "code": "PASS_THROUGH",
          "count": 7,
          "label": "I pass through this area",
          "label_source": "CONTRACT_OPTION_BANK_DRAFT",
          "ordinal_value": null,
          "percentage": null,
          "percentage_status": "WITHHELD_NOT_AUTHORIZED"
        },
        {
          "code": "RARELY",
          "count": 3,
          "label": "Rarely",
          "label_source": "CONTRACT_OPTION_BANK_DRAFT",
          "ordinal_value": null,
          "percentage": null,
          "percentage_status": "WITHHELD_NOT_AUTHORIZED"
        },
        {
          "code": "NEVER",
          "count": 2,
          "label": "Never",
          "label_source": "CONTRACT_OPTION_BANK_DRAFT",
          "ordinal_value": null,
          "percentage": null,
          "percentage_status": "WITHHELD_NOT_AUTHORIZED"
        },
        {
          "code": "NOT_SURE",
          "count": 1,
          "label": "Not sure",
          "label_source": "CONTRACT_OPTION_BANK_DRAFT",
          "ordinal_value": null,
          "percentage": null,
          "percentage_status": "WITHHELD_NOT_AUTHORIZED"
        }
      ],
      "question_id": "Q01",
      "question_text": "Which of the following describe your connection to [named area]? Select all that apply. If none apply, select one of: Rarely, Never, Not sure.",
      "question_version": "q01-v1-SYNTHETIC",
      "render_state": "WITHHELD_NOT_AUTHORIZED",
      "report_sections": [
        "R02",
        "R08"
      ],
      "response_kind": "MULTI_SELECT",
      "schema_version": "chart-spec/1",
      "source_provenance": "SYNTHETIC_TEST",
      "stimulus_hash": "stimulus-q01-synthetic",
      "title": "Area connection — synthetic preview"
    }
  },
  "construct_id": "G01_AREA_AFFILIATION",
  "counts": {
    "LIVE": 15,
    "NEVER": 2,
    "NOT_SURE": 1,
    "PASS_THROUGH": 7,
    "RARELY": 3,
    "RUN_BUSINESS": 4,
    "STUDY": 6,
    "VISIT_PURPOSE": 9,
    "WORK": 12
  },
  "denominator_scope": "V = 40 valid Q01 answers at this version and stimulus, including 6 who selected only an exclusive alternative; affiliations overlap and sum to 53",
  "evidence_context_hash": "a58cb0f5e08ccfa7461227762717319f792380d788a8af3ab085e36646dd619c",
  "explanation": {
    "V": 40,
    "affiliation_total": 53,
    "claim_scope": "SYNTHETIC_PREVIEW_ONLY_NOT_A_REPORT_FINDING",
    "exclusive_note": "RARELY, NEVER and NOT_SURE are exclusive alternatives. 6 respondents selected one of them and no affiliation. They are counted separately and are never added to the affiliation categories.",
    "exclusive_total": 6,
    "narrative_basis": "REGISTRY_VALID_TEMPLATE_FILLED_WITH_VERIFIED_SYNTHETIC_COUNTS",
    "not_a_report_finding": [
      "Not fielded data.",
      "Not an authorized measurement.",
      "Not admitted into R02 or R08.",
      "Not a census of residents, and not a demand, revenue or visit count.",
      "NOT_SURE is neither eligible nor ineligible."
    ],
    "preview_marker": "SYNTHETIC DEMONSTRATION — NOT REPORT EVIDENCE",
    "preview_submarker": "40 synthetic respondents. No real person, fielded response, customer database row or authorized measurement is represented here.",
    "production_path_behaviour": "The production explanation renderer withholds Q01 because instrument_gate is NOT_AUTHORIZED; this narrative exists only inside the synthetic preview.",
    "sentences": [
      {
        "code": "LIVE",
        "count": 15,
        "exclusive": false,
        "label": "I live in this area",
        "label_source": "CONTRACT_OPTION_BANK_DRAFT",
        "percentage": "37.5000",
        "text": "Among 40 valid Q01 respondents, 15 selected I live in this area. Categories may overlap; this is a self-reported affiliation distribution only."
      },
      {
        "code": "WORK",
        "count": 12,
        "exclusive": false,
        "label": "I work in this area",
        "label_source": "CONTRACT_OPTION_BANK_DRAFT",
        "percentage": "30.0000",
        "text": "Among 40 valid Q01 respondents, 12 selected I work in this area. Categories may overlap; this is a self-reported affiliation distribution only."
      },
      {
        "code": "STUDY",
        "count": 6,
        "exclusive": false,
        "label": "I study in this area",
        "label_source": "CONTRACT_OPTION_BANK_DRAFT",
        "percentage": "15.0000",
        "text": "Among 40 valid Q01 respondents, 6 selected I study in this area. Categories may overlap; this is a self-reported affiliation distribution only."
      },
      {
        "code": "RUN_BUSINESS",
        "count": 4,
        "exclusive": false,
        "label": "I operate a business in this area",
        "label_source": "CONTRACT_OPTION_BANK_DRAFT",
        "percentage": "10.0000",
        "text": "Among 40 valid Q01 respondents, 4 selected I operate a business in this area. Categories may overlap; this is a self-reported affiliation distribution only."
      },
      {
        "code": "VISIT_PURPOSE",
        "count": 9,
        "exclusive": false,
        "label": "I visit this area for activities or other purposes",
        "label_source": "CONTRACT_OPTION_BANK_DRAFT",
        "percentage": "22.5000",
        "text": "Among 40 valid Q01 respondents, 9 selected I visit this area for activities or other purposes. Categories may overlap; this is a self-reported affiliation distribution only."
      },
      {
        "code": "PASS_THROUGH",
        "count": 7,
        "exclusive": false,
        "label": "I pass through this area",
        "label_source": "CONTRACT_OPTION_BANK_DRAFT",
        "percentage": "17.5000",
        "text": "Among 40 valid Q01 respondents, 7 selected I pass through this area. Categories may overlap; this is a self-reported affiliation distribution only."
      },
      {
        "code": "RARELY",
        "count": 3,
        "exclusive": true,
        "label": "Rarely",
        "label_source": "CONTRACT_OPTION_BANK_DRAFT",
        "percentage": "7.5000",
        "text": "Among 40 valid Q01 respondents, 3 selected Rarely. Categories may overlap; this is a self-reported affiliation distribution only."
      },
      {
        "code": "NEVER",
        "count": 2,
        "exclusive": true,
        "label": "Never",
        "label_source": "CONTRACT_OPTION_BANK_DRAFT",
        "percentage": "5.0000",
        "text": "Among 40 valid Q01 respondents, 2 selected Never. Categories may overlap; this is a self-reported affiliation distribution only."
      },
      {
        "code": "NOT_SURE",
        "count": 1,
        "exclusive": true,
        "label": "Not sure",
        "label_source": "CONTRACT_OPTION_BANK_DRAFT",
        "percentage": "2.5000",
        "text": "Among 40 valid Q01 respondents, 1 selected Not sure. Categories may overlap; this is a self-reported affiliation distribution only."
      }
    ],
    "template_id": "VD-Q01-APPROVED",
    "template_text": "Among {V} valid Q01 respondents, {count} selected {category}. Categories may overlap; this is a self-reported affiliation distribution only."
  },
  "generated_at": "2026-11-22T09:00:00+00:00",
  "instrument_gate": "NOT_AUTHORIZED",
  "instrument_status": "BLOCKED_MEASUREMENT",
  "measurement": {
    "A": 40,
    "I": "UNKNOWN_NOT_ENUMERABLE",
    "Q": 44,
    "S": 41,
    "V": 40
  },
  "preview_marker": "SYNTHETIC DEMONSTRATION — NOT REPORT EVIDENCE",
  "preview_submarker": "40 synthetic respondents. No real person, fielded response, customer database row or authorized measurement is represented here.",
  "question_id": "Q01",
  "question_version": "q01-v1-SYNTHETIC",
  "render_state": "SYNTHETIC_PREVIEW_ONLY",
  "report_sections": [
    "R02",
    "R08"
  ],
  "respondent_summary": {
    "affiliation_selections": 53,
    "exclusive_only": 6,
    "exclusive_selections": 6,
    "overlap_selections": 19,
    "respondents": 40,
    "selections": 59,
    "substantive_respondents": 34
  },
  "schema_version": "q01-synthetic-preview/1",
  "section_admission": {
    "R02": {
      "administrative_only": true,
      "blocking_gates": [],
      "may_render_measurement": false,
      "reason": null,
      "scope_qualifier": null,
      "state": "RENDERABLE_ADMINISTRATIVE"
    },
    "R08": {
      "administrative_only": false,
      "blocking_gates": [
        "G01",
        "G07",
        "G08"
      ],
      "may_render_measurement": false,
      "reason": null,
      "scope_qualifier": "LIMITED_CONTEXT",
      "state": "SPECIFICATION_ONLY"
    }
  },
  "synthetic": {
    "cutoff": "2026-11-22T09:00:00+00:00",
    "fixture_module": "sitewise.project1.q01_synthetic_preview",
    "origin": "SYNTHETIC_TEST",
    "scope": "ISOLATED_TEST",
    "snapshot_id": "snap-q01-synthetic-0001",
    "synthetic_run_id": "run-q01-synthetic-0001"
  }
}''';

const String q01SyntheticPreviewChartJson = r'''{
  "admission": {
    "authority": "AUTHORITY_UNVERIFIED",
    "gates": [
      "A10_ADAPTER_UNVERIFIED",
      "EXPLANATION_TEMPLATE_AUTHORITY_UNVERIFIED",
      "REPORT_ADMISSION_REQUIRED",
      "SYNTHETIC_DATA_NOT_REPORTABLE"
    ],
    "real_reportable": false,
    "status": "HELD"
  },
  "campaign_id": "campaign-q01-synthetic",
  "chart_id": "chart:snap-q01-synthetic-0001:R02",
  "chart_type": "HORIZONTAL_BAR",
  "cohort_scope": "DEVELOPER_PREVIEW / qualification qual-q01-synthetic",
  "concept_version": "P3-01C-VNEXT-0.6.1-CUST-REC",
  "construct_id": "G01_AREA_AFFILIATION",
  "cutoff": "2026-11-22T09:00:00Z",
  "denominator_scope": "V = 40 valid Q01 answers at this version and stimulus, including 6 who selected only an exclusive alternative; affiliations overlap and sum to 53",
  "derived_lines": [],
  "evidence_context_hash": "a58cb0f5e08ccfa7461227762717319f792380d788a8af3ab085e36646dd619c",
  "highest_options": [
    "LIVE"
  ],
  "limitation": "Synthetic preview only. Forty fabricated respondents, aggregated by fixture arithmetic rather than by an EE-01 execution. No fielded response, no consent event and no real person is represented. Affiliation categories overlap, so counts sum above V; they are not a partition and not a census of residents. RARELY, NEVER and NOT_SURE are exclusive alternatives, counted separately and never treated as eligible or ineligible. Q01 has no declared numerator (Q01-NR-DEFAULT), so the shares shown are the mechanical 100*x/V demonstration and are not an authorized distribution.",
  "limitations": [
    "Synthetic preview only. Forty fabricated respondents, aggregated by fixture arithmetic rather than by an EE-01 execution. No fielded response, no consent event and no real person is represented. Affiliation categories overlap, so counts sum above V; they are not a partition and not a census of residents. RARELY, NEVER and NOT_SURE are exclusive alternatives, counted separately and never treated as eligible or ineligible. Q01 has no declared numerator (Q01-NR-DEFAULT), so the shares shown are the mechanical 100*x/V demonstration and are not an authorized distribution.",
    "Respondent residence; residential totals; demand counts; treating NOT_SURE as eligible or ineligible"
  ],
  "measurement": {
    "A": 40,
    "I": "UNKNOWN_NOT_ENUMERABLE",
    "Q": 44,
    "S": 41,
    "V": 40
  },
  "option_bank_version": "option-bank-q01-SYNTHETIC-PREVIEW",
  "options": [
    {
      "code": "LIVE",
      "count": 15,
      "label": "I live in this area",
      "label_source": "CONTRACT_OPTION_BANK_DRAFT",
      "ordinal_value": null,
      "percentage": "37.5000",
      "percentage_status": "SYNTHETIC_PREVIEW_ESTIMABLE"
    },
    {
      "code": "WORK",
      "count": 12,
      "label": "I work in this area",
      "label_source": "CONTRACT_OPTION_BANK_DRAFT",
      "ordinal_value": null,
      "percentage": "30.0000",
      "percentage_status": "SYNTHETIC_PREVIEW_ESTIMABLE"
    },
    {
      "code": "STUDY",
      "count": 6,
      "label": "I study in this area",
      "label_source": "CONTRACT_OPTION_BANK_DRAFT",
      "ordinal_value": null,
      "percentage": "15.0000",
      "percentage_status": "SYNTHETIC_PREVIEW_ESTIMABLE"
    },
    {
      "code": "RUN_BUSINESS",
      "count": 4,
      "label": "I operate a business in this area",
      "label_source": "CONTRACT_OPTION_BANK_DRAFT",
      "ordinal_value": null,
      "percentage": "10.0000",
      "percentage_status": "SYNTHETIC_PREVIEW_ESTIMABLE"
    },
    {
      "code": "VISIT_PURPOSE",
      "count": 9,
      "label": "I visit this area for activities or other purposes",
      "label_source": "CONTRACT_OPTION_BANK_DRAFT",
      "ordinal_value": null,
      "percentage": "22.5000",
      "percentage_status": "SYNTHETIC_PREVIEW_ESTIMABLE"
    },
    {
      "code": "PASS_THROUGH",
      "count": 7,
      "label": "I pass through this area",
      "label_source": "CONTRACT_OPTION_BANK_DRAFT",
      "ordinal_value": null,
      "percentage": "17.5000",
      "percentage_status": "SYNTHETIC_PREVIEW_ESTIMABLE"
    },
    {
      "code": "RARELY",
      "count": 3,
      "label": "Rarely",
      "label_source": "CONTRACT_OPTION_BANK_DRAFT",
      "ordinal_value": null,
      "percentage": "7.5000",
      "percentage_status": "SYNTHETIC_PREVIEW_ESTIMABLE"
    },
    {
      "code": "NEVER",
      "count": 2,
      "label": "Never",
      "label_source": "CONTRACT_OPTION_BANK_DRAFT",
      "ordinal_value": null,
      "percentage": "5.0000",
      "percentage_status": "SYNTHETIC_PREVIEW_ESTIMABLE"
    },
    {
      "code": "NOT_SURE",
      "count": 1,
      "label": "Not sure",
      "label_source": "CONTRACT_OPTION_BANK_DRAFT",
      "ordinal_value": null,
      "percentage": "2.5000",
      "percentage_status": "SYNTHETIC_PREVIEW_ESTIMABLE"
    }
  ],
  "question_id": "Q01",
  "question_text": "Which of the following describe your connection to [named area]? Select all that apply. If none apply, select one of: Rarely, Never, Not sure.",
  "question_version": "q01-v1-SYNTHETIC",
  "render_state": "SYNTHETIC_PREVIEW_ONLY",
  "report_sections": [
    "R02",
    "R08"
  ],
  "response_kind": "MULTI_SELECT",
  "schema_version": "chart-spec/1",
  "source_provenance": "SYNTHETIC_TEST",
  "stimulus_hash": "stimulus-q01-synthetic",
  "title": "Area connection — synthetic preview"
}''';

const String q01HeldChartJson = r'''{
  "admission": {
    "authority": "AUTHORITY_UNVERIFIED",
    "gates": [
      "A10_ADAPTER_UNVERIFIED",
      "EXPLANATION_TEMPLATE_AUTHORITY_UNVERIFIED",
      "REPORT_ADMISSION_REQUIRED",
      "SYNTHETIC_DATA_NOT_REPORTABLE"
    ],
    "real_reportable": false,
    "status": "HELD"
  },
  "campaign_id": "campaign-q01-synthetic",
  "chart_id": "chart:snap-q01-synthetic-0001:R02",
  "chart_type": "HORIZONTAL_BAR",
  "cohort_scope": "DEVELOPER_PREVIEW / qualification qual-q01-synthetic",
  "concept_version": "P3-01C-VNEXT-0.6.1-CUST-REC",
  "construct_id": "G01_AREA_AFFILIATION",
  "cutoff": "2026-11-22T09:00:00Z",
  "denominator_scope": "V = 40 valid Q01 answers at this version and stimulus, including 6 who selected only an exclusive alternative; affiliations overlap and sum to 53",
  "derived_lines": [],
  "evidence_context_hash": "a58cb0f5e08ccfa7461227762717319f792380d788a8af3ab085e36646dd619c",
  "highest_options": [
    "LIVE"
  ],
  "limitation": "Synthetic preview only. Forty fabricated respondents, aggregated by fixture arithmetic rather than by an EE-01 execution. No fielded response, no consent event and no real person is represented. Affiliation categories overlap, so counts sum above V; they are not a partition and not a census of residents. RARELY, NEVER and NOT_SURE are exclusive alternatives, counted separately and never treated as eligible or ineligible. Q01 has no declared numerator (Q01-NR-DEFAULT), so the shares shown are the mechanical 100*x/V demonstration and are not an authorized distribution.",
  "limitations": [
    "Synthetic preview only. Forty fabricated respondents, aggregated by fixture arithmetic rather than by an EE-01 execution. No fielded response, no consent event and no real person is represented. Affiliation categories overlap, so counts sum above V; they are not a partition and not a census of residents. RARELY, NEVER and NOT_SURE are exclusive alternatives, counted separately and never treated as eligible or ineligible. Q01 has no declared numerator (Q01-NR-DEFAULT), so the shares shown are the mechanical 100*x/V demonstration and are not an authorized distribution.",
    "Respondent residence; residential totals; demand counts; treating NOT_SURE as eligible or ineligible"
  ],
  "measurement": {
    "A": 40,
    "I": "UNKNOWN_NOT_ENUMERABLE",
    "Q": 44,
    "S": 41,
    "V": 40
  },
  "option_bank_version": "option-bank-q01-SYNTHETIC-PREVIEW",
  "options": [
    {
      "code": "LIVE",
      "count": 15,
      "label": "I live in this area",
      "label_source": "CONTRACT_OPTION_BANK_DRAFT",
      "ordinal_value": null,
      "percentage": null,
      "percentage_status": "WITHHELD_NOT_AUTHORIZED"
    },
    {
      "code": "WORK",
      "count": 12,
      "label": "I work in this area",
      "label_source": "CONTRACT_OPTION_BANK_DRAFT",
      "ordinal_value": null,
      "percentage": null,
      "percentage_status": "WITHHELD_NOT_AUTHORIZED"
    },
    {
      "code": "STUDY",
      "count": 6,
      "label": "I study in this area",
      "label_source": "CONTRACT_OPTION_BANK_DRAFT",
      "ordinal_value": null,
      "percentage": null,
      "percentage_status": "WITHHELD_NOT_AUTHORIZED"
    },
    {
      "code": "RUN_BUSINESS",
      "count": 4,
      "label": "I operate a business in this area",
      "label_source": "CONTRACT_OPTION_BANK_DRAFT",
      "ordinal_value": null,
      "percentage": null,
      "percentage_status": "WITHHELD_NOT_AUTHORIZED"
    },
    {
      "code": "VISIT_PURPOSE",
      "count": 9,
      "label": "I visit this area for activities or other purposes",
      "label_source": "CONTRACT_OPTION_BANK_DRAFT",
      "ordinal_value": null,
      "percentage": null,
      "percentage_status": "WITHHELD_NOT_AUTHORIZED"
    },
    {
      "code": "PASS_THROUGH",
      "count": 7,
      "label": "I pass through this area",
      "label_source": "CONTRACT_OPTION_BANK_DRAFT",
      "ordinal_value": null,
      "percentage": null,
      "percentage_status": "WITHHELD_NOT_AUTHORIZED"
    },
    {
      "code": "RARELY",
      "count": 3,
      "label": "Rarely",
      "label_source": "CONTRACT_OPTION_BANK_DRAFT",
      "ordinal_value": null,
      "percentage": null,
      "percentage_status": "WITHHELD_NOT_AUTHORIZED"
    },
    {
      "code": "NEVER",
      "count": 2,
      "label": "Never",
      "label_source": "CONTRACT_OPTION_BANK_DRAFT",
      "ordinal_value": null,
      "percentage": null,
      "percentage_status": "WITHHELD_NOT_AUTHORIZED"
    },
    {
      "code": "NOT_SURE",
      "count": 1,
      "label": "Not sure",
      "label_source": "CONTRACT_OPTION_BANK_DRAFT",
      "ordinal_value": null,
      "percentage": null,
      "percentage_status": "WITHHELD_NOT_AUTHORIZED"
    }
  ],
  "question_id": "Q01",
  "question_text": "Which of the following describe your connection to [named area]? Select all that apply. If none apply, select one of: Rarely, Never, Not sure.",
  "question_version": "q01-v1-SYNTHETIC",
  "render_state": "WITHHELD_NOT_AUTHORIZED",
  "report_sections": [
    "R02",
    "R08"
  ],
  "response_kind": "MULTI_SELECT",
  "schema_version": "chart-spec/1",
  "source_provenance": "SYNTHETIC_TEST",
  "stimulus_hash": "stimulus-q01-synthetic",
  "title": "Area connection — synthetic preview"
}''';

const String q01NotEstimableChartJson = r'''{
  "admission": {
    "authority": "AUTHORITY_UNVERIFIED",
    "gates": [
      "A10_ADAPTER_UNVERIFIED",
      "EXPLANATION_TEMPLATE_AUTHORITY_UNVERIFIED",
      "REPORT_ADMISSION_REQUIRED",
      "SYNTHETIC_DATA_NOT_REPORTABLE"
    ],
    "real_reportable": false,
    "status": "HELD"
  },
  "campaign_id": "campaign-q01-synthetic",
  "chart_id": "chart:snap-q01-synthetic-0001-not-estimable:R02",
  "chart_type": "HORIZONTAL_BAR",
  "cohort_scope": "DEVELOPER_PREVIEW / qualification qual-q01-synthetic",
  "concept_version": "P3-01C-VNEXT-0.6.1-CUST-REC",
  "construct_id": "G01_AREA_AFFILIATION",
  "cutoff": "2026-11-22T09:00:00Z",
  "denominator_scope": "V = substantive answers to Q01 at this version and stimulus",
  "derived_lines": [],
  "evidence_context_hash": "d15c3eb41de9d29b621820eed986eb3ed716256c076782b5e56ad92d990c4b4f",
  "highest_options": [],
  "limitation": "Synthetic preview only. Forty fabricated respondents, aggregated by fixture arithmetic rather than by an EE-01 execution. No fielded response, no consent event and no real person is represented. Affiliation categories overlap, so counts sum above V; they are not a partition and not a census of residents. RARELY, NEVER and NOT_SURE are exclusive alternatives, counted separately and never treated as eligible or ineligible. Q01 has no declared numerator (Q01-NR-DEFAULT), so the shares shown are the mechanical 100*x/V demonstration and are not an authorized distribution.",
  "limitations": [
    "Synthetic preview only. Forty fabricated respondents, aggregated by fixture arithmetic rather than by an EE-01 execution. No fielded response, no consent event and no real person is represented. Affiliation categories overlap, so counts sum above V; they are not a partition and not a census of residents. RARELY, NEVER and NOT_SURE are exclusive alternatives, counted separately and never treated as eligible or ineligible. Q01 has no declared numerator (Q01-NR-DEFAULT), so the shares shown are the mechanical 100*x/V demonstration and are not an authorized distribution.",
    "Respondent residence; residential totals; demand counts; treating NOT_SURE as eligible or ineligible"
  ],
  "measurement": {
    "A": 40,
    "I": "UNKNOWN_NOT_ENUMERABLE",
    "Q": 44,
    "S": 41,
    "V": 0
  },
  "option_bank_version": "option-bank-q01-SYNTHETIC-PREVIEW",
  "options": [
    {
      "code": "LIVE",
      "count": 0,
      "label": "I live in this area",
      "label_source": "CONTRACT_OPTION_BANK_DRAFT",
      "ordinal_value": null,
      "percentage": null,
      "percentage_status": "NOT_ESTIMABLE"
    },
    {
      "code": "WORK",
      "count": 0,
      "label": "I work in this area",
      "label_source": "CONTRACT_OPTION_BANK_DRAFT",
      "ordinal_value": null,
      "percentage": null,
      "percentage_status": "NOT_ESTIMABLE"
    },
    {
      "code": "STUDY",
      "count": 0,
      "label": "I study in this area",
      "label_source": "CONTRACT_OPTION_BANK_DRAFT",
      "ordinal_value": null,
      "percentage": null,
      "percentage_status": "NOT_ESTIMABLE"
    },
    {
      "code": "RUN_BUSINESS",
      "count": 0,
      "label": "I operate a business in this area",
      "label_source": "CONTRACT_OPTION_BANK_DRAFT",
      "ordinal_value": null,
      "percentage": null,
      "percentage_status": "NOT_ESTIMABLE"
    },
    {
      "code": "VISIT_PURPOSE",
      "count": 0,
      "label": "I visit this area for activities or other purposes",
      "label_source": "CONTRACT_OPTION_BANK_DRAFT",
      "ordinal_value": null,
      "percentage": null,
      "percentage_status": "NOT_ESTIMABLE"
    },
    {
      "code": "PASS_THROUGH",
      "count": 0,
      "label": "I pass through this area",
      "label_source": "CONTRACT_OPTION_BANK_DRAFT",
      "ordinal_value": null,
      "percentage": null,
      "percentage_status": "NOT_ESTIMABLE"
    },
    {
      "code": "RARELY",
      "count": 0,
      "label": "Rarely",
      "label_source": "CONTRACT_OPTION_BANK_DRAFT",
      "ordinal_value": null,
      "percentage": null,
      "percentage_status": "NOT_ESTIMABLE"
    },
    {
      "code": "NEVER",
      "count": 0,
      "label": "Never",
      "label_source": "CONTRACT_OPTION_BANK_DRAFT",
      "ordinal_value": null,
      "percentage": null,
      "percentage_status": "NOT_ESTIMABLE"
    },
    {
      "code": "NOT_SURE",
      "count": 0,
      "label": "Not sure",
      "label_source": "CONTRACT_OPTION_BANK_DRAFT",
      "ordinal_value": null,
      "percentage": null,
      "percentage_status": "NOT_ESTIMABLE"
    }
  ],
  "question_id": "Q01",
  "question_text": "Which of the following describe your connection to [named area]? Select all that apply. If none apply, select one of: Rarely, Never, Not sure.",
  "question_version": "q01-v1-SYNTHETIC",
  "render_state": "NOT_ESTIMABLE",
  "report_sections": [
    "R02",
    "R08"
  ],
  "response_kind": "MULTI_SELECT",
  "schema_version": "chart-spec/1",
  "source_provenance": "SYNTHETIC_TEST",
  "stimulus_hash": "stimulus-q01-synthetic",
  "title": "Area connection — synthetic preview"
}''';
