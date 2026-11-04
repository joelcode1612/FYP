"""Domain RBAC matrix tests (pure, no I/O)."""

import pytest

from sitewise.domain import rbac


def test_administrator_never_publicly_registrable():
    assert rbac.ROLE_ADMINISTRATOR not in rbac.PUBLIC_REGISTRATION_ROLES


def test_property_management_matrix():
    assert rbac.can_manage_properties(rbac.ROLE_PROPERTY_OWNER)
    assert rbac.can_manage_properties(rbac.ROLE_ADMINISTRATOR)
    assert not rbac.can_manage_properties(rbac.ROLE_ENTREPRENEUR)
    assert not rbac.can_manage_properties(rbac.ROLE_AGENT)
    assert not rbac.can_manage_properties(rbac.ROLE_USER)


def test_global_read_matrix():
    assert rbac.can_read_any_user_data(rbac.ROLE_ADMINISTRATOR)
    assert not rbac.can_read_any_user_data(rbac.ROLE_PROPERTY_OWNER)
    assert not rbac.can_read_any_user_data(rbac.ROLE_USER)


def test_user_administration_matrix():
    assert rbac.can_administer_users(rbac.ROLE_ADMINISTRATOR)
    for role in ("user", "entrepreneur", "property_owner", "agent"):
        assert not rbac.can_administer_users(role)


def test_unknown_role_rejected():
    assert not rbac.is_valid_role("superadmin")
    assert not rbac.is_valid_status("banned")
    # has_role on an unknown role is simply False, never an error.
    assert not rbac.has_role("superadmin", rbac.ALL_ROLES)


def test_profile_field_filtering():
    editable, attempted = rbac.filter_self_editable(
        {"full_name": "A", "phone_number": "+60", "role": "administrator"}
    )
    assert editable == {"full_name": "A", "phone_number": "+60"}
    assert attempted == ["role"]


def test_self_editable_fields_exclude_identity():
    for forbidden in ("user_id", "email", "role", "account_status", "email_verified"):
        assert forbidden not in rbac.SELF_EDITABLE_PROFILE_FIELDS
