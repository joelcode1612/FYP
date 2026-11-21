-- READ ONLY. Run in the intended DB using an authorized inspection account.
-- Example is from the disposable CP13 lab, NOT original Dss. Re-running the
-- private suite generates new IDs: copy them from cp13_bcb_persistence.json.
\set assessment_id 'ff82227b-4983-4fd7-babf-63b751555303'
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
SELECT current_database(),current_user,current_setting('transaction_read_only');
SELECT id,owner_user_id,instrument_id,revision,confirmed_revision,created_at
FROM public.m2_assessments WHERE id=:'assessment_id'::uuid;
SELECT a.id,a.item_version_id,i.item_key,a.assessment_revision,a.answer_state,a.value_json,a.created_at
FROM public.m2_answer_revisions a JOIN public.m2_item_versions i ON i.id=a.item_version_id
WHERE a.assessment_id=:'assessment_id'::uuid ORDER BY a.assessment_revision;
SELECT id,assessment_id,assessment_revision,snapshot_digest,created_at
FROM public.m2_confirmation_snapshots WHERE assessment_id=:'assessment_id'::uuid;
SELECT context_id,assessment_id,confirmation_id,assessment_revision,builder_version,
       packet_hash,snapshot_digest,lifecycle_status,created_at,packet_json
FROM public.m2_business_contexts WHERE assessment_id=:'assessment_id'::uuid;
SELECT u.id,u.confirmation_id,u.exact_text,s.provenance
FROM public.m2_confirmed_uncertainties u
JOIN public.m2_confirmation_snapshots c ON c.id=u.confirmation_id
LEFT JOIN public.m2_research_objective_sources s ON s.objective_id=u.id
WHERE c.assessment_id=:'assessment_id'::uuid;
SELECT q.id,q.objective_id,q.question,q.options,q.source_receipt
FROM public.m2_review_question_versions q
JOIN public.m2_confirmed_uncertainties u ON u.id=q.objective_id
JOIN public.m2_confirmation_snapshots c ON c.id=u.confirmation_id
WHERE c.assessment_id=:'assessment_id'::uuid;
-- Cloud tables are present in original Dss; the targeted BCB-only private
-- schema does not provision project1_ai. Run these only where it exists:
-- SELECT r.id,r.assessment_id,r.assessment_revision,r.source_fingerprint,
--        a.stage,a.prompt_version,a.prompt_hash,a.request_hash,t.outcome,t.output_digest
-- FROM project1_ai.runs r
-- JOIN project1_ai.attempts a ON a.run_id=r.id
-- LEFT JOIN project1_ai.attempt_receipts t ON t.run_id=a.run_id AND t.attempt_no=a.attempt_no
-- WHERE r.assessment_id=:'assessment_id'::uuid ORDER BY r.id,a.attempt_no;
ROLLBACK;
