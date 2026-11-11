"""Read existing UC records; never infer current QJ admission from history."""
from uuid import UUID

from sqlalchemy import text
from sqlmodel import Session

from sitewise.core.exceptions import NotFoundError


class UcHistoryRepository:
    def __init__(self, session: Session):
        self.session = session

    def read_version(self, version_id: UUID, actor_id: UUID, *, after_event_no: int = 0) -> dict:
        # Explicit ownership in SQL as well as verified identity at the HTTP edge.
        version = self.session.execute(text("""
            SELECT v.id, v.candidate_id, v.version_no, v.origin,
                   v.source_snapshot_id, v.exact_text, c.assessment_id,
                   a.revision, a.confirmed_revision, s.assessment_revision,
                   (SELECT e.action FROM project1_uc.candidate_events e
                    WHERE e.version_id=v.id ORDER BY e.event_no DESC LIMIT 1) AS latest_action,
                   (SELECT coalesce(jsonb_agg(to_jsonb(page) ORDER BY page.event_no), '[]'::jsonb)
                    FROM (SELECT e.id, e.event_no, e.action, e.actor_user_id,
                                 e.confirmed_uncertainty_id, e.created_at,
                                 u.exact_text AS confirmed_exact_text
                          FROM project1_uc.candidate_events e
                          LEFT JOIN public.m2_confirmed_uncertainties u
                            ON u.id=e.confirmed_uncertainty_id
                           AND u.actor_user_id=:actor_id
                           AND u.confirmation_id=v.source_snapshot_id
                          WHERE e.version_id=v.id AND e.event_no > :after_event_no
                          ORDER BY e.event_no LIMIT 101) page) AS history_page,
                   (v.version_no = (SELECT max(n.version_no)
                     FROM project1_uc.candidate_versions n
                     WHERE n.candidate_id = v.candidate_id)) AS latest_version
            FROM project1_uc.candidate_versions v
            JOIN project1_uc.candidates c ON c.id = v.candidate_id
            JOIN public.m2_assessments a ON a.id = c.assessment_id
            JOIN public.m2_confirmation_snapshots s ON s.id = v.source_snapshot_id
            WHERE v.id = :version_id AND a.owner_user_id = :actor_id
              AND s.assessment_id = a.id AND s.actor_user_id = :actor_id
        """), {"version_id": version_id, "actor_id": actor_id,
                 "after_event_no": after_event_no}).mappings().one_or_none()
        if version is None:
            raise NotFoundError("Uncertainty version not found.")
        # One SQL statement gives the latest action and page the same MVCC
        # snapshot even when a decision is appended concurrently.
        version = dict(version)
        events = version.pop("history_page")
        has_more = len(events) > 100
        events = events[:100]
        return {
            "version": dict(version), "events": [dict(e) for e in events],
            "latest_recorded_action": version["latest_action"],
            "next_after_event_no": events[-1]["event_no"] if has_more else None,
            "history_only": True,
            "qj_admission_status": "NOT_EVALUATED",
            "qj_handoff_authorized": False,
        }
