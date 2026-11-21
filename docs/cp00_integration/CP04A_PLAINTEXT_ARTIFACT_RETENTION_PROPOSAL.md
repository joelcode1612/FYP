# CP-04A — Plaintext Artifact Retention and Remediation Proposal

**Status:** PROPOSED. Owner decision required. Nothing here has been executed.
**Author:** a3-artifacts (read-only audit role) · **Date:** 2026-11-17, rev. 2
**Basis:** direct inspection of `backend/backups/`, git state, and a verified `pg_restore` listing.
**Constraint:** no artifact may be deleted, moved or modified without written Owner approval.

## 0. Already applied

Ignore rules applied by team-lead; I re-verified them.

| Rule | Line | Verified effect |
|---|---|---|
| `backend/backups/` | `.gitignore:91` | `git check-ignore -v` matches; `git add -A --dry-run` refuses |
| `.env*.bak`, `**/.env*.bak` | `.gitignore:96-97` | covers the `.env.local.*.bak` copy |
| `backend/var/cp03f_*/` | `.gitignore:101` | covers `journey_backend.json` (holds declared M2 answers) |

All 12 previously-stageable files are no longer stageable. **This closes the future-commit path only** — nothing already on disk or in history.

## 1. The credential copy — rotation is the only remedy

`backend/backups/cp00r_20261116/.env.local.2ec7f332a64d.bak` (345 bytes) holds `M2_DATABASE_URL` (58 chars) and `EE01_DATABASE_URL` (113 chars) — live connection strings.

Ignoring it prevents a future commit and does nothing about: the secret on disk; OneDrive sync/version history; any earlier copy (a `.bak` is a copy by definition); shell history or scrollback.

**Rotating both credentials is the only action that closes this.** Order, Owner-executed: (1) rotate `M2` and `EE01` role passwords and update every consumer; (2) confirm the app runs on them; (3) only then, with written approval, delete the file and purge it from OneDrive version history. Do not reverse 1 and 3 — deleting first destroys the only local record of what was exposed while changing nothing about the exposure.

## 2. The three already-tracked files

Committed before the rule existed; ignoring does not untrack them. They remain tracked (`git ls-files`) and in history (`d37464f`).

| File | Bytes | Verified contents | Sensitivity |
|---|---|---|---|
| `20261110_owner_listing_verification_backup.json` | 1,638 | Row counts (all 0 except `fyp.rental_properties` = 1182), FK definitions, one CHECK. No rows, no identifiers. | Low |
| `20261110_drop_legacy_property_backup.json` | 3,055 | 1,162-char `CREATE TABLE` DDL, child FK list, row counts (all 0). | Low |
| `migration_20261110/sitewise_property_tables_before.dump` | 5,367,712 | 17 tables, **17 `TABLE DATA` sections, ~7,779 rows** — see §4 | **Addressable owner-linked data** |

| Option | Effect | Cost |
|---|---|---|
| Leave as-is | Blob stays in history | None; exposure unchanged |
| `git rm --cached` | Removes from HEAD; history unchanged | **Does not reduce exposure**; implies a fix that did not happen |
| History rewrite | Removes blob from all commits | Destructive: invalidates every clone and every commit hash cited in the CP-00R/CP-01H/CP-03D/CP-03E/CP-03F reports. Needs explicit Owner authorisation. |

## 3. The five raw model outputs

18,892 bytes total (correcting my earlier verbal figure of 19,892): `cp03d_96cefb30/bdj_output.json` 1,186 · `cp03d_uncertainty_fd0b4380/probe.json` 6,075 · `cp03e_9aefb13d/result.json` 1,305 · `cp03e_79ee04e1/result.json` 4,021 · `cp03e_bb54ef7b/result.json` 6,305.

All derive from assessment `da90aa4a-f9cf-4145-9acf-7de36c9d6fad` (revision 12), actor `11111111-1111-4111-8111-111111111111`, labelled "synthetic test identity" at `scripts/cp03d_bdj_execution.py:25`. They hold parsed completions (`model_output_raw`) and `diagnostics.quotes` — short verbatim substrings of instrument answers.

Synthetic, so the privacy case for deletion is weak, and they are **the only surviving record of those provider responses** (the ledger keeps only digests). Encryption in place is not warranted while key custody (B3) is unsolved: it protects nothing a gitignored plaintext copy does not, and adds a key that must itself be protected.

**Recommendation: retain, ignored, in place**, 90-day horizon from `created_at` (review 2027-02-15), revisit when the `bdj_raw_responses` write path (A3) makes them redundant.

## 4. The tracked `.dump` — contents now confirmed

The previous revision said "unverified": `pg_restore` 16.14 refused the archive (v1.16). **That gap is closed** — PostgreSQL 18.6 reads it. Reproduce with:

`"/c/Program Files/PostgreSQL/18/bin/pg_restore.exe" --list backend/backups/migration_20261110/sitewise_property_tables_before.dump`

Archive: 142 TOC entries, gzip, 17 `TABLE DATA` sections across 17 distinct tables. Row counts via `--data-only --table=<t> -f -` piped to a counter (no values printed):

| Table | Rows | Table | Rows |
|---|---|---|---|
| `properties` | 2,126 | `property_geospatial_features` | 481 |
| `subject_features` | 1,849 | `property_features` | 227 |
| `rental_properties` | 1,182 | `property` | 4 |
| `property_listing_sources` | 955 | `favourite_properties` | 0 |
| `property_subject_links` | 955 | `recommendation_result(s)` | 0 |
| | | `property_feature`, `property_geospatial_feature`, `property_photo`, `property_photos`, `property_listing_verification`, `virtual_tours` | 0 |

**A premise in my briefing was wrong; I checked it rather than repeating it.** I was told three tables — `favourite_properties`, `recommendation_results`, `subject_features` — hold user-behaviour and derived-decision data. By row count the two behavioural tables are **empty**; that exposure is potential, not actual. `subject_features` does have 1,849 rows, but its columns are property-level analytics (`subject_id`, `canonical_property_id`, distances, `district_income_median_myr` — an area median, not an individual's income), so it is not person-level.

What *is* personal-adjacent is `rental_properties` (1,182): `owner_id` and `owner_user_id` beside `address`, `city`, `state`, `rental_price` and free-text `description` — an owner account UUID bound to a street address. `properties` (2,126) carries `address` with `source_workbook`/`source_url`, i.e. a scraped dataset. So: real, addressable, owner-linked data, in history since `d37464f`.

**Recommendation — unchanged in outcome, changed in reasoning, stated explicitly.** My earlier "leave as-is" rested on the dump looking like metadata. It is not metadata. The decisive argument survives, though: a history rewrite would invalidate every commit hash cited across six checkpoint reports to remove ~7.8k rows of pre-migration property inventory that contains no credentials, when the exposure window is already closed. I keep "leave as-is" for git and add one condition: confirm whether those `owner_user_id` values correspond to live accounts. If they do, this is a data-retention decision under §1, not a git decision.

## 5. What must not happen

No deletion of evidence without written Owner approval. No history rewrite without explicit authorisation naming the affected commits. No credential rotation performed by an agent. No `git rm --cached` presented as remediation.

## 6. Corrections to my earlier verbal audit

1. I reported `docs/cp00_integration/` as empty. It has 15 entries. My `ls` ran with `backend/` as cwd, so it inspected `backend/docs/cp00_integration/`. The path I named and the path I looked at differed.
2. I reported the columns in `20261117_03_bdj_result_persistence.sql` as pre-existing design. It was untracked and under active edit (mtime 14:50:59, after the 14:45:56 spec). `git diff` would not have shown this — it only reports tracked files; `git status --porcelain` was correct.
