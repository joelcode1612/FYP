-- PRIVATE TEST FIXTURE ONLY: owner-review policy candidate, no assigned-reviewer support.
-- Depends on the private identity rehearsal and is not a deployable migration.
DROP POLICY owner_scope ON public.assessment_workflow_projection;
CREATE POLICY owner_scope ON public.assessment_workflow_projection
  USING (owner_user_id=project1_identity.verified_actor())
  WITH CHECK (owner_user_id=project1_identity.verified_actor());
DROP POLICY owner_scope ON public.m2_business_contexts;
CREATE POLICY owner_scope ON public.m2_business_contexts
  USING (owner_user_id=project1_identity.verified_actor())
  WITH CHECK (owner_user_id=project1_identity.verified_actor());
DROP POLICY owner_scope ON public.m2_business_context_builds;
CREATE POLICY owner_scope ON public.m2_business_context_builds
  USING (owner_user_id=project1_identity.verified_actor())
  WITH CHECK (owner_user_id=project1_identity.verified_actor());
-- Assignment/review writes are only through the narrow definer function.
-- No direct assignment or review INSERT privilege is granted to the runtime.
