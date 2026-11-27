-- Owner's Intended Option: the minimum schema extension the review contract needs.
--
-- Why this is a new column rather than a new table
-- ------------------------------------------------
-- The owner's intention is a property of *the review*, not an independent
-- record with its own lifecycle. It is decided at the same moment as the
-- decision, refused by the same predicates, and read by the same projection, so
-- putting it anywhere but on ``m2_qg_candidate_reviews`` would create two rows
-- that could disagree about one act and would make "approval and intention are
-- persisted atomically" impossible to guarantee without a transaction that spans
-- both.
--
-- Why an array, when ``expected_option_code`` already exists
-- ---------------------------------------------------------
-- The single column can hold one code. A ``MULTIPLE_CHOICE`` question admits
-- several selections, so a single column cannot state the owner's intention for
-- it: the record would either truncate the intention to its first value or
-- refuse to represent it at all. DD-031 recorded that limitation and deferred
-- it; this migration is the widening.
--
-- ``expected_option_code`` is **kept and kept in sync** for single-selection
-- formats, because existing readers use it and a migration that silently
-- orphaned them would make historical rows unreadable. For a multiple-choice
-- question the singular column stays NULL rather than holding an arbitrary
-- first element, and the constraint below makes that the only consistent state.
--
-- What is deliberately not added
-- ------------------------------
-- No ``assessment_id``, ``assessment_revision`` or ``objective_id`` duplicate:
-- ``candidate_id`` is a foreign key to ``m2_qg_candidates``, and a candidate row
-- is raised against exactly one assessment revision and one objective and is
-- never mutated to another. The relationship is therefore already pinned by the
-- foreign key, and copying it here would create a second copy that could drift
-- from the first. §11 asks to reuse existing foreign keys; this does.

ALTER TABLE public.m2_qg_candidate_reviews
    ADD COLUMN IF NOT EXISTS expected_option_codes text[];

COMMENT ON COLUMN public.m2_qg_candidate_reviews.expected_option_codes IS
    'The owner''s intended response option codes for this candidate. '
    'Entrepreneur-declared research context only: never a respondent answer, '
    'never written to a customer-response table, never read by a CQ or EE-01 '
    'calculation, never disclosed to a respondent. NULL means none recorded.';

-- "No selection" and "an empty selection" are the same statement. Storing both
-- would let a reader see a non-NULL array and conclude an intention exists.
ALTER TABLE public.m2_qg_candidate_reviews
    ADD CONSTRAINT m2_qg_candidate_reviews_expected_codes_shape
    CHECK (expected_option_codes IS NULL OR cardinality(expected_option_codes) >= 1);

-- A blank code can never be a real option code, and an array containing one
-- would pass a length test while pointing at nothing.
ALTER TABLE public.m2_qg_candidate_reviews
    ADD CONSTRAINT m2_qg_candidate_reviews_expected_codes_no_blank
    CHECK (expected_option_codes IS NULL
           OR NOT ('' = ANY (expected_option_codes)));

-- A code cannot be selected twice: a set with a repeat is not a selection.
--
-- A CHECK may not contain a subquery, so the count is taken by an immutable
-- helper. ``STRICT`` makes it return NULL for a NULL array, and a NULL CHECK
-- result is treated as satisfied, which is the behaviour wanted here.
CREATE OR REPLACE FUNCTION public.m2_qg_distinct_count(text[])
RETURNS int
LANGUAGE sql
IMMUTABLE
STRICT
AS $$ SELECT count(DISTINCT element)::int FROM unnest($1) AS element $$;

ALTER TABLE public.m2_qg_candidate_reviews
    ADD CONSTRAINT m2_qg_candidate_reviews_expected_codes_distinct
    CHECK (expected_option_codes IS NULL
           OR cardinality(expected_option_codes)
              = public.m2_qg_distinct_count(expected_option_codes));

-- The two representations must not disagree. Single-selection formats write
-- both and they are equal; multiple-choice writes only the array.
ALTER TABLE public.m2_qg_candidate_reviews
    ADD CONSTRAINT m2_qg_candidate_reviews_expected_codes_single
    CHECK (expected_option_code IS NULL
           OR expected_option_codes IS NULL
           OR expected_option_code = expected_option_codes[1]);

-- Backfill, before the trigger exists.
--
-- Without this, every already-approved row would carry NULL in the new array
-- while holding a valid singular code, and the trigger below fires on UPDATE as
-- well as INSERT. The first unrelated edit to such a row — a rationale change,
-- a decision re-record — would be refused with QG_OWNER_INTENTION_REQUIRED,
-- because the trigger cannot tell "the intention was never recorded" from "the
-- intention is recorded in the column this migration widened". That would make
-- historical rows effectively immutable and would look like data corruption.
--
-- The singular value is the authoritative statement for a single-selection
-- format, so copying it into the array states the same fact once more rather
-- than inventing one. Rows where the singular column is NULL are deliberately
-- left NULL: no intention was recorded, and this migration must not manufacture
-- one.
UPDATE public.m2_qg_candidate_reviews
   SET expected_option_codes = ARRAY[expected_option_code]
 WHERE decision = 'APPROVE_FOR_REVIEW'
   AND expected_option_code IS NOT NULL
   AND expected_option_codes IS NULL;

-- An approval without a recorded intention must not be storable at all.
--
-- This is a trigger rather than a CHECK because the requirement is conditional
-- on the *candidate's* response format, which lives on another table, and a
-- CHECK cannot read it. The rule could live only in the application, but then
-- "an approved Section B question must not exist without a valid owner
-- intention" would be a claim about one code path rather than about the data.
--
-- Historical rows are untouched: a trigger fires on write, not on read.
CREATE OR REPLACE FUNCTION public.m2_qg_review_requires_intention()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    candidate_format text;
BEGIN
    IF NEW.decision IS DISTINCT FROM 'APPROVE_FOR_REVIEW' THEN
        RETURN NEW;
    END IF;

    SELECT c.response_format
      INTO candidate_format
      FROM public.m2_qg_candidates c
     WHERE c.candidate_id = NEW.candidate_id;

    -- No candidate row: the foreign key will refuse this write with a clearer
    -- error than this function could.
    IF candidate_format IS NULL THEN
        RETURN NEW;
    END IF;

    IF NEW.expected_option_codes IS NULL
       OR cardinality(NEW.expected_option_codes) = 0 THEN
        RAISE EXCEPTION
            'QG_OWNER_INTENTION_REQUIRED: an approved question must record the '
            'owner''s intended option (candidate %, format %)',
            NEW.candidate_id, candidate_format
            USING ERRCODE = '23514';
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS m2_qg_review_requires_intention_trg
    ON public.m2_qg_candidate_reviews;

CREATE TRIGGER m2_qg_review_requires_intention_trg
    BEFORE INSERT OR UPDATE ON public.m2_qg_candidate_reviews
    FOR EACH ROW
    EXECUTE FUNCTION public.m2_qg_review_requires_intention();
