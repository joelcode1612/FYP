class SiteWiseError(Exception):
    """Base class for all application errors."""

    status_code = 500
    """HTTP status the presentation layer should map this error to."""


class NotFoundError(SiteWiseError):
    status_code = 404


# ---------------------------------------------------------------------------
# Authentication / authorization errors.
#
# These are raised by the security adapter and auth dependencies and translated
# by the presentation layer into the HTTP responses mandated by the spec:
#   401 - missing, invalid or expired authentication
#   403 - authenticated but not permitted
#   503 - the authentication service itself is unreachable
# They intentionally carry no token material or secret values in their text.
# ---------------------------------------------------------------------------


class AuthError(SiteWiseError):
    """A request failed authentication. Maps to 401."""

    status_code = 401


class AuthUnavailableError(AuthError):
    """The authentication service (Supabase/JWKS) could not be reached.

    Maps to 503 rather than 401: the caller's token may well be valid, the
    verifier simply cannot confirm it right now. Fail closed, but tell the
    client it is a service problem, not a credentials problem.
    """

    status_code = 503


class ForbiddenError(SiteWiseError):
    """The request was authenticated but lacks permission. Maps to 403."""

    status_code = 403


class ForbiddenActionError(ForbiddenError):
    """An authenticated user attempted a change they are not allowed to make
    (e.g. editing their own role or suspension status)."""


class ModelUnavailableError(SiteWiseError):
    """A trained ML model artifact is missing or unusable.

    Maps to 503: the request is fine, the model simply is not there. Callers
    receive an explicit availability report instead of a fabricated score.
    """

    status_code = 503
