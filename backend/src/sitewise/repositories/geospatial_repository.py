import uuid
from typing import Optional

from sqlmodel import Session, select

from sitewise.db.models.property_geospatial_feature import PropertyGeospatialFeature
from sitewise.db.models.nearby_competitor import NearbyCompetitor
from sitewise.db.models.property_foot_traffic import PropertyFootTraffic
from sitewise.db.models.district_demographic import DistrictDemographic


class GeospatialRepository:
    def __init__(self, session: Session):
        self.session = session

    # PropertyGeospatialFeature
    def create_geo_feature(self, feature: PropertyGeospatialFeature) -> PropertyGeospatialFeature:
        self.session.add(feature)
        self.session.commit()
        self.session.refresh(feature)
        return feature

    def get_geo_feature_by_property_id(self, property_id: int) -> Optional[PropertyGeospatialFeature]:
        statement = select(PropertyGeospatialFeature).where(PropertyGeospatialFeature.property_id == property_id)
        return self.session.exec(statement).first()

    def update_geo_feature(self, property_id: int, data: dict) -> Optional[PropertyGeospatialFeature]:
        feature = self.get_geo_feature_by_property_id(property_id)
        if not feature:
            return None
        for key, value in data.items():
            setattr(feature, key, value)
        self.session.add(feature)
        self.session.commit()
        self.session.refresh(feature)
        return feature

    def delete_geo_feature(self, property_id: int) -> bool:
        feature = self.get_geo_feature_by_property_id(property_id)
        if not feature:
            return False
        self.session.delete(feature)
        self.session.commit()
        return True

    # NearbyCompetitor
    def create_competitor(self, competitor: NearbyCompetitor) -> NearbyCompetitor:
        self.session.add(competitor)
        self.session.commit()
        self.session.refresh(competitor)
        return competitor

    def get_competitors_by_property_id(self, property_id: int) -> list[NearbyCompetitor]:
        statement = select(NearbyCompetitor).where(NearbyCompetitor.property_id == property_id)
        return list(self.session.exec(statement).all())

    def get_competitor_by_id(self, competitor_id: uuid.UUID) -> Optional[NearbyCompetitor]:
        return self.session.get(NearbyCompetitor, competitor_id)

    def delete_competitor(self, competitor_id: uuid.UUID) -> bool:
        competitor = self.get_competitor_by_id(competitor_id)
        if not competitor:
            return False
        self.session.delete(competitor)
        self.session.commit()
        return True

    # PropertyFootTraffic
    def create_foot_traffic(self, traffic: PropertyFootTraffic) -> PropertyFootTraffic:
        self.session.add(traffic)
        self.session.commit()
        self.session.refresh(traffic)
        return traffic

    def get_foot_traffic_by_property_id(self, property_id: int) -> Optional[PropertyFootTraffic]:
        statement = select(PropertyFootTraffic).where(PropertyFootTraffic.property_id == property_id)
        return self.session.exec(statement).first()

    def update_foot_traffic(self, property_id: int, data: dict) -> Optional[PropertyFootTraffic]:
        traffic = self.get_foot_traffic_by_property_id(property_id)
        if not traffic:
            return None
        for key, value in data.items():
            setattr(traffic, key, value)
        self.session.add(traffic)
        self.session.commit()
        self.session.refresh(traffic)
        return traffic

    # DistrictDemographic
    def get_district_by_id(self, district_id: str) -> Optional[DistrictDemographic]:
        return self.session.get(DistrictDemographic, district_id)

    def get_all_districts(self, offset: int = 0, limit: int = 100) -> list[DistrictDemographic]:
        statement = select(DistrictDemographic).offset(offset).limit(limit)
        return list(self.session.exec(statement).all())

    def create_district(self, district: DistrictDemographic) -> DistrictDemographic:
        self.session.add(district)
        self.session.commit()
        self.session.refresh(district)
        return district

    def update_district(self, district_id: str, data: dict) -> Optional[DistrictDemographic]:
        district = self.get_district_by_id(district_id)
        if not district:
            return None
        for key, value in data.items():
            setattr(district, key, value)
        self.session.add(district)
        self.session.commit()
        self.session.refresh(district)
        return district

    def delete_district(self, district_id: str) -> bool:
        district = self.get_district_by_id(district_id)
        if not district:
            return False
        self.session.delete(district)
        self.session.commit()
        return True
