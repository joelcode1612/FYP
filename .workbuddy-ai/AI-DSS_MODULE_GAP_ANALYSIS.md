# AI-DSS Module Gap Analysis — Proposed UI Additions

**Source document:** `RSW_JEDTANHOUJIE_Project1.docx.pdf` (133 pages, "Evidence-Based
AI-Assisted Decision Support System (AI-DSS)", by Jed Tan Hou Jie, BMCS3043 Project I)

**Target project:** `C:\Users\Lenovo\AndroidStudioProjects\FYP` (Sitewise)

**Purpose:** Identify which modules/UI the report specifies that the current app does not
yet have, and describe exactly what would be added. **No code has been written yet.**

---

## 1. The critical finding: the report describes TWO subsystems

The report (p.82, §4.1) states the proposed system integrates **two** systems into one
platform:

| Subsystem | Status in your app |
|---|---|
| **AI-Enhanced Geospatial Recommendation System** (property selection) | **~85% present** |
| **Evidence-Based AI-DSS** (adaptive assessment → decision engine → explainable report) | **~0% present** |

Your app is essentially **subsystem 1**. The report's research contribution — and most of
its module list — is **subsystem 2**, which has not been built.

**Evidence:** `grep -ri "benchmark" lib/` returns **0 matches**. There is no Assessment,
Question Bank, EGD-CS, Evidence Processing, Decision Engine, RAG/Explanation, or
Business-Knowledge-Catalogue code anywhere in the project. The only "assessment" strings
are landing-page marketing copy (`landing_content.dart:110-111`).

---

## 2. Modules named in the report (§1.6 Project Team, pp.18-21)

### 2a. Modules already covered by your app (property half)

| Report module | Your equivalent | Status |
|---|---|---|
| User Management & Authentication | `auth_service`, `mobile_auth_page` | ✅ |
| Administration Module | `admin_users/verification/listings` (web+mobile) | ✅ |
| Commercial Property Management | `owner_add_property`, `owner_properties`, `property_service` | ✅ |
| Data Processing & Geospatial Intelligence | `intelligence_usecases`, `location_intelligence` | ✅ (analysis only) |
| Entrepreneur Preference Management | `entrepreneur_preferences_*` | ✅ |
| AI Recommendation Module | `recommendation_service`, `entrepreneur_recommendations_*` | ⚠️ present, but scores are heuristic — report specifies **Positive-Unlabeled Learning** (REQ-310) |
| Explainable AI Module | `sitewise_factor_row`, `sitewise_evidence_score` | ⚠️ partial — no grounded-explanation generation |
| Interactive Map Module | — | ❌ **no map library** (`flutter_map`/Google Maps absent) |
| 360° Virtual Tour Module | `panorama_capture_service`, `tour_*` pages | ✅ |
| Reporting Module | `entrepreneur_report_*` | ⚠️ partial |

### 2b. Modules entirely MISSING (the AI-DSS half)

| # | Report module | Report ref |
|---|---|---|
| M1 | **Knowledge Management** (business knowledge, benchmarks, literature, versioning) | FR-01…FR-04 |
| M2 | **Assessment Orchestration** (create/state/associate sessions) | FR-05…FR-08 |
| M3 | **Adaptive Questionnaire** (phases, display logic, priority, EGD-CS selection) | FR-09…FR-13 |
| M4 | **Evidence Processing** (transform, validate, aggregate, confidence, insufficient) | FR-14…FR-18 |
| M5 | **Decision Analysis / Decision Engine** (benchmarks, compare, findings, statuses, deviation, traceability) | FR-19…FR-25 |
| M6 | **Recommendation Management** (associate, rank, preserve linkage) | FR-26…FR-28 |
| M7 | **AI/RAG Integration & Knowledge Retrieval** (retrieve grounding, grounded context, generate explanation, protect findings) | FR-29…FR-34 |
| M8 | **Report Generation** (assessment report, findings, explanations, audit trace) | FR-35…FR-38 |

---

## 3. The report's UI specification (§4.6, pp.116-127) — 14 screens

This is the authoritative screen list. It is split by platform:

### Mobile — "Mobile Questionnaire Interface" (4 screens)

| | Screen | Report ref | Status |
|---|---|---|---|
| a | **Assessment Start** — assessment info, status, progress | Fig 4.6.1(a) | ❌ |
| b | **Answer Question** — answer current questionnaire item | Fig 4.6.1(b) | ❌ |
| c | **Add Evidence** — submit supporting photo/file/link | Fig 4.6.1(c) | ❌ |
| d | **Questionnaire Completion** — confirm submission | Fig 4.6.1(d) | ❌ |

> Note: your app **already has** a 5-stage onboarding questionnaire
> (`onboarding_flow_page`) — but it collects *marketing preferences*, not assessed business
> evidence. The report's questionnaire is a different, evidence-producing instrument.

### Web — "Web-Based Assessment Management and Decision Support Interface" (10 screens)

| | Screen | Report ref | Status |
|---|---|---|---|
| a | **Dashboard** — assessments, key statistics, recent activity | Fig 4.7.2(a) | ❌ |
| b | **Assessment Management** — view/search/filter/manage assessments | Fig 4.7.2(b) | ❌ |
| c | **Create Assessment** — site, business, assessment info | Fig 4.7.2(c) | ❌ |
| d | **Assessment Overview** — progress, site info, section access | Fig 4.7.2(d) | ❌ |
| e | **Metrics and Analytics** — KPI cards + charts of variables/benchmark status | Fig 4.7.2(e) | ❌ |
| f | **Decision Findings** — variables vs benchmarks | Fig 4.7.2(f) | ❌ |
| g | **Recommendations** — recommended actions + priorities | Fig 4.7.2(g) | ❌ |
| h | **Assessment Report** — summary, findings, analysis, recommendations | Fig 4.7.2(h) | ❌ |
| i | **AI Explanation** — natural-language explanations of findings | Fig 4.7.2(i) | ❌ |
| j | **Decision Traceability** — full chain: responses → evidence → benchmarks → findings → recommendations → report | Fig 4.7.2(j) | ❌ |

---

## 4. Hard requirements from the report that constrain any UI

These come from the use cases (§3.2.1) and functional requirements (§3.2.2). They matter
because they forbid common UI shortcuts:

- **C6 — Determinism:** identical evidence states must produce identical question selections.
  No randomness anywhere in the questionnaire flow.
- **C9 / FR-33 / FR-34 — LLM boundary:** LLM output must **never** change decision findings
  or determine the business decision. Explanations are display-only.
- **FR-22 — Decision statuses** must be exactly: `BELOW_THRESHOLD`, `ON_TRACK`,
  `ABOVE_THRESHOLD`, `NO_BENCHMARK`.
- **FR-17 — Evidence confidence** must be `HIGH` / `MEDIUM` / `LOW`.
- **FR-18 / REQ alternate flow A2** — an `INSUFFICIENT_DATA` status must exist and must
  *block* completion where mandatory evidence is short (C7).
- **Alternate flow A3** — an `EXHAUSTED` stopping reason when no eligible question remains.
- **FR-25 / FR-38 — Traceability is mandatory**, not decorative: every finding must link
  back to its evidence and benchmark; reports must carry an audit trace.
- **ASR-1** — Flutter Mobile **and** Flutter Web from one shared codebase (matches your
  current `presentation/{mobile,web}` split).
- **ASR-2** — Google Gemini / OpenStreetMap / Supabase must sit behind repository
  abstractions, never in widgets (matches your existing architecture rule).

---

## 5. Proposed additions — three options

### Option A — Mobile questionnaire only (smallest, matches §4.6 mobile spec)

**Adds:** 4 mobile screens + the domain/data layer to support them.

- `domain/entities/` — `assessment_session`, `assessment_question`, `question_response`,
  `evidence_record`, `evidence_state`
- `domain/services/` — `evidence_gap_selector` (the EGD-CS mechanism)
- `application/services/` — `assessment_service`
- `presentation/mobile/assessment/pages/` — `assessment_start_page`,
  `assessment_question_page`, `assessment_evidence_page`, `assessment_complete_page`

**Cost:** moderate. **Delivers:** the report's mobile UI figure exactly.

### Option B — Full AI-DSS (mobile + web, all 14 screens)

**Adds:** everything in Option A, plus 10 web screens and the whole decision pipeline
(Evidence Processing → Decision Engine → Recommendations → RAG → Report → Traceability),
plus a Knowledge Management module for administrators.

**Cost:** large — this is effectively a second application. **Delivers:** the full report.

### Option C — Hybrid (recommended)

Build the **complete non-visual core** (entities, EGD-CS selector, evidence processing,
decision engine, traceability), then the **7 highest-value screens**:

1. Mobile: Answer Question + Questionnaire Completion
2. Web: Create Assessment, Assessment Overview, Decision Findings, Recommendations,
   Decision Traceability

**Cost:** medium. **Delivers:** a demonstrable end-to-end assessment→finding→explanation
chain, covering every module's "happy path" so the report's claims can be evidenced.
Screens omitted (Dashboard, Metrics, Assessment Management, AI Explanation, Report, mobile
Start/Add-Evidence) can follow one at a time.

---

## 6. What I need from you before writing any code

1. **Which option** — A, B, or C?
2. **Which project** — `FYP` (your real project) or `Sitewise_UI_Experiment` (sandbox)?
3. **Map module** — the report requires an Interactive Map (REQ-501…REQ-511). Your app has
   none. Do you want it added, or deferred? It needs a new dependency (`flutter_map` +
   OpenStreetMap, per ASR-2).
4. **PGx / real AI** — is the app still in demo-data mode? The report's RAG layer assumes a
   Gemini key; if absent, explanations must be template-generated (which still satisfies
   FR-32, since explanation text is not a decision).

---

## 7. Honest limitations of this analysis

- The report's UI figures (pp.116-125) are **embedded raster images**, so I could read their
  **captions** (which name all 14 screens) but **not the mockup visuals**. Screen names and
  purposes are therefore reliable; exact pixel layouts are not.
- Requirements I quoted are verbatim from the PDF's extracted text and tables.
- Your app was inspected by grep/glob only; I have not run it (`flutter` CLI is broken on
  this machine — Windows pipe-pool exhaustion).
