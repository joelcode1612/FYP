"""Clean Architecture dependency-rule tests (spec 15 - architecture tests)."""

import ast
import re
from pathlib import Path

SRC = Path(__file__).resolve().parents[1] / "src" / "sitewise"

FORBIDDEN_IN_DOMAIN = ("fastapi", "supabase", "sqlmodel", "sqlalchemy", "pydantic_settings")
FORBIDDEN_IN_ML = ("fastapi", "sqlmodel")
FORBIDDEN_IN_FEATURE_DOMAIN = (
    "fastapi",
    "pydantic",
    "pydantic_settings",
    "sqlalchemy",
    "sqlmodel",
    "supabase",
    "psycopg",
    "psycopg2",
    "asyncpg",
    "alembic",
    "sqlite3",
    "http",
    "httpx",
    "requests",
    "urllib",
    "starlette",
    "aiohttp",
    "sitewise.api",
    "sitewise.repositories",
    "sitewise.db",
    "sitewise.database",
)

#: `from sitewise.api...` / `import sitewise.api` — an actual dependency. The
#: rule is about imports, not prose: a docstring that names the module which
#: depends on this one is documentation of the relationship, while an import is
#: the relationship itself.
_IMPORT_RE = re.compile(r"^[ \t]*(?:from|import)[ \t]+(sitewise[\w.]*)", re.MULTILINE)


def imports_module(source: str, module: str) -> bool:
    """True when [source] imports [module] or one of its submodules."""
    return any(
        name == module or name.startswith(module + ".")
        for name in _IMPORT_RE.findall(source)
    )


def _source_of(*parts: str) -> str:
    path = SRC.joinpath(*parts)
    return path.read_text(encoding="utf-8")


def _import_names(source: str, package: str) -> set[str]:
    """Collect module dependencies from static and constant dynamic imports.

    Imported *member* names are not module paths. Only the special case
    ``from sitewise import api`` (or another outer-layer package) is expanded,
    because that form really does import a submodule.
    """
    names = set()
    package_parts = package.split(".")
    outer_packages = {"main", "api", "repositories", "db", "database"}

    def dynamic_name(node: ast.Call) -> str | None:
        func = node.func
        if isinstance(func, ast.Name) and func.id in {"__import__", "import_module"}:
            return func.id
        if (
            isinstance(func, ast.Attribute)
            and func.attr == "import_module"
            and isinstance(func.value, ast.Name)
            and func.value.id == "importlib"
        ):
            return "importlib.import_module"
        return None

    for node in ast.walk(ast.parse(source)):
        if isinstance(node, ast.Import):
            names.update(alias.name for alias in node.names)
        elif isinstance(node, ast.ImportFrom):
            if node.level:
                prefix = package_parts[: len(package_parts) - node.level + 1]
                module_parts = node.module.split(".") if node.module else []
                imported_module = ".".join(prefix + module_parts)
            else:
                imported_module = node.module or ""
            names.add(imported_module)
            if imported_module == "sitewise":
                names.update(
                    f"{imported_module}.{alias.name}"
                    for alias in node.names
                    if alias.name in outer_packages
                )
        elif isinstance(node, ast.Call) and dynamic_name(node) and node.args:
            target = node.args[0]
            if isinstance(target, ast.Constant) and isinstance(target.value, str):
                names.add(target.value)
    return names


def test_domain_has_no_framework_dependencies():
    for module in ("rbac.py", "suitability_engine.py", "entities.py", "ranking.py"):
        source = _source_of("domain", module)
        for forbidden in FORBIDDEN_IN_DOMAIN:
            assert forbidden not in source, (
                f"domain/{module} must not depend on {forbidden}"
            )


def test_feature_domain_has_no_framework_or_outer_layer_dependencies():
    modules = SRC / "modules"
    domain_files = [
        path for path in modules.rglob("*.py") if "domain" in path.relative_to(modules).parts
    ]
    assert domain_files
    internal_forbidden_parts = {"api", "repository", "repositories", "db", "database"}
    for path in domain_files:
        relative = path.relative_to(modules)
        package_parts = ["sitewise", "modules", *relative.parts[:-1]]
        for imported in _import_names(
            path.read_text(encoding="utf-8"), ".".join(package_parts)
        ):
            forbidden = next(
                (
                    dependency
                    for dependency in FORBIDDEN_IN_FEATURE_DOMAIN
                    if imported == dependency or imported.startswith(dependency + ".")
                ),
                None,
            )
            internal_layer = imported.startswith("sitewise.") and bool(
                internal_forbidden_parts.intersection(imported.split("."))
            )
            assert forbidden is None and not internal_layer, (
                f"{path.relative_to(SRC)} must not depend on {forbidden or imported}"
            )


def test_import_scanner_does_not_treat_member_names_as_modules():
    source = (
        "from sitewise.modules.decision_engine.domain import db\n"
        "from sitewise import api\n"
    )
    names = _import_names(source, "sitewise.modules.decision_engine.domain")
    assert "sitewise.modules.decision_engine.domain.db" not in names
    assert "sitewise.api" in names


def test_import_scanner_detects_constant_dynamic_imports():
    source = (
        "import importlib\n"
        "a = importlib.import_module('fastapi')\n"
        "b = __import__('sqlalchemy')\n"
    )
    names = _import_names(source, "sitewise.modules.decision_engine.domain")
    assert "fastapi" in names
    assert "sqlalchemy" in names


def test_ml_has_no_framework_dependencies():
    for module in ("model_loader.py", "pu_learning.py", "shap_explainer.py"):
        source = _source_of("ml", module)
        for forbidden in FORBIDDEN_IN_ML:
            assert forbidden not in source, f"ml/{module} must not depend on {forbidden}"


def test_domain_modules_import_cleanly():
    from sitewise.domain import ranking, rbac, suitability_engine  # noqa: F401


def test_legacy_m2_rules_reexport_same_objects():
    from sitewise.domain import m2_rules as legacy
    from sitewise.modules.decision_engine.domain import m2_rules as feature

    for name in (
        "M2ValidationError",
        "resolve_m2_items",
        "derived_m2_selections",
        "validate_m2_answer",
        "missing_required_items",
    ):
        assert getattr(legacy, name) is getattr(feature, name)


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
    """The domain layer never imports the presentation layer.

    Checked against import statements rather than raw substrings: `rbac.py`
    documents in prose which API module enforces its matrices, and that
    documentation is not a dependency. A real `import sitewise.api...` (or
    `from sitewise.api import ...`) still fails this test.
    """
    domain_sources = "".join(
        p.read_text(encoding="utf-8") for p in (SRC / "domain").glob("*.py")
    )
    assert not imports_module(domain_sources, "sitewise.main")
    assert not imports_module(domain_sources, "sitewise.api")


def test_identity_email_collision_fails_closed_without_rekey():
    """A matching email never authorizes replacing a Supabase identity UUID."""
    import uuid
    import pytest
    from sitewise.core.exceptions import ConflictError
    from sitewise.services.user_service import UserService

    old_id = uuid.uuid4()
    new_id = uuid.uuid4()

    class FakeRepo:
        def __init__(self):
            self.existing = type('UserRow', (), {'user_id': old_id})()
            self.rekeys = []
            self.creates = []

        def get_by_id(self, uid):
            return None

        def get_by_email(self, email):
            return self.existing

        def rekey(self, old, new):
            self.rekeys.append((old, new))

        def create(self, row):
            self.creates.append(row)
            return row

        def get_or_create_from_supabase(self, **kwargs):
            self.creates.append(kwargs)
            return (kwargs, True)

    repo = FakeRepo()
    service = UserService.__new__(UserService)
    service.repo = repo
    with pytest.raises(ConflictError):
        service.get_or_sync_current(
            user_id=new_id, email='staff@example.test', email_verified=True
        )
    with pytest.raises(ConflictError):
        service.ensure_staff_profile(
            user_id=new_id, email='staff@example.test', full_name='Staff',
            phone_number=None, role='admin', account_status='active'
        )
    assert repo.rekeys == []
    assert repo.creates == []
