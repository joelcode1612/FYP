from collections import Counter

from sqlalchemy import text
from sqlmodel import Session

from sitewise.domain import rbac
from sitewise.services.property_verification_service import AdminPropertyReviewService


def dashboard_statistics(session: Session) -> dict:
    """Aggregate the operational catalogue independently of the review preview."""
    reviews = AdminPropertyReviewService(session)
    directory = reviews.queue(scope="all", limit=1)
    queue = reviews.queue(scope="queue", limit=6)
    summary = directory["summary"]
    verification = dict(session.execute(text("""
        SELECT CASE
            WHEN pv.listing_status IN ('pending', 'under_review')
              OR pv.ownership_status IN ('pending', 'under_review') THEN 'pending'
            WHEN pv.listing_status = 'rejected' OR pv.ownership_status = 'rejected'
                THEN 'rejected'
            WHEN pv.listing_status = 'information_requested'
              OR pv.ownership_status = 'information_requested' THEN 'information_requested'
            WHEN pv.listing_status = 'verified' THEN 'verified'
            ELSE 'not_submitted'
        END AS status, count(*)
        FROM fyp.rental_properties p
        LEFT JOIN fyp.property_verification pv ON pv.property_id = p.id
        GROUP BY 1
    """)).tuples().all())
    property_types = session.execute(text("""
        SELECT lower(NULLIF(btrim(property_type), '')) AS type, count(*)
        FROM fyp.rental_properties GROUP BY 1
    """)).all()
    types: Counter[str] = Counter()
    for raw_type, count in property_types:
        normalized = (raw_type or "").replace("_", " ").replace("-", " ")
        label = {
            "shop": "Shop lot", "shoplot": "Shop lot", "shop lot": "Shop lot",
            "retail": "Retail space", "retail space": "Retail space",
        }.get(normalized, normalized.capitalize() or "Type not recorded")
        types[label] += count

    roles: Counter[str] = Counter()
    for role, count in session.execute(text("SELECT role, count(*) FROM public.users GROUP BY role")):
        roles[rbac.canonical_role(role) or "unknown"] += count

    return {
        "total_properties": summary["total"],
        "published": summary["published"],
        "pending_reviews": queue["total"],
        "registered_users": sum(roles.values()),
        "verification": verification,
        "states": directory["counts"]["state"],
        "types": dict(types),
        "roles": dict(roles),
        "reviews": [
            {
                "id": row["property_id"],
                "name": row["title"],
                "city": row["city"],
                "state": row["state"],
                "status": (
                    row["listing_status"]
                    if row["listing_status"] in ("pending", "under_review")
                    else row["ownership_status"]
                ),
            }
            for row in queue["items"]
        ],
    }
