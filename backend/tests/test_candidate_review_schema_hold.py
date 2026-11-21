"""Schema incompatibility must not produce a successful or unbound review."""
import unittest
from types import SimpleNamespace
from uuid import uuid4

from fastapi import HTTPException
from sqlalchemy.exc import ProgrammingError

from sitewise.api.v1.m2 import CandidateReviewRequest, owner_candidate_review


class MissingColumn(Exception):
    pgcode = '42703'


class CandidateReviewSchemaHold(unittest.TestCase):
    def test_missing_column_returns_actionable_hold(self):
        class Service:
            def record_owner_review(self, *args):
                raise ProgrammingError('INSERT', {}, MissingColumn('sensitive internal detail'))

        with self.assertRaises(HTTPException) as caught:
            owner_candidate_review(uuid4(), CandidateReviewRequest(
                decision='APPROVE_FOR_REVIEW', rationale='Synthetic review'),
                SimpleNamespace(user_id=uuid4()), Service())
        self.assertEqual(caught.exception.status_code, 503)
        self.assertEqual(caught.exception.detail['code'], 'CANDIDATE_REVIEW_SCHEMA_UNAVAILABLE')
        self.assertNotIn('sensitive', str(caught.exception.detail))


if __name__ == '__main__':
    unittest.main()
