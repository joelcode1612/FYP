-- LOCAL ONLY: Final_Location_Analysis. Run as the application's DB owner.
BEGIN;
DO $$ BEGIN
 IF current_database() <> 'Final_Location_Analysis' THEN
   RAISE EXCEPTION 'Run this migration on Final_Location_Analysis';
 END IF;
 IF to_regclass('public.agent_listing_assignment') IS NULL THEN
   RAISE EXCEPTION 'Existing local assignment table is required';
 END IF;
END $$;
ALTER TABLE public.agent_listing_assignment
 ADD COLUMN IF NOT EXISTS workflow_status text DEFAULT 'requested',
 ADD COLUMN IF NOT EXISTS requested_at timestamptz DEFAULT now(),
 ADD COLUMN IF NOT EXISTS responded_at timestamptz,
 ADD COLUMN IF NOT EXISTS inspection_data jsonb DEFAULT '{}'::jsonb,
 ADD COLUMN IF NOT EXISTS inspection_updated_at timestamptz,
 ADD COLUMN IF NOT EXISTS panorama_id uuid,
 ADD COLUMN IF NOT EXISTS panorama_tour_id uuid,
 ADD COLUMN IF NOT EXISTS panorama_job_id text,
 ADD COLUMN IF NOT EXISTS panorama_uploaded_at timestamptz,
 ADD COLUMN IF NOT EXISTS submitted_at timestamptz,
 ADD COLUMN IF NOT EXISTS decline_reason text;
CREATE SCHEMA IF NOT EXISTS sitewise_sync;
CREATE SEQUENCE IF NOT EXISTS sitewise_sync.assignment_revision AS bigint;
CREATE TABLE IF NOT EXISTS sitewise_sync.assignment_outbox (
 listing_id bigint PRIMARY KEY,
 revision bigint NOT NULL,
 operation text NOT NULL CHECK (operation IN ('upsert','delete')),
 snapshot jsonb,
 attempts integer NOT NULL DEFAULT 0,
 next_attempt_at timestamptz NOT NULL DEFAULT now(),
 synced_at timestamptz,
 last_error text,
 changed_at timestamptz NOT NULL DEFAULT now(),
 CHECK ((operation='delete' AND snapshot IS NULL) OR (operation='upsert' AND snapshot IS NOT NULL))
);
CREATE INDEX IF NOT EXISTS assignment_outbox_pending_idx
 ON sitewise_sync.assignment_outbox(next_attempt_at) WHERE synced_at IS NULL;
CREATE OR REPLACE FUNCTION sitewise_sync.enqueue_assignment(p_id bigint, p_operation text, p_snapshot jsonb)
RETURNS void LANGUAGE sql SET search_path=pg_catalog,sitewise_sync AS $$
 INSERT INTO sitewise_sync.assignment_outbox(listing_id,revision,operation,snapshot)
 VALUES (p_id,nextval('sitewise_sync.assignment_revision'),p_operation,p_snapshot)
 ON CONFLICT(listing_id) DO UPDATE SET revision=excluded.revision,
 operation=excluded.operation,snapshot=excluded.snapshot,attempts=0,
 next_attempt_at=now(),synced_at=NULL,last_error=NULL,changed_at=now();
$$;
CREATE OR REPLACE FUNCTION sitewise_sync.capture_assignment_change()
RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,sitewise_sync AS $$
BEGIN
 IF TG_OP='DELETE' THEN
   PERFORM sitewise_sync.enqueue_assignment(OLD.listing_id,'delete',NULL);
   RETURN OLD;
 END IF;
 IF TG_OP='UPDATE' THEN
   IF OLD.listing_id <> NEW.listing_id THEN
     PERFORM sitewise_sync.enqueue_assignment(OLD.listing_id,'delete',NULL);
   END IF;
 END IF;
 PERFORM sitewise_sync.enqueue_assignment(NEW.listing_id,'upsert',to_jsonb(NEW));
 RETURN NEW;
END $$;
LOCK TABLE public.agent_listing_assignment IN SHARE ROW EXCLUSIVE MODE;
DROP TRIGGER IF EXISTS sitewise_assignment_sync ON public.agent_listing_assignment;
CREATE TRIGGER sitewise_assignment_sync AFTER INSERT OR UPDATE OR DELETE
 ON public.agent_listing_assignment FOR EACH ROW EXECUTE FUNCTION sitewise_sync.capture_assignment_change();
-- Seed existing records once; never reset a newer pending event on rerun.
INSERT INTO sitewise_sync.assignment_outbox(listing_id,revision,operation,snapshot)
 SELECT a.listing_id,nextval('sitewise_sync.assignment_revision'),'upsert',to_jsonb(a)
 FROM public.agent_listing_assignment a ON CONFLICT(listing_id) DO NOTHING;
COMMIT;
