BEGIN;
DO $guard$
BEGIN
  IF current_setting('project1.m2_bcb_migration_target',true) IS DISTINCT FROM current_database()
     OR nullif(current_setting('project1.m2_bcb_migration_receipt',true),'') IS NULL THEN
    RAISE EXCEPTION 'Explicit target and migration receipt required';
  END IF;
END $guard$;
CREATE TABLE public.m2_candidate_review_assignments (
    candidate_id uuid NOT NULL REFERENCES public.m2_review_question_versions(id),
    reviewer_id uuid NOT NULL, authority_reference text NOT NULL CHECK(length(trim(authority_reference))>0),
    PRIMARY KEY(candidate_id,reviewer_id)
);
CREATE TABLE public.m2_candidate_owner_reviews (
    candidate_id uuid PRIMARY KEY, reviewer_id uuid NOT NULL,
    decision text NOT NULL CHECK(decision IN ('APPROVE_FOR_REVIEW','REJECT')),
    rationale text NOT NULL CHECK(length(trim(rationale)) BETWEEN 1 AND 1000),
    recorded_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY(candidate_id,reviewer_id) REFERENCES public.m2_candidate_review_assignments
);
ALTER TABLE public.m2_candidate_review_assignments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.m2_candidate_owner_reviews ENABLE ROW LEVEL SECURITY;
CREATE TRIGGER m2_owner_review_append_only BEFORE UPDATE OR DELETE ON public.m2_candidate_owner_reviews
    FOR EACH ROW EXECUTE FUNCTION public.m2_bcb_reject_mutation();
COMMIT;
