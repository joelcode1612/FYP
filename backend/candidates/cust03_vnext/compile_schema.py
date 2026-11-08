"""Compile review-only PostgreSQL DDL. This script never connects to a database."""
from pathlib import Path

from sqlalchemy.dialects import postgresql
from sqlalchemy.schema import CreateTable

from sitewise.db.models.customer_candidate_schema import customer_candidate_metadata


def render():
    statements = [
        '-- CUST03 SYNTHETIC CANDIDATE ONLY — NOT AN APPROVED APPLICATION MIGRATION.',
        '-- Kept outside alembic/ and supabase/migrations/ to prevent automatic discovery.',
        '-- PostgreSQL execution, RLS/access review and production integration NOT VERIFIED.',
        '-- No instrument, feature bank, concept, translation or approval is seeded.',
        'BEGIN;',
    ]
    for table in customer_candidate_metadata.sorted_tables:
        statements.append(str(CreateTable(table).compile(dialect=postgresql.dialect())).strip() + ';')
    statements.append('''CREATE FUNCTION cq_candidate_history_append_only() RETURNS trigger
LANGUAGE plpgsql AS $$ BEGIN
    RAISE EXCEPTION 'Candidate history is append-only';
END $$;''')
    for name in ('cq_candidate_displays', 'cq_candidate_response_history',
                 'cq_candidate_structured_pretests', 'cq_candidate_stimulus_exposures'):
        statements.append(f'''CREATE TRIGGER {name}_append_only BEFORE UPDATE OR DELETE ON {name}
FOR EACH ROW EXECUTE FUNCTION cq_candidate_history_append_only();''')
    statements.append('COMMIT;')
    return '\n\n'.join(statements) + '\n'


if __name__ == '__main__':
    target = Path(__file__).with_name('001_customer_candidate_REVIEW_ONLY.sql')
    target.write_text(render(), encoding='utf-8')
    print('Wrote review-only DDL; no database connection was made.')
