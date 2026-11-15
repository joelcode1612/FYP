from pydantic import SecretStr
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    # --- Databases ---------------------------------------------------------
    # Application database (user profiles, saved properties, preferences).
    # Startup `create_all` runs through this URL, so it is the only database
    # the ORM ever writes to.
    database_url: str = (
        "postgresql+psycopg2://postgres:123456@localhost:5432/Dss"
    )
    # Analytics database (DOSM statistics, geospatial features). Read-only by
    # convention; the ORM never runs create_all or migrations against it.
    analytics_database_url: str = (
        "postgresql+psycopg2://postgres:123456@localhost:5432/Final_Location_Analysis"
    )

    # --- Application -------------------------------------------------------
    log_level: str = "INFO"
    secret_key: str = "change-me"  # app-local signing (NOT Supabase's JWT secret)
    cors_origins: str = (
        "http://localhost:8090,http://127.0.0.1:8090,http://localhost:3000,"
        "http://127.0.0.1:3000"
    )

    # Private document storage for property verification evidence. Files live
    # OUTSIDE any web-served directory and are streamed only through the
    # authenticated download endpoint. Empty => `<repo>/backend/var/
    # verification-documents` is used.
    verification_storage_dir: str = ""
    verification_max_upload_mb: int = 10

    # --- M2 upstream research feature (CORRECTIVE R16 / P0-01) -------------
    # Feature flag referenced by api/v1/router.py:38. Intended as a DEFAULT-OFF
    # gate: the opt-in /m2 router is only registered when this is explicitly
    # true. M2 schema + authorized questionnaire records still require separate
    # Owner/governance approval and a controlled migration; flipping this flag
    # alone does NOT activate any M2 endpoint or schema.
    m2_upstream_enabled: bool = False

    # Separate staging bridge; does not enable the unresolved BDJ/M2 write router.
    project1_cp07_enabled: bool = False
    project1_cp07_uc_database_url: SecretStr = SecretStr("")

    # --- Supabase authentication ------------------------------------------
    # Identity provider. Registration/login happen in the frontend through the
    # Supabase SDK; this backend only VERIFIES the issued access tokens.
    supabase_url: str = ""
    # Publishable (anon) key - public by design, used for /auth/v1/user lookups.
    supabase_publishable_key: str = ""
    # Server-only secret key. NEVER sent to a client, never used to sign JWTs.
    # Optional for this integration (only needed for admin API operations).
    supabase_secret_key: str = ""
    # JWKS endpoint of the asymmetric signing keys (ES256 on current projects).
    supabase_jwks_url: str = ""
    # Accepted `aud` claim values (Supabase issues "authenticated" for users).
    supabase_jwt_audiences: str = "authenticated"
    # Clock-skew allowance for exp/nbf validation, seconds.
    supabase_jwt_leeway: int = 30
    # JWKS cache lifetime, seconds. Rotated keys are picked up either when the
    # cache expires or immediately when an unknown `kid` appears.
    supabase_jwks_cache_seconds: int = 600

    # Public Entrepreneur registration when the project keeps email
    # confirmation ON. True (default) lets the trusted backend create the
    # identity already email-confirmed via the documented GoTrue admin API, so
    # a fresh signup can obtain a GENUINE session from a real password sign-in
    # without an email-verification screen. Set False to leave the project's
    # global confirmation policy entirely in force: the registration endpoint
    # then refuses with 503 and the app reports a configuration dependency
    # instead of fabricating a session. This flag NEVER applies to staff
    # invitations, administrator accounts or OAuth sign-in.
    public_registration_autoconfirm: bool = True

    # --- Staff administration ----------------------------------------------
    # Redirect target Supabase embeds in agent invite / password-setup emails.
    # This URL must ALSO be allow-listed in Supabase Auth -> URL Configuration
    # (Redirect URLs), otherwise GoTrue rejects the flow. Empty falls back to
    # the first CORS origin + /auth/callback.
    supabase_staff_invite_redirect_url: str = ""
    # Timeout (seconds) for GoTrue admin REST calls not wrapped by supabase-py
    # (MFA factor administration in supabase-py 2.34.0).
    supabase_admin_timeout_seconds: int = 15

    # --- Google Maps Platform (server-side only) ---------------------------
    # Address validation / location verification ONLY. Never used to replace
    # the OSM/Overture analytical dataset, and never exposed to a browser or
    # mobile client: the key stays on this server.
    google_maps_api_key: str = ""
    google_maps_timeout_seconds: int = 12

    # --- WorldPop age-sex tile set (server-local, NOT in the repository) ---
    # Directory holding the 42 GeoTIFFs (20 male + 20 female five-year bands
    # + T_F + T_M, ~1.2 GB) that the ``age_population`` enrichment category
    # reads. Provision with backend/scripts/data/fetch_worldpop_agesex.py,
    # then point SITEWISE_AGE_RASTER_DIR at the directory. Empty (default) =>
    # the category settles as "unavailable: not configured" for every
    # property instead of guessing.
    sitewise_age_raster_dir: str = ""

    # --- Layer-1 PU model variant ------------------------------------------
    # Which PU artifact the personalised recommender's Layer-1 score comes
    # from. "legacy" (default) keeps the stored production
    # research_p_association_score untouched. "experimental47" runs LIVE
    # inference with the supplied experimental 47-feature bagged Histogram
    # Gradient Boosting artifact for research properties whose full
    # 47-feature vector resolves (DB + committed training bridge); everything
    # else reports "47-feature inference unavailable" and is excluded from
    # that experimental ranking. The two score families are NEVER mixed
    # inside one ranking batch, and experimental scores are never written to
    # the legacy score columns. Research/testing only: the experimental
    # artifact is production_ready=false per its model card.
    #
    # "expanded64" (2026-11-15) is the same live-inference policy for the
    # 64-feature expanded Logistic artifact (44 baseline features minus
    # LandScan + 12 WorldPop age + 8 residential). Its 16 new measurements
    # exist only in the committed training data (the analytics DB has no
    # values for them), so only the 1,796 research subjects with a complete
    # expanded bridge record can score; everything else reports the missing
    # fields and is excluded. production_ready=false per its model card.
    #
    # DEFAULT CHANGED to "expanded64" by the 2026-11-15 category-aware
    # integration. The retrained Stage-2 category model is defined over the
    # SAME 54 features (the 64-feature contract minus the ten competitor
    # counts), and the brief forbids mixing the original 47-feature stored
    # scores with the new 64-feature scores in one ranking. Keeping "legacy"
    # as the default would do exactly that. Coverage measured on the live
    # catalogue: 896/955 properties resolve a complete 64-feature vector and
    # 351 pass the unchanged strictly-greater-than-50 gate. "legacy" and
    # "experimental47" remain selectable for comparison and audit.
    sitewise_pu_model_variant: str = "expanded64"

    @property
    def pu_model_variant(self) -> str:
        variant = (self.sitewise_pu_model_variant or "legacy").strip().lower()
        if variant not in {"legacy", "experimental47", "expanded64"}:
            raise ValueError(
                "SITEWISE_PU_MODEL_VARIANT must be 'legacy', 'experimental47' or "
                f"'expanded64', got {self.sitewise_pu_model_variant!r}"
            )
        return variant

    @property
    def cors_origin_list(self) -> list[str]:
        return [o.strip() for o in self.cors_origins.split(",") if o.strip()]

    @property
    def staff_invite_redirect(self) -> str:
        if self.supabase_staff_invite_redirect_url:
            return self.supabase_staff_invite_redirect_url
        return self._default_auth_redirect

    @property
    def entrepreneur_invite_redirect(self) -> str:
        """Redirect embedded in a public (entrepreneur) invitation.

        Entrepreneurs are not staff, so they must not be sent to the staff
        password-setup target. Both land on the web app's auth callback, which
        is the endpoint that exchanges the one-time code for a session.
        """
        return self._default_auth_redirect

    @property
    def _default_auth_redirect(self) -> str:
        origin = self.cors_origin_list[0] if self.cors_origin_list else "http://localhost:8090"
        return f"{origin}/auth/callback"

    @property
    def supabase_issuer(self) -> str:
        return f"{self.supabase_url.rstrip('/')}/auth/v1"

    @property
    def jwt_audience_list(self) -> list[str]:
        return [a.strip() for a in self.supabase_jwt_audiences.split(",") if a.strip()]


settings = Settings()
