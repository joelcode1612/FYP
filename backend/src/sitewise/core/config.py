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

    @property
    def cors_origin_list(self) -> list[str]:
        return [o.strip() for o in self.cors_origins.split(",") if o.strip()]

    @property
    def staff_invite_redirect(self) -> str:
        if self.supabase_staff_invite_redirect_url:
            return self.supabase_staff_invite_redirect_url
        origin = self.cors_origin_list[0] if self.cors_origin_list else "http://localhost:8090"
        return f"{origin}/auth/callback"

    @property
    def supabase_issuer(self) -> str:
        return f"{self.supabase_url.rstrip('/')}/auth/v1"

    @property
    def jwt_audience_list(self) -> list[str]:
        return [a.strip() for a in self.supabase_jwt_audiences.split(",") if a.strip()]


settings = Settings()
