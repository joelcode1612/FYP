\set ON_ERROR_STOP on
-- Independent raw-CQ arithmetic oracle for the saved Q05 reference vector.
-- No ee01_source_units values or mutable cq_effective_answers are used.
-- Dependent-context invalidation is verified separately by application replay.
BEGIN READ ONLY;
SELECT set_config('project1.actor_id',:'actor_id',true);
\pset format unaligned
\pset tuples_only on
WITH bound AS (
 SELECT * FROM ee01_measurement_snapshots
 WHERE id=:'snapshot_id'::uuid AND assessment_id=:'assessment_id'::uuid
 AND campaign_id=:'campaign_id'::uuid AND slot_id='Q05'
), raw AS (
 SELECT b.id,b.q,b.s,b.a,b.v,s.respondent_user_id,
  (ctl.eligibility='ELIGIBLE' AND ctl.research_mode='CUSTOMER_DEMAND_SURVEY'
   AND ce.consented AND ce.version=ctl.source_json->>'consent_version') IS TRUE AS qualified,
  EXISTS(SELECT 1 FROM cq_render_events r WHERE r.session_id=s.id AND r.slot_id=b.slot_id AND r.created_at<=b.cutoff) AS shown,
  CASE WHEN b.metadata_json->>'rule'='CUST03_CURRENT_ATTEMPT_DIAGNOSTIC'
        AND rejected.id IS NOT NULL AND (accepted.id IS NULL OR rejected.revision>=accepted.revision)
   THEN CASE WHEN EXISTS(SELECT 1 FROM cq_render_events r WHERE r.display_id=rejected.display_id AND r.session_id=s.id AND r.created_at<=b.cutoff)
             THEN 'INVALID' ELSE 'SHOWN_NO_ANSWER' END
   WHEN accepted.id IS NOT NULL AND EXISTS(SELECT 1 FROM cq_render_events r WHERE r.display_id=accepted.display_id AND r.session_id=s.id AND r.created_at<=b.cutoff)
    THEN accepted.state ELSE 'SHOWN_NO_ANSWER' END AS selected_state,
  accepted.value_json
 FROM bound b JOIN cq_campaigns c ON c.id=b.campaign_id AND c.assessment_id=b.assessment_id AND c.owner_user_id=:'actor_id'::uuid
 JOIN cq_sessions s ON s.campaign_id=c.id AND s.release_id=b.release_id AND s.created_at<=b.cutoff
 LEFT JOIN cq_session_controls ctl ON ctl.session_id=s.id AND ctl.created_at<=b.cutoff
 LEFT JOIN LATERAL (SELECT * FROM cq_consent_events WHERE session_id=s.id AND created_at<=b.cutoff ORDER BY revision DESC LIMIT 1) ce ON true
 LEFT JOIN LATERAL (SELECT * FROM cq_answer_revisions WHERE session_id=s.id AND slot_id=b.slot_id AND created_at<=b.cutoff ORDER BY revision DESC LIMIT 1) accepted ON true
 LEFT JOIN LATERAL (SELECT * FROM cq_rejected_answer_events WHERE session_id=s.id AND slot_id=b.slot_id AND created_at<=b.cutoff ORDER BY revision DESC,created_at DESC,id LIMIT 1) rejected ON true
), counted AS (
 SELECT id,max(q) AS saved_q,max(s) AS saved_s,max(a) AS saved_a,max(v) AS saved_v,
 count(DISTINCT respondent_user_id) FILTER(WHERE qualified) AS q,
 count(DISTINCT respondent_user_id) FILTER(WHERE qualified AND shown) AS s,
 count(DISTINCT respondent_user_id) FILTER(WHERE qualified AND shown AND selected_state IN
 ('ANSWERED_SUBSTANTIVE','ANSWERED_NON_SUBSTANTIVE','REFUSED','INVALID')) AS a,
 count(DISTINCT respondent_user_id) FILTER(WHERE qualified AND shown AND selected_state='ANSWERED_SUBSTANTIVE') AS v,
 count(DISTINCT respondent_user_id) FILTER(WHERE qualified AND shown AND selected_state='ANSWERED_SUBSTANTIVE'
 AND value_json IN ('"PROB_YES"'::jsonb,'"DEF_YES"'::jsonb)) AS x
 FROM raw GROUP BY id
)
SELECT json_build_object('snapshot_id',id,'from_raw_CQ',json_build_object('Q',q,'S',s,'A',a,'V',v,'top_two_x',x),
 'diagnostic_percentage',CASE WHEN v>0 THEN round(100.0*x/v,6) ELSE NULL END,
 'matches_saved_counts',(q=saved_q AND s=saved_s AND a=saved_a AND v=saved_v),
 'basis','distinct respondent; cutoff consent/render/revision; Q05 reference scope only')
 FROM counted;
COMMIT;
