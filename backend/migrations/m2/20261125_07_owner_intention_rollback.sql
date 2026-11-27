-- Rollback for 20261125_07_owner_intention.
--
-- Drops the trigger first, then the constraints, then the helper, then the
-- column. Dropping the column last means a partial rollback never leaves a
-- constraint referring to a column that is gone.
--
-- This discards recorded owner intentions. It exists so a deployment can be
-- reversed during development; it must not be run against a database whose
-- intentions are the evidence for a published questionnaire.

DROP TRIGGER IF EXISTS m2_qg_review_requires_intention_trg
    ON public.m2_qg_candidate_reviews;

DROP FUNCTION IF EXISTS public.m2_qg_review_requires_intention();

ALTER TABLE public.m2_qg_candidate_reviews
    DROP CONSTRAINT IF EXISTS m2_qg_candidate_reviews_expected_codes_single;

ALTER TABLE public.m2_qg_candidate_reviews
    DROP CONSTRAINT IF EXISTS m2_qg_candidate_reviews_expected_codes_distinct;

ALTER TABLE public.m2_qg_candidate_reviews
    DROP CONSTRAINT IF EXISTS m2_qg_candidate_reviews_expected_codes_no_blank;

ALTER TABLE public.m2_qg_candidate_reviews
    DROP CONSTRAINT IF EXISTS m2_qg_candidate_reviews_expected_codes_shape;

ALTER TABLE public.m2_qg_candidate_reviews
    DROP COLUMN IF EXISTS expected_option_codes;

DROP FUNCTION IF EXISTS public.m2_qg_distinct_count(text[]);
