\set ON_ERROR_STOP on
-- Scope variables: actor_id (campaign owner), assessment_id, campaign_id, session_id.
BEGIN READ ONLY;
SELECT current_database(),current_user,current_setting('transaction_read_only');
SELECT c.assessment_id,c.id AS campaign_id,s.id AS session_id,s.respondent_user_id,
 s.revision,s.state AS stored_state,
 CASE WHEN s.state='ACTIVE' AND l.action='PAUSE' THEN 'PAUSED' ELSE s.state END AS api_state,
 s.consented,ctl.eligibility AS independent_eligibility,ctl.research_mode,
 r.payload_json->>'disposition' AS receipt_area_disposition,
 r.id AS receipt_id,r.receipt_hash
 FROM cq_campaigns c JOIN cq_sessions s ON s.campaign_id=c.id
 LEFT JOIN cq_session_controls ctl ON ctl.session_id=s.id
 LEFT JOIN LATERAL (SELECT action FROM cq_lifecycle_events WHERE session_id=s.id ORDER BY revision DESC LIMIT 1) l ON true
 LEFT JOIN cq_submission_receipts r ON r.session_id=s.id
 WHERE c.owner_user_id=:'actor_id'::uuid AND c.assessment_id=:'assessment_id'::uuid
 AND c.id=:'campaign_id'::uuid AND s.id=:'session_id'::uuid;

SELECT a.question_id,a.slot_id,a.question_version,a.bank_version,
 e.state AS current_state,e.answer_event_id,e.revision AS projection_revision,
 v.revision AS selected_answer_revision,v.state AS answer_state,v.value_json,
 v.context_digest,v.display_id,
 (SELECT count(*) FROM cq_answer_revisions h WHERE h.session_id=s.id AND h.slot_id=a.slot_id) AS preserved_revisions,
 (SELECT count(*) FROM cq_render_events d WHERE d.session_id=s.id AND d.slot_id=a.slot_id) AS actual_render_acknowledgements
 FROM cq_campaigns c JOIN cq_sessions s ON s.campaign_id=c.id
 JOIN cq_question_assignments a ON a.release_id=s.release_id
 LEFT JOIN cq_effective_answers e ON e.session_id=s.id AND e.slot_id=a.slot_id
 LEFT JOIN cq_answer_revisions v ON v.id=e.answer_event_id AND v.session_id=s.id AND v.slot_id=a.slot_id
 WHERE c.owner_user_id=:'actor_id'::uuid AND c.assessment_id=:'assessment_id'::uuid
 AND c.id=:'campaign_id'::uuid AND s.id=:'session_id'::uuid
 ORDER BY a.question_id,a.slot_id;

SELECT v.id,v.slot_id,v.revision,v.state,v.value_json,v.display_id,v.context_digest,
 (v.id=e.answer_event_id) AS is_current_effective
 FROM cq_campaigns c JOIN cq_sessions s ON s.campaign_id=c.id
 JOIN cq_answer_revisions v ON v.session_id=s.id
 LEFT JOIN cq_effective_answers e ON e.session_id=s.id AND e.slot_id=v.slot_id
 WHERE c.owner_user_id=:'actor_id'::uuid AND c.assessment_id=:'assessment_id'::uuid
 AND c.id=:'campaign_id'::uuid AND s.id=:'session_id'::uuid ORDER BY v.revision;

SELECT d.revision,x->>'slot_id' AS slot_id,x->>'verdict' AS verdict,
 x->>'state' AS response_state,x->>'reason' AS reason,x->'facts' AS gate_facts
 FROM cq_campaigns c JOIN cq_sessions s ON s.campaign_id=c.id
 JOIN LATERAL (SELECT revision,decision_json FROM cq_routing_decisions WHERE session_id=s.id ORDER BY revision DESC LIMIT 1) d ON true
 CROSS JOIN LATERAL jsonb_array_elements(d.decision_json) x
 WHERE c.owner_user_id=:'actor_id'::uuid AND c.assessment_id=:'assessment_id'::uuid
 AND c.id=:'campaign_id'::uuid AND s.id=:'session_id'::uuid ORDER BY x->>'slot_id';
COMMIT;
