"""Provider performance — only what SiteWise actually measures.

The retired Agent web page drew an impressions -> views -> contact-clicks ->
enquiries funnel with every stage marked "not captured", because no event is
logged anywhere for the first three. That honesty is preserved here: this
service reports the two things that ARE stored (listing state, enquiries) and
the engagement stages are reported as ``tracked: false`` with the reason —
never as a zero, which would be indistinguishable from "measured, and it was
0".

Nothing here estimates, extrapolates or invents. The property counts are
arithmetic over the caller's own managed rows and the enquiry counts are
arithmetic over the caller's own enquiries.
"""

from __future__ import annotations

from typing import Any

from sqlalchemy import text
from sqlmodel import Session

from sitewise.services.enquiry_service import EnquiryService

#: ``fyp.rental_properties.verification_status`` values this report groups by.
_LISTING_STATES: tuple[str, ...] = (
    "draft",
    "pending",
    "under_review",
    "approved",
    "rejected",
)

#: Engagement metrics the product concept needs but the schema does not store.
#: Reported explicitly as unavailable so a screen never renders a fake zero.
_UNTRACKED_METRICS: tuple[dict[str, str], ...] = (
    {
        "key": "impressions",
        "label": "Impressions",
        "reason": "Search and recommendation results are not logged.",
    },
    {
        "key": "views",
        "label": "Listing views",
        "reason": "No page-view event is emitted when a listing is opened.",
    },
    {
        "key": "contact_clicks",
        "label": "Contact clicks",
        "reason": "Sending an enquiry is not accompanied by a click event.",
    },
)


class ProviderPerformanceService:
    """Listing and enquiry arithmetic over the caller's own managed rows."""

    def __init__(self, session: Session):
        self.session = session

    def _listing_rows(self, property_ids: list[int] | None) -> list[dict[str, Any]]:
        params: dict[str, Any] = {}
        where = ""
        if property_ids is not None:
            if not property_ids:
                return []
            names = [f"__pid_{i}" for i in range(len(property_ids))]
            where = (
                " WHERE id IN (" + ", ".join(f":{name}" for name in names) + ")"
            )
            params.update(
                dict(zip(names, (int(v) for v in property_ids), strict=True))
            )
        rows = self.session.execute(
            text(
                "SELECT id, verification_status, is_published, rental_price, "
                "size_sqft FROM fyp.rental_properties" + where
            ),
            params,
        ).mappings().all()
        return [dict(row) for row in rows]

    def report(
        self, *, property_ids: list[int] | None, is_agent: bool
    ) -> dict[str, Any]:
        rows = self._listing_rows(property_ids)

        by_state = {state: 0 for state in _LISTING_STATES}
        other = 0
        published = 0
        rents = [
            float(row["rental_price"])
            for row in rows
            if isinstance(row["rental_price"], (int, float))
        ]
        sizes = [
            float(row["size_sqft"])
            for row in rows
            if isinstance(row["size_sqft"], (int, float))
        ]
        for row in rows:
            state = str(row["verification_status"] or "")
            if state in by_state:
                by_state[state] += 1
            else:
                other += 1
            # Publication is its own flag: an approved-but-unpublished row is
            # not a live listing.
            if state == "approved" and row["is_published"]:
                published += 1

        enquiries = EnquiryService(self.session).metrics(property_ids=property_ids)

        return {
            "scope": {
                "is_agent": bool(is_agent),
                "managed_properties": len(rows),
            },
            "listings": {
                "total": len(rows),
                "published": published,
                "by_state": by_state,
                "other_state": other,
            },
            "portfolio": {
                "median_rent": _median(rents),
                "average_size_sqft": (sum(sizes) / len(sizes)) if sizes else None,
            },
            "enquiries": enquiries,
            "engagement": {
                "tracked": False,
                "reason": (
                    "SiteWise records listing state and enquiries. It does not "
                    "record impressions, views or contact clicks, so they are "
                    "not reported rather than shown as zero."
                ),
                "metrics": [dict(metric) for metric in _UNTRACKED_METRICS],
            },
        }


def _median(values: list[float]) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    middle = len(ordered) // 2
    if len(ordered) % 2:
        return ordered[middle]
    return (ordered[middle - 1] + ordered[middle]) / 2
