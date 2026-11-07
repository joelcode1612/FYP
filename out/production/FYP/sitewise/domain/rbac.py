"""Role and permission rules (domain layer).

Pure business rules with no framework imports: the presentation layer maps
these onto FastAPI dependencies, the application layer enforces them in use
cases, and tests exercise them directly.

Roles (confirmed SITEWISE model — exactly three, stored authoritatively in
``public.users.role``)
--------------------------------------------------------------------------------
``entrepreneur``  Public self-registration. Explores properties, creates
                  assessments, accesses reports, saves/owns properties.
``agent``         Created by an administrator only. Email/password sign-in,
                  mandatory TOTP MFA, manages ONLY assigned listings.
``admin``         Securely provisioned. Everything an agent can do plus staff
                  administration (create/suspend agents, assign listings,
                  approve listings, audit review, survey campaigns).

Legacy aliases
--------------
The database and older code versions carried ``user``, ``administrator`` and
``property_owner``. These are normalised to canonical roles on read via
:func:`canonical_role`; they are never written again.

Ownership rules
---------------
* Entrepreneurs own their saved properties and recommendation results, and
  manage properties they own (``property.user_id``) or are authorized to
  manage. There is no separate ``property_owner`` role.
* Agents reach listings only through the
  ``authenticated UUID -> agent profile (agent.user_id) -> listing.agent_id``
  chain; they never mutate another agent's listings.
* Administrators act within explicitly authorized administrative routes.
* Community questionnaire access depends on survey eligibility, not on a
  ``resident`` role (which does not exist).
"""

from __future__ import annotations

ROLE_ENTREPRENEUR = "entrepreneur"
ROLE_AGENT = "agent"
ROLE_ADMIN = "admin"

ALL_ROLES = (ROLE_ENTREPRENEUR, ROLE_AGENT, ROLE_ADMIN)

# Legacy values found in existing databases / older code. They are mapped to
# canonical roles wherever a role is read; writes always use canonical values.
ROLE_USER = "user"  # deprecated alias of entrepreneur
ROLE_PROPERTY_OWNER = "property_owner"  # deprecated alias of entrepreneur
ROLE_ADMINISTRATOR = "administrator"  # deprecated alias of admin

LEGACY_ROLE_ALIASES: dict[str, str] = {
    ROLE_USER: ROLE_ENTREPRENEUR,
    ROLE_PROPERTY_OWNER: ROLE_ENTREPRENEUR,
    ROLE_ADMINISTRATOR: ROLE_ADMIN,
}

# Roles a person may hold while self-registering. Only entrepreneurs may be
# minted publicly: agents and administrators are provisioned by the trusted
# backend, and a client-submitted role claim is always ignored.
PUBLIC_REGISTRATION_ROLES = (ROLE_ENTREPRENEUR,)

# Roles that may create / mutate property listings. Property ownership is an
# ownership relationship on the property row, so entrepreneurs manage the
# properties they own; administrators manage any property administratively.
PROPERTY_MANAGEMENT_ROLES = (ROLE_ENTREPRENEUR, ROLE_ADMIN)

# Staff portal roles (agents + administrators).
STAFF_ROLES = (ROLE_AGENT, ROLE_ADMIN)

# Roles that may read any user's saved properties / recommendations
# (administrative overview). Everyone else is limited to their own rows.
GLOBAL_READ_ROLES = (ROLE_ADMIN,)

# Roles allowed to list every user and mutate account status.
USER_ADMINISTRATION_ROLES = (ROLE_ADMIN,)

ACCOUNT_STATUSES = ("pending", "active", "suspended")
STATUS_ACTIVE = "active"
STATUS_SUSPENDED = "suspended"
STATUS_PENDING = "pending"

# Authentication assurance level required for staff operations. Supabase
# puts the verified level in the ``aal`` claim: ``aal1`` = password only,
# ``aal2`` = password + a verified MFA factor. A password login alone
# (``aal1``) must never authorize protected staff operations.
REQUIRED_STAFF_AAL = "aal2"

# Profile fields the authenticated owner may edit about themselves.
SELF_EDITABLE_PROFILE_FIELDS = ("full_name", "phone_number", "profile_picture_url")

# Fields whose authoritative value lives server-side. A client-submitted
# change to any of these is rejected, never silently ignored.
PROTECTED_PROFILE_FIELDS = (
    "user_id",
    "email",
    "role",
    "account_status",
    "email_verified",
    "last_login",
    "created_at",
    "updated_at",
)


def canonical_role(role: str | None) -> str | None:
    """Normalise a stored / submitted role to its canonical value.

    Legacy values map to the confirmed three-role model; unknown values pass
    through unchanged so callers can still reject them explicitly.
    """
    if role is None:
        return None
    return LEGACY_ROLE_ALIASES.get(role, role)


def is_valid_role(role: str) -> bool:
    return canonical_role(role) in ALL_ROLES


def is_valid_status(status: str) -> bool:
    return status in ACCOUNT_STATUSES


def has_role(role: str, allowed: tuple[str, ...]) -> bool:
    """``True`` when the canonical form of ``role`` is one of ``allowed``.

    Legacy aliases are honoured on read (existing records keep working) but
    administrators keep their own explicit grants: they are only included in
    the matrices above where the specification grants them that power, so no
    implicit elevation happens here.
    """
    return canonical_role(role) in allowed


def is_staff(role: str) -> bool:
    return has_role(role, STAFF_ROLES)


def can_manage_properties(role: str) -> bool:
    return has_role(role, PROPERTY_MANAGEMENT_ROLES)


def can_read_any_user_data(role: str) -> bool:
    return has_role(role, GLOBAL_READ_ROLES)


def can_administer_users(role: str) -> bool:
    return has_role(role, USER_ADMINISTRATION_ROLES)


def filter_self_editable(data: dict) -> tuple[dict, list[str]]:
    """Split a client profile-update payload.

    Returns ``(editable, attempted_protected)`` where ``editable`` contains
    only the fields the caller may change and ``attempted_protected`` lists
    the protected fields the caller tried to touch (the application layer
    rejects the request when that list is non-empty - rejection, not silent
    ignoring, so clients learn their payload is wrong).
    """
    editable = {
        key: value
        for key, value in data.items()
        if key in SELF_EDITABLE_PROFILE_FIELDS
    }
    attempted = [key for key in data if key not in SELF_EDITABLE_PROFILE_FIELDS]
    return editable, attempted
