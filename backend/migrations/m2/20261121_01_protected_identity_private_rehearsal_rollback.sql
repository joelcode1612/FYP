-- PRIVATE TEST REHEARSAL ONLY. Restores insecure legacy policy only in throwaway DB.
BEGIN;
DO $$ BEGIN
  IF current_database() <> 'project1_m2_bcb_test'
     OR current_setting('project1.identity_test_receipt', true) IS DISTINCT FROM 'PRIVATE-SYNTHETIC-ONLY' THEN
    RAISE EXCEPTION 'Private synthetic database and receipt required';
  END IF;
END $$;
DROP POLICY owner_scope ON public.m2_assessments;
CREATE POLICY owner_scope ON public.m2_assessments
  USING (owner_user_id = nullif(current_setting('project1.actor_id', true), '')::uuid)
  WITH CHECK (owner_user_id = nullif(current_setting('project1.actor_id', true), '')::uuid);
DROP SCHEMA project1_identity CASCADE;
COMMIT;
