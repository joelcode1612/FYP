"""Pure permission regression: no DB or Supabase credentials required."""
from sitewise.domain.rbac import (
    PropertyRelationship, can_capture_panorama, can_upload_panorama,
)


def test_owners_never_capture_even_own_property():
    for fn in (can_capture_panorama, can_upload_panorama):
        assert not fn('owner', PropertyRelationship.owned)
        assert not fn('admin', PropertyRelationship.administrator)
        assert not fn('entrepreneur', PropertyRelationship.explicit_grant)
        assert not fn('agent', PropertyRelationship.none)


def test_only_assigned_agent_captures():
    for fn in (can_capture_panorama, can_upload_panorama):
        assert fn('agent', PropertyRelationship.assigned_agent)
