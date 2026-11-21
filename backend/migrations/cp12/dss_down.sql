-- Rollback is permitted only before any discard intent/receipt exists.
BEGIN;
DO $$ DECLARE t record; body text; BEGIN
 IF current_setting('project1.cp12_migration_target',true) IS DISTINCT FROM current_database()
 OR nullif(current_setting('project1.cp12_migration_receipt',true),'') IS NULL THEN RAISE EXCEPTION 'CP12_MIGRATION_APPROVAL_REQUIRED'; END IF;
 IF EXISTS(SELECT FROM cp12.operations) THEN RAISE EXCEPTION 'CP12_ROLLBACK_WOULD_DESTROY_JOURNAL'; END IF;
 FOR t IN SELECT n.nspname,c.relname FROM cp12.guarded_relations g JOIN pg_class c ON c.oid=g.relation_oid JOIN pg_namespace n ON n.oid=c.relnamespace LOOP
 EXECUTE format('DROP TRIGGER cp12_barrier ON %I.%I',t.nspname,t.relname);
 END LOOP;
 SELECT original_definition.body INTO body FROM cp12.original_definition;
 EXECUTE body;
END $$;
DROP FUNCTION cp12.reserve(uuid,uuid,text),cp12.complete(uuid,uuid,text),cp12.remove_draft(uuid,uuid,text),cp12.inspect(uuid),cp12.write_barrier();
DROP TABLE cp12.operations,cp12.policy,cp12.target_reviews,cp12.guarded_relations,cp12.original_definition;
DROP FUNCTION cp12.actor(),cp12.proof(text,uuid,uuid,uuid);
DROP TABLE cp12.handoff_key;
DROP SCHEMA cp12;
-- pgcrypto is retained: it may have existed before this migration.
COMMIT;
