-- Run in Final_Location_Analysis. No schema or record changes.
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL statement_timeout = '15s';

-- audit: marketplace_assessments
SELECT a.assessment_id, a.user_id, a.property_id, a.status,
       a.created_at, a.updated_at, p.title AS property_title,
       (p.id IS NOT NULL) AS catalogue_reference_exists
FROM public.assessment a
LEFT JOIN fyp.catalogue_properties p ON p.id = a.property_id
ORDER BY a.created_at DESC, a.assessment_id;

-- audit: marketplace_constraints
SELECT conname, pg_get_constraintdef(oid) AS definition
FROM pg_constraint
WHERE conrelid = 'public.assessment'::regclass
ORDER BY conname;

ROLLBACK;
