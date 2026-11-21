BEGIN;
SET LOCAL lock_timeout='5s';
DO $$ BEGIN
 IF current_setting('project1.m2_bcb_migration_target',true) IS DISTINCT FROM current_database()
 OR nullif(current_setting('project1.m2_bcb_migration_receipt',true),'') IS NULL THEN
 RAISE EXCEPTION 'Explicit migration target and receipt required'; END IF;
END $$;
CREATE TABLE public.assessment_workflow_projection (
 projection_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 assessment_id uuid NOT NULL, owner_user_id uuid NOT NULL,
 assessment_revision integer NOT NULL CHECK(assessment_revision>=0),
 projection_sequence bigint NOT NULL CHECK(projection_sequence>0),
 schema_version text NOT NULL DEFAULT 'workflow-overview/1',
 source_fingerprint text NOT NULL CHECK(length(source_fingerprint)=64),
 projection_data jsonb NOT NULL, created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 FOREIGN KEY(assessment_id,owner_user_id) REFERENCES public.m2_assessments(id,owner_user_id),
 UNIQUE(assessment_id,projection_sequence)
);
ALTER TABLE public.assessment_workflow_projection ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.assessment_workflow_projection FROM PUBLIC;
CREATE TRIGGER immutable_projection BEFORE UPDATE OR DELETE ON public.assessment_workflow_projection
 FOR EACH ROW EXECUTE FUNCTION public.m2_bcb_reject_mutation();

-- Optional CQ bridge replaces this empty view once both schemas exist.
CREATE VIEW public.m2_workflow_campaigns WITH (security_invoker=true) AS
 SELECT NULL::uuid AS assessment_id,NULL::uuid AS owner_user_id,NULL::jsonb AS campaigns WHERE false;

CREATE VIEW public.m2_workflow_summary WITH (security_invoker=true) AS
SELECT a.id AS assessment_id,a.owner_user_id,a.revision,
 jsonb_build_object('assessment',jsonb_build_object('id',a.id,'revision',a.revision,'confirmed_revision',a.confirmed_revision,'instrument_version',i.version_tag),
 'review_events',coalesce((SELECT jsonb_agg(jsonb_build_object('id',v.id,'revision',v.assessment_revision) ORDER BY v.created_at,v.id) FROM public.m2_review_events v WHERE v.assessment_id=a.id),'[]'),
 'clarifications',coalesce((SELECT jsonb_agg(jsonb_build_object('id',v.id,'revision',v.assessment_revision,'finding',v.finding_id,'decision',v.decision,'sequence',v.event_sequence) ORDER BY v.assessment_revision,v.event_sequence) FROM public.m2_clarification_events v WHERE v.assessment_id=a.id),'[]'),
 'confirmations',coalesce((SELECT jsonb_agg(jsonb_build_object('id',c.id,'revision',c.assessment_revision,'digest',c.snapshot_digest) ORDER BY c.id)
 FROM public.m2_confirmation_snapshots c WHERE c.assessment_id=a.id),'[]'),
 'contexts',coalesce((SELECT jsonb_agg(jsonb_build_object('id',b.context_id,'revision',b.assessment_revision,'hash',b.packet_hash,'status',b.lifecycle_status,'attributes',b.packet_json#>'{business_description,source_question_ids}') ORDER BY b.context_id)
 FROM public.m2_business_contexts b WHERE b.assessment_id=a.id),'[]'),
 'builds',coalesce((SELECT jsonb_agg(jsonb_build_object('confirmation',b.confirmation_id,'revision',b.assessment_revision,'status',b.status,'reason',b.last_code,'attempts',b.attempt_count) ORDER BY b.confirmation_id)
 FROM public.m2_business_context_builds b WHERE b.assessment_id=a.id),'[]'),
 'bdj_evaluations',coalesce((SELECT jsonb_agg(jsonb_build_object('id',e.id,'revision',e.assessment_revision,'rule_version',e.evaluator_version) ORDER BY e.id) FROM public.m2_bdj_evaluations e WHERE e.assessment_id=a.id),'[]'),
 'findings',coalesce((SELECT jsonb_agg(jsonb_build_object('id',f.id,'revision',f.assessment_revision,'type',f.issue_type,'decision',f.review_state,'sources',f.source_answer_ids) ORDER BY f.id) FROM public.m2_bdj_findings f WHERE f.assessment_id=a.id),'[]'),
 'objectives',coalesce((SELECT jsonb_agg(jsonb_build_object('id',u.id,'revision',c.assessment_revision,'confirmation',c.id,'origin',s.provenance->>'origin','parent',s.provenance->>'parent_objective_id','exploration_used',s.provenance->'exploration_used','limitation_recorded',l.objective_id IS NOT NULL,'child',r.child_id) ORDER BY u.id)
 FROM public.m2_confirmation_snapshots c JOIN public.m2_confirmed_uncertainties u ON u.confirmation_id=c.id JOIN public.m2_research_objective_sources s ON s.objective_id=u.id LEFT JOIN public.m2_research_clarifications l ON l.objective_id=u.id LEFT JOIN public.m2_research_revisions r ON r.parent_id=u.id WHERE c.assessment_id=a.id),'[]'),
 'candidates',coalesce((SELECT jsonb_agg(jsonb_build_object('id',q.id,'objective',u.id,'revision',c.assessment_revision,'supersedes',q.supersedes,'desired_option',d.option_code,
 'qj_route',receipt.data#>>'{evaluation,qj,route}','bank_outcome',receipt.data#>>'{evaluation,bank}',
 'candidate_decision',receipt.data#>>'{evaluation,qg,decision}','source_version',receipt.data#>>'{candidate,source_version}','owner_decision',v.decision,'decision_time',to_char(v.recorded_at AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"')) ORDER BY q.id)
 FROM public.m2_confirmation_snapshots c JOIN public.m2_confirmed_uncertainties u ON u.confirmation_id=c.id JOIN public.m2_review_question_versions q ON q.objective_id=u.id CROSS JOIN LATERAL (SELECT CASE WHEN q.source_receipt IS JSON OBJECT THEN q.source_receipt::jsonb END AS data) receipt LEFT JOIN public.m2_desired_options d ON d.question_version=q.id LEFT JOIN public.m2_candidate_owner_reviews v ON v.candidate_id=q.id WHERE c.assessment_id=a.id),'[]'),
 'campaigns',(SELECT cq.campaigns FROM public.m2_workflow_campaigns cq WHERE cq.assessment_id=a.id AND cq.owner_user_id=a.owner_user_id),
 'llm_execution','NOT_VERIFIED','scientific_review','NOT_VERIFIED','fielding','NOT_VERIFIED','report_admission','NOT_VERIFIED') AS summary
FROM public.m2_assessments a JOIN public.m2_instrument_versions i ON i.id=a.instrument_id;

CREATE FUNCTION public.refresh_m2_workflow(aid uuid) RETURNS void LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
DECLARE s record; prev record; fingerprint text;
BEGIN
 PERFORM 1 FROM public.m2_assessments WHERE id=aid FOR UPDATE;
 SELECT * INTO s FROM public.m2_workflow_summary WHERE assessment_id=aid;
 IF NOT FOUND THEN RETURN; END IF;
 fingerprint:=encode(sha256(convert_to(s.summary::text,'UTF8')),'hex');
 SELECT projection_sequence,source_fingerprint INTO prev FROM public.assessment_workflow_projection
 WHERE assessment_id=aid ORDER BY projection_sequence DESC LIMIT 1;
 IF prev.source_fingerprint IS DISTINCT FROM fingerprint THEN
 INSERT INTO public.assessment_workflow_projection(assessment_id,owner_user_id,assessment_revision,projection_sequence,source_fingerprint,projection_data)
 VALUES(aid,s.owner_user_id,s.revision,coalesce(prev.projection_sequence,0)+1,fingerprint,s.summary);
 END IF;
END $$;
CREATE FUNCTION public.m2_workflow_change() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
DECLARE rowdata jsonb; aid uuid; uid uuid;
BEGIN
 rowdata:=CASE WHEN TG_OP='DELETE' THEN to_jsonb(OLD) ELSE to_jsonb(NEW) END;
 IF TG_TABLE_NAME='m2_assessments' THEN aid:=(rowdata->>'id')::uuid;
 ELSIF rowdata ? 'assessment_id' THEN aid:=(rowdata->>'assessment_id')::uuid;
 ELSE
 uid:=coalesce(rowdata->>'objective_id',rowdata->>'parent_id')::uuid;
 IF uid IS NULL THEN SELECT objective_id INTO uid FROM public.m2_review_question_versions WHERE id=coalesce(rowdata->>'candidate_id',rowdata->>'question_version')::uuid; END IF;
 SELECT c.assessment_id INTO aid FROM public.m2_confirmed_uncertainties u JOIN public.m2_confirmation_snapshots c ON c.id=u.confirmation_id WHERE u.id=uid;
 END IF;
 PERFORM public.refresh_m2_workflow(aid);
 RETURN NULL;
END $$;
DO $$ DECLARE t text; BEGIN
 FOREACH t IN ARRAY ARRAY['m2_assessments','m2_review_events','m2_clarification_events','m2_confirmation_snapshots','m2_business_contexts','m2_business_context_builds','m2_bdj_evaluations','m2_bdj_findings','m2_research_objective_sources','m2_research_clarifications','m2_research_revisions','m2_review_question_versions','m2_desired_options','m2_candidate_owner_reviews'] LOOP
 EXECUTE format('CREATE CONSTRAINT TRIGGER refresh_workflow AFTER INSERT OR UPDATE OR DELETE ON public.%I DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.m2_workflow_change()',t);
 END LOOP;
END $$;
SELECT public.refresh_m2_workflow(id) FROM public.m2_assessments ORDER BY id;
REVOKE ALL ON FUNCTION public.refresh_m2_workflow(uuid),public.m2_workflow_change() FROM PUBLIC;
COMMIT;
