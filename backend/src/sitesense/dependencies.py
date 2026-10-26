from typing import Annotated

from fastapi import Depends

from sitesense.db.session import get_db


DbSession = Annotated[object, Depends(get_db)]
