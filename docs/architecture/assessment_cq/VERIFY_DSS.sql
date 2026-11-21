-- Run in Dss as an authorized diagnostic operator. Owner RLS can hide rows
-- from runtime accounts; an empty runtime result is not proof of absence.
-- This file writes nothing. Cross-database ownership is checked separately
-- against VERIFY_MARKETPLACE.sql, never by comparing UUIDs as if interchangeable.
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL statement_timeout = '15s';

-- audit: assessment_links
SELECT l.link_id, l.marketplace_assessment_id, l.m2_assessment_id,
       l.user_id, l.revoked_at, l.created_at,
       a.owner_user_id AS m2_owner, a.instrument_id,
       a.revision, a.confirmed_revision,
       (SELECT count(*) FROM public.m2_answer_revisions r
        WHERE r.assessment_id = a.id) AS answer_revisions,
       (SELECT count(*) FROM public.m2_confirmation_snapshots r
        WHERE r.assessment_id = a.id) AS confirmation_snapshots,
       c.id AS campaign_id
FROM public.m2_assessment_links l
JOIN public.m2_assessments a ON a.id = l.m2_assessment_id
LEFT JOIN public.cq_campaigns c ON c.assessment_id = a.id
ORDER BY l.created_at, l.link_id;

-- audit: campaigns
SELECT c.id AS campaign_id, c.assessment_id, c.owner_user_id,
       c.release_id, a.owner_user_id AS m2_owner,
       l.marketplace_assessment_id,
       (SELECT count(*) FROM public.cq_sessions s
        WHERE s.campaign_id = c.id) AS sessions
FROM public.cq_campaigns c
JOIN public.m2_assessments a ON a.id = c.assessment_id
LEFT JOIN public.m2_assessment_links l
  ON l.m2_assessment_id = a.id AND l.revoked_at IS NULL
ORDER BY c.id;

-- audit: synthetic_cases
SELECT x.case_key, x.origin, x.real_reportable,
       s.id AS session_id, s.campaign_id, c.assessment_id, c.owner_user_id,
       s.state AS submission_record_status, s.revision,
       ctl.research_mode, ctl.eligibility, ev.lifecycle_status,
       r.id AS receipt_id, r.revision AS receipt_revision,
       (SELECT count(*) FROM public.cq_answer_revisions ar
        WHERE ar.session_id = s.id) AS answer_revisions,
       (SELECT count(*) FROM public.cq_effective_answers ea
        WHERE ea.session_id = s.id AND ea.answer_event_id IS NOT NULL)
         AS current_answer_pointers,
       (SELECT count(DISTINCT qa.question_id)
        FROM public.cq_effective_answers ea
        JOIN public.cq_question_assignments qa
          ON qa.release_id = s.release_id AND qa.slot_id = ea.slot_id
        WHERE ea.session_id = s.id AND ea.answer_event_id IS NOT NULL)
         AS current_question_count
FROM public.cq_synthetic_cases x
JOIN public.cq_sessions s ON s.id = x.session_id
JOIN public.cq_campaigns c ON c.id = s.campaign_id
JOIN public.cq_session_controls ctl ON ctl.session_id = s.id
LEFT JOIN public.cq_submission_receipts r ON r.session_id = s.id
LEFT JOIN LATERAL (
  SELECT lifecycle_status FROM public.cq_synthetic_execution_events e
  WHERE e.session_id = s.id
  ORDER BY e.revision DESC, e.created_at DESC, e.id DESC LIMIT 1
) ev ON true
ORDER BY x.case_key;

-- audit: completed_session_answers
SELECT ea.slot_id, qa.question_id, ea.state, ea.answer_event_id,
       ar.session_id, ar.revision AS accepted_revision, ar.value_json
FROM public.cq_effective_answers ea
JOIN public.cq_sessions s ON s.id = ea.session_id
JOIN public.cq_question_assignments qa
  ON qa.release_id = s.release_id AND qa.slot_id = ea.slot_id
JOIN public.cq_answer_revisions ar
  ON ar.id = ea.answer_event_id
 AND ar.session_id = ea.session_id AND ar.slot_id = ea.slot_id
WHERE ea.session_id = '78c9374e-776e-523e-ac17-69fc9d6665a5'::uuid
ORDER BY qa.question_id, ea.slot_id;

-- audit: measurements
SELECT m.id, m.assessment_id, m.campaign_id, m.release_id,
       m.q, m.s, m.a, m.v, m.scope, m.status,
       m.metadata_json->>'synthetic_run_id' AS synthetic_run_id,
       (SELECT count(*) FROM public.ee01_source_units u
        WHERE u.snapshot_id = m.id) AS source_units,
       (SELECT count(*) FROM public.ee01_source_units u
        WHERE u.snapshot_id = m.id AND
        u.session_id = '78c9374e-776e-523e-ac17-69fc9d6665a5'::uuid)
          AS completed_session_source_units
FROM public.ee01_measurement_snapshots m ORDER BY m.created_at, m.id;

-- audit: integrity
SELECT 'campaign_assessment_or_owner_mismatch' AS check_name, count(*) AS violations
FROM public.cq_campaigns c LEFT JOIN public.m2_assessments a ON a.id = c.assessment_id
WHERE a.id IS NULL OR a.owner_user_id <> c.owner_user_id
UNION ALL
SELECT 'more_than_one_campaign_per_m2', count(*) FROM (
  SELECT assessment_id FROM public.cq_campaigns
  GROUP BY assessment_id HAVING count(*) > 1
) bad
UNION ALL
SELECT 'session_campaign_release_or_participant_mismatch', count(*)
FROM public.cq_sessions s
LEFT JOIN public.cq_campaigns c ON c.id = s.campaign_id
LEFT JOIN public.cq_participants p
 ON p.campaign_id = s.campaign_id AND p.respondent_user_id = s.respondent_user_id
WHERE c.id IS NULL OR c.release_id <> s.release_id OR p.campaign_id IS NULL
UNION ALL
SELECT 'effective_answer_cross_session_or_slot', count(*)
FROM public.cq_effective_answers e
LEFT JOIN public.cq_answer_revisions a
 ON a.id = e.answer_event_id AND a.session_id = e.session_id AND a.slot_id = e.slot_id
WHERE e.answer_event_id IS NOT NULL AND a.id IS NULL
UNION ALL
SELECT 'measurement_campaign_assessment_owner_release_mismatch', count(*)
FROM public.ee01_measurement_snapshots m
LEFT JOIN public.cq_campaigns c ON c.id = m.campaign_id
WHERE c.id IS NULL OR m.assessment_id <> c.assessment_id
 OR m.owner_user_id <> c.owner_user_id OR m.release_id <> c.release_id
UNION ALL
SELECT 'measurement_source_session_campaign_mismatch', count(*)
FROM public.ee01_source_units u
JOIN public.ee01_measurement_snapshots m ON m.id = u.snapshot_id
LEFT JOIN public.cq_sessions s ON s.id = u.session_id
WHERE s.id IS NULL OR s.campaign_id <> m.campaign_id
UNION ALL
SELECT 'active_link_owner_mismatch', count(*)
FROM public.m2_assessment_links l
LEFT JOIN public.m2_assessments a ON a.id = l.m2_assessment_id
WHERE l.revoked_at IS NULL AND (a.id IS NULL OR a.owner_user_id <> l.user_id);

-- audit: constraints
SELECT conrelid::regclass::text AS source_table, conname, contype,
       pg_get_constraintdef(oid) AS definition
FROM pg_constraint
WHERE conrelid IN (
 'public.m2_assessment_links'::regclass, 'public.m2_assessments'::regclass,
 'public.cq_campaigns'::regclass, 'public.cq_participants'::regclass,
 'public.cq_sessions'::regclass, 'public.cq_answer_revisions'::regclass,
 'public.cq_effective_answers'::regclass, 'public.cq_submission_receipts'::regclass,
 'public.ee01_measurement_snapshots'::regclass, 'public.ee01_source_units'::regclass)
ORDER BY source_table, conname;

-- audit: indexes
SELECT tablename, indexname, indexdef FROM pg_indexes
WHERE schemaname = 'public' AND tablename IN ('m2_assessment_links', 'cq_campaigns')
ORDER BY tablename, indexname;

-- audit: table_counts
SELECT 'assessment' AS table_name, count(*) AS rows FROM public.assessment
UNION ALL SELECT 'm2_assessments', count(*) FROM public.m2_assessments
UNION ALL SELECT 'm2_assessment_links', count(*) FROM public.m2_assessment_links
UNION ALL SELECT 'cq_campaigns', count(*) FROM public.cq_campaigns
UNION ALL SELECT 'cq_sessions', count(*) FROM public.cq_sessions
UNION ALL SELECT 'cq_answer_revisions', count(*) FROM public.cq_answer_revisions
UNION ALL SELECT 'ee01_measurement_snapshots', count(*) FROM public.ee01_measurement_snapshots;

ROLLBACK;
