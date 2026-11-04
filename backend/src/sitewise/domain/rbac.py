"""Role and permission rules (domain layer).

Pure business rules with no framework imports: the presentation layer maps
these onto FastAPI dependencies, the application layer enforces them in use
cases, and tests exercise them directly.

Roles
-----
``user``            Auto-provisioned default; authenticated but role-unassigned.
``entrepreneur``    F&B business user browsing and assessing locations.
``property_owner``  Lists and manages owned commercial properties.
``agent``           Professional agent; listing privileges only after approval.
``administrator``   Back-office administration (never publicly self-assigned).

Ownership rules
---------------
* Entrepreneurs own their saved properties and recommendation results.
* Property owners own the listings they created; they never see or mutate
  another owner's listings through ownership-scoped endpoints.
* Agents cannot mutate arbitrary property records; agent listing privileges
  additionally require professional verification (a flag the application
  database does not carry yet - see the gap analysis).
* Administrators act within explicitly authorized administrative routes.
"""

from __future__ import annotations

ROLE_USER = "user"
ROLE_ENTREPRENEUR = "entrepreneur"
ROLE_PROPERTY_OWNER = "property_owner"
ROLE_AGENT = "agent"
ROLE_ADMINISTRATOR = "administrator"

ALL_ROLES = (
    ROLE_USER,
    ROLE_ENTREPRENEUR,
    ROLE_PROPERTY_OWNER,
    ROLE_AGENT,
    ROLE_ADMINISTRATOR,
)

# Roles a person may hold while self-registering. Administrators are excluded:
# no public flow may mint an administrator.
PUBLIC_REGISTRATION_ROLES = (ROLE_ENTREPRENEUR, ROLE_PROPERTY_OWNER, ROLE_AGENT)

# Roles allowed to create / mutate property listings.
PROPERTY_MANAGEMENT_ROLES = (ROLE_PROPERTY_OWNER, ROLE_ADMINISTRATOR)

# Roles that may read any user's saved properties / recommendations
# (administrative overview). Everyone else is limited to their own rows.
GLOBAL_READ_ROLES = (ROLE_ADMINISTRATOR,)

# Roles allowed to list every user and mutate account status.
USER_ADMINISTRATION_ROLES = (ROLE_ADMINISTRATOR,)

ACCOUNT_STATUSES = ("pending", "active", "suspended")
STATUS_ACTIVE = "active"
STATUS_SUSPENDED = "suspended"

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


def is_valid_role(role: str) -> bool:
    return role in ALL_ROLES


def is_valid_status(status: str) -> bool:
    return status in ACCOUNT_STATUSES


def has_role(role: str, allowed: tuple[str, ...]) -> bool:
    """``True`` when ``role`` is one of ``allowed``.

    Administrators keep their own explicit grants: they are only included in
    the matrices above where the specification grants them that power, so this
    function performs no implicit elevation.
    """
    return role in allowed


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
