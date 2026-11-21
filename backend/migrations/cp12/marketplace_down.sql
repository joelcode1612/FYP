BEGIN;
DO $$ DECLARE t record; BEGIN
 IF current_setting('project1.cp12_migration_target',true) IS DISTINCT FROM current_database()
 OR nullif(current_setting('project1.cp12_migration_receipt',true),'') IS NULL THEN RAISE EXCEPTION 'CP12_MIGRATION_APPROVAL_REQUIRED'; END IF;
 IF EXISTS(SELECT FROM cp12.operations) THEN RAISE EXCEPTION 'CP12_ROLLBACK_WOULD_DESTROY_JOURNAL'; END IF;
 FOR t IN SELECT n.nspname,c.relname FROM cp12.guarded_relations g JOIN pg_class c ON c.oid=g.relation_oid JOIN pg_namespace n ON n.oid=c.relnamespace LOOP
 EXECUTE format('DROP TRIGGER cp12_barrier ON %I.%I',t.nspname,t.relname);
 END LOOP;
END $$;
DROP FUNCTION cp12.finish(uuid,uuid,text),cp12.prepare(uuid,uuid),cp12.market_barrier();
DROP TABLE cp12.guarded_relations,cp12.operations,cp12.policy,cp12.target_reviews;
DROP FUNCTION cp12.actor(),cp12.proof(text,uuid,uuid,uuid);
DROP TABLE cp12.handoff_key;
DROP SCHEMA cp12;
COMMIT;
