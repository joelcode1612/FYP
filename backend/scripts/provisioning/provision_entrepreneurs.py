"""Provision Entrepreneur accounts from an authorised CSV.

Design constraints that this script does not relax
--------------------------------------------------
* An account exists only if Supabase Auth created it. The UUID written to
  ``public.users`` (Supabase and local) is the UUID Supabase returned — it is
  never generated here. A locally invented UUID is not an authenticated
  account and is never presented as one.
* ``email_verified`` is read from the Auth user's ``email_confirmed_at`` /
  ``confirmed_at``. It is never set true by this script, and an account that
  has not confirmed is reported as ``pending`` and cannot sign in.
* No password is created, shared or printed. The invite strategy uses
  Supabase's own password-setup link; the ``admin-create`` strategy creates an
  identity with no password that the owner must set through password recovery.
* Re-running is safe: each row is matched on the Supabase Auth identity, then
  reconciled, then given a draft listing only if the owner has none.

CSV columns
-----------
Required: ``email``, ``full_name``, ``property_name``
Optional: ``phone_number``, ``property_type``, ``address``, ``city``, ``state``,
          ``postcode``, ``rental_price``, ``size_sqft``

Blank optional fields produce an explicitly incomplete draft, which is the
honest representation: no coordinates are invented and nothing is published.

Usage (from ``backend``)::

    # Validate the file and show what would happen. Writes nothing.
    .\\.venv\\Scripts\\python.exe -m scripts.provisioning.provision_entrepreneurs \
        --csv path/to/entrepreneurs.csv

    # Create the accounts and their drafts.
    .\\.venv\\Scripts\\python.exe -m scripts.provisioning.provision_entrepreneurs \
        --csv path/to/entrepreneurs.csv --apply
"""

from __future__ import annotations

import argparse
import csv
import re
import sys
import uuid
from datetime import UTC, datetime
from pathlib import Path

from sqlalchemy import text
from sqlmodel import Session

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "src"))

from sitewise.core.config import settings  # noqa: E402
from sitewise.core.supabase_admin import SupabaseAdminService  # noqa: E402
from sitewise.db.session import engine  # noqa: E402
from sitewise.domain import rbac  # noqa: E402
from sitewise.repositories.fyp_property_repository import FypPropertyRepository  # noqa: E402

EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[A-Za-z]{2,}$")

REQUIRED = ("email", "full_name", "property_name")

REPORT_FIELDS = [
    "email",
    "full_name",
    "auth_user_id",
    "supabase_profile",
    "local_profile",
    "email_verified",
    "account_status",
    "can_authenticate",
    "property_id",
    "outcome",
    "detail",
]


def _read_rows(path: Path) -> list[dict[str, str]]:
    with path.open(newline="", encoding="utf-8-sig") as handle:
        reader = csv.DictReader(handle)
        missing = [c for c in REQUIRED if c not in (reader.fieldnames or [])]
        if missing:
            raise SystemExit(f"CSV is missing required column(s): {', '.join(missing)}")
        rows = []
        for index, raw in enumerate(reader, start=2):
            row = {(k or "").strip(): (v or "").strip() for k, v in raw.items()}
            if not any(row.values()):
                continue
            row["_line"] = str(index)
            rows.append(row)
    return rows


def _validate(rows: list[dict[str, str]]) -> list[str]:
    problems: list[str] = []
    seen: dict[str, str] = {}
    for row in rows:
        email = row.get("email", "").lower()
        line = row["_line"]
        if not EMAIL_RE.match(email):
            problems.append(f"line {line}: invalid email {row.get('email')!r}")
        if not row.get("full_name"):
            problems.append(f"line {line}: full_name is required")
        if not row.get("property_name"):
            problems.append(f"line {line}: property_name is required")
        if email in seen:
            problems.append(f"line {line}: duplicate email {email} (also line {seen[email]})")
        else:
            seen[email] = line
    return problems


def _ensure_auth_identity(
    service: SupabaseAdminService, *, email: str, full_name: str, strategy: str
) -> tuple[dict | None, str]:
    """Return ``(auth_user, detail)``. Never fabricates an identity."""
    existing = service.find_auth_user_by_email(email)
    if existing is not None:
        return existing, "auth identity already existed"
    if strategy == "invite":
        try:
            invited = service.client.auth.admin.invite_user_by_email(
                email,
                options={
                    "data": {"full_name": full_name},
                    "redirect_to": settings.entrepreneur_invite_redirect,
                },
            )
            data = getattr(invited, "model_dump", None)
            return (data() if callable(data) else invited), "invitation email sent"
        except Exception as exc:  # noqa: BLE001 - reported, never guessed
            return None, f"invite failed: {type(exc).__name__}: {exc}"
    try:
        created = service.client.auth.admin.create_user(
            {
                "email": email,
                "email_confirm": False,
                "user_metadata": {"full_name": full_name},
            }
        )
        data = getattr(created, "user", None) or created
        dump = getattr(data, "model_dump", None)
        return (dump() if callable(dump) else data), "auth identity created (unconfirmed)"
    except Exception as exc:  # noqa: BLE001
        return None, f"create_user failed: {type(exc).__name__}: {exc}"


def _auth_facts(auth_user: dict) -> tuple[str, bool]:
    user_id = str(auth_user.get("id") or "")
    confirmed = bool(
        auth_user.get("email_confirmed_at") or auth_user.get("confirmed_at")
    )
    return user_id, confirmed


def _sync_local(
    session: Session, *, user_id: str, email: str, full_name: str, status: str, verified: bool
) -> str:
    """Create-or-update the local enforcement mirror with the SAME UUID."""
    uid = uuid.UUID(user_id)
    existing = session.execute(
        text("SELECT user_id::text, email FROM users WHERE user_id = :uid"),
        {"uid": user_id},
    ).mappings().first()
    collision = session.execute(
        text("SELECT user_id::text FROM users WHERE lower(email) = :email"),
        {"email": email.lower()},
    ).mappings().first()
    if collision is not None and collision["user_id"] != user_id:
        # Never resolve an identity collision by email. Report it.
        return f"collision: local row {collision['user_id']} already owns this email"
    now = datetime.now(UTC)
    if existing is None:
        session.execute(
            text(
                """
                INSERT INTO users (user_id, full_name, email, role, account_status,
                                   email_verified, created_at, updated_at)
                VALUES (:uid, :name, :email, :role, :status, :verified, :now, :now)
                """
            ),
            {
                "uid": str(uid),
                "name": full_name,
                "email": email,
                "role": rbac.ROLE_ENTREPRENEUR,
                "status": status,
                "verified": verified,
                "now": now,
            },
        )
        session.commit()
        return "local profile created"
    session.execute(
        text(
            """
            UPDATE users SET full_name = :name, role = :role, account_status = :status,
                             email_verified = :verified, updated_at = :now
            WHERE user_id = :uid
            """
        ),
        {
            "uid": str(uid),
            "name": full_name,
            "role": rbac.ROLE_ENTREPRENEUR,
            "status": status,
            "verified": verified,
            "now": now,
        },
    )
    session.commit()
    return "local profile updated"


def _existing_property(session: Session, owner_user_id: str) -> int | None:
    value = session.execute(
        text(
            "SELECT id FROM fyp.rental_properties WHERE owner_user_id = :owner "
            "ORDER BY id LIMIT 1"
        ),
        {"owner": owner_user_id},
    ).scalar()
    return int(value) if value is not None else None


def _draft_payload(row: dict[str, str]) -> dict:
    """Only fields the CSV genuinely supplies. No coordinates are invented."""

    def number(key: str) -> float | None:
        raw = row.get(key, "").strip()
        if not raw:
            return None
        try:
            return float(raw)
        except ValueError:
            return None

    return {
        "name": row["property_name"],
        "property_type": row.get("property_type", ""),
        "description": None,
        "address": row.get("address", ""),
        "city": row.get("city", ""),
        "state": row.get("state", ""),
        "postcode": row.get("postcode", ""),
        "latitude": None,
        "longitude": None,
        "rental_price": number("rental_price"),
        "size_sqft": number("size_sqft"),
        "availability": "",
        "floor_level": None,
        "frontage_ft": None,
        "has_parking": False,
        "is_fnb_suitable": False,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--csv", type=Path, required=True)
    parser.add_argument("--apply", action="store_true", help="create accounts and drafts")
    parser.add_argument(
        "--strategy",
        choices=("invite", "admin-create"),
        default="invite",
        help="invite = Supabase invitation email; admin-create = identity without email",
    )
    parser.add_argument("--limit", type=int, default=None)
    parser.add_argument("--report", type=Path, default=Path("var/entrepreneur_provisioning.csv"))
    args = parser.parse_args()

    if not args.csv.exists():
        raise SystemExit(f"CSV not found: {args.csv}")
    rows = _read_rows(args.csv)
    problems = _validate(rows)
    if problems:
        print("The CSV cannot be processed:")
        for problem in problems:
            print(f"  {problem}")
        return 2
    if args.limit:
        rows = rows[: args.limit]

    print(f"Rows to process : {len(rows)}")
    print(f"Mode            : {'APPLY' if args.apply else 'DRY RUN'}")
    print(f"Identity route  : {args.strategy}")
    print(f"Supabase        : {settings.supabase_url}")
    print(f"Local database  : {settings.database_url.rsplit('/', 1)[-1]}")
    print()

    service = SupabaseAdminService()
    report: list[dict] = []
    counts: dict[str, int] = {}

    with Session(engine) as session:
        for row in rows:
            email = row["email"].lower()
            full_name = row["full_name"]
            entry = {
                "email": email,
                "full_name": full_name,
                "auth_user_id": "",
                "supabase_profile": "",
                "local_profile": "",
                "email_verified": "",
                "account_status": "",
                "can_authenticate": "no",
                "property_id": "",
                "outcome": "",
                "detail": "",
            }

            if not args.apply:
                existing = service.find_auth_user_by_email(email)
                entry["outcome"] = "would_provision" if existing is None else "exists"
                entry["auth_user_id"] = str((existing or {}).get("id") or "")
                report.append(entry)
                counts[entry["outcome"]] = counts.get(entry["outcome"], 0) + 1
                continue

            auth_user, detail = _ensure_auth_identity(
                service, email=email, full_name=full_name, strategy=args.strategy
            )
            if auth_user is None:
                entry["outcome"] = "auth_failed"
                entry["detail"] = detail
                report.append(entry)
                counts["auth_failed"] = counts.get("auth_failed", 0) + 1
                continue

            user_id, verified = _auth_facts(auth_user)
            if not user_id:
                entry["outcome"] = "auth_failed"
                entry["detail"] = "Auth response carried no user id"
                report.append(entry)
                counts["auth_failed"] = counts.get("auth_failed", 0) + 1
                continue

            status = rbac.STATUS_ACTIVE if verified else rbac.STATUS_PENDING
            entry["auth_user_id"] = user_id
            entry["email_verified"] = "yes" if verified else "no"
            entry["account_status"] = status

            # 1. Supabase public.users — authoritative identity row.
            try:
                service.upsert_identity_profile(
                    user_id=user_id,
                    email=email,
                    full_name=full_name,
                    phone_number=row.get("phone_number") or None,
                    role=rbac.ROLE_ENTREPRENEUR,
                    account_status=status,
                )
                service.update_identity_profile(user_id, {"email_verified": verified})
                entry["supabase_profile"] = "synced"
            except Exception as exc:  # noqa: BLE001
                entry["outcome"] = "supabase_profile_failed"
                entry["detail"] = f"{type(exc).__name__}: {exc}"
                report.append(entry)
                counts["supabase_profile_failed"] = counts.get("supabase_profile_failed", 0) + 1
                continue

            # 2. Local mirror — same UUID, same role/status.
            local = _sync_local(
                session,
                user_id=user_id,
                email=email,
                full_name=full_name,
                status=status,
                verified=verified,
            )
            entry["local_profile"] = local
            if local.startswith("collision"):
                entry["outcome"] = "local_collision"
                entry["detail"] = local
                report.append(entry)
                counts["local_collision"] = counts.get("local_collision", 0) + 1
                continue

            # 3. One owned draft listing, created only when the owner has none.
            property_id = _existing_property(session, user_id)
            if property_id is None:
                try:
                    created = FypPropertyRepository(session).create_owner_draft(
                        owner_user_id=user_id, payload=_draft_payload(row)
                    )
                    property_id = int(created["id"])
                    entry["detail"] = "draft listing created (unpublished)"
                except Exception as exc:  # noqa: BLE001
                    entry["outcome"] = "property_failed"
                    entry["detail"] = f"{type(exc).__name__}: {exc}"
                    report.append(entry)
                    counts["property_failed"] = counts.get("property_failed", 0) + 1
                    continue
            else:
                entry["detail"] = "owner already had a listing"
            entry["property_id"] = str(property_id)
            entry["can_authenticate"] = "yes" if verified else "no (email not confirmed)"
            entry["outcome"] = "provisioned" if verified else "provisioned_pending"
            report.append(entry)
            counts[entry["outcome"]] = counts.get(entry["outcome"], 0) + 1

    args.report.parent.mkdir(parents=True, exist_ok=True)
    with args.report.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=REPORT_FIELDS)
        writer.writeheader()
        writer.writerows(report)

    print("Outcomes:")
    for name, count in sorted(counts.items()):
        print(f"  {name:<24} {count}")
    print(f"\nReport: {args.report.resolve()}")
    if not args.apply:
        print("\nDRY RUN — no account, profile or listing was written.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
