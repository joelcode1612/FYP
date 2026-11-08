# PROJECT1 — Jaspr three-coordinate geometry and report proof-of-concept

**Assignee:** Existing Jaspr UI and geometric/report integration team. **Execution:** isolated prototype only; no production workspace edits without independent authorisation.

Owner decision: **Do not wait for the rental teammate to supply coordinates before building the synthetic geographic UI.** Use exactly the three fictional centres in `lib/synthetic_rentals.dart`. They are neither real rentals nor certified premises coordinates. Leave the teammate catalogue and BC-05 production UI untouched.

Start from this V2 package. Establish the installed Dart/Jaspr versions, run dependency resolution, compile, run `dart test`, serve and build. Correct compile or interaction defects in the isolated increment and document diffs, tests, and execution outcomes. Keep `jaspr` web frontend, Leaflet renderer, and an OSM basemap with visible copyright attribution.

Run the additional six fake venue point geometry tests (`test/synthetic_venue_geometry_test.dart`); keep those venue fixtures out of production R09. Implement and demonstrate: three synthetic rental markers simultaneously; selected marker and test-only study circle; change preview `R` between 400/500/800/1200 metres with no automatic default claim; R01 synthetic locality and R09 S1 missing-source status plus separate R12-style provenance; one combined illustrative report with three rental references; geometry validation, precision/refusal tests, keyboard/accessible status/qualifier tests and responsive screenshots. Add a `SYNTHETIC_ONLY` banner to every visible report/export.

Preserve ODR-3's two demonstrated defects as regression obligations: D-1 6000 m must be refused, not silently clamped to 5000 m; F-2 boundary tolerance must be explicit and tested, without presenting the experimental 0.5 m as adopted policy. Follow GM-12 S-state triggers and never use array length alone to assert completeness or market absence. Do not count POI labels from map tiles.

**Separate technical from governance:** the code may be developed in the isolated prototype; do not claim Jaspr integration complete or make production edits. Report compiled/tested cases separately from synthetic assertions. Keep real rental integration, ODR-3a adoption, ODR-4 and H-F venue source rights, and H3/H0/report scientific gates open.

Return: (1) exact source commit / SHA, (2) Dart/Jaspr versions and reproducible commands, (3) build and tests results, (4) three-point map screenshots plus report preview, (5) accessibility checklist and defects, (6) remaining-to-production contract list. Do not reopen the previous geographic research or conduct live competitor scraping.
