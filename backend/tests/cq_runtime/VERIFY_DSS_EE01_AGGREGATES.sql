\set ON_ERROR_STOP on
BEGIN READ ONLY;
SELECT s.id,s.assessment_id,s.campaign_id,s.release_id,s.slot_id,s.question_version,s.cutoff,
 s.scope,s.status,s.q,s.s,s.a,s.v,s.metadata_json->>'rule' AS rule,s.fingerprint,s.rules_hash,s.source_hash,
 c.code,c.x,c.v AS denominator,c.percentage AS official_percentage,c.diagnostic_percentage,c.status AS category_status
FROM ee01_measurement_snapshots s JOIN ee01_category_cells c ON c.snapshot_id=s.id
JOIN cq_synthetic_import_records r ON r.table_name='ee01_measurement_snapshots' AND r.record_key->>'id'=s.id::text
WHERE r.run_id=:'run_id'::uuid ORDER BY s.id,c.code;
SELECT u.snapshot_id,u.session_id,u.render_id,u.answer_id,u.rejected_id,u.source_hash,u.source_json
FROM ee01_source_units u JOIN cq_synthetic_import_records r ON r.table_name='ee01_measurement_snapshots' AND r.record_key->>'id'=u.snapshot_id::text
WHERE r.run_id=:'run_id'::uuid ORDER BY u.snapshot_id,u.session_id;
SELECT e.snapshot_id,e.context_hash,e.context_json,e.status
FROM ee01_report_readbacks e JOIN cq_synthetic_import_records r ON r.table_name='ee01_measurement_snapshots' AND r.record_key->>'id'=e.snapshot_id::text
WHERE r.run_id=:'run_id'::uuid ORDER BY e.snapshot_id;
COMMIT;
