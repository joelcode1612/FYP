import uuid

from sqlmodel import Session, select

from sitewise.db.models.entrepreneur_preferences import EntrepreneurPreferences


class PreferencesRepository:
    """Persistence for one entrepreneur's stored recommendation preferences.

    The ``entrepreneur_preferences`` table has no unique constraint on
    ``user_id``, so "one record per entrepreneur" is enforced here instead:
    reads take the most recently updated row and writes update that row in
    place rather than inserting a second one.
    """

    def __init__(self, session: Session):
        self.session = session

    def get_by_user(self, user_id: uuid.UUID) -> EntrepreneurPreferences | None:
        return self.session.exec(
            select(EntrepreneurPreferences)
            .where(EntrepreneurPreferences.user_id == user_id)
            .order_by(
                EntrepreneurPreferences.updated_at.desc(),
                EntrepreneurPreferences.created_at.desc(),
            )
            .limit(1)
        ).first()

    def save(self, record: EntrepreneurPreferences) -> EntrepreneurPreferences:
        self.session.add(record)
        self.session.commit()
        self.session.refresh(record)
        return record
