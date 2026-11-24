"""Domain RBAC matrix tests (pure, no I/O).

Role model: exactly four canonical roles (``admin``, ``owner``, ``agent``,
``entrepreneur``). Legacy values (``user``, ``property_owner``,
``administrator``) map to canonical roles on read and are never written.

The single behavioural change these tests pin down: ``property_owner`` now
resolves to ``owner``, not ``entrepreneur``. The old fold demoted every real
property owner into a role with no property authority.
"""

import pytest

from sitewise.domain import rbac


def test_exactly_four_canonical_roles():
    assert rbac.ALL_ROLES == ("admin", "owner", "agent", "entrepreneur")


def test_owner_is_a_role_not_an_alias():
    assert rbac.ROLE_OWNER == "owner"
    assert rbac.ROLE_OWNER in rbac.ALL_ROLES
    assert rbac.is_valid_role("owner")


def test_only_entrepreneur_is_publicly_registrable():
    assert rbac.PUBLIC_REGISTRATION_ROLES == (rbac.ROLE_ENTREPRENEUR,)
    for privileged in (rbac.ROLE_OWNER, rbac.ROLE_AGENT, rbac.ROLE_ADMIN):
        assert privileged not in rbac.PUBLIC_REGISTRATION_ROLES


def test_legacy_aliases_map_to_canonical_roles():
    assert rbac.canonical_role("user") == "entrepreneur"
    # The change this model exists for: an owner is an owner.
    assert rbac.canonical_role("property_owner") == "owner"
    assert rbac.canonical_role("administrator") == "admin"
    assert rbac.canonical_role("entrepreneur") == "entrepreneur"
    assert rbac.canonical_role("owner") == "owner"
    assert rbac.canonical_role("agent") == "agent"
    assert rbac.canonical_role("admin") == "admin"
    assert rbac.canonical_role("superadmin") == "superadmin"  # unknown passes through
    assert rbac.canonical_role(None) is None


def test_alias_normalisation_is_conservative():
    assert rbac.canonical_role("  Owner  ") == "owner"
    assert rbac.canonical_role("PROPERTY_OWNER") == "owner"
    assert rbac.canonical_role("property-owner") == "owner"


def test_property_owner_is_not_silently_promoted_on_write():
    """Reading an alias back must not turn an entrepreneur into an owner.

    ``canonical_role`` parses; it never rewrites an account. An account stored as
    ``entrepreneur`` stays an entrepreneur even though ``property_owner`` — a
    different stored value — now means owner.
    """
    assert rbac.canonical_role("entrepreneur") == "entrepreneur"
    assert rbac.canonical_role("entrepreneur") != rbac.ROLE_OWNER


def test_property_management_matrix():
    # Owners manage the properties recorded against their account; entrepreneurs
    # keep the surface they had under the old model; agents are part of the
    # *provider* workspace and may hold listings they represent. This is the
    # coarse gate only — role membership alone authorises nothing on an existing
    # record: the listing API additionally requires `owner_user_id` equality, an
    # `agent_listing_assignment` row, or an explicit grant.
    assert rbac.can_manage_properties(rbac.ROLE_OWNER)
    assert rbac.can_manage_properties(rbac.ROLE_ENTREPRENEUR)
    assert rbac.can_manage_properties(rbac.ROLE_ADMIN)
    assert rbac.can_manage_properties(rbac.ROLE_AGENT)
    # Legacy aliases still authorise on read (existing records keep working).
    assert rbac.can_manage_properties(rbac.ROLE_PROPERTY_OWNER)
    assert rbac.can_manage_properties(rbac.ROLE_ADMINISTRATOR)


def test_staff_matrix_excludes_owner_and_entrepreneur():
    assert rbac.is_staff(rbac.ROLE_AGENT)
    assert rbac.is_staff(rbac.ROLE_ADMIN)
    assert not rbac.is_staff(rbac.ROLE_ENTREPRENEUR)
    assert not rbac.is_staff(rbac.ROLE_OWNER)
    assert not rbac.is_staff(rbac.ROLE_USER)  # legacy alias -> entrepreneur


def test_global_read_matrix():
    assert rbac.can_read_any_user_data(rbac.ROLE_ADMIN)
    assert rbac.can_read_any_user_data(rbac.ROLE_ADMINISTRATOR)  # legacy alias
    assert not rbac.can_read_any_user_data(rbac.ROLE_ENTREPRENEUR)
    assert not rbac.can_read_any_user_data(rbac.ROLE_PROPERTY_OWNER)  # alias -> owner
    assert not rbac.can_read_any_user_data(rbac.ROLE_OWNER)
    assert not rbac.can_read_any_user_data(rbac.ROLE_AGENT)


def test_user_administration_matrix():
    assert rbac.can_administer_users(rbac.ROLE_ADMIN)
    assert rbac.can_administer_users(rbac.ROLE_ADMINISTRATOR)  # legacy alias
    for role in ("user", "entrepreneur", "property_owner", "owner", "agent"):
        assert not rbac.can_administer_users(role)


def test_only_admin_may_change_roles():
    assert rbac.can_change_roles(rbac.ROLE_ADMIN)
    for role in ("owner", "agent", "entrepreneur", "property_owner", "user"):
        assert not rbac.can_change_roles(role)


def test_unknown_role_rejected():
    assert not rbac.is_valid_role("superadmin")
    assert not rbac.is_valid_status("banned")
    # has_role on an unknown role is simply False, never an error.
    assert not rbac.has_role("superadmin", rbac.ALL_ROLES)
    # normalize_role returns None so callers must decide explicitly.
    assert rbac.normalize_role("superadmin") is None
    assert rbac.normalize_role("owner") == "owner"


# ---------------------------------------------------------------------------
# Permission matrix (mirrors the Flutter `SitewisePermission` enum)
# ---------------------------------------------------------------------------


def test_every_role_can_view_own_profile_and_published_panoramas():
    for role in rbac.ALL_ROLES:
        assert rbac.can(role, rbac.Permission.view_own_profile)
        assert rbac.can(role, rbac.Permission.view_published_panorama)


def test_only_admin_holds_administrative_permissions():
    for permission in (
        rbac.Permission.change_user_role,
        rbac.Permission.manage_agent_accounts,
    ):
        assert rbac.can(rbac.ROLE_ADMIN, permission)
        for role in ("owner", "agent", "entrepreneur"):
            assert not rbac.can(role, permission)


def test_owner_holds_property_permissions_but_not_administration():
    assert rbac.can(rbac.ROLE_OWNER, rbac.Permission.manage_own_property)
    assert rbac.can(rbac.ROLE_OWNER, rbac.Permission.capture_panorama)
    assert rbac.can(rbac.ROLE_OWNER, rbac.Permission.upload_panorama)
    assert not rbac.can(rbac.ROLE_OWNER, rbac.Permission.change_user_role)


def test_entrepreneur_does_not_hold_manage_own_property():
    # Their entitlement is always explicit and per-property, never implied by the
    # role. They may still capture/upload *for an authorised property*.
    assert not rbac.can(
        rbac.ROLE_ENTREPRENEUR, rbac.Permission.manage_own_property
    )
    assert rbac.can(rbac.ROLE_ENTREPRENEUR, rbac.Permission.capture_panorama)


def test_unknown_role_has_no_permissions():
    assert rbac.permissions_for("superadmin") == frozenset()


# ---------------------------------------------------------------------------
# Property-level decisions: a role never grants a property on its own
# ---------------------------------------------------------------------------


def test_owner_can_manage_only_owned_property():
    owned = rbac.can_manage_property(
        rbac.ROLE_OWNER, rbac.PropertyRelationship.owned
    )
    assert owned.allowed
    for relationship in (
        rbac.PropertyRelationship.none,
        rbac.PropertyRelationship.assigned_agent,
        rbac.PropertyRelationship.explicit_grant,
    ):
        assert not rbac.can_manage_property(rbac.ROLE_OWNER, relationship)


def test_agent_requires_a_verified_assignment():
    assert rbac.can_manage_property(
        rbac.ROLE_AGENT, rbac.PropertyRelationship.assigned_agent
    ).allowed
    assert not rbac.can_manage_property(
        rbac.ROLE_AGENT, rbac.PropertyRelationship.owned
    )
    assert not rbac.can_manage_property(
        rbac.ROLE_AGENT, rbac.PropertyRelationship.none
    )


def test_entrepreneur_requires_an_explicit_grant():
    assert rbac.can_manage_property(
        rbac.ROLE_ENTREPRENEUR, rbac.PropertyRelationship.explicit_grant
    ).allowed
    for relationship in (
        rbac.PropertyRelationship.none,
        rbac.PropertyRelationship.owned,
        rbac.PropertyRelationship.assigned_agent,
    ):
        assert not rbac.can_manage_property(rbac.ROLE_ENTREPRENEUR, relationship)


def test_forged_administrative_relationship_is_rejected():
    # A non-admin claiming the administrative relationship is not an
    # administrator, whatever it asserts about itself.
    for role in ("owner", "agent", "entrepreneur"):
        assert not rbac.can_manage_property(
            role, rbac.PropertyRelationship.administrator
        )
    assert rbac.can_manage_property(
        rbac.ROLE_ADMIN, rbac.PropertyRelationship.administrator
    ).allowed


def test_administrator_without_a_relationship_is_refused():
    assert not rbac.can_manage_property(
        rbac.ROLE_ADMIN, rbac.PropertyRelationship.none
    )


def test_cross_property_access_is_never_implied():
    """The same role, two relationships: only the verified one passes."""
    assert rbac.can_manage_property(
        rbac.ROLE_OWNER, rbac.PropertyRelationship.owned
    ).allowed
    assert not rbac.can_manage_property(
        rbac.ROLE_OWNER, rbac.PropertyRelationship.none
    ).allowed


def test_unassociated_panorama_is_never_uploadable():
    for role in rbac.ALL_ROLES:
        decision = rbac.can_upload_panorama(role, rbac.PropertyRelationship.none)
        assert not decision.allowed
        assert "assigned Property Agent" in decision.reason


def test_capture_requires_the_assigned_agent():
    for role in rbac.ALL_ROLES:
        for relationship in rbac.PropertyRelationship:
            expected = (
                role == rbac.ROLE_AGENT
                and relationship is rbac.PropertyRelationship.assigned_agent
            )
            assert rbac.can_capture_panorama(role, relationship).allowed is expected
            assert rbac.can_upload_panorama(role, relationship).allowed is expected


def test_require_property_access_raises_with_the_reason():
    with pytest.raises(rbac.PermissionDenied) as excinfo:
        rbac.require_property_access(
            rbac.ROLE_AGENT, rbac.PropertyRelationship.none
        )
    assert "not assigned" in str(excinfo.value)


def test_resolve_relationship_prefers_administrative_capacity():
    assert (
        rbac.resolve_relationship(
            role=rbac.ROLE_ADMIN, owns_property=True
        )
        is rbac.PropertyRelationship.administrator
    )
    assert (
        rbac.resolve_relationship(role=rbac.ROLE_OWNER, owns_property=True)
        is rbac.PropertyRelationship.owned
    )
    assert (
        rbac.resolve_relationship(role=rbac.ROLE_AGENT, is_assigned_agent=True)
        is rbac.PropertyRelationship.assigned_agent
    )
    assert (
        rbac.resolve_relationship(
            role=rbac.ROLE_ENTREPRENEUR, has_explicit_grant=True
        )
        is rbac.PropertyRelationship.explicit_grant
    )
    assert (
        rbac.resolve_relationship(role=rbac.ROLE_ENTREPRENEUR)
        is rbac.PropertyRelationship.none
    )


# ---------------------------------------------------------------------------
# Client-cache resolution: never escalate
# ---------------------------------------------------------------------------


def test_effective_role_never_escalates():
    # A cached admin claim cannot upgrade an entrepreneur server role.
    assert (
        rbac.resolve_effective_role(
            server_role="entrepreneur", cached_role="admin"
        )
        == "entrepreneur"
    )
    # A stale cache can cost controls, never grant them.
    assert (
        rbac.resolve_effective_role(server_role="admin", cached_role="owner")
        == "owner"
    )
    # No server answer yields the least privileged role.
    assert rbac.resolve_effective_role(server_role=None) == "entrepreneur"
    assert rbac.resolve_effective_role(server_role="garbage") == "entrepreneur"


def test_profile_field_filtering():
    editable, attempted = rbac.filter_self_editable(
        {"full_name": "A", "phone_number": "+60", "role": "admin"}
    )
    assert editable == {"full_name": "A", "phone_number": "+60"}
    assert attempted == ["role"]


def test_self_editable_fields_exclude_identity():
    for forbidden in ("user_id", "email", "role", "account_status", "email_verified"):
        assert forbidden not in rbac.SELF_EDITABLE_PROFILE_FIELDS


def test_staff_aal_requirement_constant():
    # A password login alone (aal1 / no aal claim) must never authorize
    # protected staff operations.
    assert rbac.REQUIRED_STAFF_AAL == "aal2"
