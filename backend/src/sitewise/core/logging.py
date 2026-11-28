import logging
import re

from sitewise.core.config import settings

logger = logging.getLogger("sitewise")

# HTTP request logs can carry a Supabase/GoTrue apikey in a query string or a
# rendered header dict. Keep the parameter name for diagnostics, drop the
# credential itself. This is applied to uvicorn's access/error loggers and to
# the root handlers, so third-party request logs are covered too.
_SECRET_QUERY = re.compile(
    # Google Maps Platform sends its credential as `?key=`, not `apikey=`.
    # Cover both forms, plus bearer/token query parameters.
    r"(?i)([?&](?:apikey|api_key|api-key|key|access_token|token)=)([^&\s]+)"
)
_SECRET_FIELD = re.compile(
    r"(?i)(apikey|api[-_]key|x-api-key|authorization)"
    r"([\"']?\s*[:=]\s*[\"']?)(bearer\s+)?([^\s&\"',}]+)"
)


class _RedactSecretsFilter(logging.Filter):
    def filter(self, record: logging.LogRecord) -> bool:
        try:
            message = record.getMessage()
        except Exception:  # noqa: BLE001 - never let logging break a request
            return True
        redacted = _SECRET_QUERY.sub(r"\1[REDACTED]", message)
        redacted = _SECRET_FIELD.sub(
            lambda m: f"{m.group(1)}{m.group(2)}{m.group(3) or ''}[REDACTED]",
            redacted,
        )
        if redacted != message:
            record.msg = redacted
            record.args = ()
        return True


_REDACT_FILTER = _RedactSecretsFilter()


def configure_logging() -> None:
    logging.basicConfig(level=getattr(logging, settings.log_level.upper(), logging.INFO))
    for handler in logging.getLogger().handlers:
        handler.addFilter(_REDACT_FILTER)
    for name in ("uvicorn", "uvicorn.access", "uvicorn.error", "sitewise"):
        logging.getLogger(name).addFilter(_REDACT_FILTER)
