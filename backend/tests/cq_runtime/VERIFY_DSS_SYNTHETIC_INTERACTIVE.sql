\set ON_ERROR_STOP on
BEGIN READ ONLY;
SELECT x.case_key,x.scenario,x.source_sha256,x.origin,x.real_reportable,
 s.id AS session_id,s.campaign_id,s.release_id,s.respondent_user_id,s.revision,s.state AS submission_record_status,
 COALESCE(e.lifecycle_status,CASE WHEN x.scenario='UNRESOLVED' THEN 'UNRESOLVED' ELSE 'IN_PROGRESS' END) AS lifecycle_status,
 e.developer_user_id,e.operation,e.snapshot_sha256,
 (SELECT count(*) FROM cq_submission_receipts r WHERE r.session_id=s.id) AS receipt_count,
 (SELECT count(*) FROM cq_answer_revisions r WHERE r.session_id=s.id) AS accepted_revisions,
 (SELECT count(*) FROM cq_render_events r WHERE r.session_id=s.id) AS actual_shown_events,
 ctl.research_mode,ctl.eligibility,u.account_status,u.email_verified
FROM cq_synthetic_cases x JOIN cq_sessions s ON s.id=x.session_id
JOIN cq_session_controls ctl ON ctl.session_id=s.id JOIN users u ON u.user_id=s.respondent_user_id
LEFT JOIN LATERAL(SELECT * FROM cq_synthetic_execution_events z WHERE z.session_id=s.id ORDER BY revision DESC,created_at DESC,id DESC LIMIT 1)e ON true
WHERE x.run_id=:'run_id'::uuid ORDER BY x.case_key;
SELECT x.case_key,a.id,a.slot_id,qa.question_version,a.revision,a.state,a.value_json,a.display_id,a.context_digest,
 EXISTS(SELECT 1 FROM cq_render_events r WHERE r.session_id=a.session_id AND r.display_id=a.display_id) AS actual_render_ack
FROM cq_synthetic_cases x JOIN cq_sessions s ON s.id=x.session_id JOIN cq_answer_revisions a ON a.session_id=s.id
JOIN cq_question_assignments qa ON qa.release_id=s.release_id AND qa.slot_id=a.slot_id
WHERE x.run_id=:'run_id'::uuid ORDER BY x.case_key,a.revision;
SELECT x.case_key,e.slot_id,e.state,e.answer_event_id,e.revision,a.value_json,a.revision AS accepted_revision
FROM cq_synthetic_cases x JOIN cq_effective_answers e ON e.session_id=x.session_id
LEFT JOIN cq_answer_revisions a ON a.id=e.answer_event_id
WHERE x.run_id=:'run_id'::uuid ORDER BY x.case_key,e.slot_id;
SELECT e.id,e.session_id,e.developer_user_id,e.operation,e.revision,e.lifecycle_status,e.snapshot_sha256,e.created_at
FROM cq_synthetic_execution_events e WHERE e.run_id=:'run_id'::uuid ORDER BY e.created_at,e.id;
SELECT m.id,m.campaign_id,m.cutoff,m.q,m.s,m.a,m.v,m.scope,m.status,m.fingerprint,m.source_hash,
 m.metadata_json->>'rule' AS rule,c.code,c.x,c.v AS denominator,c.percentage AS official_percentage,c.diagnostic_percentage
FROM ee01_measurement_snapshots m JOIN ee01_category_cells c ON c.snapshot_id=m.id
WHERE m.metadata_json->>'synthetic_run_id'=:'run_id' ORDER BY m.created_at,m.id,c.code;
COMMIT;
