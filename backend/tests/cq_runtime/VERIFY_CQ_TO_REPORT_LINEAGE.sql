\set ON_ERROR_STOP on
BEGIN READ ONLY;
SELECT set_config('project1.actor_id', :'actor_id',true);
SELECT s.id AS snapshot_id,s.assessment_id,s.campaign_id,u.session_id,u.render_id,r.display_id,
 u.answer_id,a.revision,a.state,a.value_json,u.rejected_id,i.reason,u.source_hash,
 b.id AS readback_id,b.context_hash,b.context_json,b.status,
 'A10_ADAPTER_UNVERIFIED / REPORT_ADMISSION_REQUIRED' AS remaining_gate
 FROM ee01_measurement_snapshots s JOIN ee01_source_units u ON u.snapshot_id=s.id
 LEFT JOIN cq_render_events r ON r.id=u.render_id LEFT JOIN cq_answer_revisions a ON a.id=u.answer_id
 LEFT JOIN cq_rejected_answer_events i ON i.id=u.rejected_id
 LEFT JOIN ee01_report_readbacks b ON b.snapshot_id=s.id
 WHERE s.id=:'snapshot_id'::uuid AND s.assessment_id=:'assessment_id'::uuid AND s.campaign_id=:'campaign_id'::uuid
 ORDER BY u.session_id;
COMMIT;
