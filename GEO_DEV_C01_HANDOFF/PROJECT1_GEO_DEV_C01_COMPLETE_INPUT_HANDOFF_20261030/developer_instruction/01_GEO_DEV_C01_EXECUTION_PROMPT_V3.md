# PROJECT1 — GEO-DEV-C01: Bounded Jaspr geographic/report development now
**Directive:** `PROJECT1-JASPR-GEO-SAFE-INCREMENT-20261030-V3`
**To:** Existing Jaspr developer team. **Scope:** local isolated synthetic development; no global team reorganisation.

## Coordinator profile and authority
**Role title:** Geographic Frontend Integration Coordinator (`GEO-DEV-C01`).
**Minimum profile:** demonstrable Dart/Jaspr client components, CSS responsive design, test harnesses, JavaScript interop/Leaflet, map layers, GIS provenance concepts, accessibility, immutable-source workflows and code-review/change-log discipline. Evidence of ability is an actual environment check and reproducible build, not an LLM persona claim.
**Accountability:** one coordinator must own task dependency tracking, a pin register, issue/decision log, a combined acceptance report and submission to Owner. The coordinator can allocate roles within its own developer team, stop risky changes, and request missing inputs. It cannot approve research policy, overwrite another team's rental code, license real datasets, sign independent QA or declare H3/H-F/production passed. Record coordinator agent identifier, workspace branch and accept/decline of role in `DEV00_COORDINATOR_RECEIPT.md`; if not appointed, `COORDINATOR_UNASSIGNED` rather than pretending.
**Team roles:** D1 Jaspr frontend developer, D2 geometry/contract adapter developer (may be same person if resource-constrained but tracked), D3 accessibility/test implementer, and **Q1 independent reviewer** selected by Owner, distinct from D1/D2/coordinator. If Q1 unavailable, provide tests but leave independent verdict `NOT_EXECUTED`.

## Authority / scope guard
Owner requests preparation of this bounded isolated synthetic increment. This text does **not** itself grant `BUILD-01`, real rentals, live source ingestion, database migrations, production UI replacement or release. Check actual local authorization register before any repository write. If production write is not authorized, create a separate worktree/prototype folder and commit nothing to protected branches.

## Phase 0 — reuse actual baseline
1. Locate Project1 Jaspr V4 12-workflow candidate and the earlier Jaspr three-coordinate scaffold. Inspect actual root, `pubspec.yaml`, lockfile, Dart/Jaspr versions, git state; pin relevant bytes and state which is controlling. **Do not create a second competing 12-workflow app.**
2. Inspect frozen `GEOH-01…05`, overlay `GEOHD-01…03`, and `PROJECT1_GEOHD_SECOND_PASS_CHALLENGE_20261030.md`. Note 88 old and 62 new documentary check emissions; 49 app acceptance tests are **specified, not executed**. Label unresolved S2 findings as `PENDING_POLICY`.
3. Verify skill/toolchain using installed version and official Jaspr docs. Useful commands: `dart --version`, `jaspr doctor`, `dart pub get`, `dart test`, `jaspr analyze`, `jaspr serve`, `jaspr build`; capture exact exit codes, versions, artifacts. Use rendering mode *of existing application* rather than silently creating a new architecture. For Leaflet use properly scoped client-side JS interop; preserve server-rendering safety if the existing app uses SSR.
4. Document source access gaps, current authorization and safe write destination before changes.

## Phase 1 — uncontested synthetic UI only
1. Build/repair the **three fictional rental points**: A=(3.143200,101.689200), B=(3.150200,101.698800), C=(3.135600,101.702200), `synthetic=true` explicitly. Show them together, select by stable test ID, and keep BC-05 selection unmodified. Reuse source-provided distance fixtures to test (not invent result accuracy from screenshots).
2. Render Leaflet/OpenStreetMap **basemap only** with the required attribution; no bulk tile download. Draw clearly labelled experimental circles in 400/500/800/1200 m previews; no assumed default or official R. Study/display radii must match; invalid/over-max requests produce a reason code, not silent clamp. For disputed boundary uncertainty, do not implement the GEOHD second-pass predicate as adopted; mark precise membership test `BLOCKED_POLICY`, use only conservative display or non-border fixtures.
3. Administrative geography is a **separate layer** from study circles. Support STATE_FT, DISTRICT, MUKIM with jurisdiction-specific `notApplicable`, plus the five display *labels* `verified`, `partial`, `named`, `unresolved`, `notApplicable`. Preserve locality hint separate from an area code. Do not infer district from city name, parent district from mukim name, or a polygon from a circle. Use clearly watermarked **synthetic polygon fixtures only**; unvalidated/unlicensed real polygons never render. Keep separate polygon-render, marker-display and tier-identity state fields.
4. R01 presents rental locality/admin status; R09 presents a **synthetic context / no-real-evidence** explanation, never a competition ranking, true competitor count, demand or suitability; R12 presents synthetic source and data limitations. Implement accessible links/tabs/anchors between R09 and R12 as a layout candidate, preserving missing-footprint explanation. **Do not pre-adopt GM-12 Option B**, E2_DESC, the new boundary-undecided rule or newly contested cardinality: put them behind explicit `UNADOPTED_POLICY` / neutral showcase mock mode, no default.
5. Provide desktop and mobile views, keyboard focus, non-colour state labels and attribution. Clearly watermark all synthetic data and prevent export through any evidence/real-report route.
6. Use modular clean code: domain models (synthetic fixtures), geometry helper, map bridge, administrative state presenter, R01/R09/R12 presenter; descriptive comments for invariants and source/decision IDs, no invented author names or misleading self-certification.

## Phase 2 — independently test what is buildable
- Executed tests for three markers/selection, experimental radius equality/refusal, labels never masquerading as polygons, marker-versus-polygon independence, source/date/unknown states, synthetic watermarks and export refusal, keyboard navigation, R09/R12 linkage, mobile rendering.
- Include **negative cases** (incorrect district inference, a faux real polygon, 6,000m clamp, rental label with digits, missing footprint, mismatched radii), but hold tests whose expected oracle is disputed under S2-01…06.
- Compare the GEOH/GEOHD `T-01…T-49` catalogue with implemented tests; give each case one of `EXECUTED_HOLDS`, `EXECUTED_VIOLATED`, `NOT_EXECUTED_POLICY`, `BLOCKED_SOURCE`, `ABSENT_INPUT`; do not present 49/49 if only a subset ran.
- Run full Jaspr build and actual local browser; include logs, screenshots, any server/client runtime errors, map-tile attribution and accessibility checks. A source compilation alone is not browser QA.

## Coordination and handover outputs
Save in a new isolated, version-controlled work folder under `New_Goal/JASPR_GEO_SAFE_INCREMENT_20261030` unless the Owner authorizes another destination:
`DEV00_COORDINATOR_RECEIPT.md`, `DEV01_INPUT_PINS_AND_SCOPE.md`, `DEV02_COMPONENT_AND_DATA_ADAPTER.md`, `DEV03_TEST_EXECUTION.csv`, `DEV04_BROWSER_EVIDENCE.md`, `DEV05_POLICY_BLOCKERS_AND_RESEARCH_QUESTIONS.md`, `DEV06_HANDOVER_AND_VERDICT.md`, `SHA256_MANIFEST.txt`; include actual source code and screenshots.
Include source/branch/commit, line-linked deviations from GEOH/GEOHD, any dependency requested from Track G or BC-05, and exact paths to verification files. Coordinate direct **questions** to Track G via Owner; do not assume Master or other centralised lead exists.

## Exit criteria
- L1 candidate only when `dart test` and `jaspr build` exit 0 **and** a browser run demonstrates the named synthetic UI and accessibility checks. Other failed/blocked tests must be visible.
- On partial result use `JASPR_GEO_SYNTHETIC_PARTIAL`; on actual verifiable compile/browser success with accepted non-contested tests use `JASPR_GEO_SYNTHETIC_IMPLEMENTED_PENDING_INDEPENDENT_QA`.
- Never claim `L2`, `L3`, `H3`, Owner adoption or finished R09 competitor specification. Return blockers and next smallest correction, no blank success statement.
