\set ON_ERROR_STOP on
BEGIN READ ONLY;
SELECT current_database(),current_user,rolsuper,rolbypassrls FROM pg_roles WHERE rolname=current_user;
SELECT table_name,column_name,data_type,is_nullable FROM information_schema.columns
 WHERE table_schema='public' AND (table_name LIKE 'ee01_%' OR table_name IN
 ('cq_lifecycle_events','cq_render_events','cq_rejected_answer_events','cq_session_controls')) ORDER BY 1,ordinal_position;
SELECT cl.relname,c.conname,pg_get_constraintdef(c.oid) FROM pg_constraint c JOIN pg_class cl ON cl.oid=c.conrelid
 WHERE cl.relname LIKE 'ee01_%' ORDER BY 1,2;
SELECT tablename,indexname,indexdef FROM pg_indexes WHERE schemaname='public' AND tablename LIKE 'ee01_%' ORDER BY 1,2;
SELECT c.relname,c.relrowsecurity,c.relforcerowsecurity,pg_get_userbyid(c.relowner) AS owner
 FROM pg_class c WHERE c.relname LIKE 'ee01_%' AND c.relkind='r' ORDER BY 1;
SELECT tablename,policyname,roles,qual,with_check FROM pg_policies WHERE tablename LIKE 'ee01_%' ORDER BY 1,2;
SELECT * FROM cq_schema_migrations ORDER BY version;
COMMIT;
