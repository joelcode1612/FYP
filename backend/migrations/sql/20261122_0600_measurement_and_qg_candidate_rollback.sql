-- Rollback for 20261122_0600_measurement_and_qg_candidate.
-- Order matters: candidates reference authorizations, authorizations reference
-- admissions. Only the four tables and two helper functions created by the
-- forward migration are removed; no existing row is touched.
BEGIN;
SET LOCAL lock_timeout = '5s';

DO $guard$
BEGIN
  IF current_database() IN ('Dss', 'dss', 'Final_Location_Analysis', 'sitesense', 'postgres') THEN
    RAISE EXCEPTION 'Refusing rollback on protected database %', current_database();
  END IF;
  IF inet_server_port() = 5432 THEN
    RAISE EXCEPTION 'Refusing rollback on the protected cluster (port 5432)';
  END IF;
END
$guard$;

DROP TABLE IF EXISTS public.m2_qg_candidates;
DROP TABLE IF EXISTS public.m2_qg_authorizations;
DROP TABLE IF EXISTS public.m2_measurement_decisions;
DROP TABLE IF EXISTS public.m2_measurement_specs;

DROP FUNCTION IF EXISTS public.m2_qg_authorization_guard();
DROP FUNCTION IF EXISTS public.m2_phase3b_reject_mutation();

COMMIT;
