from sqlmodel import Session

from sitewise.repositories.statistics_repository import StatisticsRepository


class StatisticsService:
    def __init__(self, session: Session):
        self.repo = StatisticsRepository(session)

    def list_districts(self) -> list[dict]:
        return self.repo.list_districts()

    def get_district_statistics(self, state: str, district: str) -> dict | None:
        return self.repo.get_district_statistics(state, district)
