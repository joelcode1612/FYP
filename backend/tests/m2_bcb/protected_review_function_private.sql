-- PRIVATE REHEARSAL ONLY. This function is not approved for deployment.
-- It returns only the review receipt; it never returns the confirmation body.
CREATE FUNCTION project1_identity.record_candidate_review(p_candidate uuid, p_decision text, p_rationale text)
RETURNS TABLE(candidate_id uuid,reviewer_id uuid,decision text,rationale text,context_hash text,recorded_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE actor uuid; owner_id uuid; snapshot_hash text;
BEGIN
  -- This rehearsal's owner-only projection trigger cannot safely commit a
  -- review from a different actor. Fail closed until reviewer-compatible
  -- audit/projection semantics have been independently designed and tested.
  actor := project1_identity.verified_actor();
  IF actor IS NULL OR p_decision NOT IN ('APPROVE_FOR_REVIEW','REJECT','REQUEST_REVISION')
     OR p_rationale IS NULL OR length(trim(p_rationale)) NOT BETWEEN 1 AND 1000 THEN RETURN; END IF;
  SELECT m.owner_user_id, c.snapshot_digest INTO owner_id,snapshot_hash
    FROM public.m2_review_question_versions q
    JOIN public.m2_confirmed_uncertainties u ON u.id=q.objective_id
    JOIN public.m2_confirmation_snapshots c ON c.id=u.confirmation_id
    JOIN public.m2_assessments m ON m.id=c.assessment_id
    WHERE q.id=p_candidate AND m.confirmed_revision=m.revision
      AND m.revision=c.assessment_revision
      AND NOT EXISTS (SELECT 1 FROM public.m2_review_question_versions n WHERE n.supersedes=q.id)
    FOR UPDATE OF m;
  IF owner_id IS NULL THEN RETURN; END IF;
  IF owner_id=actor THEN
    INSERT INTO public.m2_candidate_review_assignments(candidate_id,reviewer_id,authority_reference)
      VALUES(p_candidate,actor,'ASSESSMENT_OWNER') ON CONFLICT DO NOTHING;
  ELSIF NOT EXISTS (SELECT 1 FROM public.m2_candidate_review_assignments a
                    WHERE a.candidate_id=p_candidate AND a.reviewer_id=actor) THEN
    RETURN;
  END IF;
  RETURN QUERY INSERT INTO public.m2_candidate_owner_reviews AS r
    (candidate_id,reviewer_id,decision,rationale,context_hash)
    VALUES(p_candidate,actor,p_decision,p_rationale,snapshot_hash)
    ON CONFLICT ON CONSTRAINT m2_candidate_owner_reviews_pkey DO NOTHING
    RETURNING r.candidate_id,r.reviewer_id,r.decision::text,r.rationale::text,r.context_hash::text,r.recorded_at;
  -- In the private rehearsal the deferred audit trigger is owner-scoped. Run
  -- the existing trigger while the definer is active rather than letting a
  -- reviewer transaction silently skip the owner's projection refresh.
  SET CONSTRAINTS public.refresh_workflow IMMEDIATE;
END $$;
REVOKE ALL ON FUNCTION project1_identity.record_candidate_review(uuid,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION project1_identity.record_candidate_review(uuid,text,text) TO p1_m2_runtime;
