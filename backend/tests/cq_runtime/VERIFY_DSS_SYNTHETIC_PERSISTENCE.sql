\set ON_ERROR_STOP on
-- psql -v run_id=<exact import UUID> -f this_file.sql
BEGIN READ ONLY;
SELECT current_database() AS database,inet_server_addr() AS host,inet_server_port() AS port;
SELECT run_id,origin,effective_mode,consent_semantics,real_reportable,package_sha256,plan_sha256
FROM cq_synthetic_import_runs WHERE run_id=:'run_id'::uuid;
SELECT table_name,count(*) AS imported_rows FROM cq_synthetic_import_records
WHERE run_id=:'run_id'::uuid GROUP BY table_name ORDER BY table_name;
SELECT c.assessment_id,c.id AS campaign_id,count(s.id) AS sessions
FROM cq_campaigns c JOIN cq_sessions s ON s.campaign_id=c.id
JOIN cq_synthetic_import_records r ON r.table_name='cq_campaigns' AND r.record_key->>'id'=c.id::text
WHERE r.run_id=:'run_id'::uuid GROUP BY c.assessment_id,c.id;
SELECT s.id AS session_id,s.campaign_id,s.release_id,s.revision,s.state,ctl.research_mode,ctl.eligibility,
 CASE WHEN s.state='ACTIVE' AND (SELECT action FROM cq_lifecycle_events l WHERE l.session_id=s.id ORDER BY revision DESC LIMIT 1)='PAUSE'
 THEN 'PAUSED' ELSE s.state END AS persisted_status,
 (SELECT count(*) FROM cq_submission_receipts z WHERE z.session_id=s.id) AS submission_receipts,
 (SELECT count(*) FROM cq_answer_revisions z WHERE z.session_id=s.id) AS answer_revisions,
 (SELECT count(*) FROM cq_render_events z WHERE z.session_id=s.id) AS actual_render_events,
 (SELECT count(*) FROM cq_presentations z WHERE z.session_id=s.id) AS presentation_decisions
FROM cq_sessions s JOIN cq_session_controls ctl ON ctl.session_id=s.id
JOIN cq_synthetic_import_records r ON r.table_name='cq_sessions' AND r.record_key->>'id'=s.id::text
WHERE r.run_id=:'run_id'::uuid ORDER BY s.id;
SELECT e.session_id,e.slot_id,e.state,e.revision,e.answer_event_id,a.revision AS accepted_revision,a.value_json,a.context_digest
FROM cq_effective_answers e LEFT JOIN cq_answer_revisions a ON a.id=e.answer_event_id
JOIN cq_synthetic_import_records r ON r.table_name='cq_sessions' AND r.record_key->>'id'=e.session_id::text
WHERE r.run_id=:'run_id'::uuid ORDER BY e.session_id,e.slot_id;
SELECT a.session_id,a.slot_id,a.id,a.revision,a.state,a.value_json,a.display_id,a.context_digest
FROM cq_answer_revisions a JOIN cq_synthetic_import_records r ON r.table_name='cq_sessions' AND r.record_key->>'id'=a.session_id::text
WHERE r.run_id=:'run_id'::uuid ORDER BY a.session_id,a.revision;
-- Both must be zero. Synthetic profiles must never become login accounts.
SELECT count(*) AS login_enabled_test_profiles FROM users u JOIN cq_synthetic_import_records r
 ON r.table_name='users' AND r.record_key->>'user_id'=u.user_id::text
WHERE r.run_id=:'run_id'::uuid AND (u.account_status<>'suspended' OR u.email_verified);
SELECT count(*) AS synthetic_customer_demand_controls FROM cq_session_controls c JOIN cq_synthetic_import_records r
 ON r.table_name='cq_sessions' AND r.record_key->>'id'=c.session_id::text
WHERE r.run_id=:'run_id'::uuid AND c.research_mode='CUSTOMER_DEMAND_SURVEY';
COMMIT;
