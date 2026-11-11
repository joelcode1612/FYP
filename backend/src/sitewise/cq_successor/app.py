"""Standalone synthetic FastAPI factory.

CRITICAL: this app is NEVER registered in `sitewise.main` or
`sitewise.api.v1.router`. The live v1 app currently has two independent
import-time defects (S7-a / S7-b) and is deliberately out of scope.
This factory exists only for isolated TestClient verification.
"""

from fastapi import FastAPI, HTTPException
from pydantic import ValidationError

from .contracts import (
    ConsentPort,
    PrincipalPort,
    RoutePreviewRequest,
    RoutePreviewResponse,
    StaticConsentPort,
    StaticPrincipalPort,
)
from .policy import SyntheticAuthority, evaluate_route

READ_ONLY = True


def create_successor_app(
    principal_port: PrincipalPort | None = None,
    consent_port: ConsentPort | None = None,
    authority: SyntheticAuthority | None = None,
    server_revision: int = 0,
) -> FastAPI:
    """Return a fresh, unregistered synthetic app. No DB, no network, no writes."""
    principals = principal_port or PrincipalPort()
    consents = consent_port or ConsentPort()
    auth = authority or SyntheticAuthority()

    app = FastAPI(
        title="Project1 CQ Successor — SYNTHETIC ONLY",
        description="Unregistered successor candidate. Not an approved CUST03 replacement.",
        version="0.1.0-synthetic",
    )
    cache: dict[str, RoutePreviewResponse] = {}

    def compute(request: RoutePreviewRequest) -> RoutePreviewResponse:
        principal = principals.resolve(request.assessment_id)
        consent = consents.resolve(request.assessment_id)
        return evaluate_route(request, principal, consent, auth, server_revision)

    @app.post(
        "/api/v1/customer/questionnaires/{assessment_id}/route-preview",
        response_model=RoutePreviewResponse,
    )
    def preview(assessment_id: str, body: dict) -> RoutePreviewResponse:
        # Reject authority-granting fields before Pydantic ever sees them.
        forbidden = {
            "viewer_authorized", "consented", "withdrawn", "completed_ids",
            "production_fielding_authorized", "report_release_authorized",
            "synthetic", "q10_feature_bank_approved",
        }
        leaked = forbidden.intersection(body)
        if leaked or any(k.endswith("_approved") or k.endswith("_authorized") for k in body):
            raise HTTPException(status_code=422, detail="AUTHORITY_FIELD_FORBIDDEN")
        if "assessment_id" not in body:
            body = {**body, "assessment_id": assessment_id}
        try:
            request = RoutePreviewRequest.model_validate(body)
        except ValidationError as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from exc
        result = compute(request)
        cache[assessment_id] = result
        return result

    @app.get(
        "/api/v1/customer/questionnaires/{assessment_id}/route-preview",
        response_model=RoutePreviewResponse,
    )
    def read_preview(assessment_id: str) -> RoutePreviewResponse:
        """Idempotent read of the last computed preview; never recomputes."""
        if assessment_id not in cache:
            raise HTTPException(status_code=404, detail="NO_PREVIEW_COMPUTED")
        return cache[assessment_id]

    @app.get("/health")
    def health() -> dict:
        return {
            "mode": "SYNTHETIC_ONLY",
            "registered_in_live_app": False,
            "production_fielding_authorized": False,
            "report_release_authorized": False,
        }

    return app


def allowed_app(
    assessment_id: str = "SYN-ASSESSMENT",
    tenant_id: str = "SYN-TENANT",
    authority: SyntheticAuthority | None = None,
    server_revision: int = 0,
) -> FastAPI:
    """Convenience: an app with server-side synthetic authorization granted."""
    from .contracts import ConsentSnapshot, Principal

    return create_successor_app(
        principal_port=StaticPrincipalPort(
            Principal(
                actor_ref="SYN-ACTOR",
                tenant_id=tenant_id,
                authenticated=True,
                roles=("RESEARCHER",),
                jurisdiction="JOHOR",
            )
        ),
        consent_port=StaticConsentPort(
            ConsentSnapshot(consented=True, withdrawn=False, consent_version="SYN-CONSENT-V1")
        ),
        authority=authority,
        server_revision=server_revision,
    )
