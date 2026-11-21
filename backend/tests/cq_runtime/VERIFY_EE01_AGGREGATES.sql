\set ON_ERROR_STOP on
-- Required psql variables: actor_id, assessment_id, campaign_id, snapshot_id.
BEGIN READ ONLY;
SELECT set_config('project1.actor_id', :'actor_id',true);
SELECT s.id,s.assessment_id,s.campaign_id,s.slot_id,s.question_version,s.cutoff,s.scope,
 s.q,s.s,s.a,s.v,s.counts_json,s.metadata_json,s.fingerprint,s.rules_hash,s.source_hash,
 c.code,c.x,c.v AS denominator,c.percentage,c.diagnostic_percentage,c.status,
 (0<=c.x AND c.x<=s.v AND s.v<=s.a AND s.a<=s.s AND s.s<=s.q) AS counts_ordered
 FROM ee01_measurement_snapshots s JOIN ee01_category_cells c ON c.snapshot_id=s.id
 WHERE s.id=:'snapshot_id'::uuid AND s.assessment_id=:'assessment_id'::uuid AND s.campaign_id=:'campaign_id'::uuid
 ORDER BY c.code;
-- Independent SQL oracle: one persisted, selected source unit per session.
SELECT count(*) FILTER(WHERE (u.source_json->>'qualified')::boolean) AS q,
 count(*) FILTER(WHERE (u.source_json->>'qualified')::boolean AND (u.source_json->>'shown')::boolean) AS s,
 count(*) FILTER(WHERE (u.source_json->>'qualified')::boolean AND u.source_json->>'state' IN
 ('ANSWERED_SUBSTANTIVE','ANSWERED_NON_SUBSTANTIVE','REFUSED','INVALID')) AS a,
 count(*) FILTER(WHERE (u.source_json->>'qualified')::boolean AND u.source_json->>'state'='ANSWERED_SUBSTANTIVE') AS v,
 count(*) FILTER(WHERE (u.source_json->>'qualified')::boolean AND u.source_json->>'state'='ANSWERED_SUBSTANTIVE'
 AND a.value_json IN ('"PROB_YES"'::jsonb,'"DEF_YES"'::jsonb)) AS q05_top_two
 FROM ee01_source_units u JOIN ee01_measurement_snapshots s ON s.id=u.snapshot_id
 LEFT JOIN cq_answer_revisions a ON a.id=u.answer_id
 WHERE s.id=:'snapshot_id'::uuid AND s.assessment_id=:'assessment_id'::uuid AND s.campaign_id=:'campaign_id'::uuid;
COMMIT;
