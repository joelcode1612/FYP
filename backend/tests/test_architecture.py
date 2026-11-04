"""Clean Architecture dependency-rule tests (spec 15 - architecture tests)."""

from pathlib import Path

SRC = Path(__file__).resolve().parents[1] / "src" / "sitewise"

FORBIDDEN_IN_DOMAIN = ("fastapi", "supabase", "sqlmodel", "sqlalchemy", "pydantic_settings")
FORBIDDEN_IN_ML = ("fastapi", "sqlmodel")


def _source_of(*parts: str) -> str:
    path = SRC.joinpath(*parts)
    return path.read_text(encoding="utf-8")


def test_domain_has_no_framework_dependencies():
    for module in ("rbac.py", "suitability_engine.py", "entities.py", "ranking.py"):
        source = _source_of("domain", module)
        for forbidden in FORBIDDEN_IN_DOMAIN:
            assert forbidden not in source, (
                f"domain/{module} must not depend on {forbidden}"
            )


def test_ml_has_no_framework_dependencies():
    for module in ("model_loader.py", "pu_learning.py", "shap_explainer.py"):
        source = _source_of("ml", module)
        for forbidden in FORBIDDEN_IN_ML:
            assert forbidden not in source, f"ml/{module} must not depend on {forbidden}"


def test_domain_modules_import_cleanly():
    from sitewise.domain import ranking, rbac, suitability_engine  # noqa: F401


def test_services_are_testable_with_fake_repositories():
    """UserService works against any object exposing the repo interface."""
    import uuid

    from sitewise.services.user_service import UserService

    class FakeRepo:
        def __init__(self):
            self.rows = {}

        def update(self, user_id, data):
            self.rows[user_id].update(data)
            return self.rows[user_id]

        def get_or_create_from_supabase(self, **kwargs):
            return {"user_id": kwargs["user_id"]}, True

    service = UserService.__new__(UserService)  # bypass __init__'s SQLModel session
    service.repo = FakeRepo()
    uid = uuid.uuid4()

    # update_own_profile uses rbac filtering + repo.update.
    import pytest as _pytest

    from sitewise.core.exceptions import ForbiddenActionError

    service.rows = service.repo.rows
    service.repo.rows[uid] = {"full_name": "old"}
    with _pytest.raises(ForbiddenActionError):
        service.update_own_profile(uid, {"role": "administrator"})
    assert service.repo.rows[uid]["full_name"] == "old"
    service.update_own_profile(uid, {"full_name": "new"})
    assert service.repo.rows[uid]["full_name"] == "new"


def test_no_circular_import_of_main_from_inner_layers():
    domain_sources = "".join(
        p.read_text(encoding="utf-8") for p in (SRC / "domain").glob("*.py")
    )
    assert "sitewise.main" not in domain_sources
    assert "sitewise.api" not in domain_sources
