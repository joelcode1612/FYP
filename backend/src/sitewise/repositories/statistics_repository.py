"""Read-only repository for DOSM statistical datasets.

These tables are queried with raw SQL (not SQLModel table models) on purpose:
registering them in the application ORM metadata would cause create_all() to
attempt to (re)create them in the application database.
"""

from sqlmodel import Session, text


class StatisticsRepository:
    def __init__(self, session: Session):
        self.session = session

    def list_districts(self) -> list[dict]:
        stmt = text(
            "SELECT DISTINCT state, district FROM vw_latest_district_statistics "
            "ORDER BY state, district"
        )
        rows = self.session.exec(stmt).all()
        return [{"state": r[0], "district": r[1]} for r in rows]

    def get_district_statistics(self, state: str, district: str) -> dict | None:
        stmt = text(
            "SELECT state, district, population_as_of, population_persons, age_as_of, "
            "pct_age_20_34, income_as_of, income_mean, income_median, expenditure_mean, "
            "gini, poverty, hies_as_of, p_rate, u_rate, ep_ratio, lfs_as_of "
            "FROM vw_latest_district_statistics "
            "WHERE state = :state AND district = :district"
        )
        row = self.session.exec(stmt, params={"state": state, "district": district}).first()
        if not row:
            return None
        cols = [
            "state", "district", "population_as_of", "population_persons", "age_as_of",
            "pct_age_20_34", "income_as_of", "income_mean", "income_median",
            "expenditure_mean", "gini", "poverty", "hies_as_of", "p_rate", "u_rate",
            "ep_ratio", "lfs_as_of",
        ]
        return dict(zip(cols, row))
