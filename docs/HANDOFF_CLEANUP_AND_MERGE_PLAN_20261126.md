# Handoff cleanup — merge plan for the team

**Date:** 2026-11-26
**Branch the cleanup lands on:** `merge_main_jed` (tracks `origin/merge_main_jed`)
**Repo:** `https://github.com/joelcode1612/FYP.git`
**Cleanup commit:** `________________` *(owner: fill in after committing — see Step 0)*

---

## TL;DR

Development is finished and the repo is being handed to the moderator. A set of
development-only files has been **deleted in a commit** and **excluded via `.gitignore`**.

The single thing that matters for everyone else:

> **A deletion is a commit, not a setting on your machine.**
> If your branch is based on a commit older than the cleanup, your branch still *contains*
> those files. Merging it will bring them back unless you resolve the conflict by keeping
> the deletion.

`.gitignore` will **not** save you. Ignore rules only apply to *untracked* files. If the
file is already tracked in your branch, it stays tracked no matter what `.gitignore` says.

---

## 1. What was retired

### 1a. Deleted from the repository (do not restore)

| Path | Files | What it was |
|---|---:|---|
| `tool/` | 34 | Browser/CDP probe scripts (`.js`) + `malaysia_postcodes_source.json` |
| `SiteWise_Expanded64_v2_Recalculation_Package/` | 29 | ML feature recalculation package (archived, see §6) |
| `determine_decision.py` | 1 | Standalone demo of the six response states |
| `report_composition_demo.py` | 1 | Synthetic report demo; superseded by `project1/q01_synthetic_preview.py` |
| `sitewise_clear_name_reset_mfa.py` (root copy) | 1 | Byte-identical duplicate of `backend/sitewise_clear_name_reset_mfa.py` |
| `fyp.iml` | 1 | Orphan IntelliJ module file |
| `fyp` | 1 | Dangling submodule gitlink (mode `160000`, no `.gitmodules`) |
| `helo.txt` | 1 | 2.3 MB `tree /f` directory dump |
| `ure-Object -Line).Lines` | 1 | Shell accident — a stray list of paths |
| `rating_collection.pid` | 1 | Runtime PID file |
| `synthetic_report.json` / `.md` | 2 | Generated output of `report_composition_demo.py` |
| `ee01_registry_results.txt` | 1 | Captured output of `ee01_registry_verification.sql` |

### 1b. Untracked and ignored, but **still on disk** (local scratch)

| Path | Files | What it is |
|---|---:|---|
| `.sitewise_patch_backups/` | 24 | Timestamped source snapshots written before each UI edit |
| `var/evidence/` | 9 | pytest JUnit dumps (`gate6_*.xml`, `p3_*.xml`) |
| `backups/` | 3 | One-off frontend / pre-migration snapshots |
| `analysis_output/` | 10 | Ad-hoc residential-density analysis |

These were removed from the index with `git rm --cached`. They are **not** deleted from
disk; they are only no longer version-controlled.

### 1c. Never tracked, deleted from disk

| Path | Why |
|---|---|
| `out/` | IntelliJ Python compiler output — a stale mirror of `backend/src/sitewise` (last written 2026-11-08) |
| `jaspr_provider_compat/` | Dead shell: only `.dart_tool` residue, never had a `pubspec.yaml` |

### 1d. Moved, not deleted

| From | To |
|---|---|
| `SQL/SQL_VERIFICATION_RUNBOOK_20261124.md` | `docs/SQL_VERIFICATION_RUNBOOK_20261124.md` |
| `PROJECT1_F01_F02_BD01_BD02_INTEGRATION_REPORT_20261117.md` | `docs/PROJECT1_F01_F02_BD01_BD02_INTEGRATION_REPORT_20261117.md` |

Nothing in `backend/src`, `fyp_jaspr_web`, `fyp_mobile_app`, `shared_logic`, `prompt_eval`,
`docs/` or `backend/migrations/` was removed. Production code is untouched.

---

## 2. Step 0 — owner: land the cleanup first

**Do this before anyone merges anything.** If an old PR lands first, the files return and
the cleanup has to delete them a second time — noisy and conflict-prone.

```bash
cd FYP
git status                       # confirm the staged set: 110 deletions + 4 renames
git add .gitignore               # the ignore rules are currently UNSTAGED
git commit -m "chore: remove development-only artefacts before handoff

- delete tool/ probes, SiteWise_Expanded64 package and dead root scripts
- untrack .sitewise_patch_backups/, var/evidence/, backups/ (kept on disk)
- move SQL runbook and F01/F02 report into docs/
- add .gitignore rules for owner-local scratch"
git log -1 --format=%H          # record this hash at the top of this document
git push origin merge_main_jed
```

Then tell the team the cleanup hash. Everything below depends on their branch being
descended from it.

---

## 3. What each teammate must do

### Case A — your branch does **not** touch the retired paths

Nothing to do. Merge normally:

```bash
git fetch origin
git merge origin/merge_main_jed
```

Because you never modified those files, git applies the deletion cleanly. The files
disappear from your working tree, which is the intended outcome.

### Case B — your branch **modifies** a file under a retired path

You will get a **modify/delete conflict**:

```
CONFLICT (modify/delete): tool/stage3_settle_20261124.js deleted in origin/merge_main_jed
and modified in HEAD. Version HEAD left in tree.
```

**Resolve by keeping the deletion:**

```bash
git rm tool/stage3_settle_20261124.js
git commit                        # or: git rebase --continue
```

If the modification contained something worth keeping, salvage the *content* into a
different file — do not resurrect the retired path.

> ⚠️ Do **not** resolve this with `git checkout --theirs <file>`, `git merge -X theirs`,
> or `git restore <file>`. All three bring the file back into the tree.

### Case C — your branch **adds new files** under a retired path

Example: a new probe `tool/my_new_probe.js`. `.gitignore` will not stop it if you
`git add -f`, and it *will* reappear after the merge.

Decide with the owner:
- If it is a one-off probe → keep it outside the repo, or under `backend/tools/` if it is a
  real harness.
- If it genuinely belongs in the repo → the owner re-opens that path deliberately, in a
  separate commit, and updates this document.

### Case D — you are rebasing, not merging

```bash
git fetch origin
git rebase origin/merge_main_jed
```

Same conflict rules as Case B: resolve modify/delete with `git rm`, then
`git rebase --continue`.

---

## 4. The trap that already happened once

On 2026-11-26 at 15:05 a `git restore` / `git checkout .` in this repo **silently
reverted** an earlier cleanup: 33 `tool/*.js` files, `backups/` and
`.sitewise_patch_backups/` all came back, and `git status` went from 45 deletions to 1.

Why: those files were tracked, so restoring the index brings them back.

**Rules for everyone:**

1. Never run `git checkout .`, `git restore .`, or `git checkout -- <path>` on a branch
   that predates the cleanup without knowing what it will restore.
2. Never run `git add -A` / `git add .` blindly. Stage explicitly, or check
   `git status` first.
3. After any merge or restore, run the check in §5.

---

## 5. Verify — the one check that matters

Run this **after every merge**, on the integration branch:

```bash
git ls-files -- \
  tool \
  SiteWise_Expanded64_v2_Recalculation_Package \
  .sitewise_patch_backups \
  var/evidence \
  backups \
  determine_decision.py report_composition_demo.py \
  sitewise_clear_name_reset_mfa.py fyp.iml fyp helo.txt \
  rating_collection.pid synthetic_report.json synthetic_report.md \
  ee01_registry_results.txt
```

**Expected output: nothing at all.**

If it prints paths, the merge resurrected them. Fix before pushing:

```bash
git rm -r --cached tool SiteWise_Expanded64_v2_Recalculation_Package \
                   .sitewise_patch_backups var/evidence backups
git commit -m "chore: drop retired paths reintroduced by merge"
```

`--cached` removes them from the index but leaves them on disk — the correct choice for
the local scratch folders.

---

## 6. Recovery — nothing was destroyed

If a retired file turns out to be needed:

| Want | Do |
|---|---|
| A specific deleted file | `git checkout <cleanup-hash>~1 -- tool/some_probe.js` |
| The whole archive (117 MB) | `cp -a ../FYP_archive_20261126/. .` |
| The Expanded64 package | `cp -a ../FYP_archive_20261126/SiteWise_Expanded64_v2_Recalculation_Package .` |
| One probe script | `cp -a ../FYP_archive_20261126/tool/. tool/` |

The archive lives at `C:/Users/HP/OneDrive/Desktop/sport-marketplace/FYP_archive_20261126`
and has a `RESTORE.md` with a per-group inventory. The 33 probe scripts in it were
verified byte-for-byte (SHA-256) before deletion.

The `SiteWise_Expanded64_v2_Recalculation_Package` is **not reproducible** without the
`Final_Location_Analysis` PostgreSQL database. Treat the archive copy as the only one.

---

## 7. Conflict-resolution cheat sheet

| Situation | Correct action | Wrong action |
|---|---|---|
| modify/delete on a retired path | `git rm <path>` | `git checkout --theirs` |
| delete/delete | nothing to do | — |
| New file added under a retired path | decide with owner; usually `git rm --cached` | `git add -f` |
| "I need that old probe back" | restore from archive, outside the repo | commit it back into `tool/` |
| Merge looks clean but files reappeared | §5 check, then `git rm --cached` | assume it's fine |

---

## 8. Checklist before the moderator sees it

- [ ] Cleanup committed and pushed; hash recorded at the top of this file
- [ ] `.gitignore` change committed (it is currently **unstaged**)
- [ ] Every open PR rebased/merged, with modify/delete conflicts resolved by `git rm`
- [ ] §5 check prints nothing on the integration branch
- [ ] `git status` on the integration branch shows only intentional changes
- [ ] Archive folder exists outside the repo and `RESTORE.md` opens
- [ ] `deliverables/` and `artifacts/` (375 MB total) are gitignored — confirm whether the
      moderator receives a git clone or a zipped folder, because they will not be in the
      clone

---

## 9. Known dangling references (intentional)

These dated audit documents still mention `tool/` scripts that no longer exist. They were
**not** rewritten, because they are point-in-time records:

- `docs/10_SYSTEM_AUDIT_2026-11-05.md` — cites `tool/auth_client.js`
- `docs/11_ROLE_MODEL_MFA_DELIVERABLES.md` — cites `tool/probe_auth_flows.js`,
  `tool/serve_spa.js`

`docs/architecture/activity_history/ACTIVITY_HISTORY_CQ_INTEGRATION_20261125.md` **was**
updated: it now says the acceptance probe is archived outside the repo, so the "28 checks
pass" evidence still reads correctly.

---

## 10. Questions

**Why not just leave the files and ignore them?**
Ignore rules do not apply to tracked files. Leaving them tracked means every clone carries
them forever, and `git checkout` can resurrect them at any time.

**Why delete `tool/` if it was useful?**
The probes were one-off CDP scripts that drove a browser to capture screenshots and
assertions. They were never imported by the app and were superseded by direct agent-driven
browser testing. The evidence they produced is already recorded in `docs/`.

**Will my build break?**
No. Nothing under `backend/src`, `fyp_jaspr_web/lib`, `fyp_mobile_app/lib` or
`shared_logic/lib` was removed, and no import referenced any retired path.
