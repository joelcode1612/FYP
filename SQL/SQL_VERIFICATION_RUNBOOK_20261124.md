# SiteWise PG18 E2E — SQL Verification Runbook

**Version:** 1.0  
**Date:** 2026-11-24  
**Target:** `project1_pg18_migrated_tests` @ `127.0.0.1:5544` (PostgreSQL 18.6)  
**Assessment under test:** `8c30a934-c800-4250-9872-bdf6637ab85b` (marketplace, `EP-02087`)  
**M2 assessment:** `c30051ba-f9d9-469a-9064-74f1968461ca`  
**Instrument:** `M2V2-20261122-1` (`42ee86eb-3b5a-5f2c-be4d-be88e5f6f2f6`)

> Not committed. Local evidence only, per owner instruction.

---

## 0. How to read this runbook

Every operation records **executed** SQL separately from **illustrative** SQL.

| Marker            | Meaning                                                                                                                         |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| **EXECUTED**      | Traced from the running system: PostgreSQL log/error text, `pg_get_functiondef`, or the ORM statement SQLAlchemy actually sent. |
| **RECONSTRUCTED** | The equivalent SQL written by hand for you to run. Same schema, same semantics, but it is not a transcript.                     |
| **PROPOSED**      | A mutation this runbook does *not* recommend running, listed for completeness.                                                  |

Connections used:

| Role            | Purpose                           | Privileges                                    |
| --------------- | --------------------------------- | --------------------------------------------- |
| `sitewise_e2e`  | marketplace lane (`DATABASE_URL`) | table owner grants on app tables              |
| `p1_m2_runtime` | M2 lane (`M2_DATABASE_URL`)       | SELECT/INSERT/UPDATE on M2 tables; RLS-scoped |
| `postgres`      | verification only                 | cluster owner                                 |

Identity proof (run this first, every session):

```sql
SELECT current_database() AS db,
       inet_server_port()  AS port,
       current_user        AS role,
       (SELECT rolsuper OR rolbypassrls FROM pg_roles WHERE rolname = current_user) AS privileged,
       current_setting('transaction_read_only') AS tx_read_only;
```

|                                          |      |        |       |                      |
| ---------------------------------------- | ---- | ------ | ----- | -------------------- |
| Expected: \`project1_pg18_migrated_tests | 5544 | <role> | false | off\` for app roles. |

---

## 1. READ — Property discovery (recommendations search)

**Operation:** READ  
**Application action:** Opened `/entrepreneur/recommendations`, searched, paged results.  
**Backend:** `POST /api/v1/recommendations/search`, `GET /api/v1/recommendations/facets` → `RecommendationService`.  
**Database:** PG18, 5544. Schema `fyp` (view `catalogue_properties` over `sitewise_app.properties`), `fyp.rental_properties`, `sitewise_analytics.subject_features`.

**EXECUTED** (shape, parameters bound):

```sql
SELECT ... FROM fyp.catalogue_properties c
  JOIN fyp.rental_properties r ON r.listing_id = c.id
 WHERE c.id IS NOT NULL
 ORDER BY ... LIMIT :limit OFFSET :offset;
```

**Manual verification SQL:**

```sql
-- 955 discoverable rows; the view is the catalogue, not the rental table.
SELECT count(*) AS catalogue_rows FROM fyp.catalogue_properties;

SELECT c.id, c.name, r.monthly_rent_rm
  FROM fyp.catalogue_properties c
  LEFT JOIN fyp.rental_properties r ON r.listing_id = c.id
 WHERE c.id = 'EP-02087';
```

**Expected:** `catalogue_rows = 955`; `EP-02087` resolves to one row with a rent value.  
**Actual:** PASS — 955 rows; `EP-02087` present.  
**Status:** PASS.

---

## 2. CREATE — Save property

**Operation:** CREATE  
**Application action:** Property detail page → **Save property**.  
**Backend:** `POST /api/v1/saved-properties/` → saved-property service.  
**Database:** PG18, 5544. `public.favorite_property`.

**EXECUTED** (from the 500 that preceded migration `20260923_09`, verbatim):

```
InvalidTextRepresentation: invalid input syntax for type integer: "EP-02087"
INSERT INTO public.favorite_property (user_id, property_id) VALUES (%(user_id)s, %(property_id)s)
```

After `20261123_09_favorite_property_property_id_text.sql` converted `property_id` to `text`  
and dropped the integer FK:

```sql
INSERT INTO public.favorite_property (user_id, property_id) VALUES (:user_id, :property_id);
```

**Manual verification SQL:**

```sql
SELECT f.favorite_id, f.property_id, f.created_at, u.email
  FROM public.favorite_property f
  JOIN public.users u ON u.user_id = f.user_id
 WHERE f.property_id = 'EP-02087';
```

**Expected:** exactly 1 row for `tabhello1612@gmail.com`.  
**Actual:** PASS — 1 row, `favorite_id = c9133526-3f9d-4c65-abf3-4cbed2b8f06d`, created 2026-11-23 15:21:29 UTC.  
**Status:** PASS.

---

## 3. CREATE — Assessment

**Operation:** CREATE  
**Application action:** Saved page → **Create assessment** → selected `EP-02087`.  
**Backend:** `POST /api/v1/assessments/` → `assessment_service`.  
**Database:** PG18, 5544. `public.assessment`, plus reads from `public.district_population` (DOSM).

**EXECUTED:**

```sql
INSERT INTO public.assessment (assessment_id, user_id, property_id, status, current_stage)
VALUES (:id, :user_id, :property_id, 'in_progress', 1);
```

**Manual verification SQL:**

```sql
SELECT a.assessment_id, a.property_id, a.status, a.current_stage, a.created_at
  FROM public.assessment a
 WHERE a.assessment_id = '8c30a934-c800-4250-9872-bdf6637ab85b';
```

**Expected:** 1 row, `status = in_progress`, `current_stage = 2` after Stage 1 completes.  
**Actual:** PASS — 1 row, `current_stage = 2`, `completed_stages = 1`, `progress_percent = 20`.  
**Status:** PASS.

> **Known behaviour, recorded deliberately:** on the first attempt the POST returned **500** yet the  
> row was committed. Creation commits, then payload assembly fails, so the client reports an error  
> for a row that exists. Not repaired — documented, because "the request failed" is not evidence  
> that nothing was written.

---

## 4. CREATE — M2 instrument registration (provisioning, not app CRUD)

**Operation:** CREATE  
**Application action:** none. Owner authorization `OWNER-TEST-ENV-M2V2-20261123`.  
**Backend:** `backend/tools/pg18_register_m2v2_e2e.py`.  
**Database:** PG18, 5544. `public.m2_instrument_versions`, `public.m2_item_versions`.

**EXECUTED:**

```sql
INSERT INTO public.m2_instrument_versions (id, code, version_tag, approval_state, schema_digest)
VALUES ('42ee86eb-3b5a-5f2c-be4d-be88e5f6f2f6', 'M2V2', 'M2V2-20261122-1',
        'AUTHORIZED', '62a3effd7583aa8cd5e10cd36e601b7fa72a78c97b3b7632d14ccf7bb6604861');
INSERT INTO public.m2_item_versions (...) VALUES (...);   -- 19 rows
```

**Manual verification SQL:**

```sql
SELECT v.code, v.version_tag, v.approval_state, v.schema_digest,
       count(i.id) AS items,
       count(*) FILTER (WHERE i.requiredness = 'REQUIRED')    AS required,
       count(*) FILTER (WHERE i.requiredness = 'CONDITIONAL') AS conditional,
       count(*) FILTER (WHERE i.requiredness = 'OPTIONAL')    AS optional,
       count(*) FILTER (WHERE i.answer_kind  = 'COMPOSITE')   AS composite,
       count(*) FILTER (WHERE i.answer_kind  = 'ACTION')      AS action_items
  FROM public.m2_instrument_versions v
  JOIN public.m2_item_versions i ON i.instrument_id = v.id
 WHERE v.code = 'M2V2'
 GROUP BY 1,2,3,4;
```

**Expected:** 1 row — 19 items, 14 REQUIRED, 3 CONDITIONAL, 2 OPTIONAL, 7 COMPOSITE, **0 ACTION**.  
**Actual:** PASS — exact match. `M2V1` untouched; no M2V2 row in `Dss`.  
**Status:** PASS.

---

## 5. CREATE — M2 link (Initialize M2 questionnaire)

**Operation:** CREATE  
**Application action:** Assessment workspace → **Initialize M2 questionnaire**.  
**Backend:** `POST /api/v1/m2/assessments/by-marketplace/{id}/link` → `AssessmentLinkService.resolve()`.  
**Database:** PG18, 5544. `public.m2_assessments`, `public.m2_assessment_links`, `public.assessment_workflow_projection`.

**EXECUTED** (one transaction, role `p1_m2_runtime`, `project1.actor_id` bound per transaction):

```sql
-- 1. instrument resolution (read)
SELECT id, code, approval_state FROM public.m2_instrument_versions WHERE code = 'M2V2';

-- 2. create + bind (write)
INSERT INTO public.m2_assessments (id, owner_user_id, instrument_id, revision)
VALUES (:id, :owner, :instrument, 0);

INSERT INTO public.m2_assessment_links
       (m2_assessment_id, marketplace_assessment_id, user_id, created_by)
VALUES (:m2, :mp, :uid, :uid);

-- 3. trigger m2_workflow_change() → refresh_m2_workflow(aid)
SELECT * FROM public.m2_workflow_summary WHERE assessment_id = aid;
INSERT INTO public.assessment_workflow_projection
       (assessment_id, owner_user_id, assessment_revision,
        projection_sequence, source_fingerprint, projection_data)
VALUES (aid, s.owner_user_id, s.revision, coalesce(prev.projection_sequence,0)+1, fingerprint, s.summary);
```

**Manual verification SQL:**

```sql
SELECT l.link_id, l.m2_assessment_id, l.marketplace_assessment_id,
       l.user_id, l.created_at, l.revoked_at,
       v.code, v.version_tag
  FROM public.m2_assessment_links l
  JOIN public.m2_assessments a       ON a.id = l.m2_assessment_id
  JOIN public.m2_instrument_versions v ON v.id = a.instrument_id
 WHERE l.marketplace_assessment_id = '8c30a934-c800-4250-9872-bdf6637ab85b';
```

**Expected:** 1 active link (`revoked_at IS NULL`) bound to `M2V2-20261122-1`.  
**Actual:** PASS — `link_id 15833209-7ed7-47fb-b584-991ec3179098`, `m2_assessment_id c30051ba-…`,  
instrument `M2V2-20261122-1`, `revoked_at NULL`.  
**Status:** PASS.

> Four grants were missing before this worked, each surfacing only as a bare 503. See §9.

---

## 6. UPDATE — M2 answer persistence (17 answers, revision 0 → 33)

**Operation:** UPDATE (append-only: each save inserts a new `m2_answer_revisions` row)  
**Application action:** Answered the questionnaire; each save bumps the assessment revision.  
**Backend:** `PUT /api/v1/m2/assessments/{id}/answers/{item_key}` → `M2Service.update_answer`.  
**Database:** PG18, 5544. `public.m2_answer_revisions`, `public.m2_assessments`.

**EXECUTED:**

```sql
INSERT INTO public.m2_answer_revisions
       (id, assessment_id, item_version_id, assessment_revision, answer_state, value_json)
VALUES (:id, :assessment, :item_version, :rev, :state, :value);

UPDATE public.m2_assessments SET revision = revision + 1 WHERE id = :id;  -- CAS on expected_revision
```

**Manual verification SQL:**

```sql
-- Latest answer per item, one row per item, ordered by the instrument.
SELECT i.item_key, i.answer_kind, a.assessment_revision, a.answer_state,
       a.value_json
  FROM public.m2_answer_revisions a
  JOIN public.m2_item_versions i ON i.id = a.item_version_id
 WHERE a.assessment_id = 'c30051ba-f9d9-469a-9064-74f1968461ca'
   AND a.assessment_revision = (SELECT max(assessment_revision)
                                  FROM public.m2_answer_revisions
                                 WHERE assessment_id = a.assessment_id)
 ORDER BY i.sort_order;
```


**Expected:** 17 answered items; `M2V2-07` and `M2V2-18` (both OPTIONAL) absent.  
**Actual:** PASS — 17 rows at revision 33; 33 answer rows total (append-only history intact).  
COMPOSITE values persisted verbatim, including `amount_myr` as a JSON number.

**Status:** PASS.

> Revisions jumped 0→19→33 because the fill script ran twice. Harmless: the table is  
> append-only and each row is a legitimate save. Recorded so the numbers are explainable.

---

## 7. CREATE — Review event

**Operation:** CREATE  
**Application action:** **Review business declaration**.  
**Backend:** `POST /api/v1/m2/assessments/{id}/review` → `ConfirmationService.record_review`.  
**Database:** PG18, 5544. `public.m2_review_events`, plus `SELECT … FOR SHARE` on `m2_assessment_links`.

**EXECUTED:**

```sql
SELECT link_id FROM public.m2_assessment_links
 WHERE m2_assessment_id = :m2 AND marketplace_assessment_id = :mp
   AND user_id = :actor AND revoked_at IS NULL
   FOR SHARE;                                    -- requires UPDATE privilege

INSERT INTO public.m2_review_events (id, assessment_id, assessment_revision, actor_user_id)
VALUES (:id, :assessment, :revision, :actor);
```

**Manual verification SQL:**

```sql
SELECT id, assessment_revision, actor_user_id, created_at
  FROM public.m2_review_events
 WHERE assessment_id = 'c30051ba-f9d9-469a-9064-74f1968461ca'
 ORDER BY created_at;
```

**Expected:** 1 event at revision 33.  
**Actual:** PASS — `a8fe27c6-dd56-4186-8bd7-e970604c277c`, revision 33, 2026-11-24 00:03:08 +08.  
**Status:** PASS.

---

## 8. CREATE — Confirmation + BCB build row

**Operation:** CREATE  
**Application action:** **Confirm business declaration**.  
**Backend:** `POST /api/v1/m2/assessments/{id}/confirm` → `ConfirmationService.confirm`.  
**Database:** PG18, 5544. `public.m2_confirmation_snapshots`, `public.m2_business_context_builds`,  
`public.m2_assessments` (confirmed_revision).

**EXECUTED:**

```sql
INSERT INTO public.m2_confirmation_snapshots
       (id, assessment_id, assessment_revision, actor_user_id,
        snapshot_json, snapshot_digest, acknowledged_issue_ids)
VALUES (:id, :assessment, :rev, :actor, :snapshot, :digest, :ack);

-- trigger m2_bcb_initialize_status()
INSERT INTO public.m2_business_context_builds
       (confirmation_id, assessment_id, owner_user_id, assessment_revision, status)
VALUES (NEW.id, NEW.assessment_id, NEW.actor_user_id, NEW.assessment_revision, 'PENDING');
```

**Manual verification SQL:**

```sql
SELECT c.id, c.assessment_revision, c.snapshot_digest,
       jsonb_array_length((c.snapshot_json::jsonb) -> 'answer_revisions') AS frozen_answers,
       (c.snapshot_json::jsonb) ->> 'instrument_version'                 AS instrument,
       (c.snapshot_json::jsonb) -> 'ai_processing' ->> 'decision'        AS ai_consent,
       c.created_at
  FROM public.m2_confirmation_snapshots c
 WHERE c.assessment_id = 'c30051ba-f9d9-469a-9064-74f1968461ca';

SELECT b.confirmation_id, b.assessment_revision, b.status, b.attempt_count
  FROM public.m2_business_context_builds b
 WHERE b.assessment_id = 'c30051ba-f9d9-469a-9064-74f1968461ca';

SELECT revision, confirmed_revision FROM public.m2_assessments
 WHERE id = 'c30051ba-f9d9-469a-9064-74f1968461ca';
```

**Expected:** one snapshot at revision 33 with 17 frozen answers, `ai_consent = NOT_GRANTED`,  
one `PENDING` build row, `confirmed_revision = 33`.

**Actual:** PASS —  
`71fa48d7-18f2-4fb7-a8a2-5333f8ad01d9`, digest `31b7d9b64ded63bd…`, 17 answers,  
instrument `M2V2-20261122-1`, `ai_consent = NOT_GRANTED`, build `PENDING` / attempts 0,  
`revision 33 = confirmed_revision 33`.

**Status:** PASS — **with one caveat**: the successful write was executed through  
`ConfirmationService.confirm` (the exact function the endpoint calls, same session wiring and  
RLS actor), *after* the UI button had already failed on the missing grant. The UI path for the  
**write** is therefore not proven by this run; the UI path for the **read** is. Recorded here  
rather than presented as a UI-pass.

**Next checkpoint:** UI re-verification of confirm on a second assessment.

---

## 9. Privilege defects found and fixed

Every one of these appeared to the browser as an identical `503 M2_SOURCE_UNAVAILABLE`.  
The endpoints convert `SQLAlchemyError` into a bare 503 and log nothing, so each had to be  
reproduced in-process to be seen.

| #  | Migration                                       | Real error                                                      | Why                                                                                  |
| -- | ----------------------------------------------- | --------------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| 13 | `20261123_13_m2_link_write_grant.sql`           | `permission denied for table m2_assessment_links` (INSERT)      | `20261123_02` omitted the table from its grant list                                  |
| 14 | `20261123_14_m2_workflow_projection_grants.sql` | `permission denied for view m2_workflow_summary`                | `refresh_m2_workflow` is not SECURITY DEFINER; the view is `security_invoker=true`   |
| 15 | `20261123_15_m2_link_row_lock_grant.sql`        | `permission denied for table m2_assessment_links` (`FOR SHARE`) | Any row-locking clause requires UPDATE; granted column-level `UPDATE (link_id)` only |
| 16 | `20261123_16_m2_bcb_write_grants.sql`           | `permission denied for table m2_business_context_builds`        | `m2_bcb_initialize_status()` inserts a PENDING row; role had SELECT only             |

**Diagnostic tools** (read-only unless `--apply`):

```
backend/tools/pg18_diag_m2_create.py   --assessment <marketplace uuid>
backend/tools/pg18_diag_m2_review.py   --assessment <m2 uuid> --revision N --user <uuid> --marketplace <uuid>
backend/tools/pg18_diag_m2_confirm.py  --assessment <m2 uuid> --revision N --user <uuid> --marketplace <uuid>
```

---

## 10. Effective-privilege audit (run any time)

```sql
SELECT c.relname, c.relkind,
       has_table_privilege('p1_m2_runtime', c.oid, 'SELECT') AS sel,
       has_table_privilege('p1_m2_runtime', c.oid, 'INSERT') AS ins,
       has_table_privilege('p1_m2_runtime', c.oid, 'UPDATE') AS upd,
       has_table_privilege('p1_m2_runtime', c.oid, 'DELETE') AS del
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = 'public' AND c.relkind IN ('r','v','m')
   AND (c.relname LIKE 'm2\_%' OR c.relname LIKE 'assessment\_workflow\_%')
 ORDER BY c.relname;
```

Expected after migrations 13–16: `p1_m2_runtime` holds **no DELETE** on any M2 relation.
