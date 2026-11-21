"""Role and permission rules (domain layer).

Pure business rules with no framework imports: the presentation layer maps
these onto FastAPI dependencies, the application layer enforces them in use
cases, and tests exercise them directly.

Roles (authoritative SITEWISE model — exactly four, stored authoritatively in
``public.users.role``)
--------------------------------------------------------------------------------
``admin``         Securely provisioned. Everything an agent can do plus staff
                  administration (create/suspend agents, assign listings,
                  approve listings, audit review, survey campaigns) and the only
                  role that may change another account's role.
``owner``         Property Owner. Manages the properties recorded against their
                  own account (``public.property.owner_id``) and the panoramas
                  attached to them. Not staff: no MFA requirement and no
                  administrative reach.
``agent``         Created by an administrator only. Email/password sign-in,
                  mandatory TOTP MFA, manages ONLY assigned listings.
``entrepreneur``  Public self-registration. Explores properties, creates
                  assessments, accesses reports, saves/owns properties. Reaches a
                  property only through an explicit, per-property authorisation.

Legacy aliases
--------------
The database and older code versions carried ``user``, ``administrator`` and
``property_owner``. These are normalised to canonical roles on read via
:func:`canonical_role`; they are never written again.

**``property_owner`` now maps to ``owner``.** It used to map to
``entrepreneur``, which was correct only while Property Owner was not a role:
ownership was then purely a relationship on the property row. It is a role now,
and folding it into ``entrepreneur`` would demote every real owner to an account
with no property authority at all. The mapping is *parsing*, not promotion — an
account whose stored value is ``entrepreneur`` stays an entrepreneur until an
administrator changes it, and no row is rewritten by reading it back.

Ownership rules
---------------
* A role never grants access to a property on its own. Every property-scoped
  decision takes the role **and** the verified relationship
  (:func:`can_manage_property`); "owner" means nothing without an ownership
  record, and "agent" means nothing without an assignment.
* Owners reach properties they own; agents reach listings only through the
  ``authenticated UUID -> agent profile (agent.user_id) -> listing.agent_id``
  chain; entrepreneurs need an explicit grant; administrators act within
  explicitly authorized administrative routes.
* Community questionnaire access depends on survey eligibility, not on a
  ``resident`` role (which does not exist).
"""

from __future__ import annotations

import enum
from dataclasses import dataclass

ROLE_ADMIN = "admin"
ROLE_OWNER = "owner"
ROLE_AGENT = "agent"
ROLE_ENTREPRENEUR = "entrepreneur"

#: The four authoritative values, in the order the database constraint lists
#: them. Anything outside this tuple is not a role.
ALL_ROLES = (ROLE_ADMIN, ROLE_OWNER, ROLE_AGENT, ROLE_ENTREPRENEUR)

# Legacy values found in existing databases / older code. They are mapped to
# canonical roles wherever a role is read; writes always use canonical values.
ROLE_USER = "user"  # deprecated alias of entrepreneur
ROLE_PROPERTY_OWNER = "property_owner"  # deprecated alias of owner
ROLE_ADMINISTRATOR = "administrator"  # deprecated alias of admin

LEGACY_ROLE_ALIASES: dict[str, str] = {
    ROLE_USER: ROLE_ENTREPRENEUR,
    # The change this module exists for. See the module docstring.
    ROLE_PROPERTY_OWNER: ROLE_OWNER,
    ROLE_ADMINISTRATOR: ROLE_ADMIN,
    # Spelling variants that reach us from forms, CSV imports and older clients.
    "propertyowner": ROLE_OWNER,
    "property owner": ROLE_OWNER,
    "landlord": ROLE_OWNER,
    "property_agent": ROLE_AGENT,
    "f&b_entrepreneur": ROLE_ENTREPRENEUR,
    "fb_entrepreneur": ROLE_ENTREPRENEUR,
}

# Roles a person may hold while self-registering. Only entrepreneurs may be
# minted publicly: owners, agents and administrators are provisioned by the
# trusted backend, and a client-submitted role claim is always ignored.
#
# `owner` is deliberately absent. Self-registration must not create an account
# with property authority, because at that moment there is no verified property
# for it to own.
PUBLIC_REGISTRATION_ROLES = (ROLE_ENTREPRENEUR,)

# Roles that may create / mutate property listings. Property ownership is an
# ownership relationship on the property row, so this tuple is a **coarse gate**
# that admits a role to the surface; it never grants access to a specific
# record.
#
# * `owner`     — manages the properties recorded against its own account.
# * `agent`     — included because the Owner / Agent workspace is a *provider*
#                 workspace: an agent must be able to create a draft and
#                 maintain the listings they represent.
# * `entrepreneur` — retained so accounts provisioned under the old three-role
#                 model keep working. Those accounts own properties recorded with
#                 their `user_id`; the record-level check still applies.
# * `admin`     — acts administratively.
#
# `sitewise.api.v1.properties` additionally requires either `owner_user_id`
# equality, an `agent_listing_assignment` row for the caller's agent profile, or
# an explicit grant, so membership here can never touch an unrelated property.
PROPERTY_MANAGEMENT_ROLES = (ROLE_OWNER, ROLE_ENTREPRENEUR, ROLE_AGENT, ROLE_ADMIN)

# Staff portal roles (agents + administrators). Owners and entrepreneurs are NOT
# staff: they must not inherit staff administrative permissions, and they are not
# subject to the staff MFA requirement.
STAFF_ROLES = (ROLE_AGENT, ROLE_ADMIN)

# Roles that may read any user's saved properties / recommendations
# (administrative overview). Everyone else is limited to their own rows.
GLOBAL_READ_ROLES = (ROLE_ADMIN,)

# Roles allowed to list every user and mutate account status.
USER_ADMINISTRATION_ROLES = (ROLE_ADMIN,)

# Roles allowed to change another account's role. Separate from
# USER_ADMINISTRATION_ROLES so the two can diverge without a silent grant.
ROLE_ADMINISTRATION_ROLES = (ROLE_ADMIN,)

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

    Legacy values map to the four-role model; unknown values pass through
    unchanged so callers can still reject them explicitly via
    :func:`is_valid_role`.

    Normalisation is deliberately conservative: case, surrounding whitespace and
    hyphen/space separators are folded, but nothing else. A role is an
    identifier, not prose.
    """
    if role is None:
        return None
    text = str(role).strip().lower().replace("-", "_")
    if not text:
        return None
    return LEGACY_ROLE_ALIASES.get(text, text)


def normalize_role(role: str | None) -> str | None:
    """Alias of :func:`canonical_role` returning ``None`` for unknown values.

    The capture app's shared RBAC module exposes this name; keeping both makes
    the two copies of the module interchangeable.
    """
    canonical = canonical_role(role)
    return canonical if canonical in ALL_ROLES else None


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
    """Coarse gate: may this role attempt property management at all?

    Passing this is **not** authorisation for a specific property — the caller
    must still resolve the relationship and call :func:`can_manage_property`.
    """
    return has_role(role, PROPERTY_MANAGEMENT_ROLES)


def can_read_any_user_data(role: str) -> bool:
    return has_role(role, GLOBAL_READ_ROLES)


def can_administer_users(role: str) -> bool:
    return has_role(role, USER_ADMINISTRATION_ROLES)


def can_change_roles(role: str) -> bool:
    """Only an administrator may change another account's role."""
    return has_role(role, ROLE_ADMINISTRATION_ROLES)


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


# ---------------------------------------------------------------------------
# Permission matrix
# ---------------------------------------------------------------------------
# The names here are also written into the Flutter client's
# `SitewisePermission` enum and into the capture app's copy of this module. A
# rename in one place is a silent authorisation change in the other, so the
# strings are the contract.


class Permission(enum.StrEnum):
    """What a role may attempt at the role level."""

    view_own_profile = "view_own_profile"
    manage_own_property = "manage_own_property"
    capture_panorama = "capture_panorama"
    upload_panorama = "upload_panorama"
    view_published_panorama = "view_published_panorama"
    change_user_role = "change_user_role"
    manage_agent_accounts = "manage_agent_accounts"


_COMMON_PERMISSIONS = frozenset(
    {
        Permission.view_own_profile,
        Permission.view_published_panorama,
    }
)

ROLE_PERMISSIONS: dict[str, frozenset[Permission]] = {
    ROLE_ADMIN: _COMMON_PERMISSIONS
    | {
        Permission.manage_own_property,
        Permission.capture_panorama,
        Permission.upload_panorama,
        Permission.change_user_role,
        Permission.manage_agent_accounts,
    },
    ROLE_OWNER: _COMMON_PERMISSIONS
    | {
        Permission.manage_own_property,
        Permission.capture_panorama,
        Permission.upload_panorama,
    },
    ROLE_AGENT: _COMMON_PERMISSIONS
    | {
        Permission.manage_own_property,
        Permission.capture_panorama,
        Permission.upload_panorama,
    },
    # An entrepreneur may capture and upload only for a property they are
    # explicitly authorised for, which is a property-level decision. At the role
    # level they are therefore *not* granted `manage_own_property`: that
    # permission means "this role may manage a property it is entitled to", and
    # an entrepreneur's entitlement is never implied.
    ROLE_ENTREPRENEUR: _COMMON_PERMISSIONS
    | {
        Permission.capture_panorama,
        Permission.upload_panorama,
    },
}


def permissions_for(role: str) -> frozenset[Permission]:
    """The role-level permission set. Unknown roles get nothing."""
    canonical = canonical_role(role)
    return ROLE_PERMISSIONS.get(canonical or "", frozenset())


def can(role: str, permission: Permission) -> bool:
    """Whether ``role`` holds ``permission`` at the role level."""
    return permission in permissions_for(role)


# ---------------------------------------------------------------------------
# Property-level decisions
# ---------------------------------------------------------------------------


class PropertyRelationship(enum.StrEnum):
    """How the signed-in account relates to one specific property.

    Resolved from real rows by the repository layer. Never inferred from a
    session id, a query parameter or a client-supplied property id.
    """

    none = "none"
    owned = "owned"
    assigned_agent = "assigned_agent"
    explicit_grant = "explicit_grant"
    administrator = "administrator"


@dataclass(frozen=True, slots=True)
class AccessDecision:
    """The result of an authorisation question, with a user-safe reason."""

    allowed: bool
    reason: str

    def __bool__(self) -> bool:
        return self.allowed

    @classmethod
    def allow(cls, reason: str) -> "AccessDecision":
        return cls(True, reason)

    @classmethod
    def deny(cls, reason: str) -> "AccessDecision":
        return cls(False, reason)


def resolve_relationship(
    *,
    role: str,
    owns_property: bool = False,
    is_assigned_agent: bool = False,
    has_explicit_grant: bool = False,
) -> PropertyRelationship:
    """Build the relationship from verified repository facts.

    The order encodes precedence, not preference: an administrator acting
    administratively is recorded as such even if they also happen to own the
    property, because the audit trail should say which capacity was used.
    """
    canonical = canonical_role(role)
    if canonical == ROLE_ADMIN:
        return PropertyRelationship.administrator
    if owns_property:
        return PropertyRelationship.owned
    if is_assigned_agent:
        return PropertyRelationship.assigned_agent
    if has_explicit_grant:
        return PropertyRelationship.explicit_grant
    return PropertyRelationship.none


def can_manage_property(
    role: str, relationship: PropertyRelationship
) -> AccessDecision:
    """Whether ``role`` may manage a property with this verified relationship.

    This is the function every property-scoped endpoint must call. The same
    matrix is enforced a second time in the database by
    ``public.sitewise_can_manage_property(bigint)`` and by the RLS policies on
    ``public.pano_jobs`` and the ``property-panoramas`` bucket, so a client that
    never calls this API is still constrained.
    """
    canonical = canonical_role(role)

    if relationship is PropertyRelationship.administrator:
        if canonical == ROLE_ADMIN:
            return AccessDecision.allow("Administrator access.")
        # Someone claiming the administrative relationship without being an
        # administrator is not an administrator.
        return AccessDecision.deny(
            "Only an administrator may act administratively on a property."
        )

    if canonical == ROLE_ADMIN:
        # An administrator with no verified relationship: refuse rather than
        # assume. The relationship is the proof, not the role.
        return AccessDecision.deny(
            "No verified administrative relationship with this property."
        )

    if canonical == ROLE_OWNER:
        if relationship is PropertyRelationship.owned:
            return AccessDecision.allow("You own this property.")
        return AccessDecision.deny(
            "This property is not registered to your account."
        )

    if canonical == ROLE_AGENT:
        if relationship is PropertyRelationship.assigned_agent:
            return AccessDecision.allow("You are assigned to this property.")
        return AccessDecision.deny("You are not assigned to this property.")

    # Entrepreneur.
    if relationship is PropertyRelationship.explicit_grant:
        return AccessDecision.allow("You are authorised for this property.")
    return AccessDecision.deny(
        "An entrepreneur needs an explicit authorisation for this property."
    )


def can_capture_panorama(
    role: str, relationship: PropertyRelationship
) -> AccessDecision:
    """Capture follows the property rules exactly."""
    return can_manage_property(role, relationship)


def can_upload_panorama(
    role: str, relationship: PropertyRelationship
) -> AccessDecision:
    """Upload is the strictest of the three.

    It is the operation the Storage policy enforces, and the one that puts bytes
    into a folder. An unassociated panorama is never uploaded: there is no folder
    that is legitimately its own.
    """
    if relationship is PropertyRelationship.none:
        return AccessDecision.deny(
            "This capture is not linked to a property you may write to."
        )
    return can_manage_property(role, relationship)


class PermissionDenied(PermissionError):
    """Raised when a decision is a refusal.

    Carries the user-safe reason so the API layer can turn it into a 403 without
    inventing a message, and without leaking ids.
    """

    def __init__(self, decision: AccessDecision) -> None:
        super().__init__(decision.reason)
        self.decision = decision


def require_permission(role: str, permission: Permission) -> None:
    """Raise :class:`PermissionDenied` unless ``role`` holds ``permission``."""
    if not can(role, permission):
        raise PermissionDenied(
            AccessDecision.deny("This role may not perform this action.")
        )


def require_property_access(role: str, relationship: PropertyRelationship) -> None:
    """Raise :class:`PermissionDenied` unless the property decision allows it."""
    decision = can_manage_property(role, relationship)
    if not decision.allowed:
        raise PermissionDenied(decision)


def resolve_effective_role(
    *,
    server_role: object,
    cached_role: object = None,
) -> str:
    """The role to act on when a client also holds a cached one.

    The rule is **never escalate**: the effective role is the less privileged of
    the server's answer and the cached one, and a missing server answer yields
    the least privileged role. A stale cache can therefore cost a user controls
    they do have, but can never grant one they do not.
    """
    server = normalize_role(server_role)  # type: ignore[arg-type]
    if server is None:
        return ROLE_ENTREPRENEUR
    cached = normalize_role(cached_role)  # type: ignore[arg-type]
    if cached is None:
        return server
    return min(cached, server, key=_administrative_breadth)


def _administrative_breadth(role: str) -> int:
    """How much administrative reach a role has.

    Not a statement about property authority — an owner outranks an agent over
    their own building — only about which role does more damage if it is wrong.
    """
    return {
        ROLE_ENTREPRENEUR: 0,
        ROLE_OWNER: 1,
        ROLE_AGENT: 2,
        ROLE_ADMIN: 3,
    }[role]


__all__ = [
    "ALL_ROLES",
    "ACCOUNT_STATUSES",
    "AccessDecision",
    "GLOBAL_READ_ROLES",
    "LEGACY_ROLE_ALIASES",
    "PROPERTY_MANAGEMENT_ROLES",
    "PROTECTED_PROFILE_FIELDS",
    "PUBLIC_REGISTRATION_ROLES",
    "Permission",
    "PermissionDenied",
    "PropertyRelationship",
    "REQUIRED_STAFF_AAL",
    "ROLE_ADMIN",
    "ROLE_ADMINISTRATION_ROLES",
    "ROLE_AGENT",
    "ROLE_ENTREPRENEUR",
    "ROLE_OWNER",
    "ROLE_PERMISSIONS",
    "SELF_EDITABLE_PROFILE_FIELDS",
    "STAFF_ROLES",
    "STATUS_ACTIVE",
    "STATUS_PENDING",
    "STATUS_SUSPENDED",
    "USER_ADMINISTRATION_ROLES",
    "can",
    "can_administer_users",
    "can_capture_panorama",
    "can_change_roles",
    "can_manage_properties",
    "can_manage_property",
    "can_read_any_user_data",
    "can_upload_panorama",
    "canonical_role",
    "filter_self_editable",
    "has_role",
    "is_staff",
    "is_valid_role",
    "is_valid_status",
    "normalize_role",
    "permissions_for",
    "require_permission",
    "require_property_access",
    "resolve_effective_role",
    "resolve_relationship",
]
