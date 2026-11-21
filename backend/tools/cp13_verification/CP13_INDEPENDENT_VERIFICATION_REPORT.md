# CP-13 independent Python package verification

Date: 19 November 2026. Actual checkout `merge_main_jed`, HEAD
`ba30035ecb24b80fa155cc7049cf3cdf94a67844`.

**Package delivery is runnable and demonstrated. Overall live-cloud CP-13
acceptance remains BLOCKED.** QJ is excluded. No real customer collection or
report authority was enabled.

## Delivered files

- `cp13_manual_verify.py`: interactive menu and equivalent arguments, three modes,
  exact sanitized JSON evidence, read-only original DB integrity checks, opt-in
  isolated live endpoint execution and persisted-evidence acceptance checks.
- `test_bdj.py`, `test_bcb.py`, `test_direct_qg.py`: actual engines and validation
  assertions; test providers are explicitly MOCKED.
- `fixtures/`: existing BCB fixture copy and 12 scenario definitions with explicit
  expected results; separate 11-answer M2V1 code example is never registered/written.
- `objective_fixture.py`: test repository for actual `ConfirmationService`
  confirmation, clarification and separate-concern operations; no retired-stage call.
- `test_source_routing.py`, `test_verifier.py`: source routing, ownership adapter,
  guard preservation, secret redaction and independent acceptance checks.
- `postgres_checks.py`: six targeted existing private-PostgreSQL checks, exporting
  real generated assessment/context IDs and exact SQL readback.
- `resolve_blockers.py`: read-only actual policy/configuration/runtime-role/schema,
  FK, budget and protected-Fiesta status evidence.
- `verify_persistence.sql`, `.env.example`, `README.md`, `verify_package.py`.

The repository's existing `run_isolated.py` gained an additive `cp13-bcb` suite.
The cloud candidate router now uses the existing dedicated, owner-scoped M2
connection. The cloud-BDJ route test's source dependency override was updated.
No new engine, endpoint, product table or questionnaire contract was invented.

## Executed results

| Check | Actual result | Classification |
| --- | --- | --- |
| Existing Python environment | Python 3.13.5; `pip check`: no broken requirements | Real environment |
| Package tests after source fix | **48 passed** | Actual source with labeled test ports |
| All scenario CLI run | **12/12 expected outcomes passed** | MOCKED provider; actual engines/validators |
| BDJ-only CLI | PASS; explicit conflict preserved despite empty fixture-model answer | MOCKED |
| BCB-only CLI | PASS; canonical deterministic packet and provenance | Actual deterministic builder, synthetic ports |
| Direct-QG-only CLI | PASS; invented RM999 refused with MODEL_FAILURE | MOCKED negative test |
| Interactive menu | PASS; BDJ menu selection ran and wrote evidence | MOCKED |
| Isolated PostgreSQL / real HTTP+JWT | **6 passed**, create 201, replay 200, cross-owner 404 | Real local HTTP/database; synthetic test identity/policy |
| Original database observations | PASS: read-only before/after hashes match; protected state retained | LIVE inspection, zero workflow writes |
| Live cloud command | BLOCKED, exit 2 as intended | No model replacement or provider dispatch |

The full controlled workflow attaches real BDJ-engine findings to an explicitly
synthetic confirmation fixture and builds BCB through the real deterministic
builder. It passes that exact packet into `DirectQgService.prepare_candidate`.
No mocked result is reported as live cloud success. A controlled validation
failure can PASS its expected refusal assertion while the module's actual outcome
is MODEL_FAILURE; both values are saved.

## Scenario coverage and limits

Complete information, explicit conflicting declarations, mandatory omissions,
typos/ambiguity preserved verbatim, confirmed objective, clarification, separate
research concern, unauthorized generation, invalid/unsupported questions, timeout,
malformed response and schema validation failure were exercised.

Objective tests call the real `ConfirmationService` through a test repository.
CLARIFY requires an existing unresolved limitation; the missing-limitation refusal
also passes. Separate concerns retain separate IDs instead of being mislabeled
as a clarification. These objective tests are not PostgreSQL persistence claims.

Deterministic BCB preserves exact answer/revision references and produces the
same hash for the same source. Candidate validators reject fabricated references,
quotes, unsupported numbers/amounts and coding/routing drift. These checks do not
prove unrestricted natural-language semantic correctness or scientific adoption.

## Reproduce

Use the exact PowerShell commands in `README.md`. The executed command log is:

`artifacts/cp13_20261119/independent/delivery_20261118T200418/executed_commands.json`

That command demonstration contains 39 tests before the final source-routing
fix; the final package test result is independently recorded in:

`artifacts/cp13_20261119/independent/pytest_after_source_fix.xml` (**48 passed**).

Actual PostgreSQL evidence:

`artifacts/cp13_20261119/isolated_bcb/cp13_bcb_persistence.json`

Read-only final configuration and original DB state:

`artifacts/cp13_20261119/final_readonly/`

The initial failed fixture expectations are preserved in earlier evidence folders.
They included an old GEO binding in the GEO-excluded current builder and two
incorrect expected failure classifications. The fixture setup and expectations
were corrected; production validators were not weakened.

## Exact live blockers

- Cloud provider and cloud-BDJ router remain disabled by effective settings.
- D02 explicitly retires M2V1 BDJ rules; no adopted applicable replacement exists.
- Normal M2 projection has no synthetic disclosure marker; no blanket relabeling
  or approval was added.
- Live BCB confirmation-validity policy is unset. Private tests use an explicit
  synthetic 90-day basis; they do not adopt a product policy.
- QG authorization binds another synthetic assessment/source. Its file was preserved.
- Actual returned-model/token/cost evidence is unavailable from an unexecuted call;
  the current QG API also lacks independently exposed returned-model metadata.

The exact decision requirements, physical FK inventory, schema limitation,
runtime grants and bounded budget are documented in
`artifacts/cp13_20261119/CP13_LIVE_CLOUD_VERIFICATION_REPORT.md` and
`blocker_resolution/blocker_evidence.json`. Original Dss has all inspected required
tables; no live SQL FK failure or ERD defect is claimed.

## Protected state and final verdict

The specified Fiesta M2 is already at **revision 12, confirmed 12, with 12 answer
rows** in the first package snapshot, rather than blank as initially described.
Its existing confirmation is preserved; BCB is PENDING with zero attempts and no
context row. No record was reset, edited or reused by this verifier. GM Klang,
historical Fiesta and unrelated data were not written.

**PASS:** reproducible package commands, controlled validation tests, source
routing/gates, read-only verification, and isolated actual BCB persistence.

**BLOCKED:** real BDJ and Direct-QG dispatch, complete live source-to-candidate
lineage, original-application BCB activation and overall CP-13 cloud acceptance.
The scripts refuse to fabricate missing authorizations or treat a 2xx response
without independent persistence/receipt evidence as full acceptance.
