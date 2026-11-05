"""Domain RBAC matrix tests (pure, no I/O).

Role model: exactly three canonical roles (``entrepreneur``, ``agent``,
``admin``). Legacy values (``user``, ``property_owner``,
``administrator``) map to canonical roles on read and are never written.
"""

from sitewise.domain import rbac


def test_exactly_three_canonical_roles():
    assert rbac.ALL_ROLES == ("entrepreneur", "agent", "admin")


def test_admin_never_publicly_registrable():
    assert rbac.PUBLIC_REGISTRATION_ROLES == (rbac.ROLE_ENTREPRENEUR,)
    assert rbac.ROLE_AGENT not in rbac.PUBLIC_REGISTRATION_ROLES
    assert rbac.ROLE_ADMIN not in rbac.PUBLIC_REGISTRATION_ROLES


def test_legacy_aliases_map_to_canonical_roles():
    assert rbac.canonical_role("user") == "entrepreneur"
    assert rbac.canonical_role("property_owner") == "entrepreneur"
    assert rbac.canonical_role("administrator") == "admin"
    assert rbac.canonical_role("entrepreneur") == "entrepreneur"
    assert rbac.canonical_role("agent") == "agent"
    assert rbac.canonical_role("admin") == "admin"
    assert rbac.canonical_role("superadmin") == "superadmin"  # unknown passes through
    assert rbac.canonical_role(None) is None


def test_property_management_matrix():
    # Entrepreneurs manage properties they OWN; administrators act
    # administratively. Agents never manage property records.
    assert rbac.can_manage_properties(rbac.ROLE_ENTREPRENEUR)
    assert rbac.can_manage_properties(rbac.ROLE_ADMIN)
    assert not rbac.can_manage_properties(rbac.ROLE_AGENT)
    # Legacy aliases still authorise on read (existing records keep working).
    assert rbac.can_manage_properties(rbac.ROLE_PROPERTY_OWNER)
    assert rbac.can_manage_properties(rbac.ROLE_ADMINISTRATOR)


def test_staff_matrix():
    assert rbac.is_staff(rbac.ROLE_AGENT)
    assert rbac.is_staff(rbac.ROLE_ADMIN)
    assert not rbac.is_staff(rbac.ROLE_ENTREPRENEUR)
    assert not rbac.is_staff(rbac.ROLE_USER)  # legacy alias -> entrepreneur


def test_global_read_matrix():
    assert rbac.can_read_any_user_data(rbac.ROLE_ADMIN)
    assert rbac.can_read_any_user_data(rbac.ROLE_ADMINISTRATOR)  # legacy alias
    assert not rbac.can_read_any_user_data(rbac.ROLE_ENTREPRENEUR)
    assert not rbac.can_read_any_user_data(rbac.ROLE_PROPERTY_OWNER)  # alias -> entrepreneur
    assert not rbac.can_read_any_user_data(rbac.ROLE_AGENT)


def test_user_administration_matrix():
    assert rbac.can_administer_users(rbac.ROLE_ADMIN)
    assert rbac.can_administer_users(rbac.ROLE_ADMINISTRATOR)  # legacy alias
    for role in ("user", "entrepreneur", "property_owner", "agent"):
        assert not rbac.can_administer_users(role)


def test_unknown_role_rejected():
    assert not rbac.is_valid_role("superadmin")
    assert not rbac.is_valid_status("banned")
    # has_role on an unknown role is simply False, never an error.
    assert not rbac.has_role("superadmin", rbac.ALL_ROLES)


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
