-- BD-01 corrected question-bank authority schema (P2).
--
-- Replaces the never-applied candidate at
--   C:/Users/HP/AppData/Local/Temp/f01fix/sql/BD01_OPTION_B_CANDIDATE_NOT_APPLIED.sql
-- which could not reach any authorising state:
--
--   BD01-SQL-01  `question_item_version` and `bank_snapshot` carried a mutable
--                lifecycle column (approval_state / state) guarded by a CHECK,
--                while an append-only trigger rejected EVERY UPDATE. The CHECK
--                demanded a transition and the trigger forbade it, so a version
--                could never leave CANDIDATE and a snapshot could never become
--                ACCEPTED. No receipt could therefore ever be issued.
--
--   BD01-SQL-02  No table carried a tenant/owner key, so row-level isolation
--                could not be expressed from the table at all.
--
-- Correction: immutable version records + separately recorded lifecycle events.
-- A row is never rewritten; a new event row records each transition, and the
-- current state is DERIVED by folding those events in a view. Append-only
-- protection stays on for every record table and is never disabled globally.
--
-- Ownership: schema and objects are owned by the migration role (postgres in the
-- disposable clone). Read views run with owner rights (security definer) so the
-- runtime role needs no base-table privilege at all for approved definitions.
-- Receipt isolation is NOT a view filter: it is RLS on the base table, keyed by
-- the transaction-local `project1.tenant_id` setting.
--
-- Explicit operator execution only. Never run at application startup.
BEGIN;
SET LOCAL lock_timeout = '5s';

DO $guard$
BEGIN
  -- Same guard shape as 20261114_02_research_objective_sources.sql:3-10.
  IF current_setting('project1.qgb_migration_target', true) IS DISTINCT FROM current_database()
     OR nullif(current_setting('project1.qgb_migration_receipt', true), '') IS NULL THEN
    RAISE EXCEPTION 'Explicit target and migration receipt required '
                    '(project1.qgb_migration_target must equal current_database(); '
                    'project1.qgb_migration_receipt must be non-empty)';
  END IF;

  -- Hard safety: the two protected databases are refused even if a caller sets
  -- the guard setting to them by mistake.
  IF current_database() IN ('Dss', 'Final_Location_Analysis') THEN
    RAISE EXCEPTION 'Refusing to apply the question-bank schema to protected database %',
                    current_database();
  END IF;

  IF to_regclass('project1_qgb.question_item') IS NOT NULL THEN
    RAISE EXCEPTION 'Schema project1_qgb already present; run the rollback first';
  END IF;
END
$guard$;

-- ---------------------------------------------------------------------------
-- Roles. Cluster-wide, so create only when absent; never drop them from a
-- rollback (that would reach beyond this database). All are NOLOGIN group
-- roles: work is performed by SET ROLE from a governed session.
-- ---------------------------------------------------------------------------
DO $roles$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'p1_qgb_issuer') THEN
    EXECUTE 'CREATE ROLE p1_qgb_issuer NOLOGIN';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'p1_qgb_runtime') THEN
    EXECUTE 'CREATE ROLE p1_qgb_runtime NOLOGIN';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'p1_qgb_admin') THEN
    EXECUTE 'CREATE ROLE p1_qgb_admin NOLOGIN';
  END IF;
END
$roles$;

CREATE SCHEMA project1_qgb;
REVOKE ALL ON SCHEMA project1_qgb FROM PUBLIC;
GRANT USAGE ON SCHEMA project1_qgb TO p1_qgb_issuer, p1_qgb_runtime, p1_qgb_admin;

-- ---------------------------------------------------------------------------
-- 1. Logical identity. No payload, no state.
-- ---------------------------------------------------------------------------
CREATE TABLE project1_qgb.question_item (
    logical_item_id uuid PRIMARY KEY,
    created_at      timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- 2. Immutable payload version. No approval column: the lifecycle lives in
--    item_lifecycle_event. A correction is a new row linked by `supersedes`.
-- ---------------------------------------------------------------------------
CREATE TABLE project1_qgb.question_item_version (
    item_version_id    uuid PRIMARY KEY,
    logical_item_id    uuid NOT NULL REFERENCES project1_qgb.question_item(logical_item_id),
    instrument_version text NOT NULL CHECK (length(btrim(instrument_version)) > 0),
    item_payload       jsonb NOT NULL CHECK (jsonb_typeof(item_payload) = 'object'),
    payload_sha256     varchar(64) NOT NULL CHECK (payload_sha256 ~ '^[0-9a-f]{64}$'),
    supersedes         uuid UNIQUE REFERENCES project1_qgb.question_item_version(item_version_id),
    created_at         timestamptz NOT NULL DEFAULT now(),
    CHECK (supersedes IS DISTINCT FROM item_version_id)
);

-- ---------------------------------------------------------------------------
-- 3. Append-only lifecycle events for item versions.
-- ---------------------------------------------------------------------------
CREATE TABLE project1_qgb.item_lifecycle_event (
    event_id       uuid PRIMARY KEY,
    item_version_id uuid NOT NULL REFERENCES project1_qgb.question_item_version(item_version_id),
    sequence       int NOT NULL CHECK (sequence > 0),
    event_type     text NOT NULL
                   CHECK (event_type IN ('CANDIDATE','INDEPENDENTLY_REVIEWED','APPROVED','RETIRED')),
    actor_id       text NOT NULL CHECK (length(btrim(actor_id)) > 0),
    actor_role     text NOT NULL
                   CHECK (actor_role IN ('SCIENTIFIC_REVIEWER','OWNER_APPROVER','SYSTEM')),
    attestation    text,
    receipt_ref    text,
    occurred_at    timestamptz NOT NULL DEFAULT now(),
    UNIQUE (item_version_id, sequence),
    -- The event type must be issuable by the role that claims it.
    CHECK (
        (event_type IN ('CANDIDATE','INDEPENDENTLY_REVIEWED')
            AND actor_role IN ('SCIENTIFIC_REVIEWER','SYSTEM'))
     OR (event_type = 'APPROVED' AND actor_role = 'OWNER_APPROVER')
     OR (event_type = 'RETIRED'  AND actor_role IN ('OWNER_APPROVER','SYSTEM'))
    ),
    -- A review and an approval are attestations, not silent flags.
    CHECK (event_type NOT IN ('INDEPENDENTLY_REVIEWED','APPROVED')
           OR (attestation IS NOT NULL AND length(btrim(attestation)) > 0))
);

-- ---------------------------------------------------------------------------
-- 4. Snapshot of a catalogue scope. No state column.
-- ---------------------------------------------------------------------------
CREATE TABLE project1_qgb.bank_snapshot (
    snapshot_id               uuid PRIMARY KEY,
    snapshot_version          text NOT NULL UNIQUE CHECK (length(btrim(snapshot_version)) > 0),
    scope_contract            text NOT NULL CHECK (length(btrim(scope_contract)) > 0),
    catalogue_sha256          varchar(64) NOT NULL CHECK (catalogue_sha256 ~ '^[0-9a-f]{64}$'),
    comparison_policy_version text NOT NULL CHECK (length(btrim(comparison_policy_version)) > 0),
    created_at                timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- 5. Append-only lifecycle events for snapshots. This is what lets a snapshot
--    reach ACCEPTED, which the candidate schema could not.
-- ---------------------------------------------------------------------------
CREATE TABLE project1_qgb.bank_snapshot_event (
    event_id    uuid PRIMARY KEY,
    snapshot_id uuid NOT NULL REFERENCES project1_qgb.bank_snapshot(snapshot_id),
    sequence    int NOT NULL CHECK (sequence > 0),
    event_type  text NOT NULL CHECK (event_type IN ('DRAFT','ACCEPTED','RETIRED')),
    actor_id    text NOT NULL CHECK (length(btrim(actor_id)) > 0),
    actor_role  text NOT NULL
                CHECK (actor_role IN ('SCIENTIFIC_REVIEWER','OWNER_APPROVER','SYSTEM')),
    attestation text,
    occurred_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (snapshot_id, sequence),
    -- Acceptance is an attested act by a named actor, never a bare flag.
    CHECK (event_type <> 'ACCEPTED'
           OR (attestation IS NOT NULL AND length(btrim(attestation)) > 0))
);

-- ---------------------------------------------------------------------------
-- 6. Snapshot membership.
-- ---------------------------------------------------------------------------
CREATE TABLE project1_qgb.bank_snapshot_item (
    snapshot_id     uuid NOT NULL REFERENCES project1_qgb.bank_snapshot(snapshot_id),
    item_version_id uuid NOT NULL REFERENCES project1_qgb.question_item_version(item_version_id),
    PRIMARY KEY (snapshot_id, item_version_id)
);

-- ---------------------------------------------------------------------------
-- 7. Issued comparison receipt. Immutable. Carries the tenant key.
-- ---------------------------------------------------------------------------
CREATE TABLE project1_qgb.comparison_receipt (
    receipt_id                 uuid PRIMARY KEY,
    snapshot_id                uuid NOT NULL REFERENCES project1_qgb.bank_snapshot(snapshot_id),
    tenant_id                  uuid NOT NULL,
    objective_id               uuid NOT NULL,
    source_confirmation_id     uuid NOT NULL,
    measurement_digest         varchar(64) NOT NULL CHECK (measurement_digest ~ '^[0-9a-f]{64}$'),
    bcb_packet_hash            varchar(64) NOT NULL CHECK (bcb_packet_hash ~ '^[0-9a-f]{64}$'),
    comparison_policy_version  text NOT NULL CHECK (length(btrim(comparison_policy_version)) > 0),
    issuer_id                  text NOT NULL CHECK (length(btrim(issuer_id)) > 0),
    issuer_attestation         text NOT NULL CHECK (length(btrim(issuer_attestation)) > 0),
    decision                   text NOT NULL
                               CHECK (decision IN ('EQUIVALENT','NO_EQUIVALENT','UNVERIFIED')),
    equivalent_item_version_id uuid REFERENCES project1_qgb.question_item_version(item_version_id),
    receipt_sha256             varchar(64) NOT NULL CHECK (receipt_sha256 ~ '^[0-9a-f]{64}$'),
    issued_at                  timestamptz NOT NULL DEFAULT now(),
    -- EQUIVALENT iff an item version is named.
    CHECK ((decision = 'EQUIVALENT') = (equivalent_item_version_id IS NOT NULL))
);

-- ---------------------------------------------------------------------------
-- 8. Per-item review rows behind a receipt.
-- ---------------------------------------------------------------------------
CREATE TABLE project1_qgb.comparison_review_item (
    receipt_id           uuid NOT NULL REFERENCES project1_qgb.comparison_receipt(receipt_id),
    item_version_id      uuid NOT NULL REFERENCES project1_qgb.question_item_version(item_version_id),
    reviewer_id          text NOT NULL CHECK (length(btrim(reviewer_id)) > 0),
    reviewer_attestation text NOT NULL CHECK (length(btrim(reviewer_attestation)) > 0),
    equivalent           boolean NOT NULL,
    rationale            text NOT NULL CHECK (length(btrim(rationale)) > 0),
    reviewed_at          timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (receipt_id, item_version_id)
);

-- ---------------------------------------------------------------------------
-- Append-only protection. Every record table refuses UPDATE and DELETE. There
-- is no per-table switch: a lifecycle change is a new event row, never a
-- rewrite of an existing one.
-- ---------------------------------------------------------------------------
CREATE FUNCTION project1_qgb.refuse_rewrite() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'QGB_APPEND_ONLY: % on % is not permitted', TG_OP, TG_TABLE_NAME
        USING ERRCODE = 'QGB01';
END;
$$;
REVOKE ALL ON FUNCTION project1_qgb.refuse_rewrite() FROM PUBLIC;

CREATE TRIGGER item_version_append_only BEFORE UPDATE OR DELETE
    ON project1_qgb.question_item_version
    FOR EACH ROW EXECUTE FUNCTION project1_qgb.refuse_rewrite();
CREATE TRIGGER item_lifecycle_append_only BEFORE UPDATE OR DELETE
    ON project1_qgb.item_lifecycle_event
    FOR EACH ROW EXECUTE FUNCTION project1_qgb.refuse_rewrite();
CREATE TRIGGER snapshot_append_only BEFORE UPDATE OR DELETE
    ON project1_qgb.bank_snapshot
    FOR EACH ROW EXECUTE FUNCTION project1_qgb.refuse_rewrite();
CREATE TRIGGER snapshot_event_append_only BEFORE UPDATE OR DELETE
    ON project1_qgb.bank_snapshot_event
    FOR EACH ROW EXECUTE FUNCTION project1_qgb.refuse_rewrite();
CREATE TRIGGER snapshot_item_append_only BEFORE UPDATE OR DELETE
    ON project1_qgb.bank_snapshot_item
    FOR EACH ROW EXECUTE FUNCTION project1_qgb.refuse_rewrite();
CREATE TRIGGER receipt_append_only BEFORE UPDATE OR DELETE
    ON project1_qgb.comparison_receipt
    FOR EACH ROW EXECUTE FUNCTION project1_qgb.refuse_rewrite();
CREATE TRIGGER review_item_append_only BEFORE UPDATE OR DELETE
    ON project1_qgb.comparison_review_item
    FOR EACH ROW EXECUTE FUNCTION project1_qgb.refuse_rewrite();

-- ---------------------------------------------------------------------------
-- Derived state: fold the event log. Nothing here mutates a record.
--
--   RETIRED                 wins outright (a retire event exists)
--   APPROVED                a SCIENTIFIC_REVIEWER INDEPENDENTLY_REVIEWED event
--                           AND an APPROVED event by an OWNER_APPROVER whose
--                           actor_id differs from that reviewer
--   INDEPENDENTLY_REVIEWED  a SCIENTIFIC_REVIEWER INDEPENDENTLY_REVIEWED event
--   CANDIDATE               only a candidate event
--   NULL                    no events registered (never implicitly approved)
-- ---------------------------------------------------------------------------
CREATE VIEW project1_qgb.question_item_version_state AS
SELECT
    s.item_version_id,
    s.logical_item_id,
    s.instrument_version,
    s.approval_state,
    CASE WHEN s.approval_state = 'APPROVED' THEN s.approved_at_candidate END AS approved_at,
    s.scientific_reviewer_id,
    s.owner_approver_id
FROM (
    SELECT
        v.item_version_id,
        v.logical_item_id,
        v.instrument_version,
        CASE
            WHEN st.retired THEN 'RETIRED'
            WHEN st.scientific_reviewer_id IS NOT NULL
             AND st.distinct_owner_approval THEN 'APPROVED'
            WHEN st.scientific_reviewer_id IS NOT NULL THEN 'INDEPENDENTLY_REVIEWED'
            WHEN st.has_candidate_event THEN 'CANDIDATE'
        END AS approval_state,
        st.approved_at_candidate,
        st.scientific_reviewer_id,
        st.owner_approver_id
    FROM project1_qgb.question_item_version v
    LEFT JOIN LATERAL (
        SELECT
            bool_or(e.event_type = 'RETIRED')   AS retired,
            bool_or(e.event_type = 'CANDIDATE') AS has_candidate_event,
            min(e.occurred_at) FILTER (WHERE e.event_type = 'APPROVED')
                AS approved_at_candidate,
            (array_agg(e.actor_id ORDER BY e.occurred_at)
                FILTER (WHERE e.event_type = 'INDEPENDENTLY_REVIEWED'
                          AND e.actor_role = 'SCIENTIFIC_REVIEWER'))[1]
                AS scientific_reviewer_id,
            (array_agg(e.actor_id ORDER BY e.occurred_at)
                FILTER (WHERE e.event_type = 'APPROVED'
                          AND e.actor_role = 'OWNER_APPROVER'))[1]
                AS owner_approver_id,
            EXISTS (
                SELECT 1
                FROM project1_qgb.item_lifecycle_event r
                JOIN project1_qgb.item_lifecycle_event a
                  ON a.item_version_id = r.item_version_id
                 AND a.event_type = 'APPROVED'
                 AND a.actor_role = 'OWNER_APPROVER'
                 AND a.actor_id <> r.actor_id
                WHERE r.item_version_id = v.item_version_id
                  AND r.event_type = 'INDEPENDENTLY_REVIEWED'
                  AND r.actor_role = 'SCIENTIFIC_REVIEWER'
            ) AS distinct_owner_approval
        FROM project1_qgb.item_lifecycle_event e
        WHERE e.item_version_id = v.item_version_id
    ) st ON TRUE
) s;

CREATE VIEW project1_qgb.bank_snapshot_state AS
SELECT
    s.snapshot_id,
    s.snapshot_version,
    s.scope_contract,
    s.catalogue_sha256,
    s.comparison_policy_version,
    s.state,
    CASE WHEN s.state = 'ACCEPTED' THEN s.accepted_at_candidate END AS accepted_at,
    s.acceptor_id
FROM (
    SELECT
        b.snapshot_id,
        b.snapshot_version,
        b.scope_contract,
        b.catalogue_sha256,
        b.comparison_policy_version,
        CASE
            WHEN st.retired THEN 'RETIRED'
            WHEN st.accepted THEN 'ACCEPTED'
            WHEN st.drafted THEN 'DRAFT'
        END AS state,
        st.accepted_at_candidate,
        st.acceptor_id
    FROM project1_qgb.bank_snapshot b
    LEFT JOIN LATERAL (
        SELECT
            bool_or(e.event_type = 'RETIRED')  AS retired,
            bool_or(e.event_type = 'ACCEPTED') AS accepted,
            bool_or(e.event_type = 'DRAFT')    AS drafted,
            min(e.occurred_at) FILTER (WHERE e.event_type = 'ACCEPTED') AS accepted_at_candidate,
            (array_agg(e.actor_id ORDER BY e.occurred_at)
                FILTER (WHERE e.event_type = 'ACCEPTED'))[1] AS acceptor_id
        FROM project1_qgb.bank_snapshot_event e
        WHERE e.snapshot_id = b.snapshot_id
    ) st ON TRUE
) s;

-- ---------------------------------------------------------------------------
-- Read views for the runtime role. Approved definitions and accepted snapshots
-- are reachable ONLY here; the runtime role gets no privilege on the base
-- tables. These views run with owner rights, and their WHERE clause is the
-- whole filter, so a CANDIDATE payload cannot leak.
-- ---------------------------------------------------------------------------
CREATE VIEW project1_qgb.approved_question_item_version AS
SELECT v.item_version_id, v.logical_item_id, v.instrument_version,
       v.item_payload, v.payload_sha256, v.supersedes, v.created_at,
       s.approval_state, s.approved_at, s.scientific_reviewer_id, s.owner_approver_id
FROM project1_qgb.question_item_version v
JOIN project1_qgb.question_item_version_state s USING (item_version_id)
WHERE s.approval_state = 'APPROVED';

CREATE VIEW project1_qgb.accepted_bank_snapshot AS
SELECT b.snapshot_id, b.snapshot_version, b.scope_contract, b.catalogue_sha256,
       b.comparison_policy_version, b.created_at,
       s.state, s.accepted_at, s.acceptor_id
FROM project1_qgb.bank_snapshot b
JOIN project1_qgb.bank_snapshot_state s USING (snapshot_id)
WHERE s.state = 'ACCEPTED';

CREATE VIEW project1_qgb.accepted_bank_snapshot_item AS
SELECT si.snapshot_id, si.item_version_id
FROM project1_qgb.bank_snapshot_item si
JOIN project1_qgb.bank_snapshot_state s USING (snapshot_id)
WHERE s.state = 'ACCEPTED';

-- ---------------------------------------------------------------------------
-- Row-level security.
--
-- comparison_receipt is the tenant boundary. The policy, not the caller's
-- WHERE clause, is the enforcement: an unset project1.tenant_id yields NULL,
-- the predicate is NULL, and no row is visible.
-- ---------------------------------------------------------------------------
ALTER TABLE project1_qgb.comparison_receipt ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_select ON project1_qgb.comparison_receipt
    FOR SELECT TO p1_qgb_runtime
    USING (tenant_id = current_setting('project1.tenant_id', true)::uuid);
CREATE POLICY issuer_insert ON project1_qgb.comparison_receipt
    FOR INSERT TO p1_qgb_issuer WITH CHECK (true);
CREATE POLICY admin_all ON project1_qgb.comparison_receipt
    FOR ALL TO p1_qgb_admin USING (true) WITH CHECK (true);

ALTER TABLE project1_qgb.comparison_review_item ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_select ON project1_qgb.comparison_review_item
    FOR SELECT TO p1_qgb_runtime
    USING (receipt_id IN (SELECT receipt_id FROM project1_qgb.comparison_receipt));
CREATE POLICY issuer_insert ON project1_qgb.comparison_review_item
    FOR INSERT TO p1_qgb_issuer WITH CHECK (true);
CREATE POLICY admin_all ON project1_qgb.comparison_review_item
    FOR ALL TO p1_qgb_admin USING (true) WITH CHECK (true);

-- ---------------------------------------------------------------------------
-- Privileges. No grants to PUBLIC anywhere; the runtime role never touches a
-- base table for definitions.
-- ---------------------------------------------------------------------------
REVOKE ALL ON ALL TABLES    IN SCHEMA project1_qgb FROM PUBLIC;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA project1_qgb FROM PUBLIC;

GRANT SELECT ON project1_qgb.approved_question_item_version  TO p1_qgb_runtime;
GRANT SELECT ON project1_qgb.accepted_bank_snapshot          TO p1_qgb_runtime;
GRANT SELECT ON project1_qgb.accepted_bank_snapshot_item     TO p1_qgb_runtime;
GRANT SELECT ON project1_qgb.comparison_receipt              TO p1_qgb_runtime;
GRANT SELECT ON project1_qgb.comparison_review_item          TO p1_qgb_runtime;

GRANT SELECT, INSERT ON project1_qgb.question_item             TO p1_qgb_issuer;
GRANT SELECT, INSERT ON project1_qgb.question_item_version     TO p1_qgb_issuer;
GRANT SELECT, INSERT ON project1_qgb.item_lifecycle_event      TO p1_qgb_issuer;
GRANT SELECT, INSERT ON project1_qgb.bank_snapshot             TO p1_qgb_issuer;
GRANT SELECT, INSERT ON project1_qgb.bank_snapshot_event       TO p1_qgb_issuer;
GRANT SELECT, INSERT ON project1_qgb.bank_snapshot_item        TO p1_qgb_issuer;
GRANT SELECT, INSERT ON project1_qgb.comparison_receipt        TO p1_qgb_issuer;
GRANT SELECT, INSERT ON project1_qgb.comparison_review_item    TO p1_qgb_issuer;
GRANT SELECT ON project1_qgb.question_item_version_state       TO p1_qgb_issuer;
GRANT SELECT ON project1_qgb.bank_snapshot_state               TO p1_qgb_issuer;

GRANT SELECT ON ALL TABLES IN SCHEMA project1_qgb TO p1_qgb_admin;

-- Prove the invariants inside the same transaction: a silent no-op must not be
-- mistaken for success.
DO $verify$
DECLARE t text;
BEGIN
    -- Runtime must not reach any record table directly.
    FOREACH t IN ARRAY ARRAY[
        'question_item','question_item_version','item_lifecycle_event',
        'bank_snapshot','bank_snapshot_event','bank_snapshot_item',
        'question_item_version_state','bank_snapshot_state'] LOOP
        IF has_table_privilege('p1_qgb_runtime', 'project1_qgb.' || t, 'SELECT') THEN
            RAISE EXCEPTION 'runtime role has direct SELECT on %', t;
        END IF;
    END LOOP;

    -- Runtime must not be able to write anything.
    FOREACH t IN ARRAY ARRAY[
        'question_item','question_item_version','item_lifecycle_event',
        'bank_snapshot','bank_snapshot_event','bank_snapshot_item',
        'comparison_receipt','comparison_review_item'] LOOP
        IF has_table_privilege('p1_qgb_runtime', 'project1_qgb.' || t, 'INSERT')
           OR has_table_privilege('p1_qgb_runtime', 'project1_qgb.' || t, 'UPDATE')
           OR has_table_privilege('p1_qgb_runtime', 'project1_qgb.' || t, 'DELETE') THEN
            RAISE EXCEPTION 'runtime role has write privilege on %', t;
        END IF;
    END LOOP;

    IF has_schema_privilege('p1_qgb_runtime', 'project1_qgb', 'CREATE') THEN
        RAISE EXCEPTION 'runtime role can create in project1_qgb';
    END IF;
    IF has_schema_privilege('public', 'project1_qgb', 'USAGE') THEN
        RAISE EXCEPTION 'PUBLIC has USAGE on project1_qgb';
    END IF;

    -- Every record table must carry its append-only trigger.
    FOREACH t IN ARRAY ARRAY[
        'question_item_version','item_lifecycle_event','bank_snapshot',
        'bank_snapshot_event','bank_snapshot_item','comparison_receipt',
        'comparison_review_item'] LOOP
        IF NOT EXISTS (
            SELECT 1 FROM pg_trigger g
            JOIN pg_class c ON c.oid = g.tgrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = 'project1_qgb' AND c.relname = t
              AND NOT g.tgisinternal AND g.tgname LIKE '%append_only'
        ) THEN
            RAISE EXCEPTION 'append-only trigger missing on %', t;
        END IF;
    END LOOP;

    IF NOT (SELECT relrowsecurity FROM pg_class
             WHERE oid = 'project1_qgb.comparison_receipt'::regclass)
       OR NOT (SELECT relrowsecurity FROM pg_class
                WHERE oid = 'project1_qgb.comparison_review_item'::regclass) THEN
        RAISE EXCEPTION 'RLS is not enabled on the receipt tables';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_policies
                    WHERE schemaname = 'project1_qgb'
                      AND tablename = 'comparison_receipt'
                      AND policyname = 'tenant_select'
                      AND qual LIKE '%project1.tenant_id%') THEN
        RAISE EXCEPTION 'tenant_select policy is missing or not tenant-keyed';
    END IF;
END
$verify$;

COMMIT;
