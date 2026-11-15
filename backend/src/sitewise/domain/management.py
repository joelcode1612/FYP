"""Property management responsibility (domain layer).

The operational schema has **no** ``management_type`` column and this module
does not add one. Management is *derived* from relationships that already
exist, in one fixed order, so every surface (property detail, recommendations,
owner pages, agent workspace, admin queue) reports the same answer for the
same listing.

Derivation hierarchy
--------------------
The order is deliberate and is the business rule, not an implementation
detail. Each step only applies when the previous step found no *valid*
responsible party.

1. ``AGENT_MANAGED``
   A row exists in ``public.agent_listing_assignment`` for the operational
   property **and** the assigned agent is an active identity with a Supabase
   agent profile. One agent may manage many properties; a property has at most
   one agent (``listing_id`` is the primary key of the assignment table).

2. ``OWNER_MANAGED``
   ``fyp.rental_properties.owner_user_id`` resolves to an *active* account and
   no agent is assigned. This makes the previously implicit rule explicit:
   entrepreneurs manage the properties they own, through the owner endpoints.

3. ``PLATFORM_MANAGED``
   An unclaimed catalogue/demo record held under documented stewardship. See
   :data:`PLATFORM_STEWARDSHIP`. The steward is a **function**
   (catalogue administration), never a person and never an arbitrary
   administrator UUID used as a legal owner.

4. ``UNRESOLVED``
   No valid responsible person and no stewardship policy. This is reported as
   a defect and queued for administrative remediation. It is never relabelled
   as a management type to make an audit look complete.

Ownership is never conflated with management
--------------------------------------------
``owner_user_id`` is the ownership relationship and is preserved separately on
every response. An agent assignment adds management responsibility; it does
not transfer ownership. A legacy ``owner_id`` integer is historical provenance
only — it is never promoted to ``owner_user_id`` without a verified identity.
"""

from __future__ import annotations

from dataclasses import dataclass

TYPE_AGENT = "agent"
TYPE_OWNER = "owner"
TYPE_PLATFORM = "platform"
TYPE_UNRESOLVED = "unresolved"

MANAGEMENT_TYPES = (TYPE_AGENT, TYPE_OWNER, TYPE_PLATFORM, TYPE_UNRESOLVED)

#: Human-readable base labels. A manager's name is appended by the client with
#: an em dash, so the rendered text is e.g. "Managed by Agent — Joel".
#: Platform and unresolved states deliberately carry no name.
LABEL_AGENT = "Managed by Agent"
LABEL_OWNER = "Managed by Owner"
LABEL_PLATFORM_RESEARCH = "Managed by SiteWise — Research Listing"
LABEL_PLATFORM_DEMO = "Managed by SiteWise — Demonstration Listing"
LABEL_UNRESOLVED = "Manager Not Assigned"

#: Provenance classes derived from the operational schema (there is no
#: provenance column; see ``scripts/provisioning/census.py``).
PROVENANCE_RESEARCH = "research_import"
PROVENANCE_DEMO = "demo_seed"
PROVENANCE_OWNER_DRAFT = "owner_draft"
PROVENANCE_OTHER = "other"

#: Documented platform-stewardship policy.
#:
#: Only these provenance classes may be represented as platform-managed. They
#: are records SiteWise holds for research or demonstration purposes; SiteWise
#: does **not** claim legal ownership of them, and the steward is the catalogue
#: administration function rather than any individual.
#:
#: ``owner_draft`` is excluded on purpose: a draft belongs to whoever created
#: it, so an ownerless draft is a defect, not stewardship.
PLATFORM_STEWARDSHIP: dict[str, dict[str, str]] = {
    PROVENANCE_RESEARCH: {
        "label": LABEL_PLATFORM_RESEARCH,
        "steward_role": "catalogue_administrator",
        "ownership_status": "unclaimed",
        "reason": "Verified research catalogue record; no owner is registered.",
    },
    PROVENANCE_DEMO: {
        "label": LABEL_PLATFORM_DEMO,
        "steward_role": "demo_data_administrator",
        "ownership_status": "legacy_unverified",
        "reason": (
            "Demonstration listing seeded before Supabase identities existed; "
            "the recorded legacy owner has no authenticated account."
        ),
    },
}

#: Reasons surfaced to administrators for unresolved properties. They name the
#: actual defect so it can be fixed, and never invent a responsible party.
REASON_OWNER_INACTIVE = "owner_account_not_active"
REASON_OWNER_MISSING = "owner_identity_missing"
REASON_AGENT_INACTIVE = "assigned_agent_not_active"
REASON_AGENT_PROFILE_MISSING = "assigned_agent_profile_missing"
REASON_NO_STEWARDSHIP = "no_owner_and_no_stewardship_policy"

ASSIGNMENT_ACTIVE = "active"
ASSIGNMENT_NONE = "none"

#: ``status`` is the machine-readable companion to ``type``. The shipped
#: ``ListingManagement`` Dart DTO reads ``status``, so both resolvers emit the
#: same object and no client has to branch on which endpoint it called.
STATUS_BY_TYPE: dict[str, str] = {
    TYPE_AGENT: "agent_managed",
    TYPE_OWNER: "owner_managed",
    TYPE_PLATFORM: "platform_managed",
    TYPE_UNRESOLVED: "unresolved",
}


@dataclass(frozen=True)
class ManagementFacts:
    """Everything the rule needs, already resolved by the repository layer.

    Keeping this a plain value object means the rule is testable without a
    database and cannot accidentally read a different source than the caller.
    """

    property_id: int
    provenance: str
    owner_user_id: str | None = None
    owner_display_name: str | None = None
    owner_account_status: str | None = None
    agent_id: int | None = None
    agent_display_name: str | None = None
    agent_account_status: str | None = None
    legacy_owner_id: int | None = None
    verification_status: str | None = None
    is_published: bool = False


def _base(
    management_type: str,
    label: str,
    *,
    facts: ManagementFacts,
    manager_name: str | None = None,
    assignment_status: str = ASSIGNMENT_NONE,
    ownership_status: str = "unknown",
    steward_role: str | None = None,
    reason: str | None = None,
) -> dict:
    """Build the wire contract.

    ``name`` is retained as an alias of ``manager_name`` because the shipped
    Dart mappers (``explore_property_mapper``, ``catalog_property_mapper``)
    read ``management['label']`` and ``management['name']``. Removing it would
    break those clients; both keys always carry the same value.
    """
    name = (manager_name or "").strip() or None
    return {
        "type": management_type,
        "status": STATUS_BY_TYPE[management_type],
        "label": label,
        "name": name,
        "manager_name": name,
        "agent_id": facts.agent_id if management_type == TYPE_AGENT else None,
        "owner_user_id": facts.owner_user_id,
        "assignment_status": assignment_status,
        "ownership_status": ownership_status,
        "steward_role": steward_role,
        "reason": reason,
        "provenance": facts.provenance,
    }


def derive(facts: ManagementFacts) -> dict:
    """Apply the four-step hierarchy to one property.

    The result always has a ``type``: there is no silent default. Callers that
    cannot complete the lookup must report ``unavailable`` themselves rather
    than calling this function with guessed facts.
    """
    owner_active = (
        facts.owner_user_id is not None and facts.owner_account_status == "active"
    )
    ownership = "verified" if owner_active else "unknown"
    if facts.owner_user_id is not None and not owner_active:
        ownership = "unverified"
    elif facts.owner_user_id is None and facts.legacy_owner_id is not None:
        # Only a pre-Supabase integer owner is recorded. That is real
        # provenance, but it is not a verified current ownership claim.
        ownership = "legacy_unverified"

    # 1. AGENT_MANAGED — but only while the assigned agent is a valid identity.
    if facts.agent_id is not None:
        agent_active = facts.agent_account_status == "active"
        if agent_active and facts.agent_display_name:
            return _base(
                TYPE_AGENT,
                LABEL_AGENT,
                facts=facts,
                manager_name=facts.agent_display_name,
                assignment_status=ASSIGNMENT_ACTIVE,
                ownership_status=ownership,
            )
        # An assignment to a suspended or unresolvable agent is not a valid
        # management relationship. Report the defect; do not show a manager.
        return _base(
            TYPE_UNRESOLVED,
            LABEL_UNRESOLVED,
            facts=facts,
            assignment_status="agent_inactive",
            ownership_status=ownership,
            reason=(
                REASON_AGENT_INACTIVE
                if facts.agent_display_name
                else REASON_AGENT_PROFILE_MISSING
            ),
        )

    # 2. OWNER_MANAGED
    if owner_active:
        name = (facts.owner_display_name or "").strip() or None
        if name:
            return _base(
                TYPE_OWNER,
                LABEL_OWNER,
                facts=facts,
                manager_name=name,
                ownership_status="verified",
            )
        # The owner UUID is authoritative but the display name is not known.
        # Never substitute an email or a guess.
        return _base(
            TYPE_UNRESOLVED,
            LABEL_UNRESOLVED,
            facts=facts,
            ownership_status="verified",
            reason="owner_display_name_unavailable",
        )

    # 3. PLATFORM_MANAGED
    policy = PLATFORM_STEWARDSHIP.get(facts.provenance)
    if policy is not None:
        # A record that carries an owner claim which cannot be verified is
        # reported as unverified ownership, not as never claimed at all.
        stewardship_status = (
            "unverified" if facts.owner_user_id is not None
            else policy["ownership_status"]
        )
        return _base(
            TYPE_PLATFORM,
            policy["label"],
            facts=facts,
            ownership_status=stewardship_status,
            steward_role=policy["steward_role"],
            reason=policy["reason"],
        )

    # 4. UNRESOLVED
    if facts.owner_user_id is not None:
        reason = REASON_OWNER_INACTIVE
    elif facts.legacy_owner_id is not None:
        # A legacy integer owner with no Supabase identity: real provenance,
        # but no reachable manager and no stewardship policy for this class.
        reason = REASON_OWNER_MISSING
    else:
        reason = REASON_NO_STEWARDSHIP
    return _base(
        TYPE_UNRESOLVED,
        LABEL_UNRESOLVED,
        facts=facts,
        ownership_status=ownership,
        reason=reason,
    )


def unavailable() -> dict:
    """The lookup itself failed. Never rendered as 'no manager'."""
    return {
        "type": "unavailable",
        "status": "unavailable",
        "label": "Management unavailable",
        "name": None,
        "manager_name": None,
        "agent_id": None,
        "owner_user_id": None,
        "assignment_status": "unknown",
        "ownership_status": "unknown",
        "steward_role": None,
        "reason": "management_lookup_failed",
        "provenance": None,
    }


def derive_provenance(listing_id: str | None) -> str:
    """Classify a property from its external reference.

    Mirrors the SQL used by the census so the API and the audit agree.
    """
    if listing_id is None:
        return PROVENANCE_OWNER_DRAFT
    text_id = str(listing_id).strip()
    if text_id.isdigit():
        return PROVENANCE_DEMO
    if text_id.startswith(("MD-", "EP-")):
        return PROVENANCE_RESEARCH
    return PROVENANCE_OTHER
