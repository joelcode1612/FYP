-- PRIVATE TEST REHEARSAL ONLY. Not approved or usable for original Dss.
-- Protects only m2_assessments; dependent policies and review writes remain open.
BEGIN;
DO $$ BEGIN
  IF current_database() <> 'project1_m2_bcb_test'
     OR current_setting('project1.identity_test_receipt', true) IS DISTINCT FROM 'PRIVATE-SYNTHETIC-ONLY' THEN
    RAISE EXCEPTION 'Private synthetic database and receipt required';
  END IF;
END $$;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE SCHEMA project1_identity;
REVOKE ALL ON SCHEMA project1_identity FROM PUBLIC;
CREATE TABLE project1_identity.private_key (id integer PRIMARY KEY CHECK (id=1), key bytea NOT NULL CHECK(octet_length(key)>=32));
REVOKE ALL ON project1_identity.private_key FROM PUBLIC, p1_m2_runtime;
CREATE FUNCTION project1_identity.verified_actor() RETURNS uuid
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE token text; pieces text[]; secret bytea; expected text;
BEGIN
  token := current_setting('project1.identity_assertion', true);
  IF token IS NULL OR length(token)>256 THEN RETURN NULL; END IF;
  pieces := string_to_array(token, '|');
  IF array_length(pieces,1)<>4 OR pieces[1] !~ '^[0-9a-f-]{36}$'
     OR pieces[2] !~ '^[0-9]{10}$' OR pieces[3] !~ '^[0-9a-f]{32}$'
     OR pieces[4] !~ '^[0-9a-f]{64}$' THEN RETURN NULL; END IF;
  IF pieces[2]::bigint <= extract(epoch FROM statement_timestamp())::bigint
     OR pieces[2]::bigint > extract(epoch FROM statement_timestamp())::bigint + 60 THEN RETURN NULL; END IF;
  SELECT k.key INTO secret FROM project1_identity.private_key k WHERE k.id=1;
  expected := encode(public.hmac(convert_to(pieces[1]||'|'||pieces[2]||'|'||pieces[3], 'UTF8'), secret, 'sha256'), 'hex');
  IF expected <> pieces[4] THEN RETURN NULL; END IF;
  RETURN pieces[1]::uuid;
EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION project1_identity.verified_actor() FROM PUBLIC;
GRANT USAGE ON SCHEMA project1_identity TO p1_m2_runtime;
GRANT EXECUTE ON FUNCTION project1_identity.verified_actor() TO p1_m2_runtime;
-- DD-021's registry RLS policy also calls verified_actor() and is read by
-- p1ai_runtime. EXECUTE is required even though the function is SECURITY
-- DEFINER; the private key itself remains revoked. Rehearsal proved that
-- without this grant the AI runtime gets "permission denied for function
-- verified_actor" when it merely SELECTs the registry.
GRANT USAGE ON SCHEMA project1_identity TO p1ai_runtime;
GRANT EXECUTE ON FUNCTION project1_identity.verified_actor() TO p1ai_runtime;
DROP POLICY owner_scope ON public.m2_assessments;
CREATE POLICY owner_scope ON public.m2_assessments
  USING (owner_user_id = project1_identity.verified_actor())
  WITH CHECK (owner_user_id = project1_identity.verified_actor());
COMMIT;
