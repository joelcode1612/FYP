"""Candidate review rationale default; authorization remains in the route/repo."""
import pytest
from pydantic import ValidationError
from sitewise.api.v1.m2 import CandidateReviewRequest
from sitewise.services.confirmation_service import ConfirmationService


class Repo:
    def __init__(self): self.saved = None
    def record_owner_review(self, version, reviewer, decision, rationale):
        self.saved = rationale
        return {'decision': decision, 'rationale': rationale}
    def commit(self): pass
    def rollback(self): pass


@pytest.mark.parametrize('value', [None, '', '   '])
def test_candidate_review_omitted_or_blank_uses_default(value):
    body = {'decision': 'REQUEST_REVISION'}
    if value is not None: body['rationale'] = value
    payload = CandidateReviewRequest(**body)
    repo = Repo()
    result = ConfirmationService(repo).record_owner_review('v', 'reviewer', payload.decision, payload.rationale)
    assert result['rationale'] == 'No rationale provided by reviewer.'
    assert result['fielding_authorized'] is False


def test_candidate_review_retains_limit_and_rejects_unsupported_decision():
    with pytest.raises(ValidationError): CandidateReviewRequest(decision='REJECT', rationale='x' * 1001)
    with pytest.raises(ValidationError): CandidateReviewRequest(decision='PUBLISH', rationale='valid')
    repo = Repo()
    with pytest.raises(ValueError): ConfirmationService(repo).record_owner_review('v', 'r', 'REJECT', 'x' * 1001)
