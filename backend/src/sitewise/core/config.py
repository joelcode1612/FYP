from pydantic import SecretStr
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=(".env", ".env.local"), extra="ignore")

    # --- Databases ---------------------------------------------------------
    # Schema creation at startup is an explicit operator decision. With this
    # off, the application never issues CREATE TABLE / CREATE SCHEMA: a missing
    # table fails loudly instead of being silently created in whatever database
    # DATABASE_URL happens to name.
    db_auto_create: bool = False
    # Application database (user profiles, saved properties, preferences).
    # Startup `create_all` runs through this URL, so it is the only database
    # the ORM ever writes to.
    database_url: str = (
        "postgresql+psycopg2://postgres:123456@localhost:5432/Final_Location_Analysis"
    )
    # Analytics database (DOSM statistics, geospatial features). Read-only by
    # convention; the ORM never runs create_all or migrations against it.
    analytics_database_url: str = (
        "postgresql+psycopg2://postgres:123456@localhost:5432/Final_Location_Analysis"
    )

    # Agent assignments: local DB is authoritative; remote mirror is opt-in.
    assignment_sync_enabled: bool = False

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
    # Persisted BCB remains default-off pending reviewed migration and real
    # tenant/concept/GEO/purpose authority adapters. No downstream activation.
    m2_bcb_persistence_enabled: bool = False
    # Separate only when needed: never silently move property/auth modules.
    # Blank reuses DATABASE_URL only if it already names the expected target.
    m2_database_url: SecretStr = SecretStr('')
    m2_expected_database: str = 'Dss'
    # Disabled until a reviewed database identity migration is installed.
    # Key is a separately provisioned secret, never the database password.
    m2_protected_identity_enabled: bool = False
    m2_identity_assertion_key: SecretStr = SecretStr('')
    # BCB confirmation validity horizon, in days. There is NO default: when
    # this is absent the resolver fails closed with
    # VALIDITY_BASIS_UNAUTHORIZED instead of assuming a 90-day window. Any
    # 90-day value used in tests is a test value, not a product rule.
    project1_bcb_confirmation_validity_days: int | None = None
    # CQ engineering adapter is separate from scientific/fielding authorization.
    cq_runtime_enabled: bool = False
    # No fallback to property/analytics or superuser connections for reporting.
    ee01_database_url: SecretStr = SecretStr('')
    ee01_expected_database: str = 'Dss'
    # Candidate explanation results live in the project1_ai ledger database.
    # The default target is the recognised disposable cluster; no production
    # database is reachable unless an operator explicitly changes these fields.
    explanation_store_database_url: SecretStr = SecretStr('')
    explanation_store_expected_database: str = 'project1_workflow_tests'
    explanation_store_expected_port: int = 5433
    # Candidate-only explanation surface. Default-off; the route stays mounted
    # so the hold is discoverable, but generation returns 503 until an admitted
    # measurement, disclosure adapter and reviewed attempt ledger row exist.
    ee01_explanation_enabled: bool = False
    # Separate local operator inspection. Never authorizes participation.
    cq_synthetic_preview_enabled: bool = False
    cq_synthetic_interactive_enabled: bool = False

    # Separate staging bridge; does not enable the unresolved BDJ/M2 write router.
    project1_cp07_enabled: bool = False
    project1_cp07_uc_database_url: SecretStr = SecretStr("")

    # Candidate AI workflow: explicit migrations and authority reconciliation only.
    project1_workflow_enabled: bool = False
    # BDJ output contract selector. 'findings' is the historical behaviour and
    # stays the default so nothing changes until a gate is explicitly passed.
    # 'shadow' evaluates both without persisting; 'objective' serves the
    # objective-proposal contract. Read through selected_bdj_contract(), which refuses
    # an unknown value instead of falling back.
    project1_bdj_contract: str = "findings"
    # Explicit private-lab opt-in. Neither field changes the default Dss target.
    project1_isolated_database_name: str = ""
    project1_isolated_database_port: int = 0
    project1_synthetic_bdj_trial_enabled: bool = False
    project1_synthetic_bdj_prompt_path: str = ""
    project1_synthetic_bdj_prompt_sha256: str = ""
    project1_rules_version: str = ""
    project1_rules_sha256: str = ""
    project1_rules_adoption_receipt: str = ""
    #: Per-instrument ruleset pins. The legacy trio above remains the M2V1
    #: default, so every historical M2V1 run identity is reproduced exactly.
    #: M2V2 has its own version, hash and receipt, so the two instruments are
    #: adopted independently and neither can silently stand in for the other.
    #: A family whose three values are not all set is simply not adopted, and
    #: its runs are refused rather than borrowing another instrument's ruleset.
    project1_rules_m2v1_version: str = ""
    project1_rules_m2v1_sha256: str = ""
    project1_rules_m2v1_adoption_receipt: str = ""
    project1_rules_m2v2_version: str = ""
    project1_rules_m2v2_sha256: str = ""
    project1_rules_m2v2_adoption_receipt: str = ""
    #: Explicit synthetic instrument scope. Empty disables the mechanism.
    #: Activation additionally requires a disposable, non-5432 database target;
    #: see sitewise.services.instrument_authorization. It never changes a
    #: stored approval_state.
    m2_synthetic_instrument_scope: str = ""
    #: Instrument code a **newly created** M2 record is built on. The code
    #: default is M2V1 so production behaviour is unchanged; the isolated PG18
    #: E2E environment sets M2V2 because that is the instrument its owner
    #: authorized there. It selects a default only — the audited usability gate
    #: in sitewise.services.instrument_authorization still decides whether the
    #: named code resolves to exactly one usable row, and an explicit
    #: ``instrument_code`` argument still wins.
    m2_default_instrument_code: str = "M2V1"
    project1_runtime_database_url: SecretStr = SecretStr("")
    project1_audit_database_url: SecretStr = SecretStr("")
    tokenharbor_api_key: SecretStr = SecretStr("")
    tokenharbor_enabled: bool = False
    tokenharbor_structured_mode: str = "json_schema"
    tokenharbor_timeout_seconds: int = 30
    #: Provisional Direct-QG evaluation cap only. The code default stays at the
    #: historical 4,000; the isolated test environment opts into 12,000. A
    #: value above MAX_TOKENHARBOR_MAX_TOKENS is refused, never clamped.
    tokenharbor_max_tokens: int = 4000
    #: The most one authorised QG attempt may be allowed to cost. Declared here
    #: rather than left implicit in an operator artifact, because a ceiling that
    #: no dispatch path reads is a comment, not a limit.
    tokenharbor_cost_ceiling_usd: float = 0.50
    # Development evaluation only: tolerate the provider reporting the model
    # without its ':free' qualifier, recorded as unverified. Never production.
    tokenharbor_model_identity_exception: bool = False
    # Key custody for the encrypted raw-response store. Filesystem directory,
    # deliberately outside the database and outside the project1_ai schema: a
    # retention deadline cannot be honoured by deleting an append-only row, so
    # expiry destroys the per-record key instead. Empty => <backend>/var/
    # key-custody. Never point this at a web-served or synced folder.
    project1_key_custody_dir: str = ""
    # Append-only JSONL receipt ledger for retention destruction. Empty =>
    # <backend>/var/audit/project1_retention_receipts.jsonl.
    project1_retention_receipt_path: str = ""

    # --- Supabase authentication ------------------------------------------
    # Identity provider. Registration/login happen in the frontend through the
    # Supabase SDK; this backend only VERIFIES the issued access tokens.
    supabase_url: str = ""
    # Publishable (anon) key - public by design, used for /auth/v1/user lookups.
    supabase_publishable_key: str = ""
    # Server-only secret key. NEVER sent to a client, never used to sign JWTs.
    # Optional for this integration (only needed for admin API operations).
    supabase_secret_key: str = ""
    # Same Supabase Storage bucket as the standalone AR capture backend.
    sitewise_public_panorama_bucket: str = "property-panoramas"
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

    # --- Optional device-panorama enhancement (default OFF) ----------------
    # When explicitly enabled, an administrator may run a CONSERVATIVE tonal
    # pass (bounded white balance + exposure normalization) over a completed
    # device panorama. It never re-stitches, never touches the canonical
    # panorama.jpg, and writes a separate panorama_enhanced.jpg whose status
    # is recorded in the panorama's coverage_report metadata. Enhancement
    # failure never destroys, blocks or replaces the valid original.
    sitewise_panorama_enhancement_enabled: bool = False

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


#: Upper bound on any single provider call, applied where a call is constructed.
#: It exists so that a misconfigured timeout cannot hang a request thread
#: indefinitely, but it must sit above the longest timeout an operator may
#: legitimately need: a real QG call has been observed to take 11.5 s, and a
#: 30 s budget produced a genuine unknown-outcome timeout on 2026-11-23. 180 s
#: leaves room for a slow provider while still bounding the call.
MAX_TOKENHARBOR_TIMEOUT_SECONDS = 180

#: Provisional ceiling for the Direct-QG evaluation cap. 12,000 is an initial
#: test limit adopted after a complete JSON response was observed; it is not a
#: production default and is not an unlimited generation budget. 120,000 is
#: deliberately not accepted in this phase.
MAX_TOKENHARBOR_MAX_TOKENS = 12_000

#: The owner-adopted ceiling for a single N04-C attempt. A configured value above
#: this is refused rather than clamped: silently lowering someone's stated budget
#: would hide that the deployment disagrees with the authorization.
MAX_TOKENHARBOR_COST_CEILING_USD = 0.50


def provider_cost_ceiling_usd() -> float:
    """The effective per-attempt ceiling, or ``None`` when it is not adopted.

    ``None`` is a refusal signal, not a default: a dispatch path that receives it
    must hold rather than assume a number. Nothing here substitutes 0.50 for an
    unset or over-large configuration.
    """
    try:
        ceiling = float(settings.tokenharbor_cost_ceiling_usd)
    except (TypeError, ValueError):
        return None
    if not 0 < ceiling <= MAX_TOKENHARBOR_COST_CEILING_USD:
        return None
    return ceiling


def provider_timeout_seconds() -> int:
    """The effective per-call timeout: configured value, clamped to the ceiling.

    One function, not three literal ``min(..., 60)`` copies, so that raising the
    ceiling is a single reviewable change and the call sites cannot drift.
    """
    return max(1, min(settings.tokenharbor_timeout_seconds,
                      MAX_TOKENHARBOR_TIMEOUT_SECONDS))


def provider_max_tokens() -> int | None:
    """The effective provider output cap, or ``None`` when not adopted.

    The default remains 4,000 so existing deployments are unchanged. The
    isolated Direct-QG environment may opt into 12,000. A larger value is a
    configuration disagreement, not a value to clamp silently: the provider
    refuses the call instead of pretending the deployment adopted a smaller
    budget.
    """
    raw = settings.tokenharbor_max_tokens
    if isinstance(raw, bool):
        return None
    try:
        value = int(raw)
    except (TypeError, ValueError):
        return None
    if not 1 <= value <= MAX_TOKENHARBOR_MAX_TOKENS:
        return None
    return value


BDJ_CONTRACTS = ("findings", "shadow", "objective")


def selected_bdj_contract() -> str:
    """The BDJ output contract, refused if the configured value is unknown.

    Fail-closed on purpose: a typo must not silently fall back to the historical
    behaviour or, worse, to the new one.
    """
    value = settings.project1_bdj_contract
    if value not in BDJ_CONTRACTS:
        raise ValueError(
            "PROJECT1_BDJ_CONTRACT must be one of %s, got %r" % (BDJ_CONTRACTS, value))
    return value
