"""Regression for candidate reads after reconfirmation (isolated SQLite)."""
import unittest
from uuid import uuid4

from sqlalchemy import create_engine, text
from sqlalchemy.orm import Session

from sitewise.repositories.m2_repository import SqlModelM2Repository


class CandidateSourceRevisionTests(unittest.TestCase):
    def test_reconfirmation_does_not_revive_old_candidate(self):
        engine = create_engine('sqlite://')
        with engine.connect() as connection:
            connection.exec_driver_sql("ATTACH DATABASE ':memory:' AS public")
            for ddl in (
                'CREATE TABLE public.m2_assessments (id text, owner_user_id text, revision int, confirmed_revision int)',
                'CREATE TABLE public.m2_confirmation_snapshots (id text, assessment_id text, assessment_revision int)',
                'CREATE TABLE public.m2_confirmed_uncertainties (id text, confirmation_id text, actor_user_id text, exact_text text)',
                'CREATE TABLE public.m2_review_question_versions (id text, objective_id text, question text, options text, supersedes text, source_receipt text)',
                'CREATE TABLE public.m2_candidate_owner_reviews (candidate_id text, decision text, rationale text, recorded_at text, reviewer_id text)',
            ):
                connection.exec_driver_sql(ddl)
            owner, assessment, confirmation, objective, candidate = (str(uuid4()) for _ in range(5))
            connection.execute(text('INSERT INTO public.m2_assessments VALUES (:id,:owner,2,2)'), {'id': assessment, 'owner': owner})
            connection.execute(text('INSERT INTO public.m2_confirmation_snapshots VALUES (:id,:aid,2)'), {'id': confirmation, 'aid': assessment})
            connection.execute(text('INSERT INTO public.m2_confirmed_uncertainties VALUES (:id,:cid,:owner,:t)'), {'id': objective, 'cid': confirmation, 'owner': owner, 't': 'synthetic'})
            connection.execute(text('INSERT INTO public.m2_review_question_versions VALUES (:id,:oid,:q,:o,NULL,:r)'), {'id': candidate, 'oid': objective, 'q': 'synthetic?', 'o': '[]', 'r': '{}'})
            with Session(bind=connection) as session:
                repository = SqlModelM2Repository(session)
                self.assertIsNotNone(repository.candidate_version(candidate, owner))
                connection.execute(text('UPDATE public.m2_assessments SET revision=3, confirmed_revision=3 WHERE id=:id'), {'id': assessment})
                self.assertIsNone(repository.candidate_version(candidate, owner))
                self.assertIsNone(repository.candidate_version(candidate, str(uuid4())))
        engine.dispose()


if __name__ == '__main__':
    unittest.main()
