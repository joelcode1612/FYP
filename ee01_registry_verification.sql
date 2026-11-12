BEGIN TRANSACTION READ ONLY;

-- Test 1: Count existing research records.
SELECT 'research_source' AS table_name, COUNT(*) AS record_count
FROM ee01.research_source
UNION ALL
SELECT 'research_source_version', COUNT(*)
FROM ee01.research_source_version
UNION ALL
SELECT 'evidence_passage', COUNT(*)
FROM ee01.evidence_passage
UNION ALL
SELECT 'evidence_fact', COUNT(*)
FROM ee01.evidence_fact
UNION ALL
SELECT 'fact_verification_review', COUNT(*)
FROM ee01.fact_verification_review
UNION ALL
SELECT 'rendered_citation', COUNT(*)
FROM ee01.rendered_citation
UNION ALL
SELECT 'research_audit_log', COUNT(*)
FROM ee01.research_audit_log
ORDER BY table_name;

-- Test 2: Inspect research registry foreign keys.
SELECT
    child.relname AS child_table,
    c.conname AS constraint_name,
    parent.relname AS parent_table,
    pg_get_constraintdef(c.oid) AS relationship,
    c.convalidated AS validated
FROM pg_constraint c
JOIN pg_class child ON child.oid = c.conrelid
JOIN pg_class parent ON parent.oid = c.confrelid
JOIN pg_namespace ns ON ns.oid = child.relnamespace
WHERE c.contype = 'f'
AND ns.nspname = 'ee01'
ORDER BY child_table, constraint_name;

-- Test 3: Inspect actual columns.
SELECT
    table_name,
    column_name,
    data_type,
    is_nullable
FROM information_schema.columns
WHERE table_schema = 'ee01'
ORDER BY table_name, ordinal_position;

COMMIT;
