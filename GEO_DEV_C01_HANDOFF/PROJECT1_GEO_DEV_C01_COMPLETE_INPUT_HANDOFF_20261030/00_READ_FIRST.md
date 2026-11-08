# PROJECT1 — GEO-DEV-C01 Complete Input Handoff (2026-10-30)

## What this handoff is

Use this package **together**: (A) the earlier *actual source scaffold* and (B) the new **GEO-DEV-C01** developer execution prompt, plus (C) documentary GEOH/GEOHD context. The source scaffold is not the adopted Project1 application, and the research documents contain *proposals* and *open* contradictions.

**Status:** `SOURCE_SCAFFOLD_VERIFIED_FOR_HANDOFF — NOT_DART_BUILT — NOT_INTEGRATED — NOT_INDEPENDENT_QA`.

**Owner authority:** this bundle supplies inputs, not authorisation to modify protected production branches, adopt policy, use real rentals/competitors/polygons, or advance H3, L1, L2 or L3.

## Open first (in order)

1. `developer_instruction/01_GEO_DEV_C01_EXECUTION_PROMPT_V3.md` — current execution assignment and coordinator profile.
2. `source_scaffold/PROJECT1_JASPR_THREE_COORDINATE_INCREMENT_20261030/README.md` — source setup and limitations.
3. `source_scaffold/PROJECT1_JASPR_THREE_COORDINATE_INCREMENT_20261030/docs/03_PROCEED_NOW_WITH_THREE_SYNTHETIC_COORDINATES.md` — why three fictional coordinate fixtures can proceed independently of BC-05.
4. `research_inputs_PROPOSED_NOT_ADOPTED/GEOH-04_JASPR_INPUT_OUTPUT_DATA_CONTRACT.md` and `GEOHD-01_REVISION_OVERLAY.md` — proposed contract and changes. **Read latest second-pass challenge before implementing any disputed rule**.
5. `research_inputs_PROPOSED_NOT_ADOPTED/PROJECT1_GEOHD_SECOND_PASS_CHALLENGE_20261030.md` — S2-01…06 open; do not treat disputed boundary membership / E2_DESC / R12 cardinality as frozen implementation oracles.

## What is already coded (source, not build)

- `lib/synthetic_rentals.dart`: three fictional rental points A/B/C, with explicitly synthetic test assumptions.
- `lib/main.client.dart`: initial Jaspr UI candidate.
- `lib/geometry_contract.dart`: Dart geometry and evidence-state helpers **with known proposed-policy deltas**.
- `web/map_bridge.js`: Leaflet map bridge and marker-selection/circle source; **node --check passed** in this handoff environment.
- `web/index.html`, `web/styles.css`: presentation assets.
- `test/geometry_contract_test.dart`, `test/synthetic_venue_geometry_test.dart`: test source **not executed** by a Dart runtime.
- `pubspec.yaml`: standalone scaffold dependency declaration.

## What is not already coded or verified

- No confirmed Jaspr compilation, `dart test`, `jaspr build`, browser run, screen-reader/keyboard checks or responsive screenshots.
- No district/mukim administrative polygon UI implementation or five-state renderer in the V2 source; this is a **new, bounded developer task**.
- No integration with actual Project1 Jaspr V4 12-workflow prototype, BC-05 teammate rental selection, account/assessment backend, persistent data, real competitor source or report assembler.
- No real district/mukim polygon licence/parent hierarchy validation; no real venue observation rights.
- The old source contains exploratory assumptions (e.g., tolerance example 0.5 m, three fixtures styled as premises). They are **not** adopted ODR-3 policies. Current GEOHD S2 conflicts are unresolved.
- The scaffold's README may still mention an older two-rental illustration in its `What you should see` section; **V2 is authoritative for fixture count**, three A/B/C markers from `synthetic_rentals.dart`. Confirm browser behaviour rather than accepting prose.

## Mandatory integration rule

First inspect the *actual* Jaspr V4 repository before writing. The correct action is to **reuse and adapt** scaffold components within an isolated branch/worktree of the current Project1 app, not to replace the 12-workflow app or create a competing frontend. If Project1 root is inaccessible, record `REPO_NOT_ACCESSIBLE` and confine work to a separate isolated test worktree.

## Required first engineering checks

1. Pin actual repo branch/commit and source hashes; inspect `pubspec.yaml`, SDK/Jaspr versions and any project-level restrictions.
2. Use the *real installed* `dart` and `jaspr` toolchain. Record `dart --version`, `dart pub get`, `dart test`, `jaspr build` results, with exact exit codes.
3. Run local browser; verify three markers, selection changes, map layer attribution, synthetic labels, keyboard navigation and mobile layout. Do not claim passed tests based solely on source checks.
4. Implement only uncontested synthetic map/admin presentation and R01/R09/R12 placeholders. Hold boundary partition, E2_DESC, GM-12 Option B and cardinality semantics behind explicit policy states pending Owner adoption.
5. Return DEV00–DEV06, source code, browser evidence, independent-QA request, manifest, blocked test table; make no unsupported production claim.

## Existing package validation performed for this bundle

- Original V2 zip: 15 files; archive CRC good.
- Original V2 SHA256 manifest: 14/14 file hashes matched extracted bytes.
- `node --check` on original `web/map_bridge.js`: exit 0.
- Dart/Jaspr not available in this handoff environment — build status remains NOT_EXECUTED.

The `original_archive/` ZIP is retained unchanged for provenance. Do not edit it; make source changes in an isolated working copy created from `source_scaffold/`, with a new versioned manifest.
