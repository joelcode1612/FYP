from sqlmodel import Session


class ReportService:
    def __init__(self, session: Session):
        self.session = session

    def generate_property_report(self, property_id: int) -> dict:
        return {"property_id": property_id, "report": "not implemented"}
