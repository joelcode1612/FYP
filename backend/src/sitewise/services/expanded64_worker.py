"""Background dispatcher for durable listing enrichment category rows."""
import logging
import threading

from sqlmodel import Session

from sitewise.db.session import engine
from sitewise.services.expanded64_enrichment import run_next
from sitewise.services.operational25_enrichment import run_next as run_operational25

logger = logging.getLogger(__name__)


def start() -> tuple[threading.Event, threading.Thread]:
    stop = threading.Event()

    def work() -> None:
        while not stop.is_set():
            try:
                with Session(engine) as session:
                    if run_next(session):
                        continue
                    if run_operational25(session):
                        continue
            except Exception as exc:
                logger.warning("Expanded64 worker could not process its queue (%s)", type(exc).__name__)
                stop.wait(15)
                continue
            stop.wait(2)

    thread = threading.Thread(target=work, name="expanded64-enrichment", daemon=True)
    thread.start()
    return stop, thread
