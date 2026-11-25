"""Stage 4 readback for persisted Direct-QG candidates.

This is the surface that closes the gap the N04-A audit found: a generated
question lived in ``public.m2_qg_candidates`` while Stage 4 read
``public.m2_review_question_versions``, so the candidate could never appear.

Design decisions, stated once so the routes cannot drift:

* **One authoritative question.** The candidate row is not copied anywhere. This
  router reads it, and writes the *judgement* about it to
  ``public.m2_qg_candidate_reviews``. There is no second mutable copy of the
  wording.
* **Owner-scoped by predicate, not only by RLS.** Every statement joins
  ``public.m2_assessments`` on ``owner_user_id``. A foreign owner's candidate id
  returns the same 404 as a missing one, so the route is not an existence oracle.
* **No authority is granted.** A review records an opinion; every response pins
  ``fielding_authorized``, ``publication_authorized`` and
  ``scientifically_accepted`` to false.
* **Stale is refused, not ignored.** A candidate raised against an assessment
  revision that has since moved cannot be reviewed, because the judgement would
  be about a question the reviewer is no longer looking at.
"""
from typing import Annotated, Literal
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query, Response
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy.exc import SQLAlchemyError

from sitewise.api.v1.m2_route import M2SourceRoute
from sitewise.dependencies import AuthenticatedUser, M2Session, require_entrepreneur
from sitewise.project1.contracts import WorkflowHeld
from sitewise.project1 import qg_candidate_read as readback

router = APIRouter(route_class=M2SourceRoute)
Owner = Annotated[AuthenticatedUser, Depends(require_entrepreneur)]

NO_STORE = {'Cache-Control': 'no-store'}

#: Refusal codes that mean "the record moved under you". They are 409, not 404:
#: the caller's identity is fine, the state is not.
CONFLICT_CODES = frozenset({
    'QG_CANDIDATE_REVISION_STALE',
})

#: How an additional objective is spelled as an objective identity. A registry
#: objective keeps its ``O``-code; an additional one is identified by the
#: proposal the owner approved, so it never has to be forced into a mandatory
#: code (DD-036). Must match ``qg_generation_eligibility.objective_identity``.
_PROPOSAL_PREFIX = 'proposal:'

#: Refusal codes that mean "the request itself is not acceptable".
INVALID_CODES = frozenset({
    'QG_CANDIDATE_REVIEW_DECISION_INVALID',
    'QG_CANDIDATE_REVIEW_RATIONALE_TOO_LONG',
    'QG_CANDIDATE_OPTION_NOT_AVAILABLE',
})


def failure(status_code: int, code: str, message: str) -> HTTPException:
    return HTTPException(status_code=status_code,
                         detail={'code': code, 'message': message},
                         headers=NO_STORE)


def _raise_for(exc: WorkflowHeld) -> None:
    code = str(exc)
    if code == 'QG_CANDIDATE_NOT_FOUND':
        raise failure(404, code, 'Candidate not found for this assessment.')
    if code in CONFLICT_CODES:
        raise failure(409, code,
                      'The candidate was raised against an assessment revision '
                      'that is no longer current. Reload before deciding.')
    if code in INVALID_CODES:
        raise failure(422, code, 'The review request is not acceptable.')
    raise failure(503, code, 'The candidate review could not be completed.')


class ReviewRequest(BaseModel):
    model_config = ConfigDict(extra='forbid')
    decision: Literal['APPROVE_FOR_REVIEW', 'REJECT', 'REQUEST_REVISION']
    rationale: str = Field(default='', max_length=1000)
    expected_revision: int | None = Field(default=None, ge=0)


class ExpectedAnswerRequest(BaseModel):
    model_config = ConfigDict(extra='forbid')
    option_code: str | None = Field(default=None, max_length=100)
    expected_revision: int | None = Field(default=None, ge=0)


def _engine(session: M2Session):
    bind = session.get_bind()
    return getattr(bind, 'engine', bind)


@router.get('/assessments/{assessment_id}/qg-candidates')
def list_qg_candidates(
        assessment_id: UUID, user: Owner, session: M2Session, response: Response,
        limit: Annotated[int, Query(ge=1, le=200)] = 50):
    """Every persisted Direct-QG candidate for this assessment, newest first."""
    response.headers.update(NO_STORE)
    try:
        return readback.list_candidates(_engine(session), actor_id=user.user_id,
                                        assessment_id=assessment_id, limit=limit)
    except WorkflowHeld as exc:
        _raise_for(exc)
    except SQLAlchemyError:
        raise failure(503, 'QG_CANDIDATE_READ_UNAVAILABLE',
                      'Candidate storage is not available.') from None


@router.get('/assessments/{assessment_id}/qg-candidates/{candidate_id}')
def read_qg_candidate(
        assessment_id: UUID, candidate_id: UUID, user: Owner, session: M2Session,
        response: Response):
    response.headers.update(NO_STORE)
    try:
        return readback.read_candidate(_engine(session), actor_id=user.user_id,
                                       assessment_id=assessment_id,
                                       candidate_id=candidate_id)
    except WorkflowHeld as exc:
        _raise_for(exc)
    except SQLAlchemyError:
        raise failure(503, 'QG_CANDIDATE_READ_UNAVAILABLE',
                      'Candidate storage is not available.') from None


@router.get('/assessments/{assessment_id}/qg-eligibility')
def read_qg_eligibility(
        assessment_id: UUID, user: Owner, session: M2Session, response: Response,
        objective_id: Annotated[str | None, Query(max_length=64)] = None,
        proposal_id: Annotated[UUID | None, Query()] = None):
    """Why Direct-QG can or cannot run, requirement by requirement.

    **Contract 2.1 is authoritative for Direct-QG.** When the caller names a
    proposal — explicitly, or by passing the ``proposal:<uuid>`` objective
    identity that Stage 4 derives from it — the report is produced by
    ``qg_generation_eligibility``: the owner's approval *is* the authority, and
    no objective-admission row is required. Reporting ``ADMISSION_NOT_FOUND``
    for such an objective described the removal of a step as a failure.

    The legacy ``sitewise-qg-eligibility/1`` report is still served for an
    ``O1..O6`` objective, because that path is genuinely bound by an admission
    row; publishing it under 2.1 would claim an authority the record does not
    carry. ``contract_version`` in the response states which one was returned,
    so a consumer never has to guess which vocabulary it is reading.

    Read-only in both cases. A ``PASS`` here is not an authorization: the live
    runner re-verifies every condition against the real request before it opens
    a socket.
    """
    from sitewise.project1 import qg_eligibility
    from sitewise.project1 import qg_generation_eligibility as generation

    response.headers.update(NO_STORE)

    resolved_proposal = proposal_id
    if resolved_proposal is None and objective_id:
        if objective_id.startswith(_PROPOSAL_PREFIX):
            try:
                resolved_proposal = UUID(objective_id[len(_PROPOSAL_PREFIX):])
            except ValueError:
                raise failure(
                    422, 'QG_ELIGIBILITY_IDENTITY_INVALID',
                    f'The objective identity {objective_id!r} names a proposal '
                    'that is not a UUID.') from None

    if resolved_proposal is not None:
        engine = _engine(session)
        try:
            # Derived once so G-06 can be answered rather than declined: the
            # objective identity is what an authorization is keyed on.
            authority = generation.derive_objective_authority(
                engine, actor_id=user.user_id, assessment_id=assessment_id,
                proposal_id=resolved_proposal)
            present = generation.live_authorization(
                engine, actor_id=user.user_id, assessment_id=assessment_id,
                objective_id=authority['objective_id'])
            return generation.evaluate(
                engine, actor_id=user.user_id, assessment_id=assessment_id,
                proposal_id=resolved_proposal, authorization_present=present)
        except WorkflowHeld as exc:
            _raise_for(exc)
        except SQLAlchemyError:
            raise failure(503, 'QG_ELIGIBILITY_UNAVAILABLE',
                          'The eligibility report could not be produced.') from None

    try:
        with session.connection() as conn:
            return qg_eligibility.evaluate(
                conn, actor_id=user.user_id, assessment_id=assessment_id,
                objective_id=objective_id, proposal_id=None)
    except WorkflowHeld as exc:
        _raise_for(exc)
    except SQLAlchemyError:
        raise failure(503, 'QG_ELIGIBILITY_UNAVAILABLE',
                      'The eligibility report could not be produced.') from None


@router.post('/assessments/{assessment_id}/qg-candidates/{candidate_id}/review',
             status_code=201)
def review_qg_candidate(
        assessment_id: UUID, candidate_id: UUID, payload: ReviewRequest,
        user: Owner, session: M2Session, response: Response):
    """Record the owner's judgement. Approving here is **not** fielding."""
    response.headers.update(NO_STORE)
    try:
        return readback.record_review(
            _engine(session), actor_id=user.user_id, assessment_id=assessment_id,
            candidate_id=candidate_id, decision=payload.decision,
            rationale=payload.rationale,
            expected_revision=payload.expected_revision)
    except WorkflowHeld as exc:
        _raise_for(exc)
    except SQLAlchemyError as exc:
        if getattr(getattr(exc, 'orig', None), 'pgcode', None) in ('42P01', '42703'):
            raise failure(503, 'QG_CANDIDATE_REVIEW_SCHEMA_UNAVAILABLE',
                          'Question review is unavailable until its versioned '
                          'storage schema is provisioned.') from None
        raise failure(503, 'QG_CANDIDATE_REVIEW_UNAVAILABLE',
                      'The review could not be recorded.') from None


@router.put('/assessments/{assessment_id}/qg-candidates/{candidate_id}/expected-answer')
def set_expected_answer(
        assessment_id: UUID, candidate_id: UUID, payload: ExpectedAnswerRequest,
        user: Owner, session: M2Session, response: Response):
    """Record the entrepreneur's expectation. Never a respondent answer."""
    response.headers.update(NO_STORE)
    try:
        return readback.set_expected_answer(
            _engine(session), actor_id=user.user_id, assessment_id=assessment_id,
            candidate_id=candidate_id, option_code=payload.option_code,
            expected_revision=payload.expected_revision)
    except WorkflowHeld as exc:
        _raise_for(exc)
    except SQLAlchemyError as exc:
        if getattr(getattr(exc, 'orig', None), 'pgcode', None) in ('42P01', '42703'):
            raise failure(503, 'QG_CANDIDATE_REVIEW_SCHEMA_UNAVAILABLE',
                          'Question review is unavailable until its versioned '
                          'storage schema is provisioned.') from None
        raise failure(503, 'QG_CANDIDATE_REVIEW_UNAVAILABLE',
                      'The expected answer could not be recorded.') from None


__all__ = ['router']
