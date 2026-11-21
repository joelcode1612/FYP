"""Identity bridge contract for expanded64 batch inference."""
from __future__ import annotations

from typing import Any

from sitewise.ml.pu_expanded import _verified_catalogue_subject_rows


class _Mappings:
    def __init__(self, rows: list[dict[str, Any]]) -> None:
        self._rows = rows

    def all(self) -> list[dict[str, Any]]:
        return self._rows


class _Result:
    def __init__(self, rows: list[dict[str, Any]]) -> None:
        self._rows = rows

    def mappings(self) -> _Mappings:
        return _Mappings(self._rows)


class _AnalyticsSession:
    def __init__(self, rows: list[dict[str, Any]]) -> None:
        self.rows = rows
        self.statement = ""
        self.parameters: dict[str, Any] = {}

    def execute(self, statement: Any, parameters: dict[str, Any]) -> _Result:
        self.statement = str(statement)
        self.parameters = parameters
        return _Result(self.rows)


def test_catalogue_subject_lookup_uses_verified_link_and_rental_primary_key() -> None:
    session = _AnalyticsSession(
        [{"catalogue_id": "MD-00510", "subject_id": "U-00510"}]
    )

    rows = _verified_catalogue_subject_rows(session, ["MD-00510"])

    normalized_sql = " ".join(session.statement.split()).lower()
    assert "select l.sitewise_property_id as catalogue_id, l.subject_id" in normalized_sql
    assert "from fyp.property_subject_links l" in normalized_sql
    assert "join fyp.rental_properties p on p.id = l.property_id" in normalized_sql
    assert "where l.sitewise_property_id = any(:ids)" in normalized_sql
    assert "l.match_verified is true" in normalized_sql
    assert "p.catalogue_id" not in normalized_sql
    assert session.parameters == {"ids": ["MD-00510"]}
    assert rows == [{"catalogue_id": "MD-00510", "subject_id": "U-00510"}]
