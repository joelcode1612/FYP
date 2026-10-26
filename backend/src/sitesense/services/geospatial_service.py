from sqlmodel import Session

from sitesense.repositories.geospatial_repository import GeospatialRepository


class GeospatialService:
    def __init__(self, session: Session):
        self.repo = GeospatialRepository(session)
