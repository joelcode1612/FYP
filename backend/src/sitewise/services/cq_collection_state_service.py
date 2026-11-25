"""Authoritative respondent target, collection progress and lifecycle (DD-097).

What this owns
--------------
* the entrepreneur's **respondent target** — a planning figure, never a count of
  responses received. It used to live only in
  ``respondent_target_store_browser.dart``, a localStorage entry that no shipped
  code reads: the built bundle contains neither the class nor its key, so the
  "the target gates the report" claim in its doc comment described nothing.
* **collection progress** derived from the persisted sessions, controls,
  receipts and EE-01 snapshots — never from a cached browser number.
* the **collection lifecycle** for a campaign: OPEN, then ENDED by an explicit
  act. ``cq_lifecycle_events`` could not carry this — its ``action`` check admits
  only PAUSE/RESUME and its keys are session-scoped.

Principal and transaction discipline
------------------------------------
Every statement runs as ``p1_ee01_runtime`` (the CQ write principal) inside a
transaction with ``project1.actor_id`` bound, so the row-level policies on
``cq_collection_state`` decide what is visible. The service refuses to run under
any other role rather than silently returning zero rows, which is what an
RLS-scoped read does when the principal is wrong.

Concurrency
-----------
Target edits and closure both take ``pg_advisory_xact_lock*`` on the campaign's
own key **as their first statement**, before any row lock. Closure takes it
exclusively, target edits take it shared. That is the same discipline DD-116
established for ``cp12.write_barrier``: one gate taken first, then narrower
locks, so two transactions cannot acquire the same pair in opposite order. It
also serialises closure against the respondent session-start path, which takes
the shared form of the same key.

Absence is a state
------------------
A campaign with no row in ``cq_collection_state`` is *published, OPEN, target not
set*. That is the honest description of a freshly published questionnaire, and it
is why the row is created lazily rather than by the publication path: publication
is a verified path (DD-116, B-7) and is not modified to carry this.

Idempotency
-----------
Both writes take a ``request_id``. Replaying the same request returns the stored
state with ``replayed`` true and performs no second transition, so a retried tap
after a dropped response cannot move the lifecycle twice.
"""
from __future__ import annotations

from contextlib import contextmanager
from datetime import datetime, timezone
from uuid import UUID

from sqlalchemy import text

from sitewise.domain.cq_runtime import CqRefused
from sitewise.domain.customer_questionnaire import digest

CONTRACT = 'cq-collection-state/2'
PRINCIPAL = 'p1_ee01_runtime'
MIN_TARGET = 1
MAX_TARGET = 9999

#: Completion policies an owner may close under. ``TARGET_REACHED_ONLY`` refuses
#: a below-target closure; ``OWNER_DISCRETION`` records one. Neither is a default:
#: the caller must state which it is, because choosing silently would be
#: inventing the production rule DD-097 leaves open.
COMPLETION_POLICIES = ('TARGET_REACHED_ONLY', 'OWNER_DISCRETION')
#: How sessions still ACTIVE at closure are treated. Only ``LEAVE_OPEN`` is
#: expressible: ``cq_sessions_check1`` forbids withdrawing a consented session,
#: and ``cq_sessions.state`` admits no fourth value.
IN_PROGRESS_DISPOSITIONS = ('LEAVE_OPEN',)

RESEARCH_MODE_TO_SCOPE = {
    'DEVELOPER_PREVIEW': 'SYNTHETIC_DEVELOPER_PREVIEW',
    'CUSTOMER_DEMAND_SURVEY': 'CUSTOMER_RESEARCH',
}


def _iso(value):
    if value is None:
        return None
    if isinstance(value, datetime):
        return value.astimezone(timezone.utc).isoformat()
    return str(value)


def _gate_key(campaign_id):
    """The campaign's advisory-lock key. Must be the first lock taken."""
    return text("SELECT pg_advisory_xact_lock_shared("
                "hashtextextended('cq.collection/' || :cid, 12))")


class CollectionStateService:
    def __init__(self, engine):
        self.engine = engine

    # -- plumbing ---------------------------------------------------------

    @contextmanager
    def connection(self, actor):
        with self.engine.begin() as c:
            role = c.execute(text(
                'SELECT current_user, rolsuper, rolbypassrls '
                'FROM pg_roles WHERE rolname = current_user')).one()
            if role != (PRINCIPAL, False, False):
                raise CqRefused('CQ_COLLECTION_STATE_PRINCIPAL_REQUIRED', 503)
            c.execute(text("SELECT set_config('project1.actor_id', :a, true)"),
                      {'a': str(actor)})
            yield c

    def _campaign(self, c, actor, assessment_id):
        row = c.execute(text(
            'SELECT id, assessment_id, owner_user_id, release_id '
            'FROM cq_campaigns WHERE assessment_id = :aid'), {'aid': str(assessment_id)}
        ).mappings().first()
        if row is None:
            # Not published, or published by somebody else. The policy makes the
            # two indistinguishable on purpose; neither is a collection.
            raise CqRefused('CQ_COLLECTION_CAMPAIGN_NOT_FOUND', 404)
        return row

    def _state(self, c, campaign_id):
        return c.execute(text(
            'SELECT campaign_id, respondent_target, lifecycle_state, ended_at, '
            '       end_reason, ended_by_user_id, state_revision, last_request_id, '
            '       evidence_cutoff, completion_policy, in_progress_disposition, '
            '       target_at_closure, reached_at_closure, created_at, updated_at '
            '  FROM cq_collection_state WHERE campaign_id = :cid'),
            {'cid': campaign_id}).mappings().first()

    # -- progress ---------------------------------------------------------

    def _counts(self, c, campaign_id):
        """The ten distinguished counts, from persisted rows only.

        ``eligible_submitted_respondents`` is the operational completion metric
        the assignment asks for: distinct respondents, eligible per the
        ``cq_session_controls`` eligibility contract (the same column EE-01's own
        qualification reads), with a SUBMITTED session **and** a receipt that
        passes the integrity checks below.
        """
        row = c.execute(text("""
            WITH scope AS (
                SELECT s.id, s.respondent_user_id, s.state,
                       ctl.eligibility, ctl.research_mode,
                       (sc.session_id IS NOT NULL) AS synthetic
                  FROM cq_sessions s
                  LEFT JOIN cq_session_controls ctl ON ctl.session_id = s.id
                  LEFT JOIN cq_synthetic_cases  sc  ON sc.session_id = s.id
                 WHERE s.campaign_id = :cid
            )
            SELECT
              count(*)                                                        AS total_sessions,
              count(DISTINCT respondent_user_id)                              AS distinct_respondents,
              count(*) FILTER (WHERE state = 'ACTIVE')                        AS open_sessions,
              count(*) FILTER (WHERE state = 'SUBMITTED')                     AS submitted_sessions,
              count(DISTINCT respondent_user_id)
                FILTER (WHERE state = 'WITHDRAWN')                            AS withdrawn_respondents,
              count(DISTINCT respondent_user_id)
                FILTER (WHERE state = 'SUBMITTED'
                          AND eligibility = 'ELIGIBLE')                       AS eligible_submitted_respondents,
              count(DISTINCT respondent_user_id)
                FILTER (WHERE eligibility = 'INELIGIBLE')                     AS screened_out_respondents,
              count(DISTINCT respondent_user_id)
                FILTER (WHERE eligibility = 'UNRESOLVED')                     AS unresolved_respondents,
              count(*) FILTER (WHERE synthetic)                               AS synthetic_sessions,
              count(*) FILTER (WHERE NOT synthetic)                           AS genuine_sessions
              FROM scope
        """), {'cid': campaign_id}).mappings().one()
        return dict(row)

    def _receipts(self, c, campaign_id):
        """Receipt integrity, using the same checks the session read path applies.

        A receipt is valid when its stored hash matches a recomputation over the
        payload minus the hash, the payload names this session, and it names the
        release's manifest. The routing-replay equality check (``decision_hash``
        against the routed rows) is enforced on the session read path and is not
        duplicated here; it is reported as not re-verified rather than assumed.
        """
        rows = c.execute(text("""
            SELECT r.id, r.session_id, r.receipt_hash, r.payload_json,
                   s.state AS session_state, s.respondent_user_id,
                   rel.manifest_hash AS release_manifest_hash
              FROM cq_submission_receipts r
              JOIN cq_sessions s        ON s.id = r.session_id
              JOIN cq_campaigns cmp     ON cmp.id = s.campaign_id
              JOIN cq_manifest_releases rel ON rel.id = cmp.release_id
             WHERE s.campaign_id = :cid
        """), {'cid': campaign_id}).mappings().all()

        valid = 0
        integrity_failures = 0
        not_submitted = 0
        per_session: dict[str, int] = {}
        valid_sessions: set[str] = set()
        for r in rows:
            per_session[r['session_id']] = per_session.get(r['session_id'], 0) + 1
            if r['session_state'] != 'SUBMITTED':
                not_submitted += 1
                continue
            body = dict(r['payload_json'])
            claimed = body.pop('receipt_hash', None)
            ok = (claimed == r['receipt_hash']
                  and digest(body) == claimed
                  and body.get('session_id') == str(r['session_id'])
                  and body.get('manifest_hash') == r['release_manifest_hash'])
            if ok:
                valid += 1
                valid_sessions.add(str(r['session_id']))
            else:
                integrity_failures += 1

        duplicates = sum(1 for n in per_session.values() if n > 1)
        return {
            'total_receipts': len(rows),
            'valid_receipts': valid,
            'integrity_failures': integrity_failures,
            'receipts_for_non_submitted_sessions': not_submitted,
            'sessions_with_multiple_receipts': duplicates,
            'routing_replay_equality': 'ENFORCED_ON_SESSION_READ_NOT_REVERIFIED_HERE',
            '_valid_sessions': valid_sessions,
        }

    def _ee01(self, c, campaign_id):
        """Q from the most recent persisted EE-01 snapshot, and which slot it is.

        Q is per (campaign, slot): it counts *qualified* sessions for one
        question, which is why it is reported with its slot rather than as a
        campaign-wide figure. The assignment forbids using Q as the completion
        count precisely because qualified is not submitted.
        """
        row = c.execute(text("""
            SELECT id, slot_id, q, s, a, v, status, cutoff, scope
              FROM ee01_measurement_snapshots
             WHERE campaign_id = :cid
             ORDER BY cutoff DESC, created_at DESC
             LIMIT 1
        """), {'cid': campaign_id}).mappings().first()
        if row is None:
            return {'snapshot_id': None, 'qualified_sessions': None,
                    'reason': 'NO_EE01_SNAPSHOT'}
        return {
            'snapshot_id': str(row['id']),
            'slot_id': row['slot_id'],
            'qualified_sessions': row['q'],
            'shown': row['s'], 'answered': row['a'], 'substantive': row['v'],
            'status': row['status'],
            'cutoff': _iso(row['cutoff']),
            'scope': row['scope'],
        }

    def _scope_of(self, c, campaign_id):
        modes = [r[0] for r in c.execute(text("""
            SELECT DISTINCT ctl.research_mode
              FROM cq_sessions s
              JOIN cq_session_controls ctl ON ctl.session_id = s.id
             WHERE s.campaign_id = :cid
        """), {'cid': campaign_id}).fetchall()]
        scopes = sorted({RESEARCH_MODE_TO_SCOPE.get(m, 'UNKNOWN') for m in modes})
        if not scopes:
            # No sessions yet: fall back to the release's declared class, which is
            # what the campaign *will* collect.
            cls = c.execute(text("""
                SELECT rel.source_class
                  FROM cq_campaigns cmp
                  JOIN cq_manifest_releases rel ON rel.id = cmp.release_id
                 WHERE cmp.id = :cid
            """), {'cid': campaign_id}).scalar()
            return ('SYNTHETIC_DEVELOPER_PREVIEW' if cls == 'SYNTHETIC_FIXTURE'
                    else 'CUSTOMER_RESEARCH' if cls else 'UNKNOWN')
        return scopes[0] if len(scopes) == 1 else 'MIXED'

    def _eligibility_cross_check(self, c, campaign_id):
        """Compare the stored eligibility with what the Q01 answer actually says.

        ``cq_session_controls.eligibility`` is the persisted contract and the
        column EE-01's own qualification reads, so it is what the headline counts
        use. It is not, however, derived at read time: the synthetic DSS import
        wrote ``ELIGIBLE`` for every imported session, including the ones whose
        test scenario is a screen-out or an unresolved case. Reporting the stored
        count without this comparison would let "0 screened out" read as "nobody
        was screened out", when what it means is "nobody is *recorded* as
        screened out".

        This is a comparison, not a second source of truth: it does not change a
        single count, it states whether the two agree.
        """
        row = c.execute(text("""
            WITH scope AS (
                SELECT s.id, ctl.eligibility,
                       (SELECT e.state FROM cq_effective_answers e
                         WHERE e.session_id = s.id AND e.slot_id = 'Q01') AS q01_state
                  FROM cq_sessions s
                  LEFT JOIN cq_session_controls ctl ON ctl.session_id = s.id
                 WHERE s.campaign_id = :cid
            )
            SELECT
              count(*) FILTER (WHERE eligibility = 'ELIGIBLE')                    AS stored_eligible,
              count(*) FILTER (WHERE q01_state = 'ANSWERED_SUBSTANTIVE')          AS q01_substantive,
              count(*) FILTER (WHERE q01_state IS NULL)                           AS q01_absent,
              count(*) FILTER (WHERE eligibility = 'ELIGIBLE'
                                 AND q01_state IS DISTINCT FROM 'ANSWERED_SUBSTANTIVE')
                                                                                  AS eligible_but_not_substantive,
              count(*) FILTER (WHERE eligibility <> 'ELIGIBLE'
                                 AND q01_state = 'ANSWERED_SUBSTANTIVE')
                                                                                  AS substantive_but_not_eligible
              FROM scope
        """), {'cid': campaign_id}).mappings().one()
        out = dict(row)
        out['agrees'] = (out['eligible_but_not_substantive'] == 0
                         and out['substantive_but_not_eligible'] == 0)
        return out

    def _open_reasons(self, c, campaign_id):
        """Why the open sessions are open, so "17 open" is not a bare number.

        A synthetic scenario that never submitted and a respondent who is simply
        mid-questionnaire are both ACTIVE, and they are not the same fact.
        """
        rows = c.execute(text("""
            SELECT coalesce(sc.scenario, 'GENUINE') AS scenario, count(*) AS n
              FROM cq_sessions s
              LEFT JOIN cq_synthetic_cases sc ON sc.session_id = s.id
             WHERE s.campaign_id = :cid AND s.state = 'ACTIVE'
             GROUP BY 1 ORDER BY 2 DESC
        """), {'cid': campaign_id}).mappings().all()
        return {r['scenario']: r['n'] for r in rows}

    def _progress(self, c, campaign, state):
        counts = self._counts(c, campaign['id'])
        receipts = self._receipts(c, campaign['id'])
        ee01 = self._ee01(c, campaign['id'])
        scope = self._scope_of(c, campaign['id'])

        target = state['respondent_target'] if state is not None else None
        actual = counts['eligible_submitted_respondents']

        if target is None:
            remaining = None
            percent = None
            reached = None
        else:
            remaining = max(0, target - actual)
            # Never report above 100%: overshooting the target is a fact about
            # `actual`, not about the plan, and a 137% bar misreads as progress.
            percent = round(min(actual, target) * 100.0 / target, 2)
            reached = actual >= target

        return {
            # -- the ten distinguished counts -----------------------------
            'total_sessions': counts['total_sessions'],
            'distinct_respondents': counts['distinct_respondents'],
            'open_sessions': counts['open_sessions'],
            'submitted_sessions': counts['submitted_sessions'],
            'eligible_submitted_respondents': actual,
            'screened_out_respondents': counts['screened_out_respondents'],
            'unresolved_respondents': counts['unresolved_respondents'],
            'withdrawn_respondents': counts['withdrawn_respondents'],
            'qualified_sessions_used_by_ee01': ee01['qualified_sessions'],
            'valid_submission_receipts': receipts['valid_receipts'],
            # -- receipt integrity, so a mismatch is visible not inferred ---
            'receipt_integrity': {
                'total_receipts': receipts['total_receipts'],
                'integrity_failures': receipts['integrity_failures'],
                'receipts_for_non_submitted_sessions':
                    receipts['receipts_for_non_submitted_sessions'],
                'sessions_with_multiple_receipts':
                    receipts['sessions_with_multiple_receipts'],
                'routing_replay_equality': receipts['routing_replay_equality'],
            },
            'ee01': ee01,
            # -- why the open sessions are open, and whether the stored
            #    eligibility agrees with the answers it should reflect ------
            'open_session_reasons': self._open_reasons(c, campaign['id']),
            'eligibility_cross_check': self._eligibility_cross_check(c, campaign['id']),
            # -- the operational target ----------------------------------
            'respondent_target': target,
            'remaining_respondents': remaining,
            'progress_percent': percent,
            'operational_target_reached': reached,
            # -- what kind of evidence these counts describe --------------
            'evidence_scope': scope,
            'synthetic_sessions': counts['synthetic_sessions'],
            'genuine_sessions': counts['genuine_sessions'],
            'real_reportable': scope != 'SYNTHETIC_DEVELOPER_PREVIEW',
            'note': ('Operational counts only. Reaching the target is not '
                     'scientific sufficiency and does not authorise findings.'),
        }

    @staticmethod
    def _shape(assessment_id, campaign, state, progress, *, replayed=False):
        present = state is not None
        ended = bool(present and state['lifecycle_state'] == 'ENDED')
        return {
            'contract_version': CONTRACT,
            'assessment_id': str(assessment_id),
            'campaign_id': str(campaign['id']),
            'release_id': str(campaign['release_id']),
            # A missing row is a published campaign with collection open and no
            # target chosen. Reporting it as ENDED or as a zero target would both
            # be wrong.
            'state_row_present': present,
            'respondent_target': state['respondent_target'] if present else None,
            'target_set': bool(present and state['respondent_target'] is not None),
            'lifecycle_state': (state['lifecycle_state'] if present else 'OPEN'),
            'accepting_responses': not ended,
            'ended_at': _iso(state['ended_at']) if present else None,
            'end_reason': state['end_reason'] if present else None,
            'ended_by_user_id': (str(state['ended_by_user_id'])
                                 if present and state['ended_by_user_id'] else None),
            # The closure record, when there is one.
            'closure': ({
                'evidence_cutoff': _iso(state['evidence_cutoff']),
                'completion_policy': state['completion_policy'],
                'in_progress_disposition': state['in_progress_disposition'],
                'target_at_closure': state['target_at_closure'],
                'reached_at_closure': state['reached_at_closure'],
                'closed_below_target': (
                    state['target_at_closure'] is not None
                    and state['reached_at_closure'] is not None
                    and state['reached_at_closure'] < state['target_at_closure']),
            } if ended else None),
            'state_revision': state['state_revision'] if present else 0,
            'progress': progress,
            'replayed': replayed,
        }

    # -- read -------------------------------------------------------------

    def read(self, actor, assessment_id):
        with self.connection(actor) as c:
            campaign = self._campaign(c, actor, assessment_id)
            state = self._state(c, campaign['id'])
            return self._shape(assessment_id, campaign, state,
                               self._progress(c, campaign, state))

    # -- report eligibility ----------------------------------------------

    def report_eligibility(self, actor, assessment_id):
        """Six separate answers, never collapsed into one "can I see the report".

        The assignment's whole point is that these are different facts:

        1. the entrepreneur's operational target was reached — a planning fact;
        2. customer data collection was closed — a lifecycle fact;
        3. EE-01 computed a measurement — a computation fact;
        4. the scientific evidence was accepted — an authority fact that nothing
           in this system currently grants;
        5. the findings were authorised for release — a governance fact;
        6. the report is viewable — which may be true as a *preview* while 4 and 5
           are both false.

        Reaching the target does not establish scientific sufficiency, and a
        successful EE-01 calculation does not authorise findings. Each answer
        therefore carries its own reason code, and ``report_viewable`` never
        implies that findings are present.
        """
        with self.connection(actor) as c:
            campaign = self._campaign(c, actor, assessment_id)
            state = self._state(c, campaign['id'])
            progress = self._progress(c, campaign, state)
            snapshot = progress['ee01']

            concepts = {}
            reasons = []

            # 1. operational target
            if progress['respondent_target'] is None:
                concepts['operational_target_reached'] = {
                    'value': None, 'reason': 'COLLECTION_TARGET_NOT_SET'}
                reasons.append('COLLECTION_TARGET_NOT_SET')
            elif progress['operational_target_reached']:
                concepts['operational_target_reached'] = {'value': True, 'reason': None}
            else:
                concepts['operational_target_reached'] = {
                    'value': False, 'reason': 'COLLECTION_TARGET_NOT_REACHED'}
                reasons.append('COLLECTION_TARGET_NOT_REACHED')

            # 2. collection closed
            closed = bool(state is not None and state['lifecycle_state'] == 'ENDED')
            concepts['collection_closed'] = {
                'value': closed, 'reason': None if closed else 'COLLECTION_STILL_OPEN'}
            if not closed:
                reasons.append('COLLECTION_STILL_OPEN')

            # 3. measurement computed
            computed = snapshot.get('snapshot_id') is not None
            concepts['measurement_computed'] = {
                'value': computed,
                'reason': None if computed else 'MEASUREMENT_NOT_COMPUTED',
                'detail': None if computed else snapshot.get('reason'),
                'snapshot_id': snapshot.get('snapshot_id'),
                'slot_id': snapshot.get('slot_id'),
                'cutoff': snapshot.get('cutoff'),
                'q': snapshot.get('qualified_sessions'),
                'status': snapshot.get('status'),
            }
            if not computed:
                reasons.append('MEASUREMENT_NOT_COMPUTED')

            # 4. scientific evidence accepted. Read from the persisted metadata,
            #    never inferred from the presence of numbers.
            authority = None
            gaps = []
            readback = None
            if computed:
                row = c.execute(text("""
                    SELECT metadata_json FROM ee01_measurement_snapshots WHERE id = :id
                """), {'id': snapshot['snapshot_id']}).mappings().one()
                authority = row['metadata_json'].get('authority')
                gaps = list(row['metadata_json'].get('scientific_gaps') or [])
                readback = c.execute(text("""
                    SELECT status FROM ee01_report_readbacks WHERE snapshot_id = :id
                """), {'id': snapshot['snapshot_id']}).mappings().first()

            accepted = authority == 'AUTHORITY_VERIFIED'
            concepts['scientific_evidence_accepted'] = {
                'value': accepted,
                # With no measurement there is no evidence to accept, and saying
                # "authority unverified" would imply a measurement exists whose
                # authority is merely unproven.
                'reason': (None if accepted
                           else ('MEASUREMENT_NOT_COMPUTED' if not computed
                                 else 'SCIENTIFIC_AUTHORITY_UNVERIFIED')),
                'authority': authority,
                'scientific_gaps': gaps,
            }
            if computed and not accepted:
                reasons.append('SCIENTIFIC_AUTHORITY_UNVERIFIED')

            # 5. findings authorised. The existing readback status is the
            #    authority and is passed through unchanged, never re-derived.
            readback_status = readback['status'] if readback else None
            authorised = readback_status is not None and 'WITHHELD' not in readback_status
            concepts['findings_authorized'] = {
                'value': authorised,
                'reason': None if authorised else (readback_status
                                                   or 'REPORT_CONTEXT_UNAVAILABLE'),
                'readback_status': readback_status,
            }
            if readback_status is None:
                reasons.append('REPORT_CONTEXT_UNAVAILABLE')
            elif not authorised:
                reasons.append(readback_status)

            # 6. viewable. A preview report may be opened while 4 and 5 are false;
            #    that is existing permitted access and is preserved. It never
            #    carries findings.
            viewable = readback_status is not None
            concepts['report_viewable'] = {
                'value': viewable,
                'reason': None if viewable else 'REPORT_CONTEXT_UNAVAILABLE',
                'mode': 'PREVIEW_WITHHELD_FINDINGS' if viewable and not authorised
                        else ('FINAL' if authorised else None),
                'findings_included': False,
            }

            if progress['evidence_scope'] == 'SYNTHETIC_DEVELOPER_PREVIEW':
                reasons.append('DEVELOPER_PREVIEW_EVIDENCE_NOT_REPORTABLE')

            return {
                'contract_version': 'cq-report-eligibility/1',
                'assessment_id': str(assessment_id),
                'campaign_id': str(campaign['id']),
                'release_id': str(campaign['release_id']),
                'concepts': concepts,
                'view_report_available': viewable,
                'findings_available': authorised,
                'reasons': reasons,
                'evidence_scope': progress['evidence_scope'],
                'real_reportable': progress['real_reportable'],
                'progress': progress,
                'note': ('Reaching the operational target does not establish '
                         'scientific sufficiency; a computed measurement does not '
                         'authorise findings.'),
            }

    # -- write: target ----------------------------------------------------

    def set_target(self, actor, assessment_id, target, request_id):
        if not isinstance(target, int) or isinstance(target, bool):
            raise CqRefused('CQ_COLLECTION_TARGET_INVALID', 422)
        if target < MIN_TARGET or target > MAX_TARGET:
            raise CqRefused('CQ_COLLECTION_TARGET_INVALID', 422)
        request_id = UUID(str(request_id))

        with self.connection(actor) as c:
            campaign = self._campaign(c, actor, assessment_id)
            # Shared gate first, before any row lock. Closure takes the exclusive
            # form, so a target edit either completes before the closure or waits
            # and then sees ENDED.
            c.execute(_gate_key(campaign['id']), {'cid': str(campaign['id'])})
            existing = self._state(c, campaign['id'])

            if existing is not None and existing['last_request_id'] == request_id:
                return self._shape(assessment_id, campaign, existing,
                                   self._progress(c, campaign, existing),
                                   replayed=True)

            if existing is not None and existing['lifecycle_state'] == 'ENDED':
                # The target is a planning figure. Rewriting it after collection
                # has ended would restate the goal in the light of the result.
                # Refusing is the conservative default; whether an ended
                # collection may ever be re-targeted is a policy decision and is
                # not taken here.
                raise CqRefused('CQ_COLLECTION_ENDED_TARGET_LOCKED', 409)

            row = c.execute(text("""
                INSERT INTO cq_collection_state
                       (campaign_id, respondent_target, lifecycle_state,
                        state_revision, last_request_id)
                VALUES (:cid, :target, 'OPEN', 1, :rid)
                ON CONFLICT (campaign_id) DO UPDATE
                   SET respondent_target = EXCLUDED.respondent_target,
                       state_revision    = cq_collection_state.state_revision + 1,
                       last_request_id   = EXCLUDED.last_request_id,
                       updated_at        = now()
                 WHERE cq_collection_state.lifecycle_state = 'OPEN'
                RETURNING campaign_id, respondent_target, lifecycle_state, ended_at,
                          end_reason, ended_by_user_id, state_revision,
                          last_request_id, evidence_cutoff, completion_policy,
                          in_progress_disposition, target_at_closure,
                          reached_at_closure, created_at, updated_at
            """), {'cid': campaign['id'], 'target': target, 'rid': request_id}
            ).mappings().first()

            if row is None:
                # Lost a race with a concurrent End Collection.
                raise CqRefused('CQ_COLLECTION_ENDED_TARGET_LOCKED', 409)
            return self._shape(assessment_id, campaign, row,
                               self._progress(c, campaign, row))

    # -- write: end collection -------------------------------------------

    def end_collection(self, actor, assessment_id, request_id, reason=None, *,
                       completion_policy, in_progress_disposition,
                       evidence_cutoff=None):
        """Close the campaign. Atomic, idempotent, and deletes nothing.

        The two policy arguments are required and have no default. The
        assignment forbids inventing the production rule for closing below target
        or for in-progress sessions; requiring the caller to state both means the
        rule is always recorded with the closure rather than assumed by code.
        """
        if completion_policy not in COMPLETION_POLICIES:
            raise CqRefused('CQ_COLLECTION_POLICY_UNSUPPORTED', 422)
        if in_progress_disposition not in IN_PROGRESS_DISPOSITIONS:
            raise CqRefused('CQ_COLLECTION_DISPOSITION_UNSUPPORTED', 422)

        request_id = UUID(str(request_id))
        reason = (reason or '').strip()[:200] or None

        # Owner directive 2026-11-25: OWNER_DISCRETION is the adopted policy for
        # closing below target, and it carries a mandatory reason. Refused here
        # as a typed 422 rather than left to the database CHECK, so the caller
        # gets a code it can act on instead of a constraint violation. The CHECK
        # (cq_collection_state_owner_reason_chk) still exists as the backstop for
        # any path that bypasses this service.
        if completion_policy == 'OWNER_DISCRETION' and reason is None:
            raise CqRefused('CQ_COLLECTION_REASON_REQUIRED', 422)

        with self.connection(actor) as c:
            campaign = self._campaign(c, actor, assessment_id)
            # Exclusive gate first. Serialises against session start (shared) and
            # against target edits (shared).
            c.execute(text("SELECT pg_advisory_xact_lock("
                           "hashtextextended('cq.collection/' || :cid, 12))"),
                      {'cid': str(campaign['id'])})
            existing = self._state(c, campaign['id'])

            if existing is not None:
                if existing['last_request_id'] == request_id \
                        or existing['lifecycle_state'] == 'ENDED':
                    # Either the same request replayed, or collection is already
                    # closed. Both are the caller's desired end state, and both
                    # return it without a second transition.
                    return self._shape(assessment_id, campaign, existing,
                                       self._progress(c, campaign, existing),
                                       replayed=existing['last_request_id'] == request_id)

            # The situation at closure, frozen. Counted before the transition so
            # the record describes the collection that was closed.
            progress = self._progress(c, campaign, existing)
            target = progress['respondent_target']
            reached = progress['eligible_submitted_respondents']

            if completion_policy == 'TARGET_REACHED_ONLY':
                if target is None:
                    raise CqRefused('CQ_COLLECTION_TARGET_NOT_SET', 409)
                if reached < target:
                    raise CqRefused('CQ_COLLECTION_TARGET_NOT_REACHED', 409)

            cutoff = evidence_cutoff or datetime.now(timezone.utc)

            if existing is not None:
                row = c.execute(text("""
                    UPDATE cq_collection_state
                       SET lifecycle_state         = 'ENDED',
                           ended_at                = now(),
                           end_reason              = :reason,
                           ended_by_user_id        = :actor,
                           evidence_cutoff         = :cutoff,
                           completion_policy       = :policy,
                           in_progress_disposition = :disposition,
                           target_at_closure       = :target,
                           reached_at_closure      = :reached,
                           state_revision          = state_revision + 1,
                           last_request_id         = :rid,
                           updated_at              = now()
                     WHERE campaign_id = :cid AND lifecycle_state = 'OPEN'
                    RETURNING campaign_id, respondent_target, lifecycle_state, ended_at,
                              end_reason, ended_by_user_id, state_revision,
                              last_request_id, evidence_cutoff, completion_policy,
                              in_progress_disposition, target_at_closure,
                              reached_at_closure, created_at, updated_at
                """), {'cid': campaign['id'], 'rid': request_id, 'reason': reason,
                       'actor': str(actor), 'cutoff': cutoff,
                       'policy': completion_policy,
                       'disposition': in_progress_disposition,
                       'target': target, 'reached': reached}).mappings().first()
                if row is None:
                    raise CqRefused('CQ_COLLECTION_STATE_CONTENDED', 409)
            else:
                # No row yet: ending collection before a target was ever chosen is
                # a legitimate act under OWNER_DISCRETION, so the row is created
                # already ended rather than the request being refused for the
                # absence of a planning figure.
                row = c.execute(text("""
                    INSERT INTO cq_collection_state
                           (campaign_id, respondent_target, lifecycle_state, ended_at,
                            end_reason, ended_by_user_id, evidence_cutoff,
                            completion_policy, in_progress_disposition,
                            target_at_closure, reached_at_closure,
                            state_revision, last_request_id)
                    VALUES (:cid, NULL, 'ENDED', now(), :reason, :actor, :cutoff,
                            :policy, :disposition, NULL, :reached, 1, :rid)
                    RETURNING campaign_id, respondent_target, lifecycle_state, ended_at,
                              end_reason, ended_by_user_id, state_revision,
                              last_request_id, evidence_cutoff, completion_policy,
                              in_progress_disposition, target_at_closure,
                              reached_at_closure, created_at, updated_at
                """), {'cid': campaign['id'], 'rid': request_id, 'reason': reason,
                       'actor': str(actor), 'cutoff': cutoff,
                       'policy': completion_policy,
                       'disposition': in_progress_disposition,
                       'reached': reached}).mappings().first()

            return self._shape(assessment_id, campaign, row,
                               self._progress(c, campaign, row))
