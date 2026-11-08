"""Read-only analytics connection to the Final_Location_Analysis database.

This engine targets the DOSM statistical datasets (district_population,
state_population, district_age_population, hh_income_district,
labor_force_statistics_district, dun_income, state_hies,
vw_latest_district_statistics) which live in Final_Location_Analysis.public.

It is intentionally SEPARATE from the application engine (sitewise.db.session)
so that the application's ORM metadata / create_all never touches the analytics
database, and so the two databases can evolve independently.
"""

from sqlmodel import Session, create_engine

from sitewise.core.config import settings

analytics_engine = create_engine(settings.analytics_database_url, pool_pre_ping=True, echo=False)


def get_analytics_db():
    with Session(analytics_engine) as session:
        yield session
