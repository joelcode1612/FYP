-- Development fixture only. Production migration requires separate approval.
DO $$
BEGIN
    IF current_database() <> 'project1_m2_bcb_test' THEN
        RAISE EXCEPTION 'Disposable M2 database required';
    END IF;
END $$;
CREATE TABLE m2_research_objective_sources (
    objective_id uuid PRIMARY KEY REFERENCES m2_confirmed_uncertainties(id),
    provenance jsonb NOT NULL
);
ALTER TABLE m2_research_objective_sources ENABLE ROW LEVEL SECURITY;
