-- Source-bank storage only. Does not create a release, campaign or session.
-- Transaction/target/receipt are supplied by register_cq_source_bank.py.
DO $$ BEGIN
 IF current_setting('project1.cq_source_bank_target',true) IS DISTINCT FROM current_database()
    OR nullif(current_setting('project1.cq_source_bank_receipt',true),'') IS NULL THEN
   RAISE EXCEPTION 'Explicit source-bank target and storage authorization required';
 END IF;
END $$;
CREATE TABLE public.cq_bank_versions (
 version varchar(100) PRIMARY KEY,
 content_hash varchar(64) NOT NULL CHECK(content_hash ~ '^[0-9a-f]{64}$'),
 questions_json jsonb NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE FUNCTION public.cq_source_bank_immutable_record() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
 RAISE EXCEPTION 'Versioned CQ source banks are append-only' USING ERRCODE='55000';
END $$;
CREATE TRIGGER cq_source_bank_append_only BEFORE UPDATE OR DELETE ON public.cq_bank_versions
FOR EACH ROW EXECUTE FUNCTION public.cq_source_bank_immutable_record();
ALTER TABLE public.cq_bank_versions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.cq_bank_versions FROM PUBLIC;
REVOKE ALL ON FUNCTION public.cq_source_bank_immutable_record() FROM PUBLIC;
