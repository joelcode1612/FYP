BEGIN;
SET LOCAL lock_timeout = '5s';
DO $guard$
BEGIN
  IF current_setting('project1.m2_bcb_migration_target', true) IS DISTINCT FROM current_database()
     OR nullif(current_setting('project1.m2_bcb_migration_receipt', true), '') IS NULL THEN
    RAISE EXCEPTION 'Explicit target and migration receipt required';
  END IF;
END
$guard$;
CREATE TABLE public.m2_research_objective_sources (
    objective_id uuid PRIMARY KEY REFERENCES public.m2_confirmed_uncertainties(id),
    provenance jsonb NOT NULL CHECK (jsonb_typeof(provenance) = 'object')
);
ALTER TABLE public.m2_research_objective_sources ENABLE ROW LEVEL SECURITY;
CREATE TRIGGER m2_objective_source_append_only BEFORE UPDATE OR DELETE ON public.m2_research_objective_sources
    FOR EACH ROW EXECUTE FUNCTION public.m2_bcb_reject_mutation();
REVOKE ALL ON public.m2_research_objective_sources FROM PUBLIC;
CREATE TABLE public.m2_research_clarifications (
    objective_id uuid PRIMARY KEY REFERENCES public.m2_research_objective_sources(objective_id),
    limitation text NOT NULL CHECK (length(trim(limitation)) > 0),
    broader_objective text CHECK (length(trim(broader_objective)) BETWEEN 1 AND 1000)
);
CREATE TABLE public.m2_research_revisions (
    parent_id uuid PRIMARY KEY REFERENCES public.m2_research_clarifications(objective_id),
    child_id uuid UNIQUE NOT NULL REFERENCES public.m2_research_objective_sources(objective_id),
    action text NOT NULL CHECK (action IN ('CLARIFY','EXPLORE'))
);
ALTER TABLE public.m2_research_clarifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.m2_research_revisions ENABLE ROW LEVEL SECURITY;
CREATE TRIGGER m2_clarification_append_only BEFORE UPDATE OR DELETE ON public.m2_research_clarifications
    FOR EACH ROW EXECUTE FUNCTION public.m2_bcb_reject_mutation();
CREATE TRIGGER m2_revision_append_only BEFORE UPDATE OR DELETE ON public.m2_research_revisions
    FOR EACH ROW EXECUTE FUNCTION public.m2_bcb_reject_mutation();
CREATE TABLE public.m2_review_question_versions (
    id uuid PRIMARY KEY, objective_id uuid NOT NULL REFERENCES public.m2_research_objective_sources(objective_id),
    source_receipt text NOT NULL, question text NOT NULL, options jsonb NOT NULL,
    supersedes uuid UNIQUE REFERENCES public.m2_review_question_versions(id)
);
CREATE TABLE public.m2_desired_options (
    question_version uuid PRIMARY KEY REFERENCES public.m2_review_question_versions(id),
    actor_id uuid NOT NULL, option_code text NOT NULL
);
ALTER TABLE public.m2_review_question_versions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.m2_desired_options ENABLE ROW LEVEL SECURITY;
CREATE TRIGGER m2_question_version_append_only BEFORE UPDATE OR DELETE ON public.m2_review_question_versions
    FOR EACH ROW EXECUTE FUNCTION public.m2_bcb_reject_mutation();
COMMIT;
