import logging

from sitewise.core.config import settings

logger = logging.getLogger("sitewise")


def configure_logging() -> None:
    logging.basicConfig(level=getattr(logging, settings.log_level.upper(), logging.INFO))
