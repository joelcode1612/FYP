# FYP Implementation Audit — Excluding 360° Virtual Tour Module

**Project:** AI-Enhanced Geospatial Recommendation System for F&B Commercial Property Selection
**Audited artefact:** `C:\Users\Lenovo\AndroidStudioProjects\FYP` (working tree `C:\Users\Lenovo\AndroidStudioProjects\FYP`)
**Authoritative source document:** `C:\Users\Lenovo\OneDrive\Desktop\RSW_JOELTANHOUJUN_Project1.pdf` (107 pages; metadata title "FYP Report Template.docx"; Chapters 1–4 + References — **no Chapter 5 exists**)
**Audit date:** 2026-10-15
**Audit mode:** Read-only. No source file, database object, dependency or configuration was created or modified. The only filesystem change made by this audit is the creation of the `docs/` directory and this report.

---

## 0. Scope Declaration and Exclusion Statement

### 0.1 360° Virtual Tour Module — Fully Excluded

The 360° Virtual Tour Module was removed **at the point of inventory construction**, not subtracted at the end. The following items were never entered into the requirement inventory, and therefore never appear in any total, percentage, outstanding-work count, priority list or recommendation in this report:

| Excluded artefact | Reason |
|---|---|
| `360_CAPTURE_ASSESSMENT.md` | Entirely 360°-scoped document |
| `REQ-801` – `REQ-808` (8 requirements) | 360° Panorama Viewer, Navigation, Overlay, Access, Upload, Preview, Edit, Delete |
| `FR-801` – `FR-808` | 360° cross-references in use-case basic flows |
| Use Case 4.4.8 / `UC111` "View and Manage 360° Virtual Tour" | 360° use case |
| `REQ-903` / `FR-903` "360° Virtual Tour Management" | 360° administration |
| `VIRTUAL_TOUR` table (§4.6 database schema) | 360° persistence |
| §4.9.1.4 and the §1.6 module entry "360° Virtual Tour Module" | 360° UI and module list |
| Report scope row "360° Virtual Tour" | 360° scope |

Partial-360 items were **trimmed, not counted**. Specifically: `REQ-902` (Property Verification Management) is retained in scope but its documented tenant-verification component is excluded; `REQ-906` (System Monitoring) is retained but any tour-verification statistics are excluded; `UC112` (Administer System and Verify Content) is retained with its virtual-tour verification step struck.

The following source files were identified as 360°-scoped and were **not audited**: `panorama_capture_page.dart`, `panorama_capture_viewmodel.dart`, `panorama_stitcher.dart`, `capture_frame_store.dart`, `mobile_tour_viewer.dart`, `tour_visual.dart`, `virtual_tour.dart`, `tour_service.dart`, `capture_target_data_source.dart`, `capture_config.dart`, `capture_point.dart`, `capture_session_state.dart`, `captured_frame.dart`, `ar_math.dart`, `capture_guidance_overlay.dart`, `tour_preview_page.dart`, `tour_preview_mobile_page.dart`, `tour_preview_viewmodel.dart`, `tours_page.dart`, `owner_tours_mobile_page.dart`, and the routes `/owner/capture`, `/owner/tours`, `/owner/tour-preview`, `/entrepreneur/tour`.

### 0.2 In-Scope Requirement Universe

| Layer | Count | Source |
|---|---|---|
| Functional requirements (`REQ-###`) | **45** | Report §3.2.1, pages 44–52, Table 3.3 |
| Non-functional requirements (`NFR##`) | **5** | Report §3.2.2, pages 52–54 |
| Architecture-significant requirements (`ASR-##`) | **5** | Report §4.1.2, page 58 |
| **ID-bearing in-scope total** | **55** | Primary denominator |
| Derived documented items without REQ/NFR/ASR IDs (Modules C, D, G, H, I, J) | **26** | §1.6 module list, §4.5–4.9 design sections |
| **Grand in-scope total** | **81** | Secondary denominator |

The report assigns **no requirement IDs** to several modules it nonetheless documents as deliverables in §1.6 (Entrepreneur Preference Management, Positive-Unlabeled Learning, Knowledge Management, Assessment Orchestration, Adaptive Questionnaire, Evidence Processing, Decision Analysis, Recommendation Management, AI/RAG Integration, Backend API, Database). Those are inventoried as derived items (`C-`, `D-`, `G-`, `H-`, `I-`, `J-`). Because they are ID-less, the headline completion rate is computed over the **55 ID-bearing requirements**, with the 81-item figure reported separately so the primary metric remains unambiguous.

### 0.3 Status Enumeration

Exactly one status is assigned per requirement:

`DONE` · `PARTIAL` · `NOT DONE` · `BROKEN` · `BLOCKED-UNVERIFIED` · `OUT OF SCOPE`

- **DONE** — the documented capability exists and operates on real data end-to-end in the audited code.
- **PARTIAL** — a surface exists but the underlying computation/data is absent, or the capability works in only one of the two UI trees, or the capability is non-persistent/placeholder-only.
- **NOT DONE** — no meaningful implementation exists.
- **BROKEN** — implemented but demonstrably non-functional (contradictory or dead code path).
- **BLOCKED-UNVERIFIED** — code exists whose runtime behaviour could not be validated in this environment.
- **OUT OF SCOPE** — excluded per §0.1 (used only in the master table legend, never in any count).

### 0.4 Verification Method and Its Hard Limits

**Method.** Static source inspection of all 219 `.dart` files across `fyp_mobile_app/`, `fyp_jaspr_web/` and `shared_logic/`; inspection of `pubspec.yaml` manifests, `web/styles.css`, the root Node/Express map server, and the root data files; extraction and reading of the report PDF text and tables with PyMuPDF.

**Hard limits — stated plainly:**

1. **No application was run, built, compiled or served.** No APK, no web bundle, no dev server. No screenshot was captured.
2. **No test was executed.** `dart --version` and `dart test` both **hang indefinitely** on this machine (independently confirmed at >120 s and >240 s; two background jobs were killed). This matches the pipe-pool exhaustion limitation already documented in `.workbuddy-ai/AI-DSS_MODULE_GAP_ANALYSIS.md`. The test counts claimed in `ARCHITECTURE_AUDIT.md` (`flutter test fyp_mobile_app` 27/27, `dart test` 18/18) and `README.md` are therefore **not reproducible here** and are recorded as **BLOCKED-UNVERIFIED**, not as passes. No test-pass claim in this report should be read as verified.
3. **No database was created and no DB object was inspected.** All schema findings are comparisons of the report's §4.6 design against the code; no live database exists.
4. Findings are **static**. Any statement about runtime behaviour is inference from code, not observation.

### 0.5 Decisive Structural Findings

These were confirmed at source level and drive most status assignments:

| # | Finding | Evidence |
|---|---|---|
| F-1 | **The application is permanently in demo mode. There is no backend of any kind.** | `shared_logic/lib/src/core/config/app_config.dart`: `apiBaseUrl = ''`, `supabaseUrl = ''`, `supabaseAnonKey = ''`; `usesDemoData => apiBaseUrl.isEmpty` is always `true`. No HTTP client, no server SDK, no `Dockerfile`, no `.sql`, no migration, no `backend/`, `api/` or `server/` Dart directory anywhere. |
| F-2 | **No machine learning of any kind exists.** No PU Learning, no SHAP, no LLM, no RAG, no vector store, no embeddings, no model artefact. | Zero matches for `pu_learning`, `Positive-Unlabeled`, `shap`, `rag`, `embedding`, `langchain`, `gemini`, `openai`, `llm` in any `.dart`/`.py`/`.js`/`.yaml` source. No `.pkl`, `.joblib`, `.h5`, `.onnx`, `.pt`, `.ipynb`. `shared_logic/pubspec.yaml` declares exactly one dependency: `bloc ^9.2.1`. |
| F-3 | **No geospatial computation exists.** Every property receives identical factor scores. | `shared_logic/lib/src/data/datasources/local/demo_data.dart:232-306` — `DemoData.analysisFor(propertyId)` resolves the property only to interpolate its `city` into two template strings; the `factors` list is a `const` literal (Population 88, Accessibility 84, Transportation 80, Competition 58, Demand 86, Rental Fit 74) **identical for all 8 properties**, and `competitorCount: 14` is a literal. |
| F-4 | **`suitabilityScore` is a pre-baked constructor literal, not a prediction.** | `domain/entities/commercial_property.dart` — `suitabilityScore` is a constructor field; `copyWith` cannot change it. `demo_data.dart` hardcodes 86, 84, 81, 78, … |
| F-5 | **The "recommendation engine" is a budget/size filter plus a sort on those literals.** | `data/repositories/recommendation_repository_impl.dart` — filters on `rentalRm`/`sizeSqft` bounds, then `..sort((a,b) => b.suitabilityScore.compareTo(a.suitabilityScore))` and `.take(5)`. `whyRecommended` is the hardcoded constant `['Strong surrounding population', 'Good accessibility', 'Within your budget']`. |
| F-6 | **XAI is predefined text.** | `intelligence_repositories_impl.dart` — `getExplanation` filters the same constant factors and appends a fixed `summary` string. The web source states this explicitly at `fyp_jaspr_web/lib/pages/entrepreneur/recommendations_page.dart:107-112`: *"there are no SHAP values to show because the model does not return any."* |
| F-7 | **There is no map in either UI tree.** | `fyp_mobile_app/lib/presentation/shared/widgets/sitewise_map_panel.dart` header: *"Stylised map placeholder panel (pins rendered from lat/lng proportions). **Swap the body for a real map SDK later**"* — implemented as `CustomPaint` grid + `Align`ed `IconButton` pins. `fyp_jaspr_web/lib/pages/entrepreneur/explore_page.dart` doc comment: *"**There is no map SDK in either tree.** The surface is the same stylised…"* |
| F-8 | **All persistence is in-memory and is lost on restart.** | `property_repository_impl.dart: _store = List.of(DemoData.properties)`; `intelligence_repositories_impl.dart`: `_saved`, `_compared` plain lists; `AppCubit` holds `Set<String>` saved/compared. The only durable state is the auth session file (`<appDocs>/sitewise/state/session.json`). |
| F-9 | **Authentication never validates a password.** | `fyp_mobile_app/lib/data/repositories/auth_repository_impl.dart` — `signInWithEmail` rejects only on `password.length < 6`, then matches the email against `_registered` or `DemoData.users`. `signInWithProvider` unconditionally returns the seeded `sarah@artisanbrew.my`. Web `login_page.dart` states: *"This prototype has no password auth. Pick the role you want to explore."* |
| F-10 | **The root data files are never read by any application code.** | `iproperty.csv` (216 KB, has full `latitude`/`longitude`/`rental_price`/`size_sqft` columns), `population_district (1).csv` (17.3 MB), `household_income_2024.xlsx` (7.7 MB), `population_2025_state.xlsx`, `hies_percentile.csv`, `hies_district.csv` (with `income_mean`, `gini`, `poverty`) — the only code reference to any CSV in the entire tree is `test/server.js:16` reading `./data/businesses.csv`. |
| F-11 | **The one real server is orphaned.** | `test/server.js` (Express 4, port 3000, Leaflet front-end, a local `haversine()` and `/api/businesses/nearby`) is standalone: **no Dart file references `localhost:3000` or any HTTP endpoint**. `README.md` itself calls `test/` "unrelated to the Dart packages". This is the only geospatial/distance computation in the repository, and the applications cannot reach it. |
| F-12 | **There is no property delete anywhere.** | `domain/repositories/property_repository.dart` declares 7 methods and **no `deleteProperty`**. No delete UI in either tree. `REQ-203` is unimplementable against the current domain contract. |
| F-13 | **The mobile "Add Property" flow persists nothing.** | `fyp_mobile_app/lib/presentation/mobile/property_owner/pages/owner_add_property_mobile_page.dart` — the 3-step `Stepper`'s `_next()` shows `SnackBar('Draft saved. Submit for verification from the detail page.')` then `Navigator.pop()`. No service call, no write. |
| F-14 | **The two UI trees have drifted.** | `parentShellRoute` is duplicated by hand: `fyp_mobile_app/lib/core/routing/app_routes.dart:48-61` vs `fyp_jaspr_web/lib/data/navigation.dart:98-112`, and they already disagree. Web has no signup page (only `landing_page.dart`, `login_page.dart`) and no logout; mobile has no profile save. |
| F-15 | **Routes emitted by the coordinator are not registered.** | `EvaluationFlowCoordinator` builds `/entrepreneur/property/$id/location`, `/suitability`, `/tour`, `/explanation`; `app_routes.dart` registers only the query-param forms `/entrepreneur/property-detail`, `/entrepreneur/tour`, `/entrepreneur/report`. |

---

## 1. Executive Summary

### Q1. How many documented requirements are in scope once the 360° module is excluded?

**55 ID-bearing in-scope requirements**: 45 functional (`REQ-###`), 5 non-functional (`NFR01`–`NFR05`) and 5 architecture-significant (`ASR-01`–`ASR-05`). A further **26 documented but ID-less items** (Modules C, D, G, H, I, J) bring the grand in-scope total to **81**. Eight of the report's original functional requirements (`REQ-801`–`REQ-808`) and one administrative requirement (`REQ-903`) were removed at inventory construction and are excluded from every figure below.

### Q2. How many are fully implemented?

**9 of 45 functional requirements (20.0%)**, **9 of 55 ID-bearing requirements (16.4%)**, **10 of 81 grand-total items (12.3%)**.

The nine completed functional requirements are: `REQ-204` View Property, `REQ-205` Search Property, `REQ-206` Filter Property, `REQ-208` View Verification Status, `REQ-606` Property Marker Display, `REQ-701` Save Favourite, `REQ-702` View Favourites, `REQ-703` Remove Favourite, and `REQ-902` Property Verification Management. The tenth completed item is the derived `D-05` verification state machine. Notably, **not one requirement concerning geospatial analysis, AI prediction, explanation or administration monitoring is in this list.**

### Q3. What is the verified completion rate?

| Denominator | DONE | PARTIAL | NOT DONE | BROKEN | **Verified completion** |
|---|---|---|---|---|---|
| 45 functional `REQ` only | 9 | 15 | 21 | 0 | **20.0%** |
| 55 ID-bearing (REQ + NFR + ASR) | 9 | 20 | 26 | 0 | **16.4%** |
| 81 grand in-scope (incl. derived) | 10 | 27 | 44 | 0 | **12.3%** |

No requirement is classified `BLOCKED-UNVERIFIED`, because the *existence* of each implementation was statically confirmed; it is the **test evidence** that is blocked (§0.4). See Q10.

### Q4. How many requirements are outstanding?

Using `Outstanding = PARTIAL + NOT DONE + BROKEN`:

- **36 outstanding** of 45 functional requirements (15 PARTIAL + 21 NOT DONE)
- **46 outstanding** of 55 ID-bearing requirements
- **71 outstanding** of 81 grand in-scope items

### Q5. Which modules are most and least complete?

**Most complete:** Commercial Property Management (B) and Favourite Properties — both have working, tested-by-inspection surfaces over demo data.

**Least complete — entirely or near-entirely absent (0% DONE):**

| Module | DONE / total |
|---|---|
| E — Geospatial Intelligence | 0 / 6 — **all six NOT DONE** |
| G — Positive-Unlabeled Learning | 0 / 4 — **all four NOT DONE** |
| J-derived — Knowledge Mgmt, Orchestration, Adaptive Questionnaire, Evidence Processing, Decision Engine, Recommendation Mgmt, RAG, Backend API, Database | 0 / 9 — **all nine NOT DONE** |
| A — User Accounts / Access | 0 / 6 (4 PARTIAL, 2 NOT DONE) |

The **AI, geospatial and backend subsystems — the project's stated contribution — are effectively absent.** What exists is a two-platform UI prototype over eight hardcoded demo records.

### Q6. Is the AI/ML core (PU Learning, SHAP) implemented?

**No. Zero percent.** There is no PU Learning model, no training pipeline, no unlabelled/positive labelling step, no feature-vector construction, no model artefact, no inference runtime, and no SHAP computation. `REQ-401` (Suitability Prediction using the trained PU Learning model) is **NOT DONE**; `REQ-502` (Feature Importance) is **NOT DONE**; derived items `G-01`–`G-04`, `H-04`, `H-05` are all **NOT DONE**.

What is presented to the user as AI output is a hardcoded `suitabilityScore` literal (F-4) sorted descending (F-5), with a fixed three-item `whyRecommended` list and a templated explanation paragraph (F-6). The web implementation documents this honestly in its own source comment.

### Q7. Is the geospatial intelligence engine implemented?

**No. Zero percent.** All six geospatial requirements (`REQ-301`–`REQ-306`: Population, Competitor, Accessibility, Demand Generator, Socioeconomic, Location Suitability Analysis) are **NOT DONE**.

`DemoData.analysisFor()` returns a `const` factor list with identical scores and identical evidence strings for every property, differing only in the city name interpolated into two sentences (F-3). `competitorCount` is the literal `14`. The two required analysis radii (500 m and 1 km, §4.8) appear nowhere. There is no distance function in any Dart file — the only `haversine()` in the repository lives in the orphaned Node server (F-11). The DOSM, WorldPop and iProperty datasets sitting in the project root are never opened (F-10). A map that displays markers would not prove spatial analysis; here there is not even a map (F-7).

### Q8. Is there a real backend or database?

**No.** `AppConfig` hardcodes empty `apiBaseUrl`/`supabaseUrl`/`supabaseAnonKey`, so `usesDemoData` is permanently `true` (F-1). None of the thirteen tables documented in §4.6 (`USER`, `RENTAL_PROPERTY`, `PROPERTY_PHOTO`, `PROPERTY_FEATURE`, `PROPERTY_GEOSPATIAL_FEATURE`, `RECOMMENDATION_RESULT`, `AI_EXPLANATION`, `NEARBY_COMPETITOR`, `PROPERTY_FOOT_TRAFFIC`, `DISTRICT_DEMOGRAPHIC`, `FAVOURITE_PROPERTY`, and the excluded `VIRTUAL_TOUR`) exists. There is no PostgreSQL, no PostGIS, and therefore no spatial index. All state is in-memory `List`/`Set` and is discarded on restart (F-8); only the auth session file survives.

### Q9. Which end-to-end workflows are broken or incomplete?

**All nine audited workflows fail to complete as documented** — see §4. Representative failures:

- **Manage Commercial Property:** add works only on web (with hardcoded `latitude: 3.0738, longitude: 101.5870`); **the mobile add flow writes nothing** (F-13); **delete does not exist at all** (F-12).
- **Perform Geospatial Analysis:** returns constants identical for every property (F-3).
- **Generate AI Recommendations:** filter-and-sort on pre-baked literals (F-5).
- **View Recommendation Explanation:** fixed prose, self-documented as having no SHAP values (F-6).
- **Explore Using Interactive Map:** there is no map SDK (F-7).
- **Authenticate:** no password is ever verified (F-9); "Forgot password?" is a stub; the web tree has no logout and no registration.
- **Report generation:** renders on screen; **no export, download, print, PDF or CSV path exists** in either tree.

### Q10. What is the immediate priority, and what could not be verified?

**Priority.** The gap is not polish — it is the absent core. `P0` work is to build the three load-bearing subsystems the project is named for: (1) the PU Learning pipeline plus feature-vector construction over real ingested data, (2) the geospatial computation engine with 500 m/1 km buffer analysis, and (3) the PostgreSQL/PostGIS backend with the documented schema. Until those exist, `REQ-301`–`REQ-306`, `REQ-401`–`REQ-405`, `REQ-501`–`REQ-502` and every dependent report/explanation surface remain unsatisfiable. **60 of the 71 outstanding items (85%) are downstream of these three subsystems.**

**Unverifiable.** In this environment the Dart/Flutter toolchain **hangs on any invocation** (confirmed twice; two jobs killed), so **no test could be run**. The documented `27/27` and `18/18` test results in `ARCHITECTURE_AUDIT.md` and `README.md` are recorded here as **BLOCKED-UNVERIFIED — not as passes**. No application was built, served or screenshotted, so all findings are static. This is itself a finding: **the project currently has no reproducible verification path on this machine**, and a report claiming test success cannot be independently confirmed.

---

## 2. Master Requirement Audit Table

Legend: `D` = DONE · `P` = PARTIAL · `ND` = NOT DONE · `BR` = BROKEN · `BU` = BLOCKED-UNVERIFIED. Evidence paths are relative to the repository root.

### Module A — User Accounts / Access

| Requirement ID | Module | Documented Functionality | Status | Code Evidence | Missing Work / Defect | Verification |
|---|---|---|---|---|---|---|
| REQ-101 | A | Register a new entrepreneur user account | **P** | `fyp_mobile_app/lib/data/repositories/auth_repository_impl.dart` (`signUpWithEmail`); **no signup page in web** — `fyp_jaspr_web/lib/pages/` contains only `landing_page.dart`, `login_page.dart` | Registration exists on mobile only; record held in the in-memory `_registered` map, lost on restart; no email verification; no server-side account creation | Static; no test run |
| REQ-102 | A | **Secure** login for registered users | **P** | `auth_repository_impl.dart:signInWithEmail` — checks only `password.length < 6`; web `login_page.dart` doc: "This prototype has no password auth. Pick the role you want to explore." | **No password is ever validated.** Provider sign-in unconditionally returns the seeded `sarah@artisanbrew.my`. No hashing (report §4.6 specifies bcrypt/Argon2), no session token, no rate limiting. Requirement explicitly says "secure" | Static; no test run |
| REQ-103 | A | Reset password through **email verification** | **ND** | `fyp_mobile_app/lib/presentation/mobile/auth/pages/mobile_auth_page.dart:219` — "Forgot password?" is a non-functional stub; no reset method on `AuthRepository` (`domain/repositories/auth_repository.dart` has no reset/forgot member) | Entire feature absent: no reset token, no email dispatch, no reset screen, no provider integration | Static; no test run |
| REQ-104 | A | Update/manage own profile information | **ND** | `fyp_jaspr_web/lib/pages/entrepreneur/profile_page.dart` — `_save()` only does `setState(() => _saved = true)`; inputs have no persistence. `fyp_mobile_app/.../entrepreneur_profile_mobile_page.dart` has no profile save, only `_logOut` | No profile field is ever written anywhere. `AuthRepository` exposes no `updateProfile`. Web shows a success message for a no-op | Static; no test run |
| REQ-105 | A | Assign access permissions based on role | **P** | `fyp_jaspr_web/lib/data/navigation.dart:roleForPath(path)` — prefix-derived (`/admin`→admin, `/owner`→owner, else entrepreneur); nav lists per role | This is **UI routing, not access control.** No permission check on any action, no guard, no authorization layer; a prefix is not an assigned permission. `AppRole` exists as a state field only | Static; no test run |
| REQ-106 | A | Securely log out | **P** | `auth_repository_impl.dart:signOut()` clears `_session` and deletes the session file; wired in mobile only (`entrepreneur_profile_mobile_page.dart:93`, `sitewise_role_menu.dart:40`). **Web has no logout at all** (zero `signOut` matches in `fyp_jaspr_web/`) | Mobile logout works against local storage; web users cannot log out. No token/session invalidation server-side (there is no server) | Static; no test run |

**Module A subtotal: 0 DONE · 4 PARTIAL · 2 NOT DONE**

### Module B — Commercial Property Management

| Requirement ID | Module | Documented Functionality | Status | Code Evidence | Missing Work / Defect | Verification |
|---|---|---|---|---|---|---|
| REQ-201 | B | Owner adds new commercial property listings | **P** | Web: `fyp_jaspr_web/lib/pages/owner/add_property_page.dart:90` `_create()` → `AppLocator.properties.create(...)`. Mobile: `owner_add_property_mobile_page.dart` `_next()` → SnackBar + `Navigator.pop()` | **Mobile persists nothing (F-13).** Web writes only to the in-memory `_store = List.of(DemoData.properties)`. Web hardcodes `latitude:3.0738, longitude:101.5870, state:'Selangor', postcode:'', propertyType:'Shop lot', suitabilityScore:0` — the owner cannot set location or type, which also blocks all geospatial scoring | Static; no test run |
| REQ-202 | B | Owner modifies commercial property information | **P** | `fyp_jaspr_web/lib/pages/owner/add_property_page.dart` `_updateExisting()`; `property_repository_impl.dart:updateProperty`; mobile owner detail exposes "Edit listing" | In-memory only. Because `copyWith` omits `address`/`city`/`latitude`/`longitude`/`propertyType`/`suitabilityScore`, the web edit path **rebuilds the entire record by hand** — fragile and a documented workaround in the source. No audit trail | Static; no test run |
| REQ-203 | B | Owner removes commercial property listings | **ND** | `shared_logic/lib/src/domain/repositories/property_repository.dart` — 7 methods, **no delete**. `property_repository_impl.dart` — no delete. No delete UI in either tree | **Feature does not exist at any layer.** Requires a new repository contract member, implementation, use case, service, cubit method and UI affordance | Static; no test run |
| REQ-204 | B | Display detailed property information | **D** | `fyp_mobile_app/.../entrepreneur_property_detail_mobile_page.dart`; `fyp_jaspr_web/lib/pages/entrepreneur/property_detail_page.dart` | Complete for the demo dataset. Renders title, price, size, city, requirements, badges | Static; no test run |
| REQ-205 | B | Search properties by **keywords and location** | **D** | `shared_logic/lib/src/application/usecases/property_filter.dart` — query matched against title, city, address; case-insensitive. Covered by `shared_logic/test/application/cubits_test.dart` ("query matches against title, city or address", "query is case-insensitive") | Implemented client-side over 8 demo records. Works as documented; note it is not a server-side keyword/location search | Static; test exists but **could not be executed (BU)** |
| REQ-206 | B | Filter by rental price, property type, floor area, other criteria | **D** | `property_filter.dart` — `minRentalRm`, `maxRentalRm`, `minSizeSqft`, `maxSizeSqft`, `propertyType`, `city`, `state`, `verifiedOnly`; `toChips()` drives the filter UI | Exceeds the documented criteria (adds verification and state). Validation guards inverted ranges | Static; test exists but **could not be executed (BU)** |
| REQ-207 | B | Owner uploads commercial property images | **ND** | Zero matches for `image_picker`, `ImagePicker`, `file_picker`, `multipart`, `uploadImage`, `PROPERTY_PHOTO` in any `.dart` file | No picker, no upload, no storage, no `PROPERTY_PHOTO` persistence. Report §4.6 defines a `PROPERTY_PHOTO` table; nothing implements it | Static; no test run |

**Module B subtotal: 3 DONE · 2 PARTIAL · 2 NOT DONE**

### Module C — Entrepreneur Preferences *(derived: no REQ IDs assigned in the report)*

| Requirement ID | Module | Documented Functionality | Status | Code Evidence | Missing Work / Defect | Verification |
|---|---|---|---|---|---|---|
| C-01 | C | Capture entrepreneur preferences (business type, location, budget, type, size, requirements, preferred areas, seating model) | **P** | `shared_logic/lib/src/domain/entities/recommendation.dart` `BusinessPreferences` (9 fields); `entrepreneur_preferences_mobile_page.dart`; `fyp_jaspr_web/lib/pages/entrepreneur/preferences_page.dart` | Fields and screens exist in both trees. Report §1.6 and §4.8 document preference management as a module but assign **no requirement IDs and no dedicated §4.9 screen** — a traceability gap | Static; no test run |
| C-02 | C | Persist preferences across sessions | **ND** | `EntrepreneurCubit.updatePreferences` emits state and calls an `onPreferencesUpdated` callback; write-back targets `ServiceLocator.preferences` / `AppLocator.preferences` — process memory only | Preferences are lost on app restart. No storage, no server round-trip. `AppConfig.usesDemoData` is permanently true | Static; no test run |
| C-03 | C | Preferences drive recommendation ranking | **P** | `recommendation_repository_impl.dart` consumes **only** `minBudgetRm`, `maxBudgetRm`, `minSizeSqft`. Grep for `businessType`/`preferredAreas`/`seatingModel`/`requirements` shows them used solely in labels and dashboards | **Six of nine preference fields have no effect on ranking.** `businessType` appears only in a display string; `preferredAreas`, `seatingModel`, `preferredLocation`, `propertyType`(pref), `maxSizeSqft` are inert. A user changing business concept gets an identical ranked list | Static; no test run |
| C-04 | C | Regenerate recommendations when preferences or property info change | **P** | Web `preferences_page.dart` `_save()` → `vm.updatePreferences(...)`; `recommendations_page.dart` `initState` → `unawaited(vm.loadRecommendations())` | Regeneration occurs only as a side effect of **navigating to a freshly constructed page**. No invalidation on preference change, no reactive recompute, and **property updates never invalidate recommendations**. Report §4.1 ASR-01 calls for deterministic reasoning isolation; none exists | Static; no test run |

**Module C subtotal: 0 DONE · 3 PARTIAL · 1 NOT DONE**

### Module D — Property Data / Verification

| Requirement ID | Module | Documented Functionality | Status | Code Evidence | Missing Work / Defect | Verification |
|---|---|---|---|---|---|---|
| REQ-208 | D | Owner views verification status of submitted properties | **D** | `fyp_mobile_app/.../owner_property_detail_mobile_page.dart` — "Submit for verification" action + status display; `fyp_jaspr_web/lib/components/ui.dart:486` `StatusBadge.forVerification`; `components/property_card.dart:9` `toneForVerification`; `commercial_property.dart` `VerificationStatus {draft, pending, verified, rejected}` | Status is visible and transitions render correctly. In-memory only | Static; no test run |
| REQ-902 | D | Admin reviews, verifies, approves or rejects submitted listings **before publication** | **D** | `admin_repositories_impl.dart:VerificationRepositoryImpl` (`getPendingQueue`, `verify`, `reject` → `properties.updateVerification`); `AdminCubit.approve/reject`; web `pages/admin/verification_page.dart` | Workflow present. **Publication gating is not enforced** — non-verified listings still appear in explore/recommendations unless the user opts into `verifiedOnly` | Static; no test run |
| D-03 | D | Ingest commercial property data from external sources (iProperty, DOSM, Google Places, OpenStreetMap — §4.8.1–4.8.6) | **ND** | `iproperty.csv` (216 KB, fully populated with `latitude`, `longitude`, `rental_price`, `size_sqft`, `nearby_landmarks`, `suitable_for`), `hies_district.csv` (`income_mean`, `gini`, `poverty`), `population_district (1).csv` (17.3 MB), `household_income_2024.xlsx` (7.7 MB) — **the only CSV reference in the tree is `test/server.js:16`** | No ingestion, no parser, no ETL, no scraper (the only scraper is a source-less `__pycache__/edgeprop_scraper.cpython-312.pyc`). The datasets the report depends on are inert files | Static; no test run |
| D-04 | D | Persist property photos and listing media | **ND** | No `PROPERTY_PHOTO` reference in any Dart file; no `image_picker`; no storage client | Table designed in §4.6, never implemented | Static; no test run |
| D-05 | D | Verification lifecycle state machine (`draft → pending → verified/rejected`) | **D** | `VerificationStatus` enum; `submitForVerification(id)` → `pending`; `updateVerification(id, status)`; `VerificationRepositoryImpl.verify/reject` | Correct and coherent, but entirely in-memory — all verification state is lost on restart | Static; no test run |
| D-06 | D | Only verified listings are published to entrepreneurs | **P** | `property_filter.dart` `verifiedOnly` flag exists and is honoured in `matches()` | It is an **opt-in filter, not a gate**. `listings()`/`getRecommendations` return draft and pending records by default | Static; no test run |

**Module D subtotal: 3 DONE · 1 PARTIAL · 2 NOT DONE**

### Module E — Geospatial Intelligence

**All six requirements NOT DONE.** `DemoData.analysisFor(propertyId)` (F-3) returns a `const` factor list identical for every property.

| Requirement ID | Module | Documented Functionality | Status | Code Evidence | Missing Work / Defect | Verification |
|---|---|---|---|---|---|---|
| REQ-301 | E | Calculate surrounding population within predefined catchment areas | **ND** | `demo_data.dart:232-306` — factor `Population, score: 88, rating: 'Strong', evidence: 'Dense residential blocks within a 10-minute walk.'` is a `const` literal, identical for all properties. `population_district (1).csv` never read | No population raster, no buffer analysis, no 500 m/1 km radii (§4.8), no density computation. Change the property, the number does not change | Static; no test run |
| REQ-302 | E | Analyse nearby F&B competitors | **ND** | `analysisFor` hardcodes `competitorCount: 14` and factor `Competition, score: 58, evidence: '14 F&B outlets within 500 m; 3 direct competitors.'` | No Places/OSM query, no competitor table, no radius query, no category classification. `NEARBY_COMPETITOR` table unimplemented. `test/data/businesses.csv` holds 59.8 KB of real competitor rows that no Dart code can reach | Static; no test run |
| REQ-303 | E | Evaluate road accessibility and transportation connectivity | **ND** | Factor `Accessibility, score: 84, evidence: 'Corner frontage with public parking nearby.'` and `Transportation, score: 80, evidence: 'Within 400 m of rail and major bus routes.'` — both `const` | No road network, no OSM data, no routing, no distance-to-transport computation. `Accessibility Score` (§4.8.6) never generated | Static; no test run |
| REQ-304 | E | Identify nearby demand generators (malls, offices, universities, hospitals, transport hubs) | **ND** | `demandSummary` is a template string interpolating only `property.city`; factor `Demand, score: 86` is `const` | No POI lookup, no six-category classification from §4.8.5, no `Demand Attraction Score` | Static; no test run |
| REQ-305 | E | Retrieve and analyse socioeconomic indicators | **ND** | `socioeconomicSummary` = `'Middle-income family catchment with steady weekend spending around ${property.city}.'` | No DOSM ingestion. `hies_district.csv` (`income_mean`, `income_median`, `expenditure_mean`, `gini`, `poverty`) and the two XLSX files are never opened. `DISTRICT_DEMOGRAPHIC` table unimplemented | Static; no test run |
| REQ-306 | E | Generate spatial indicators describing suitability of each property | **ND** | `CommercialProperty.suitabilityScore` is a **constructor field pre-baked with literals** (86, 84, 81, 78…); `copyWith` cannot change it | No spatial indicator is generated. The score is authored, not computed. `PROPERTY_GEOSPATIAL_FEATURE` table unimplemented | Static; no test run |

**Module E subtotal: 0 DONE · 0 PARTIAL · 6 NOT DONE**

### Module F — AI Recommendation

| Requirement ID | Module | Documented Functionality | Status | Code Evidence | Missing Work / Defect | Verification |
|---|---|---|---|---|---|---|
| REQ-401 | F | Predict suitability using the **trained Positive-Unlabeled Learning model** | **ND** | Zero PU Learning references in any source. No model artefact, no inference runtime, no training script. `shared_logic/pubspec.yaml` has one dependency (`bloc`) | Entire requirement absent. Report §4.8.3 specifies the PU model as the core contribution | Static; no test run |
| REQ-402 | F | Rank properties by **predicted** suitability scores | **P** | `recommendation_repository_impl.dart` — `..sort((a,b) => b.suitabilityScore.compareTo(a.suitabilityScore)).take(5)` | The ranking *mechanism* works, but ranks on pre-baked literals (F-4), not predicted scores. Rank order is therefore fixed by the demo dataset's authoring order | Static; no test run |
| REQ-403 | F | Recommend based on **entrepreneur preferences and geospatial analysis** | **P** | `recommendation_repository_impl.dart` filters `rentalRm`/`sizeSqft` against `BusinessPreferences` bounds, then sorts | Preferences contribute only budget/size (see C-03); **geospatial analysis contributes nothing** because it does not exist (Module E). Half the requirement is unimplemented | Static; no test run |
| REQ-404 | F | Regenerate recommendations when preferences or property info are updated | **P** | `EntrepreneurCubit.loadRecommendations()` re-reads `state.preferences`; web page reloads on `initState` | No automatic regeneration (see C-04). Property updates never invalidate results. No cache, no staleness handling | Static; no test run |
| REQ-405 | F | View previous recommendation results (history) | **ND** | Zero matches for any recommendation-history store, screen or route in either tree. No `RECOMMENDATION_RESULT` references | Feature absent at every layer: no persistence, no list screen, no route, no repository member | Static; no test run |

**Module F subtotal: 0 DONE · 3 PARTIAL · 2 NOT DONE**

### Module G — Positive-Unlabeled Learning *(derived: documented in §4.8.3, no REQ IDs)*

| Requirement ID | Module | Documented Functionality | Status | Code Evidence | Missing Work / Defect | Verification |
|---|---|---|---|---|---|---|
| G-01 | G | PU Learning training pipeline (positive/unlabelled labelling) | **ND** | No training code, no notebook, no script, no `.pkl`/`.joblib`/`.onnx` anywhere | Absent | Static; no test run |
| G-02 | G | Trained model artefact and inference runtime | **ND** | No model file; no ML runtime dependency in any `pubspec.yaml` or `package.json` | Absent | Static; no test run |
| G-03 | G | Feature-vector construction (commercial property, population, competitor, demand, accessibility, socioeconomic — §4.8.2–4.8.6) | **ND** | No feature extraction code; the report's six feature tables have no implementation counterpart | Absent | Static; no test run |
| G-04 | G | Runtime suitability-score generation from the model | **ND** | Scores are constructor literals (F-4) | Absent | Static; no test run |

**Module G subtotal: 0 DONE · 0 PARTIAL · 4 NOT DONE**

### Module H — Explainable AI (SHAP)

| Requirement ID | Module | Documented Functionality | Status | Code Evidence | Missing Work / Defect | Verification |
|---|---|---|---|---|---|---|
| REQ-501 | H | Explain the factors contributing to each recommendation | **P** | `intelligence_repositories_impl.dart:getExplanation` filters `analysis.factors` into strengths/considerations and appends a **hardcoded `summary`**; `RecommendationExplanation` entity; explanation screens in both trees | An explanation surface exists in both trees, but the factors it explains are identical constants for every property (F-3), so the explanation is invariant. This is a **static panel over predefined text**, not an XAI pipeline | Static; no test run |
| REQ-502 | H | Display the **contribution of each influencing factor** to the result | **ND** | `LocationFactor.score` values are the same `const` literals for every property. **Explicit self-documentation** in `fyp_jaspr_web/lib/pages/entrepreneur/recommendations_page.dart:107-112`: *"there are no SHAP values to show because the model does not return any."* No SHAP library in any manifest | No SHAP computation, no per-prediction attribution, no additive contributions. The displayed "score" is an authored constant, not a contribution | Static; no test run |
| REQ-503 | H | Present results using understandable **textual** explanations | **P** | Fixed `summary` string; `whyRecommended` = `['Strong surrounding population','Good accessibility','Within your budget']` (hardcoded list); `reason` string template | Understandable prose is rendered, but it is **predefined**, not derived from any AI result. Per the audit brief, predefined text does not constitute functioning XAI | Static; no test run |
| H-04 | H | Compute per-factor SHAP values for a prediction | **ND** | No SHAP library, no model, no attribution code | Absent | Static; no test run |
| H-05 | H | Rank/weight factors by model importance | **ND** | Factor order is the authoring order of the `const` list | Absent | Static; no test run |

**Module H subtotal: 0 DONE · 2 PARTIAL · 3 NOT DONE**

### Module I — Maps / Comparisons / Reports

| Requirement ID | Module | Documented Functionality | Status | Code Evidence | Missing Work / Defect | Verification |
|---|---|---|---|---|---|---|
| REQ-601 | I | Display properties on an **interactive digital map** | **P** | Mobile `sitewise_map_panel.dart`: *"Stylised map placeholder panel (pins rendered from lat/lng proportions). **Swap the body for a real map SDK later**"* — a `CustomPaint` grid with `Align`ed `IconButton` pins. Web `explore_page.dart`: *"**There is no map SDK in either tree.** The surface is the same stylised…"* (`_MapSurface`, `_MapPin`) | There is **no basemap, no tiles, no georeferenced projection, no panning**. Marker placement is an affine squash of lat/lng into `Alignment`. Both sources explicitly document this as a placeholder. Not a digital map | Static; no test run |
| REQ-602 | I | Visualise **nearby competitors** on the map | **ND** | No competitor markers, layer or data in either tree | Absent; depends on Module E which is absent | Static; no test run |
| REQ-603 | I | Display nearby **demand generators** on the map | **ND** | No demand-generator markers or layer | Absent | Static; no test run |
| REQ-604 | I | Allow users to **enable/disable spatial layers** | **ND** | Grep for layer toggles returns only unrelated `onToggleSaved`/`onToggleCompared` and a list/map panel toggle. No layer model, no layer control | Feature absent entirely | Static; no test run |
| REQ-605 | I | Select properties directly from the map | **P** | Web: `_MapPin` carries `href: '/entrepreneur/property-detail?id=${p.id}'` and `selectedId` drives a detail panel with "View full property" | Works on web via a styled pin. Mobile map panel pins are non-selecting. Partial across trees | Static; no test run |
| REQ-606 | I | Display commercial property **markers** on the map | **D** | Web `_MapPin` renders price-labelled pins from `_mappable` (filters `latitude != 0 \|\| longitude != 0`); mobile panel renders proportionally positioned pins | Markers render in both trees over the stylised surface | Static; no test run |
| REQ-607 | I | Display **nearby properties** surrounding the selected location | **ND** | No proximity filter, no radius query; no distance function in any Dart file | Absent. Would require the geospatial engine (Module E) | Static; no test run |
| REQ-608 | I | Display nearby **public transportation** facilities | **ND** | No transport data, layer or markers | Absent | Static; no test run |
| REQ-609 | I | Display **demographic information as a spatial layer** | **ND** | No demographic layer; DOSM files never read | Absent | Static; no test run |
| I-10 | I | Side-by-side property comparison | **P** | `ComparisonRepositoryImpl` with in-memory `List<String> _compared`; `PropertyComparison.isFull` at `>= 3`; `entrepreneur_compare_mobile_page.dart` (246 lines); `fyp_jaspr_web/lib/pages/entrepreneur/compare_page.dart` (174 lines) | Comparison renders (property, rental, size, city rows) but is **in-memory and lost on restart**. Metrics compared are basic listing fields — no geospatial or score comparison columns, so it cannot compare what the system is meant to compare | Static; no test run |
| I-11 | I | **Business Assessment Report** (§1.6 Reporting Module) | **P** | `fyp_mobile_app/.../entrepreneur_report_mobile_page.dart` (93 lines); `fyp_jaspr_web/lib/pages/entrepreneur/report_page.dart` (190 lines) | Renders on screen. **No download, print, PDF, CSV, export or share action exists in either tree.** A "report" that cannot leave the screen | Static; no test run |
| I-12 | I | **Location Recommendation Report** (§1.6 Reporting Module) | **P** | Same pages; `GenerateEvaluationReport` use case builds an `EvaluationReport` from demo analysis plus a hardcoded recommendation sentence | Same absence of export. Content is derived from constant factors (Module E), so the "assessment" is invariant across properties | Static; no test run |

**Module I subtotal (incl. derived I-10, I-11, I-12): 1 DONE · 5 PARTIAL · 6 NOT DONE** *(of which the nine ID-bearing requirements REQ-601–609 are: 1 DONE · 2 PARTIAL · 6 NOT DONE)*

### Module J — Other Documented Functionalities

| Requirement ID | Module | Documented Functionality | Status | Code Evidence | Missing Work / Defect | Verification |
|---|---|---|---|---|---|---|
| REQ-701 | J | Save commercial properties to a favourite list | **D** | `AppCubit.toggleSaved(id)` on `Set<String> saved`; wired in `property_card.dart:onToggleSaved`, `property_detail_page.dart:96`, `recommendations_page.dart:104`, `explore_page.dart:243` | Works in both trees. **In-memory only — favourites are lost on restart** (no `FAVOURITE_PROPERTY` persistence). `AppCubit` is a process singleton | Static; no test run |
| REQ-702 | J | View saved favourite properties | **D** | `entrepreneur_saved_mobile_page.dart`; `fyp_jaspr_web/lib/pages/entrepreneur/saved_page.dart:76` | Renders correctly from the in-memory set | Static; no test run |
| REQ-703 | J | Remove properties from the favourite list | **D** | `toggleSaved` removes on second call (`if (!next.remove(id)) next.add(id)`); saved page wires the toggle | Works. Same non-persistence caveat | Static; no test run |
| REQ-901 | J | Admin manages user accounts | **P** | `UserRepositoryImpl` → `DemoData.users` (read-only); `AdminCubit.loadUsers`, `filteredUsers`, `pendingUsers`; web `pages/admin/users_page.dart` | **Read-only listing with a query filter.** No suspend, delete, edit, role-change or approve action found in either tree. `DemoData.users` has no mutation path | Static; no test run |
| REQ-904 | J | Admin monitors **AI-generated recommendation results** | **ND** | `fyp_jaspr_web/lib/pages/admin/dashboard_page.dart` — **zero matches** for recommendation/explanation/monitor. No such state on `AdminCubit` (it exposes only dashboard/users/tours) | Feature absent. Admin nav contains no monitoring destination. No `RECOMMENDATION_RESULT` store to monitor | Static; no test run |
| REQ-905 | J | Admin monitors **recommendation explanations and influencing factors** | **ND** | Zero matches for explanation monitoring in `fyp_jaspr_web/lib/pages/admin/`; no `AI_EXPLANATION` persistence | Absent | Static; no test run |
| REQ-906 | J | Admin monitors system statistics, verification requests and **user activities** via a dashboard | **P** | `AdminCubit.loadDashboard`, `countByStatus`, `pendingUsers`; web `dashboard_page.dart` | Statistics and the pending-verification count are present (computed over 8 demo records). **No user-activity monitoring** (no login history, no audit log), no system health, no real monitoring. `lastLogin` is a static `DemoData` field | Static; no test run |
| J-08 | J | **Knowledge Management Module** (§1.6) | **ND** | No knowledge base, no content store, no retrieval code | Absent | Static; no test run |
| J-09 | J | **Assessment Orchestration Module** (§1.6) | **ND** | No orchestrator, no workflow controller beyond UI navigation | Absent | Static; no test run |
| J-10 | J | **Adaptive Questionnaire Module** (§1.6) | **ND** | No adaptive/conditional questionnaire. `PreferencesPage` is a flat static form; no branching, no follow-up questions | Absent | Static; no test run |
| J-11 | J | **Evidence Processing Module** (§1.6) | **ND** | No evidence ingestion, normalisation or scoring | Absent | Static; no test run |
| J-12 | J | **Decision Analysis Module (Deterministic Decision Engine)** (§1.6) | **ND** | No decision engine. The only decision logic is a budget/size predicate plus a `compareTo` sort | Absent; this is also **ASR-01** (Deterministic Business Reasoning Isolation) | Static; no test run |
| J-13 | J | **Recommendation Management Module** (§1.6) | **ND** | No recommendation persistence, versioning or lifecycle | Absent; relates to REQ-405 | Static; no test run |
| J-14 | J | **AI/RAG Integration & Knowledge Retrieval** (§1.6) | **ND** | No LLM client, no embedding model, no vector store, no retrieval. Zero matches for `rag`/`embedding`/`llm` in source | Absent; also **ASR-02** and **ASR-05** | Static; no test run |
| J-15 | J | **Backend API Development** (§1.6; ASR-03) | **ND** | `AppConfig.apiBaseUrl = ''`; no HTTP client; no server project; no `Dockerfile`; no `.sql`. The sole Express server (`test/server.js`) is **unreachable from any Dart code** | Absent. Also **ASR-03** (delegate heavy geospatial processing to PostgreSQL + PostGIS) cannot be satisfied | Static; no test run |
| J-16 | J | **Database schema** — 13 documented tables (§4.6) | **ND** | No SQL, no migration, no ORM definition, no DB client. None of `USER`, `RENTAL_PROPERTY`, `PROPERTY_PHOTO`, `PROPERTY_FEATURE`, `PROPERTY_GEOSPATIAL_FEATURE`, `RECOMMENDATION_RESULT`, `AI_EXPLANATION`, `NEARBY_COMPETITOR`, `PROPERTY_FOOT_TRAFFIC`, `DISTRICT_DEMOGRAPHIC`, `FAVOURITE_PROPERTY` exists (`VIRTUAL_TOUR` excluded) | Domain *entities* loosely mirror a few columns, but there is no persistence of any kind. No bcrypt/Argon2 password column implementation, no FK integrity, no `GEOMETRY`/spatial index | Static; no test run |

**Module J subtotal: 3 DONE · 2 PARTIAL · 11 NOT DONE** *(REQ-701–906 subset: 3 DONE · 2 PARTIAL · 2 NOT DONE)*

### Non-Functional Requirements

| Requirement ID | Documented Requirement | Status | Code Evidence | Missing Work / Defect | Verification |
|---|---|---|---|---|---|
| NFR01 | Maintainability and extensibility — Clean Architecture separating business logic from infrastructure; repository interfaces allowing external services (databases, AI providers) to be replaced without modifying the Domain Layer; AI models and RAG upgradeable independently | **P** | Domain exposes abstract contracts: `domain/repositories/auth_repository.dart`, `property_repository.dart`, `admin_repositories.dart`; `shared_logic` is UI-free (dep: `bloc` only) and both apps inject via composition roots (`app_locator.dart`, `ServiceLocator`) | The **Domain Layer is clean and the Dependency Rule holds** — genuine credit. But no Data-Layer implementation against a real database or AI provider exists to be swapped, so the extensibility claim is untested. Two hand-maintained UI trees with a **duplicated and already-drifted** `parentShellRoute` map (`app_routes.dart:48-61` vs `navigation.dart:98-112`) and three coexisting state patterns (Cubit, `ChangeNotifier` viewmodels, raw `setState`) work against maintainability. `ServiceLocator` static mutable state is a documented violation | Static; no test run |
| NFR02 | Performance efficiency — PostGIS spatial indexes, asynchronous AI processing, lazy loading/caching for interactive maps and 360° tours | **ND** | No PostGIS, no spatial index, no AI inference, no map SDK to cache. No caching layer anywhere | Nothing to optimise: the subsystems it governs do not exist. The 360° component is excluded from this assessment | Static; no test run |
| NFR03 | Scalability — stateless backend services, independently scalable spatial and knowledge databases | **ND** | No backend, no database, no service boundary. State lives in process memory (`List.of(...)`, `Set<String>`) and is single-user by construction | Absent. In-memory singletons would not survive horizontal scaling even if a backend existed | Static; no test run |
| NFR04 | Security and data integrity — RBAC restricting access by role; Domain-Layer validation ensuring business rules before storage | **P** | `roleForPath` gives role-derived navigation (not enforcement); form validation exists (`add_property_page.dart` `_showErrors`; `PropertyFilter` range validation `minRental > maxRental`) | **CRITICAL:** passwords are never verified (F-9), no RBAC enforcement, no hashing despite §4.6 specifying bcrypt/Argon2, no storage layer for validation to protect, no CSRF/session/token handling. `signInWithProvider` returns a seeded account unconditionally | Static; no test run |
| NFR05 | Usability and cross-platform consistency — unified UI across devices; XAI in clear human-readable language | **P** | Material 3 theme + shared design tokens; both trees share `shared_logic` entities and cubits; readable prose in explanations | **The two trees are not at parity:** web has no registration and no logout; mobile add-property persists nothing; navigation maps have drifted; `styles.css` grew from 1,358 to 1,876 lines, leaving `DESIGN.md` §4/§7 stale. Human-readable language exists but describes constant values (see REQ-503) | Static; no test run |

**NFR subtotal: 0 DONE · 3 PARTIAL · 2 NOT DONE**

### Architecture-Significant Requirements (§4.1.2)

| Requirement ID | Documented ASR | Status | Code Evidence | Missing Work / Defect | Verification |
|---|---|---|---|---|---|
| ASR-01 | Deterministic business reasoning isolated from non-deterministic components | **ND** | No deterministic decision engine. The entire "reasoning" path is a budget/size predicate plus `compareTo` sort on authored literals | Absent. §1.6's Decision Analysis Module has no implementation. Without isolation there is no deterministic core to reason over | Static; no test run |
| ASR-02 | Modular AI and knowledge integration — PU Learning, LLMs and RAG isolated in the Data Layer | **ND** | No PU Learning, no LLM, no RAG, no vector store. `shared_logic` deliberately has a single dependency (`bloc`) and therefore **cannot host an ML or DB client** without a manifest change | Absent. The architectural slot for AI integration exists in design only | Static; no test run |
| ASR-03 | Heavy geospatial processing delegated to PostgreSQL + PostGIS | **ND** | No PostgreSQL, no PostGIS, no SQL, no DB client. No distance function in any Dart file | Absent. Ironically the only geospatial computation in the repo is the `haversine()` in the orphaned `test/server.js`, which the applications cannot call | Static; no test run |
| ASR-04 | Cross-platform UI consistency via Flutter + BLoC | **P** | Cubit migration completed (`AppCubit`, `EntrepreneurCubit`, `OwnerCubit`, `AdminCubit` in `shared_logic/lib/src/application/cubits/`), shared entities consumed by both trees; `ARCHITECTURE_AUDIT.md` documents the ChangeNotifier→Cubit migration | **The "single Flutter codebase" premise is not met:** the web UI is a separate Jaspr/Dart-SSR tree with its own hand-written pages, its own `navigation.dart`, and its own `web/styles.css`. Feature parity has diverged (F-14). Three state patterns coexist, so BLoC is not the sole state mechanism | Static; no test run |
| ASR-05 | Independent data structuring — relational and vector stores with DTOs | **P** | Domain entities and DTO-shaped records exist: `commercial_property.dart`, `location_intelligence.dart`, `recommendation.dart`, `sitewise_records.dart`; `data/models/` present in both `shared_logic` and `fyp_mobile_app` | Only the **structuring half** exists. There is no relational store and no vector store — no `RECOMMENDATION_RESULT`, no `AI_EXPLANATION`, no embeddings. DTOs are well-formed but unbacked | Static; no test run |

**ASR subtotal: 0 DONE · 2 PARTIAL · 3 NOT DONE**

---

## 3. Module Completion Dashboard

### 3.1 ID-Bearing Requirements (primary denominator: 55)

| Module | DONE | PARTIAL | NOT DONE | BROKEN | Total | Completion | Outstanding |
|---|---|---|---|---|---|---|---|
| A — User Accounts / Access | 0 | 4 | 2 | 0 | 6 | **0.0%** | 6 |
| B — Commercial Property Management | 3 | 2 | 2 | 0 | 7 | **42.9%** | 4 |
| D — Property Data / Verification | 2 | 0 | 0 | 0 | 2 | **100.0%** | 0 |
| E — Geospatial Intelligence | 0 | 0 | 6 | 0 | 6 | **0.0%** | 6 |
| F — AI Recommendation | 0 | 3 | 2 | 0 | 5 | **0.0%** | 5 |
| H — Explainable AI (SHAP) | 0 | 2 | 1 | 0 | 3 | **0.0%** | 3 |
| I — Maps / Comparisons / Reports | 1 | 2 | 6 | 0 | 9 | **11.1%** | 8 |
| J — Other (favourites, admin) | 3 | 2 | 2 | 0 | 7 | **42.9%** | 4 |
| **Functional `REQ` subtotal** | **9** | **15** | **21** | **0** | **45** | **20.0%** | **36** |
| NFR01–NFR05 | 0 | 3 | 2 | 0 | 5 | **0.0%** | 5 |
| ASR-01–ASR-05 | 0 | 2 | 3 | 0 | 5 | **0.0%** | 5 |
| **ID-bearing total** | **9** | **20** | **26** | **0** | **55** | **16.4%** | **46** |

### 3.2 Including ID-Less Documented Modules (grand total: 81)

| Module | DONE | PARTIAL | NOT DONE | Total | Completion | Outstanding |
|---|---|---|---|---|---|---|
| A — User Accounts / Access | 0 | 4 | 2 | 6 | 0.0% | 6 |
| B — Commercial Property Management | 3 | 2 | 2 | 7 | 42.9% | 4 |
| C — Entrepreneur Preferences | 0 | 3 | 1 | 4 | 0.0% | 4 |
| D — Property Data / Verification | 3 | 1 | 2 | 6 | 50.0% | 3 |
| E — Geospatial Intelligence | 0 | 0 | 6 | 6 | 0.0% | 6 |
| F — AI Recommendation | 0 | 3 | 2 | 5 | 0.0% | 5 |
| G — Positive-Unlabeled Learning | 0 | 0 | 4 | 4 | 0.0% | 4 |
| H — Explainable AI (SHAP) | 0 | 2 | 3 | 5 | 0.0% | 5 |
| I — Maps / Comparisons / Reports | 1 | 5 | 6 | 12 | 8.3% | 11 |
| J — Other Documented Functionalities | 3 | 2 | 11 | 16 | 18.8% | 13 |
| NFR01–NFR05 | 0 | 3 | 2 | 5 | 0.0% | 5 |
| ASR-01–ASR-05 | 0 | 2 | 3 | 5 | 0.0% | 5 |
| **Grand total** | **10** | **27** | **44** | **81** | **12.3%** | **71** |

### 3.3 Dashboard Read-Out

```
Verified completion (45 functional REQ)      ████░░░░░░░░░░░░░░░░  20.0%
Verified completion (55 ID-bearing)          ███░░░░░░░░░░░░░░░░░  16.4%
Verified completion (81 grand in-scope)      ██░░░░░░░░░░░░░░░░░░  12.3%

Outstanding work (of 81)                     █████████████████░░░  71 items (87.7%)
```

**Distribution of the 81 in-scope items**

| Status | Count | Share |
|---|---|---|
| DONE | 10 | 12.3% |
| PARTIAL | 27 | 33.3% |
| NOT DONE | 44 | 54.3% |
| BROKEN | 0 | 0.0% |
| BLOCKED-UNVERIFIED | 0 *(see §0.4 — test evidence is blocked, implementation existence is not)* | — |
| OUT OF SCOPE (excluded, not counted) | 9 REQ + 1 table + 1 UC + 1 module | — |

**Interpretation.** No module exceeds 50% completion. The two modules at 0% with the highest item counts — **E (Geospatial Intelligence, 6 items)** and **J (11 NOT DONE items)** — contain the project's entire stated contribution. The 27 PARTIAL items are dominated by surfaces that render convincingly over eight hardcoded records; this is precisely the "a screen exists" evidence the audit brief warns against accepting as completion.

---

## 4. Outstanding Work by Priority

Priority is assigned on dependency and academic-claim weighting: `P0` = the project's named contribution cannot be demonstrated without it; `P1` = required for a defensible end-to-end demonstration; `P2` = required for documented compliance; `P3` = polish and completeness.

### P0 — Core Subsystems (the project's stated contribution). 12 items.

| # | Item | Requirements unblocked | Current state |
|---|---|---|---|
| P0-1 | Build the **PU Learning pipeline**: positive/unlabelled labelling, training, model artefact, inference runtime | `REQ-401`, `G-01`, `G-02`, `ASR-02` | Absent. `shared_logic` has one dependency (`bloc`) and cannot host a model client without a manifest change |
| P0-2 | Build **feature-vector construction** across the six documented feature categories (property, population, competitor, demand, accessibility, socioeconomic) | `REQ-401`, `G-03`, `REQ-301`–`REQ-305` | Absent; the report's §4.8 feature tables have no implementation |
| P0-3 | Replace the authored `suitabilityScore` literal with **runtime predicted scores** | `REQ-306`, `REQ-402`, `REQ-403`, `G-04` | `suitabilityScore` is a constructor field with literals 86/84/81/78…; `copyWith` cannot change it |
| P0-4 | Build the **geospatial computation engine**: distance/buffer analysis at the documented **500 m and 1 km** radii | `REQ-301`–`REQ-306` | **No distance function exists in any Dart file.** The only `haversine()` is in the orphaned `test/server.js` |
| P0-5 | Implement the **PostgreSQL + PostGIS backend** with the documented schema and spatial indexes | `J-15`, `J-16`, `NFR02`, `NFR03`, `ASR-03`, all persistence gaps | `AppConfig.apiBaseUrl = ''`; no server, no SQL, no DB client |
| P0-6 | **Ingest the real datasets** already present (`iproperty.csv`, `hies_district.csv`, `population_district (1).csv`, `household_income_2024.xlsx`) | `D-03`, `REQ-301`, `REQ-305`, `REQ-606` | Files are inert; nothing reads them |
| P0-7 | Implement **SHAP (or equivalent) per-factor contribution** on real predictions | `REQ-502`, `H-04`, `H-05` | Source self-documents: *"there are no SHAP values to show"* |
| P0-8 | Replace hardcoded factor constants with **computed factors per property** | `REQ-301`–`REQ-306`, `REQ-501` | `analysisFor()` returns a `const` list identical for all 8 properties |
| P0-9 | Build the **Deterministic Decision Engine** to satisfy ASR-01 isolation | `ASR-01`, `J-12` | Absent |
| P0-10 | Build **AI/RAG integration and knowledge retrieval** | `ASR-02`, `ASR-05`, `J-08`, `J-14` | No LLM, no embeddings, no vector store |
| P0-11 | Replace hardcoded `whyRecommended` / explanation `summary` with **generated** explanation content | `REQ-501`, `REQ-503` | Fixed 3-item list and a fixed summary sentence |
| P0-12 | Move the app out of permanent demo mode (`usesDemoData` is always true) | Everything | `AppConfig` hardcodes empty URLs |

### P1 — Required for a Defensible End-to-End Demonstration. 18 items.

| # | Item | Requirements | Current state |
|---|---|---|---|
| P1-1 | **Persist all state** (properties, favourites, comparison, verification, preferences, recommendations). Currently lost on restart | `NFR03`, `REQ-701`–`REQ-703`, `I-10`, `C-02`, `D-05` | `List.of(...)`, `Set<String>`, in-memory singletons |
| P1-2 | Implement **property delete** across the full stack | `REQ-203` | No `deleteProperty` on the domain contract; no UI anywhere |
| P1-3 | Fix the **mobile Add Property flow** — it currently writes nothing | `REQ-201` | `_next()` → SnackBar + `Navigator.pop()` |
| P1-4 | Let owners set **real geolocation and property type** (web hardcodes `3.0738/101.5870`, `'Shop lot'`) | `REQ-201`, `REQ-202`, `REQ-306` | Hardcoded in `add_property_page.dart:_create()` |
| P1-5 | Enforce **password verification** and implement real authentication | `REQ-102`, `NFR04` | `signInWithEmail` checks only `password.length < 6`; web declines to authenticate at all |
| P1-6 | Implement **password reset** | `REQ-103` | Non-functional stub at `mobile_auth_page.dart:219` |
| P1-7 | Implement **profile management** with real persistence | `REQ-104` | Web `_save()` only toggles a flag; mobile has no save |
| P1-8 | Implement **registration on web** and **logout on web** | `REQ-101`, `REQ-106` | Web has neither; mobile has registration and logout |
| P1-9 | Implement **RBAC enforcement** (not prefix-derived navigation) | `REQ-105`, `NFR04` | `roleForPath` is UI routing; no action-level check |
| P1-10 | Implement **property image upload** and `PROPERTY_PHOTO` persistence | `REQ-207`, `D-04` | No picker, no upload, no storage |
| P1-11 | Implement **recommendation history** | `REQ-405`, `J-13` | Zero code at any layer |
| P1-12 | Implement **admin recommendation and explanation monitoring** | `REQ-904`, `REQ-905` | Zero matches in admin pages; no such state on `AdminCubit` |
| P1-13 | Implement **report export** (PDF/CSV/print/download) | `I-11`, `I-12` | No export path in either tree |
| P1-14 | Make **preferences actually influence ranking** (6 of 9 fields are inert) | `C-03`, `REQ-403` | Only budget and min size are read |
| P1-15 | Implement **automatic recommendation regeneration** on preference/property change | `REQ-404`, `C-04` | Regeneration depends on page navigation only |
| P1-16 | Enforce **verified-only publication gating** | `D-06`, `REQ-902` | `verifiedOnly` is an opt-in filter, not a gate |
| P1-17 | Build a **real interactive map** (basemap/SDK) replacing the stylised placeholder | `REQ-601`, `REQ-605`, `REQ-606` | Both sources document the absence of any map SDK |
| P1-18 | Implement an **evidence-processing and assessment-orchestration path** | `J-09`, `J-11` | Absent |

### P2 — Documented Compliance. 15 items.

| # | Item | Requirements | Current state |
|---|---|---|---|
| P2-1 | Competitor visualisation layer on the map | `REQ-602` | Absent |
| P2-2 | Demand-generator visualisation layer | `REQ-603` | Absent |
| P2-3 | Spatial layer enable/disable controls | `REQ-604` | Absent |
| P2-4 | Nearby-property display around a selected location | `REQ-607` | Absent |
| P2-5 | Nearby public-transportation layer | `REQ-608` | Absent |
| P2-6 | Demographic spatial layer | `REQ-609` | Absent |
| P2-7 | Full admin **user management** (suspend, delete, edit, role change) | `REQ-901` | Read-only listing with a filter |
| P2-8 | **User-activity monitoring** on the admin dashboard | `REQ-906` | No audit log, no login history |
| P2-9 | **Knowledge Management Module** | `J-08` | Absent |
| P2-10 | **Adaptive Questionnaire Module** | `J-10` | Flat static form |
| P2-11 | **Recommendation Management Module** lifecycle | `J-13` | Absent |
| P2-12 | Geospatial/score columns in property comparison | `I-10` | Only basic listing fields compared |
| P2-13 | PostGIS spatial indexes and map caching | `NFR02` | Nothing to index or cache |
| P2-14 | Stateless scalable service architecture | `NFR03` | In-memory singletons |
| P2-15 | Repair **cross-platform parity** (web/mobile feature drift, duplicated nav map) | `NFR05`, `ASR-04` | `parentShellRoute` duplicated and drifted |

### P3 — Consistency, Quality and Traceability. 16 items.

| # | Item | Requirements | Current state |
|---|---|---|---|
| P3-1 | Register the `$id`-suffixed routes emitted by `EvaluationFlowCoordinator` | Routing integrity | `/entrepreneur/property/$id/{location,suitability,tour,explanation}` are not in `app_routes.dart` |
| P3-2 | Eliminate the duplicated `parentShellRoute` map (single source of truth) | `NFR01`, `NFR05` | `app_routes.dart:48-61` vs `navigation.dart:98-112`, already divergent |
| P3-3 | Consolidate the three state patterns onto one | `NFR01`, `ASR-04` | Cubit + `ChangeNotifier` viewmodels + raw `setState` |
| P3-4 | Remove the `ServiceLocator` static-mutable state | `NFR01` | Documented violation V1/V2 in `ARCHITECTURE_AUDIT.md` |
| P3-5 | Re-run and publish a reproducible test suite; **the toolchain currently hangs** | All verification claims | `dart --version` and `dart test` hang >240 s; 27/27 and 18/18 are **BLOCKED-UNVERIFIED** |
| P3-6 | Assign requirement IDs to the documented but ID-less modules | Traceability | Modules C, G and the §1.6 module list have no REQ IDs |
| P3-7 | Refresh `DESIGN.md` §4/§7 (stale: CSS grew 1,358 → 1,876 lines) | Documentation integrity | Token tables and component inventory out of date |
| P3-8 | Correct or retire `README.md` test claims | Documentation integrity | Claims 27/27 and 18/18; not reproducible |
| P3-9 | Reconcile `ARCHITECTURE_AUDIT.md` ("There are no BLoCs in this project") with the current 4 cubits | Documentation integrity | Premise now false post-migration |
| P3-10 | Decide the fate of the orphaned `test/server.js` Express app — integrate or remove | Architecture clarity | Contains the repo's only geospatial code; unreachable from the apps |
| P3-11 | Decide the fate of root data files and the source-less `edgeprop_scraper.pyc` | Architecture clarity | 25 MB of unused data; compiled scraper with no source |
| P3-12 | Remove stray root artefacts (`flutter_01.log`–`flutter_06.log`) | Repository hygiene | Six log files at root |
| P3-13 | Implement email verification and `isEmailVerified` (§4.6) | `REQ-101`, `NFR04` | No such flow |
| P3-14 | Implement password hashing per §4.6 (bcrypt/Argon2) | `NFR04` | No hashing exists |
| P3-15 | Add `PROPERTY_FEATURE` and `PROPERTY_FOOT_TRAFFIC` support | Schema completeness | Both tables unimplemented |
| P3-16 | Populate `docs/` as a maintained documentation location | Documentation | Folder did not exist before this audit |

**Priority totals: P0 = 12 · P1 = 18 · P2 = 15 · P3 = 16 → 61 work items** covering all 71 outstanding in-scope requirements (some items unblock several requirements; some requirements need several items).

---

## 5. End-to-End Workflow Audit

The report defines nine use cases in §4.4. One (4.4.8, 360° Virtual Tour) is excluded. Each remaining workflow was traced from entry point through data layer to result, using `REQ` and `FR` cross-references.

| # | Use Case (§4.4) | Trigger | Data path traced | Outcome | Verdict |
|---|---|---|---|---|---|
| 1 | **4.4.1 Manage Commercial Property** (`FR-201`–`FR-206`) | Owner opens Add Property | Form → `PropertyRepositoryImpl.create` → `_store` (memory). Mobile: form → SnackBar → pop | Web creates a record with **hardcoded `lat 3.0738`, `lng 101.5870`, `state 'Selangor'`, `type 'Shop lot'`, `score 0`**. Mobile creates nothing. **Update** works (web only) via a hand-rebuilt record. **Delete has no implementation at any layer** (`FR-203`) | **BROKEN END-TO-END** — create is partial and platform-asymmetric; delete is absent |
| 2 | **4.4.2 View / Search Property** (`FR-204`–`FR-206`) | Entrepreneur opens Explore | `Enter.` → `loadExplore` → `GetProperties` → `listings()` → `_store` → `FilterProperties` (query + structured filter) → list UI | Search and filter both work correctly over the 8 demo records. Query matches title/city/address; filter covers price, size, type, city, verification. This is the **most complete workflow in the system** | **FUNCTIONAL (scope-limited)** — works as designed, but over hardcoded demo data only |
| 3 | **4.4.3 Perform Geospatial Analysis** (`FR-301`–`FR-306`) | Entrepreneur opens a property's analysis | `loadAnalysis` → `GetLocationAnalysis` → `DemoData.analysisFor(id)` → returns a **`const` factor list** | **Every property returns identical factor scores and identical evidence strings**; only the interpolated city name in two sentences varies. `competitorCount: 14` is a literal. No distance computation, no radius, no external data | **NOT IMPLEMENTED** — the workflow returns constants. The map/analysis screens display these constants as if computed |
| 4 | **4.4.4 Generate AI-Based Recommendations** (`FR-401`–`FR-405`) | Entrepreneur opens Recommendations | `loadRecommendations` → `GetRecommendations(prefs)` → filter on `minBudgetRm`/`maxBudgetRm`/`minSizeSqft` → `sort` by authored `suitabilityScore` → `.take(5)` | No PU Learning model, no prediction, no geospatial input. Ranking is a sort over literals; rank order is fixed by demo authoring order. `whyRecommended` is a hardcoded 3-item constant. Six of nine preference fields have no effect | **NOT IMPLEMENTED AS DOCUMENTED** — a budget/size filter is presented as an AI recommendation |
| 5 | **4.4.5 View Recommendation Explanation** (`FR-501`–`FR-503`) | Entrepreneur opens Explanation | `getExplanation` → filters the same `const` factors → strengths/considerations + **hardcoded `summary`** | Explanation text is invariant across properties because its inputs are constants. **No SHAP values exist** — stated in the web source itself. This is a static panel over predefined text, which the audit brief explicitly excludes from counting as an XAI pipeline | **NOT IMPLEMENTED** — explanation is predefined prose |
| 6 | **4.4.6 Explore Property Using Interactive Map** (`FR-601`–`FR-609`) | Entrepreneur opens Explore map tab | `_MapSurface` / `SitewiseMapPanel` → `CustomPaint` grid + `Align`ed `IconButton` pins positioned by an affine lat/lng squash | **No map SDK, no basemap, no tiles, no projection, no panning** — both sources say so explicitly. Pins render and (web) link to detail. **No competitor, demand-generator, transport or demographic layers; no layer toggles; no proximity queries** | **NOT IMPLEMENTED** — a stylised placeholder, self-documented as such ("Swap the body for a real map SDK later") |
| 7 | **4.4.7 Manage Favourite Properties** (`FR-701`–`FR-703`) | Entrepreneur taps bookmark | `AppCubit.toggleSaved(id)` → `Set<String>` → saved page | Save, view and remove all work in both trees. **Set is process-memory only** — all favourites are lost on restart; `FAVOURITE_PROPERTY` is unimplemented | **FUNCTIONAL (non-persistent)** — the only fully working workflow, but durability is absent |
| 8 | **4.4.9 Administer System and Verify Content** (`FR-901`–`FR-906`, virtual-tour step excluded) | Admin opens dashboard | `loadDashboard` → counts; `loadUsers` → `DemoData.users` (read-only); verification → `getPendingQueue` → `verify`/`reject` → `updateVerification` | Verification workflow is coherent and complete in-memory. **User management is read-only** (no suspend/edit/delete). **Recommendation monitoring (`FR-904`) and explanation monitoring (`FR-905`) have zero implementation.** Dashboard shows counts over demo data; **no user-activity monitoring** | **PARTIAL** — verification works; monitoring and management do not |
| 9 | **Reporting** (§1.6: Business Assessment Report, Location Recommendation Report) | Entrepreneur opens Report | `GenerateEvaluationReport` → `DemoData` analysis + a **hardcoded recommendation sentence** → `EvaluationReport` → on-screen render | Report renders. **No download, print, PDF, CSV, export or share action exists in either tree.** Content derives from constant factors, so the "assessment" is identical across properties | **PARTIAL** — viewable, not deliverable, and not property-specific |

### 5.1 Cross-Cutting Workflow Defects

| Defect | Impact | Evidence |
|---|---|---|
| **No persistence anywhere** | Every workflow resets on restart. Verification state, favourites, comparison, created properties and preferences are all lost | `List.of(DemoData.properties)`, `Set<String>`, in-memory singletons; only the auth session file survives |
| **Platform divergence** | Web lacks registration and logout; mobile's add-property persists nothing; navigation maps have drifted | `fyp_jaspr_web/lib/pages/` contains no signup page; zero `signOut` matches in web; F-13; F-14 |
| **Unregistered routes** | `EvaluationFlowCoordinator` emits `/entrepreneur/property/$id/{location,suitability,tour,explanation}`; `app_routes.dart` registers only query-param forms. Deep links into per-property analysis are dead ends | `app_routes.dart` vs `evaluation_flow_coordinator.dart` |
| **No error surface for data failures** | Since there is no backend, "error" states are unreachable and untested; a real data layer would expose unhandled paths | Cubits catch exceptions and emit `error` strings, but nothing exercises them |
| **Placeholder presented as feature** | The stylised map, the constant "AI" scores and the predefined explanations all render convincingly. A reviewer evaluating the UI alone would overestimate completeness — the exact risk the audit brief flags | F-3, F-5, F-6, F-7 |

**Workflow scorecard: 2 functional (both non-persistent or scope-limited) · 3 partial · 4 not implemented.** No workflow completes end-to-end in the way the report describes.

---

## 6. Documentation and Architecture Gaps

### 6.1 Documentation Gaps

| # | Gap | Detail |
|---|---|---|
| DG-1 | **No Chapter 5 (Implementation) exists** | The report runs Chapters 1–4 then References. There is no implementation chapter describing what was actually built, no testing/evaluation chapter, and no results discussion. The gap between design (§4) and code is therefore undocumented everywhere, not just here |
| DG-2 | **Requirements have no traceability to implementation** | §3.2.1 defines 54 `REQ-###`; nothing in the repository references a single one. No traceability matrix exists. This audit had to construct the mapping from scratch |
| DG-3 | **Documented modules carry no requirement IDs** | The §1.6 team table lists Knowledge Management, Assessment Orchestration, Adaptive Questionnaire, Evidence Processing, Decision Analysis (Deterministic Decision Engine), Recommendation Management, AI/RAG Integration, Reporting and Backend API as deliverables, but §3.2.1 assigns them no IDs. Nine such modules are entirely absent yet untracked by the requirements table |
| DG-4 | **`docs/` did not exist** | No documentation folder was present anywhere in the repository. This report creates it. Project documentation lived only in root-level Markdown and `.workbuddy-ai/` |
| DG-5 | **Named deliverables are not in the repository** | `RSW_JOELTANHOUJUN_Project1`, `Project Summary.docx` and `Section_3_3_System_Design_Use_Case_Tables.docx` were searched for across the tree, the user profile and OneDrive. **No `.docx`, `.doc` or `.pdf` exists anywhere in the repository.** The only copy of the report is the OneDrive PDF used as the authority for this audit |
| DG-6 | **README test claims are not reproducible** | `README.md` and `ARCHITECTURE_AUDIT.md` assert `flutter test fyp_mobile_app` 27/27, `dart test` 18/18 and a 28-route Jaspr build. **None can be reproduced** — the CLI hangs (§0.4). The test files do exist (`fyp_mobile_app/test/widget_test.dart` 275 lines with 10 `testWidgets`; `shared_logic/test/application/cubits_test.dart` 198 lines with 20 `test` cases), so the claims are plausible but unverifiable |
| DG-7 | **`DESIGN.md` is stale** | `web/styles.css` grew from 1,358 to 1,876 lines after `DESIGN.md` was written; its §4 (components) and §7 (tokens) no longer match the stylesheet |
| DG-8 | **`ARCHITECTURE_AUDIT.md` states a now-false premise** | It declares "There are no BLoCs in this project" — true before the migration, false now: four cubits live in `shared_logic/lib/src/application/cubits/`. The document was not updated after the migration it describes |
| DG-9 | **No API documentation, no schema DDL, no deployment documentation** | §4.6 specifies 13 tables and §4.5 a deployment diagram, but no DDL, no migration, no API specification and no deployment guide exist in the repository |
| DG-10 | **AI-DSS scope was analysed but not actioned** | `.workbuddy-ai/AI-DSS_MODULE_GAP_ANALYSIS.md` already records that subsystem 2 (Evidence-Based AI-DSS) is "~0%" and lists 8 missing AI-DSS modules and 14 report screens. **This audit independently reproduces that conclusion** by construction from the report text rather than from that memo |

### 6.2 Architecture Gaps Against §4.1

The report specifies strict Clean Architecture with four layers — Presentation, Application, Domain, Data — under the Dependency Rule, plus five ASRs.

| # | Documented architecture element | Implementation reality | Verdict |
|---|---|---|---|
| AG-1 | **Presentation → Application → Domain → Data** with inward-pointing dependencies | `shared_logic` genuinely separates Domain (entities, repository interfaces, use cases) from Application (cubits, services) and is UI-free. Inward dependencies hold. **This is the project's strongest architectural achievement** | **Partially satisfied** |
| AG-2 | **Data Layer** integrating PostgreSQL/PostGIS, ML models and LLMs | **The Data Layer is entirely demo : `DemoData`, in-memory repositories, no DB, no model, no LLM.** `shared_logic` has a single dependency (`bloc`) and is deliberately dependency-free, so it structurally cannot host a DB or ML client without a manifest change | **NOT IMPLEMENTED** — the layer with the most documented responsibility exists only as local fixtures |
| AG-3 | **ASR-02** AI and knowledge integration isolated to the Data Layer | No AI or knowledge component exists to isolate | **NOT IMPLEMENTED** |
| AG-4 | **ASR-03** heavy geospatial processing delegated to PostgreSQL + PostGIS | No PostgreSQL, no PostGIS. The only spatial computation in the repo is an orphaned Express `haversine()` crossing no application boundary | **NOT IMPLEMENTED** |
| AG-5 | **ASR-04** cross-platform consistency via Flutter + BLoC | The web UI is a **separate Jaspr SSR tree**, not Flutter. BLoC is one of three coexisting state mechanisms | **NOT IMPLEMENTED as specified** — the single-codebase premise is unmet |
| AG-6 | **ASR-01** deterministic business reasoning isolated | No deterministic engine; reasoning is a predicate and a sort | **NOT IMPLEMENTED** |
| AG-7 | **ASR-05** independent relational and vector stores with DTOs | DTOs/entities exist and are clean; **neither store exists** | **Partially satisfied** (structuring only) |
| AG-8 | **§4.5 deployment architecture** | No deployment artefacts of any kind — no Docker, no CI, no hosting config, no environment management. `AppConfig` holds empty credentials | **NOT IMPLEMENTED** |
| AG-9 | **§4.6 database schema** (13 tables) | Zero tables materialised; no DDL | **NOT IMPLEMENTED** |
| AG-10 | **Single source of truth for shell/navigation** | `parentShellRoute` is hand-duplicated between the two trees and has already drifted (`app_routes.dart:48-61` vs `navigation.dart:98-112`) | **DEFECT** |
| AG-11 | **One UI codebase** (report §4.9 presents a unified UI design) | Two independent hand-written UI trees, 33 mobile pages + 27 web pages = 60 pages, with partial and diverging feature parity | **DEFECT** |
| AG-12 | **Repository pattern enabling service substitution** | Interfaces are correctly defined and injected via composition roots (`app_locator.dart`, `ServiceLocator`) — but no alternative implementation has ever been supplied, so substitutability is designed, not demonstrated | **Designed, unproven** |

### 6.3 Structural Risk Summary

1. **The gap is architectural, not incremental.** The three subsystems that define the project — PU Learning, geospatial intelligence, and the PostGIS-backed data layer — have no implementation. Adding them requires new dependencies, a new backend, a new persistence layer and a new module; this is not a set of finishing fixes. **12 P0 items, and 60 of the 71 outstanding requirements (85%) are downstream of P0-1 through P0-6.**

2. **The UI currently overstates completeness.** Constant scores, invariant factor lists, predefined explanations and a placeholder map all render as finished features. Any evaluation based on screenshots rather than data flow will materially overestimate progress. This is the single most important finding for the project's academic defence.

3. **There is no reproducible verification path on this machine.** The Dart/Flutter CLI hangs on every invocation. Until that is resolved, no test result, no build result and no runtime claim in the project's documentation can be independently confirmed, and this audit's own §3E/§9 test-execution obligation must be recorded as **BLOCKED-UNVERIFIED** rather than passed.

4. **Traceability is absent.** The report's 54 `REQ-###` identifiers appear nowhere in the codebase, and nine documented modules have no requirement IDs at all. Without a traceability matrix, implementation progress cannot be measured by anyone — including the authors.

5. **Scope reduction is a legitimate option.** If the PU Learning and geospatial subsystems cannot be delivered in the remaining time, the honest and defensible path is to formally reduce scope in the report (declare the geospatial and ML modules as future work), rather than to present constant-valued placeholders as implemented analysis. The current codebase already contains several candid source comments admitting the placeholders — those comments should be reflected in the documentation.

---

## 7. Audit Integrity Statement

- **360° Virtual Tour Module:** fully excluded per §0.1, removed at inventory construction. It contributes **zero** to the 45/55/81 denominators, to the 9/10 DONE counts, to the completion percentages, to the 71 outstanding items and to the 61 prioritised work items.
- **No source code was modified.** No database object was created. No dependency was added. No screen was rewritten.
- **No test was executed and no result is claimed.** The Dart/Flutter toolchain hangs on invocation in this environment; all test claims are `BLOCKED-UNVERIFIED`.
- **No application was built, served or rendered.** Every finding is a static code or document finding.
- **No finding is fabricated.** Each status is backed by a named file and, where relevant, a line reference or an in-source quotation.
- **Metrics used:** `Outstanding = PARTIAL + NOT DONE + BROKEN`; `Verified completion rate = DONE / total in-scope × 100%`; `OUT OF SCOPE` excluded from all denominators. No requirement is `BROKEN` and none is `BLOCKED-UNVERIFIED` (implementation existence was statically confirmed; it is the *test evidence* that is blocked).
- **Headline result:** of **81** in-scope documented items, **10 (12.3%)** are implemented, **27 (33.3%)** are partial, **44 (54.3%)** are not done, and **71 (87.7%)** require further work.

*End of report.*