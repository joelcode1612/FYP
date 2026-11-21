# PROJECT1 — Migration Plan: `Dss` → `Final_Location_Analysis`

**Status:** `PLAN_ONLY_NOT_EXECUTED`. No DDL, DML or migration has been run. Every fact below comes from read-only catalogue queries taken on 2026-11-17.

**Evidence base**
| Artefact | What it holds |
|---|---|
| `artifacts/migration_inventory/dss_inventory.json` | Full source inventory: relations, columns, constraints, indexes, triggers, policies, functions, ACLs, roles |
| `artifacts/migration_inventory/target_inventory.json` | Target inventory: schemas, relations, columns, constraints, indexes, functions, roles, extensions, RLS |
| `artifacts/migration_inventory/project1_objects.json` | **The authoritative object list to migrate** (generated from the source inventory) |

**Measured environment**

| | Source `Dss` | Target `Final_Location_Analysis` |
|---|---|---|
| Server | PostgreSQL **16.14**, `localhost:5432` | PostgreSQL **16.14**, `localhost:5432` (same cluster) |
| Encoding / collation | UTF8 / `Chinese (Simplified)_Hong Kong SAR.1252` | UTF8 (same cluster) |
| `public` tables | 68 (49 PROJECT1 + 19 legacy + 1 sequence) | 155 (rental application) |
| `project1_ai` schema | 10 tables | **absent** |
| RLS tables | 57 (20 with `FORCE ROW LEVEL SECURITY`) | 0 |
| Policies | 82 | 0 |
| Extensions | `plpgsql` only | `plpgsql`, `hstore 1.8` |

Because both databases are on the same cluster, the server version, encoding, collation and cluster-wide roles are **already identical**. That removes the usual cross-version restore risk entirely.

---

## 1. Scope — exactly what moves

From `project1_objects.json`:

| Object class | Count | Notes |
|---|---|---|
| `public` tables | **49** | `m2_*` (19), `cq_*` (25), `ee01_*` (4), `assessment_workflow_projection` (1) |
| `project1_ai` tables | **10** | `attempts`, `attempt_receipts`, `bdj_raw_responses`, `bdj_result_findings`, `bdj_result_sources`, `bdj_result_validations`, `bdj_results`, `finding_provenance`, `runs`, `schema_versions` |
| Views | **2** | `public.m2_workflow_summary`, `public.m2_workflow_campaigns` |
| Functions | **15** | `deny_mutation`, `cq_immutable_record`, `cq_source_bank_immutable_record`, `cq_session_update_guard`, `cq_synthetic_can_execute`, `cq_synthetic_can_read`, `cq_synthetic_profile_guard`, `cq_is_synthetic_campaign`, `ee01_source_binding_guard`, `m2_bcb_freeze_definition`, `m2_bcb_initialize_status`, `m2_bcb_reject_mutation`, `m2_workflow_change`, `m2_workflow_cq_change`, `refresh_m2_workflow` |
| Sequences | **0** | the only sequence, `property_property_id_seq`, is legacy |
| Indexes | 157 | 129 back constraints, 28 standalone, all btree |
| Constraints | 395 | 78 PK, 118 FK, 50 unique, 132 check, 17 trigger |
| Triggers | 72 | 26 append-only + 15 `m2_bcb_reject_mutation` |
| Policies | 82 | on 57 tables |

### Explicitly NOT copied — 20 legacy real-estate objects

`address`, `ai_explanation`, `assessment` (singular — the legacy table, **not** `m2_assessments`), `district_demographic`, `entrepreneur_preferences`, `favorite_property`, `nearby_competitor`, `property`, `property_feature`, `property_foot_traffic`, `property_geospatial_feature`, `property_photo`, `property_property_id_seq`, `property_verification`, `recommendation_result`, `user_tokens`, `users`, `verification_audit`, `verification_document`, `virtual_tour`.

These belong to the legacy SiteWise application. The target already has its own equivalents. **Copying them would overwrite or collide with the rental application's data.**

### The one cross-application hinge: `public.users`

- **8 PROJECT1 foreign keys point at `public.users`**: `m2_assessments`, `m2_confirmation_snapshots`, `m2_confirmed_uncertainties`, `m2_review_events`, `cq_campaigns`, `cq_participants`, `cq_synthetic_import_runs`, `ee01_measurement_snapshots`.
- The two `users` tables are **structurally identical** — 11 columns, same names, same types, same order, both `user_id uuid` — so the FKs will bind without a type conflict.
- They are **different populations**. A PROJECT1 row whose `owner_user_id` refers to a `Dss` user will violate the FK against the target's `users` unless that UUID also exists there.

This single fact decides whether you can carry data across, and it is the subject of §8.

---

## 2. Decision required before execution

| Option | What it means | Consequence |
|---|---|---|
| **A. Structure only** (recommended for a first pass) | Create the 59 tables, 2 views, 15 functions, policies and grants. No rows. | Cannot fail on the `users` hinge. Produces a working empty PROJECT1 in the target. Data is re-seeded or re-generated. |
| **B. Structure + data, identities preserved** | Also copy the `users` rows referenced by PROJECT1, then PROJECT1 data. | Risk of `email` unique collisions and of merging two identity populations. Needs an explicit, reviewed user-merge step. |
| **C. Structure + data, FKs deferred** | Load PROJECT1 data with FKs absent, then add FKs `NOT VALID` and reconcile orphans. | Honest about orphans but leaves the database in a partially-enforced state until reconciled. |

**Recommendation: A.** Your PROJECT1 data is synthetic test data (`Dss` holds a synthetic confirmed assessment and test ledger rows). Paying the identity-merge cost to carry it is not worth it. Run A, then re-run the synthetic fixtures against the target.

---

## 3. Pre-flight gates — all must pass before any DDL

Run as `postgres` against `Final_Location_Analysis`, inside one transaction that you `ROLLBACK` if any gate fails.

```sql
BEGIN;
SET LOCAL statement_timeout = '30s';

-- G1. Right database, right server version.
SELECT current_database(), current_setting('server_version');          -- expect Final_Location_Analysis, 16.14

-- G2. No name collisions. All four must return 0.
SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
 WHERE n.nspname IN ('public','project1_ai')
   AND (c.relname LIKE 'm2\_%' OR c.relname LIKE 'cq\_%' OR c.relname LIKE 'ee01\_%');
SELECT count(*) FROM pg_namespace WHERE nspname='project1_ai';
SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
 WHERE n.nspname IN ('public','project1_ai')
   AND p.proname IN ('deny_mutation','cq_immutable_record','m2_workflow_change');

-- G3. public.users exists and has the expected 11 columns.
SELECT count(*) FROM information_schema.columns
 WHERE table_schema='public' AND table_name='users';                  -- expect 11

-- G4. No hstore/uuid-ossp/postgis dependency. Source needs none; confirm target has what it needs.
SELECT extname, extversion, n.nspname FROM pg_extension e
  JOIN pg_namespace n ON n.oid=e.extnamespace;

-- G5. Roles. Record which already exist — see §4, this decides your migration route.
SELECT rolname, rolcanlogin, rolsuper, rolbypassrls, rolinherit
  FROM pg_roles WHERE rolname LIKE 'p1%' ORDER BY rolname;

-- G6. You can create in public (must be owner or superuser; PUBLIC has no CREATE).
SELECT has_schema_privilege(current_user,'public','CREATE');
ROLLBACK;
```

**Verified today on this cluster:** G2 passes (zero `m2_*`/`cq_*`/`ee01_*` objects, no `project1_ai` schema), G3 passes (11 columns, identical to source), G4 passes (source needs no extension beyond `plpgsql`), G6 passes for `postgres`.

---

## 4. Roles — the step that differs between your PC and your friend's laptop

Roles are **cluster-wide**, not per-database. On your PC they already exist (created when `Dss` was provisioned). On your friend's laptop, if only `Final_Location_Analysis` was restored, they will **not** exist.

**The migration files are inconsistent about this**, which is why this step must be handled outside them:

| File:line | Behaviour when the role exists |
|---|---|
| `project1_ai/20261117_01_execution_principal.sql:22-28` | Idempotent: `IF EXISTS ... RAISE NOTICE` else `CREATE`; then `ALTER ROLE` to reconcile |
| `project1_ai/20261111_01_candidate_ledger.sql:20-22` | **`RAISE EXCEPTION 'Workflow role already exists: reconcile grants before migrating'`** |
| `project1_ai/20261116_02_m2_runtime_role.sql:40` | Bare `CREATE ROLE` → fails with `duplicate_object` |
| `cq/20261116_02_ee01_snapshots.sql:15` | Bare `CREATE ROLE p1_ee01_runtime NOLOGIN ...` → same |

### Provision roles first, idempotently, before running any migration

```sql
-- Run once per cluster, as a superuser. Safe to re-run.
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
      ('p1ai_owner',        false, false, false, false),
      ('p1ai_runtime',      false, false, false, false),
      ('p1ai_audit',        false, false, false, false),
      ('p1ai_engine',       true,  false, false, false),
      ('p1ai_auditor',      true,  false, false, false),
      ('p1_m2_runtime',     true,  false, false, true),   -- NOINHERIT
      ('p1_ee01_runtime',   true,  false, false, false),
      ('p1uc_stage_human',  true,  false, false, false),
      ('p1uc_stage_llm',    true,  false, false, false),
      ('p1uc_stage_qj',     true,  false, false, false)
    ) AS t(n, login, su, bypass, noinherit)
  LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r.n) THEN
      EXECUTE format('ALTER ROLE %I %s NOSUPERUSER NOBYPASSRLS', r.n,
                     CASE WHEN r.login THEN 'LOGIN' ELSE 'NOLOGIN' END);
    ELSE
      EXECUTE format('CREATE ROLE %I %s NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS',
                     r.n, CASE WHEN r.login THEN 'LOGIN' ELSE 'NOLOGIN' END);
    END IF;
  END LOOP;
END $$;

-- Memberships recorded in the source (both are required by the audit path).
GRANT p1ai_audit   TO p1ai_auditor;
GRANT p1ai_runtime TO p1ai_engine;
```

**Passwords are not in any migration or in this plan.** `p1_m2_runtime`, `p1ai_engine` and `p1ai_auditor` are LOGIN roles; set their passwords on the friend's laptop with `ALTER ROLE ... PASSWORD '...'` locally and never commit them. On your PC they already have passwords.

**Consequence for execution:** if you run `20261111_01_candidate_ledger.sql` on your PC with the roles already present, it **raises by design** — that exception is a safety interlock telling you grants need reconciling. The supported route on a cluster that already has the roles is to apply the schema from a dump (§6), not to replay the provisioning migrations.

---

## 5. RLS, grants and ownership to recreate

| Item | Source value | Action in target |
|---|---|---|
| RLS enabled | 57 tables | `ALTER TABLE ... ENABLE ROW LEVEL SECURITY` |
| `FORCE ROW LEVEL SECURITY` | **20 tables** — all 9 mutable `project1_ai` tables, `cq_synthetic_*` (7), `ee01_*` (4) | `ALTER TABLE ... FORCE ROW LEVEL SECURITY`. This makes even the table owner subject to policy. Required for `p1ai_owner`-owned tables. |
| Policies | 82 | Replay from `dss_inventory.json` → `policies[]` (`qual`, `with_check`, roles, cmd) |
| Grants | 60 relation grant rows; everything else is `NULL relacl` = owner-only | Replay from `dss_inventory.json` → `relation_grants[]` |
| Schema ownership | `project1_ai` → `p1ai_owner` | `CREATE SCHEMA project1_ai AUTHORIZATION p1ai_owner; REVOKE ALL ON SCHEMA project1_ai FROM PUBLIC;` |
| Table ownership | `public` tables → `postgres`; `project1_ai` → `p1ai_owner` | `ALTER TABLE ... OWNER TO ...` after creation |
| `p1_m2_runtime` | `LOGIN NOINHERIT NOSUPERUSER NOBYPASSRLS` | It does **not** bypass RLS. Any verification must run as this role, not as `postgres`. |

> `p1_m2_runtime` being `NOINHERIT` matters: it does not pick up privileges from role membership, so its grants must be explicit.

---

## 6. Ordering — eleven phases

Triggers are the ordering constraint people get wrong: **26 tables are append-only by trigger** and 15 more use `m2_bcb_reject_mutation`. Creating triggers before loading data makes the load fail by design. So triggers go last, after data.

| Phase | Action | Why this position |
|---|---|---|
| 0 | Pre-flight gates (§3); `pg_dump -Fc Final_Location_Analysis` to a file outside the repo | You need a restore point before touching a shared database |
| 1 | Provision roles idempotently (§4) | Cluster-level; must precede any object that names them |
| 2 | `CREATE SCHEMA project1_ai AUTHORIZATION p1ai_owner; REVOKE ALL ... FROM PUBLIC;` | Schema before its objects |
| 3 | `SET check_function_bodies = false;` for this session | Some function bodies reference tables/views that do not exist yet |
| 4 | Create 49 `public` tables, then 10 `project1_ai` tables — with PK, unique, check constraints inline; **FKs deferred** | `project1_ai` has 5 FKs into `public.m2_assessments` / `public.m2_bdj_findings`, so `public` must come first |
| 5 | Add the 118 FK constraints | All tables must exist before FKs; 8 of them target the pre-existing `public.users` |
| 6 | Create the 28 standalone indexes (the other 129 arrive with constraints) | After tables |
| 7 | Create the 2 views | Depend on tables |
| 8 | Create the 15 functions | Depend on tables/views; `check_function_bodies=false` covers forward references |
| 9 | `ENABLE` RLS on 57 tables, `FORCE` on 20, create 82 policies | Policies reference columns, so after tables |
| 10 | Apply grants (60 rows) and ownership | After objects exist |
| 11 | **Data** (optional, §8), then create the 72 triggers | Triggers last, or the append-only guards reject the load |
| 12 | Verification (§10) | — |

### Generating the dump command from the object list

Do not hand-write 49 `-t` flags. Generate them:

```bash
python - <<'PY' > /tmp/p1_dump_args.txt
import json
d=json.load(open('artifacts/migration_inventory/project1_objects.json'))
for t in d['tables']:
    print(f"-t {t['schema']}.{t['name']}")
for v in d['views']:
    print(f"-t {v['schema']}.{v['name']}")
PY
```

Then, with `pg_dump` **16.14** (matches the server; 18.6 also works but matching majors avoids doubt):

```bash
PG_DUMP="/c/Program Files/PostgreSQL/16/bin/pg_dump.exe"
"$PG_DUMP" -h localhost -p 5432 -U postgres -d Dss \
  --schema-only --no-owner --no-privileges \
  $(tr '\n' ' ' < /tmp/p1_dump_args.txt) \
  > /tmp/p1_schema.sql
```

Review `/tmp/p1_schema.sql` before applying. It will contain `CREATE TRIGGER` statements — **delete or comment them** and keep them in a separate file to run in phase 11. It will also contain `CREATE SCHEMA project1_ai` (keep) and `CREATE ROLE` only if a role-owned default references one (check).

---

## 7. Exact guard edits required

The database **name** is used as a security identity. Nine sites must change. Nothing else in the codebase hardcodes it.

### 7.1 Python — four literals, one label

**`backend/src/sitewise/core/config.py`** — no new setting needed; `m2_expected_database` already exists at `:54` and is already consumed by `m2_session._verified_engine` and `customer_questionnaire.py:53`. Reuse it as the single knob.

**`backend/src/sitewise/api/v1/project1_workflow.py`**

```python
# line 31 — before
valid = (settings.project1_workflow_enabled and url.database == 'Dss' and
# after
valid = (settings.project1_workflow_enabled and
         url.database == settings.m2_expected_database and

# line 41 — before
if identity[0] != 'Dss' or identity[1] or identity[2]:
# after
if identity[0] != settings.m2_expected_database or identity[1] or identity[2]:

# line 104 — before
if role[0] != 'Dss' or role[1] or role[2]:
# after
if role[0] != settings.m2_expected_database or role[1] or role[2]:
```

**`backend/src/sitewise/api/v1/synthetic_inspection.py:18`**

```python
# before
if not u or u.host not in ('localhost','127.0.0.1','::1') or u.database!='Dss' or u.username!='p1_ee01_runtime' ...
# after
if not u or u.host not in ('localhost','127.0.0.1','::1') or u.database!=settings.m2_expected_database or u.username!='p1_ee01_runtime' ...
```

**`backend/src/sitewise/services/synthetic_inspection_service.py:70`** — cosmetic but misleading:

```python
# before
'database':'Dss',
# after
'database': settings.m2_expected_database,
```

Then set the environment on the target machine:

```
M2_EXPECTED_DATABASE=Final_Location_Analysis
```

One variable flips all five code sites. The name `m2_expected_database` is historical; it now governs every PROJECT1 database-identity check.

### 7.2 SQL — four migration guards

The other **16 of 20** migration files are already name-agnostic: they compare `project1.*_migration_target` to `current_database()` and will run unchanged against `Final_Location_Analysis` provided the operator sets that GUC.

The four that hardcode a name:

| File:line | Current text |
|---|---|
| `project1_ai/20261111_01_candidate_ledger.sql:9` | `IF current_database() NOT IN ('Dss', 'project1_workflow_tests')` |
| `project1_ai/20261116_02_m2_runtime_role.sql:25` | `IF current_database() <> 'Dss'` |
| `project1_ai/20261117_02_finding_provenance.sql:17` | `IF current_database() NOT IN ('Dss', 'project1_workflow_tests')` |
| `project1_ai/20261117_03_bdj_result_persistence.sql:53` | `IF current_database() NOT IN ('Dss', 'project1_workflow_tests')` |

**Recommended edit** — keep the allowlist, but make it operator-supplied with today's values as the default. This preserves fail-closed behaviour (an unexpected database still raises) without coupling the repository to one deployment's name:

```sql
-- before (the three identical variants)
IF current_database() NOT IN ('Dss', 'project1_workflow_tests')
   OR current_setting('project1.migration_target', true) IS DISTINCT FROM current_database()
   OR coalesce(current_setting('project1.migration_receipt', true), '') = '' THEN

-- after
IF current_database() NOT IN (
     SELECT btrim(x) FROM unnest(string_to_array(
       coalesce(nullif(current_setting('project1.migration_allowed_databases', true), ''),
                'Dss,project1_workflow_tests'), ',')) AS x)
   OR current_setting('project1.migration_target', true) IS DISTINCT FROM current_database()
   OR coalesce(current_setting('project1.migration_receipt', true), '') = '' THEN
```

```sql
-- before (20261116_02:25)
IF current_database() <> 'Dss'
   OR current_setting('project1.migration_target', true) IS DISTINCT FROM current_database()
   OR coalesce(current_setting('project1.migration_receipt', true), '') = '' THEN

-- after
IF current_database() <> coalesce(nullif(current_setting('project1.migration_expected_database', true), ''), 'Dss')
   OR current_setting('project1.migration_target', true) IS DISTINCT FROM current_database()
   OR coalesce(current_setting('project1.migration_receipt', true), '') = '' THEN
```

Operator invocation on the target becomes:

```sql
SET project1.migration_allowed_databases = 'Final_Location_Analysis';
SET project1.migration_expected_database = 'Final_Location_Analysis';
SET project1.migration_target = 'Final_Location_Analysis';
SET project1.migration_receipt = '<reviewed change record>';
```

> **Rejected alternative:** adding `'Final_Location_Analysis'` to the literal allowlist. It works, but it permanently welds a deployment-specific name into reviewed migration files and weakens the identity property those guards exist to provide.

---

## 8. Data migration and the `users` problem

Only relevant if you choose option B or C in §2.

The FK hinge is `public.users`. Eight PROJECT1 tables reference it. Before any data load:

```sql
-- On the source: which user ids does PROJECT1 actually reference?
SELECT count(DISTINCT owner_user_id) FROM public.m2_assessments;
-- On the target: how many of those already exist?
SELECT count(*) FROM public.users WHERE user_id = ANY($1);
```

Then choose:

- **B1 — copy the referenced users.** `INSERT ... ON CONFLICT DO NOTHING` into target `users`. Watch `email` (NOT NULL, likely unique) and `role`/`account_status` check constraints. Any conflict means two identity populations are being merged and needs a human decision, not a merge rule.
- **B2 — remap.** Create fresh target users and rewrite the 8 FK columns. This is the only option that avoids mixing populations, and it invalidates any `Dss` user id recorded in audit evidence.
- **C — defer.** Add the 118 FKs as `NOT VALID`, load data, then `VALIDATE CONSTRAINT` and reconcile the violations it reports. Honest, but the database is unenforced until reconciliation completes.

**Do not use `pg_dump --disable-triggers` blindly.** It disables *all* triggers for the load, including foreign-key enforcement, so it can silently admit referential violations that the append-only guards would otherwise have blocked. If you use it, `VALIDATE CONSTRAINT` every FK afterwards.

---

## 9. Rollback

| Point | How |
|---|---|
| Before phase 4 | Nothing to undo; `ROLLBACK` the pre-flight transaction |
| After DDL, before data | `DROP SCHEMA project1_ai CASCADE;` + drop the 49 `public` tables by name from `project1_objects.json` |
| After data | Restore phase 0's dump: `pg_restore -d Final_Location_Analysis --clean --if-exists` |
| Roles | Roles are cluster-wide — **dropping them affects `Dss` too**. Do not drop roles as part of rollback; they are shared. |

---

## 10. Verification — prove it, don't assume it

```sql
-- V1. Object counts match the manifest.
SELECT n.nspname, count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
 WHERE n.nspname IN ('public','project1_ai') AND c.relkind='r'
   AND (c.relname LIKE 'm2\_%' OR c.relname LIKE 'cq\_%' OR c.relname LIKE 'ee01\_%'
        OR n.nspname='project1_ai')
 GROUP BY 1;                                                    -- expect project1_ai 10, public 49

-- V2. Constraints.
SELECT contype, count(*) FROM pg_constraint c JOIN pg_namespace n ON n.oid=c.connamespace
 WHERE n.nspname IN ('public','project1_ai') GROUP BY 1;         -- expect p 78, f 118, u 50, c 132

-- V3. RLS and FORCE.
SELECT count(*) FILTER (WHERE relrowsecurity) AS rls_on,
       count(*) FILTER (WHERE relforcerowsecurity) AS forced
  FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
 WHERE n.nspname IN ('public','project1_ai');                    -- expect 57 / 20

-- V4. Policies.
SELECT count(*) FROM pg_policies WHERE schemaname IN ('public','project1_ai');  -- expect 82

-- V5. Triggers.
SELECT count(*) FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid
  JOIN pg_namespace n ON n.oid=c.relnamespace
 WHERE NOT t.tgisinternal AND n.nspname IN ('public','project1_ai');            -- expect 72

-- V6. Behavioural, not just structural: RLS must actually deny.
--     Run as p1_m2_runtime (NOSUPERUSER, NOBYPASSRLS, NOINHERIT), never as postgres.
SET LOCAL ROLE p1_m2_runtime;
SELECT set_config('project1.actor_id', '<owner uuid>', true);
SELECT count(*) FROM public.m2_assessments;                      -- owner sees own rows
SELECT set_config('project1.actor_id', '<other uuid>', true);
SELECT count(*) FROM public.m2_assessments;                      -- expect 0
```

V6 is the check that matters. A migration that recreates 57 RLS flags but where the policy expression silently allows everything would pass V1–V5 and fail V6. This is the same evidence standard used for the earlier `Dss` deployment (12/12 verification, RLS proven as `p1_m2_runtime`, not as `postgres`).

---

## 11. Risks

| Risk | Severity | Mitigation |
|---|---|---|
| Copying the 20 legacy objects overwrites the rental app's tables | **Critical** | The object list in `project1_objects.json` is an allowlist. Never dump `public` wholesale. |
| `public.users` identity mismatch | **Critical** | §8. Structure-only (option A) sidesteps it entirely. |
| Append-only triggers block the data load | High | Triggers in phase 11, after data (§6). |
| `CREATE ROLE` fails or raises depending on cluster | High | §4 idempotent provisioning; do not replay the provisioning migrations on a cluster that already has the roles. |
| RLS recreated but not enforced | High | V6 behavioural check as `p1_m2_runtime`. |
| `FORCE ROW LEVEL SECURITY` omitted on the 20 tables | High | Then `p1ai_owner` bypasses its own policies. V3 catches it. |
| Guard edits half-applied | Medium | All nine sites are listed in §7; `grep -rn "'Dss'" backend/src` must return zero hits afterwards. |
| Two databases on one cluster share roles | Medium | Dropping or altering a role affects `Dss`. Treat roles as shared infrastructure. |
| Target `public` is owned by `pg_database_owner` | Low | Run DDL as `postgres`. |

---

## 12. What this plan does not do

- It does not migrate anything. Status is `PLAN_ONLY_NOT_EXECUTED`.
- It does not authorise the guard edits. Those change a security control and need your explicit approval before I apply them.
- It does not make PROJECT1 production-ready. `ResearchWorkflow` is still never instantiated in `src/`, there is no bank port (`BD-01` unsigned), and `F-01` (the uncertainty-version gap) is still open. Migrating the schema does not change any of those.
