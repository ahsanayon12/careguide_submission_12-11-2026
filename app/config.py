"""Application configuration, read exclusively from environment variables."""

from __future__ import annotations

import os
from dataclasses import dataclass

VALID_LOG_LEVELS = {"DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"}


@dataclass(frozen=True)
class Settings:
    app_name: str
    app_version: str
    environment: str
    host: str
    port: int
    log_level: str

    @classmethod
    def from_env(cls) -> Settings:
        log_level = os.getenv("LOG_LEVEL", "INFO").upper()
        if log_level not in VALID_LOG_LEVELS:
            log_level = "INFO"

        try:
            port = int(os.getenv("PORT", "8080"))
        except ValueError:
            port = 8080

        return cls(
            app_name=os.getenv("APP_NAME", "careguide-api"),
            app_version=os.getenv("APP_VERSION", "0.0.0-dev"),
            environment=os.getenv("ENVIRONMENT", "local"),
            host=os.getenv("HOST", "0.0.0.0"),  # noqa: S104 - container must bind all interfaces
            port=port,
            log_level=log_level,
        )


settings = Settings.from_env()
