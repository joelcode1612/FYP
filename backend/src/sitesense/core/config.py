from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    database_url: str = "postgresql://postgres:123456@localhost:5432/sitesense"
    log_level: str = "INFO"
    secret_key: str = "change-me"
    cors_origins: str = "http://localhost:8090,http://127.0.0.1:8090,http://localhost:3000"


settings = Settings()
