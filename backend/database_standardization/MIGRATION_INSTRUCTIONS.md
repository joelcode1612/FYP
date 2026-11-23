# Migration Instructions — SiteWise Database Standardization

Windows PowerShell commands. Credentials come from `backend/.env` only; nothing
in this document contains or requires secrets.

## 0. Preconditions

```powershell
cd C:\Users\Lenovo\AndroidStudioProjects\FYP\backend
# Backend environment ready (venv, .env with DATABASE_URL + Supabase keys)
.venv\Scripts\python.exe -c "from sitewise.db.session import engine; print('local DB reachable')"
```

Take a backup before phase 4 (the task mandates backups before destructive
operations; this migration's moves are non-destructive renames, but the
legacy-duplicate drops are permanent):

```powershell
& "C:\Program Files\PostgreSQL\18\bin\pg_dump.exe" `
  -h 127.0.0.1 -p 5432 -U postgres -d Final_Location_Analysis `
  --schema-only -f database_standardization\rollback\local_schema_backup.sql
# or full data for the operational schema:
& "C:\Program Files\PostgreSQL\18\bin\pg_dump.exe" `
  -h 127.0.0.1 -p 5432 -U postgres -d Final_Location_Analysis `
  -n fyp -n public -n sitewise_sync -f database_standardization\rollback\local_operational_backup.sql
```

## 1. Local PostgreSQL (migration 02 — APPLIED 2026-11-22)

```powershell
# Dry run (prints plan only)
.venv\Scripts\python.exe database_standardization\scripts\apply_migration.py `
  --file database_standardization\migrations\01_preflight.sql --autocommit

# Apply (transactional, guarded, idempotent)
.venv\Scripts\python.exe database_standardization\scripts\apply_migration.py `
  --file database_standardization\migrations\02_local_schema_migration.sql

# Relationship reconciliation + validation
.venv\Scripts\python.exe database_standardization\scripts\apply_migration.py `
  --file database_standardization\migrations\04_relationship_reconciliation.sql
.venv\Scripts\python.exe database_standardization\scripts\apply_migration.py `
  --file database_standardization\migrations\05_post_migration_validation.sql --autocommit

# Record in the project's migration history (already stamped 2026-11-22):
.venv\Scripts\python.exe -m alembic stamp 0014_canonical_fyp_schema
```

## 2. Supabase (migration 03 — requires SQL editor or a direct DSN)

The environment holds only REST credentials for Supabase. Apply
`migrations/03_supabase_schema_migration.sql` **either**:

**Option A — Supabase dashboard (recommended):**
1. Open the Supabase project → SQL Editor.
2. Paste the full contents of
   `database_standardization/migrations/03_supabase_schema_migration.sql`.
3. Run. The script is transactional and idempotent; it renames
   `public.property` → `fyp.rental_properties` in place (no data copy),
   renames `property_photo` → `fyp.property_photos`, moves all mirror tables
   into `fyp`, and applies the locked-down grant/RLS model.
4. In **Settings → API → Exposed schemas**, add `fyp` (required only for the
   assignment-mirror worker, which uses `Accept-Profile: fyp`).

**Option B — psql with a direct connection string** (when you have one):

```powershell
$env:SUPABASE_DB_URL = "<your direct postgres DSN>"   # never commit this
.venv\Scripts\python.exe database_standardization\scripts\audit_database_schema.py `
  --target supabase --supabase-dsn "$env:SUPABASE_DB_URL"
psql "$env:SUPABASE_DB_URL" -f database_standardization\migrations\03_supabase_schema_migration.sql
psql "$env:SUPABASE_DB_URL" -f database_standardization\migrations\04_relationship_reconciliation.sql
psql "$env:SUPABASE_DB_URL" -f database_standardization\migrations\05_post_migration_validation.sql
```

## 3. Reconciliation and verification

```powershell
# Data reconciliation (drafts 9234/9235/9236/10120 -> Supabase, parity reports)
.venv\Scripts\python.exe database_standardization\scripts\reconcile_application_data.py --mode dry-run
.venv\Scripts\python.exe database_standardization\scripts\reconcile_application_data.py --mode apply `
  --output database_standardization\audit\reconciliation_apply_report.json

# Consistency verification (schema + data parity + intentional differences)
.venv\Scripts\python.exe database_standardization\scripts\verify_database_consistency.py `
  --output database_standardization\audit\consistency_report.json
```

## 4. Backend restart

The FastAPI backend must be restarted after migration 02 (SQLModel metadata
now declares `fyp`-schema business tables; the startup guard verifies their
presence and refuses to start against a non-migrated database):

```powershell
cd C:\Users\Lenovo\AndroidStudioProjects\FYP
.\run-sitewise.cmd
```

## 5. Rollback

* Schema-level rollback: restore the dump taken in step 0
  (`psql ... -f database_standardization\rollback\local_operational_backup.sql`
  after dropping the migrated schema), or replay inverse `ALTER TABLE ... SET
  SCHEMA public` statements — the archive of the retired demo user row is in
  `rollback/fyp_users_demo_archive.sql`.
* Alembic: `0014_canonical_fyp_schema.downgrade()` is a deliberate no-op
  (documented in the revision); restore from dump instead.
* Supabase: apply migration 03 only after reviewing its rollback notes
  (renames are reversible; the empty-table drops are not — both are guarded
  by row-count assertions).

## 6. Known environmental notes

* Alembic head history had a pre-existing unmerged `0010` branch; the project
  applies revisions out-of-band (0004-0014) and stamps — follow the same
  pattern. Current stamp: `0014_canonical_fyp_schema`.
* Supabase settings → API → Exposed schemas must include `fyp` before the
  assignment mirror worker can write (`Accept-Profile: fyp`).
* `ASSIGNMENT_SYNC_ENABLED=true` opt-in still controls the worker, unchanged
  from the pre-existing design.
