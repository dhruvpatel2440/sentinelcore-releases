"""Relay configuration. Provider credentials come from the SERVER env only,
never from the repo. See .env.example for the full set (placeholders only)."""

from __future__ import annotations

import os
from dataclasses import dataclass, field


def _int(name: str, default: int) -> int:
    try:
        return int(os.getenv(name, str(default)))
    except ValueError:
        return default


@dataclass
class Settings:
    # Storage: sqlite path (default) or a Postgres DSN via DB_URL (future).
    db_path: str = field(default_factory=lambda: os.getenv("RELAY_DB_PATH", "/data/relay.db"))

    # Admin API secret (protects list/revoke). REQUIRED in production.
    admin_secret: str = field(default_factory=lambda: os.getenv("RELAY_ADMIN_SECRET", ""))

    # Provider selection + credentials (server-side only).
    provider: str = field(default_factory=lambda: os.getenv("RELAY_PROVIDER", "fake"))
    brevo_api_key: str = field(default_factory=lambda: os.getenv("BREVO_API_KEY", ""))
    from_address: str = field(default_factory=lambda: os.getenv("RELAY_FROM_ADDRESS", "notify@sentinelcore.app"))
    from_name: str = field(default_factory=lambda: os.getenv("RELAY_FROM_NAME", "SentinelCore"))

    # Limits.
    register_rate_per_ip_hour: int = field(default_factory=lambda: _int("RELAY_REGISTER_RATE_PER_IP_HOUR", 5))
    send_rate_per_token_min: int = field(default_factory=lambda: _int("RELAY_SEND_RATE_PER_TOKEN_MIN", 30))
    daily_quota_per_token: int = field(default_factory=lambda: _int("RELAY_DAILY_QUOTA_PER_TOKEN", 250))
    global_daily_quota: int = field(default_factory=lambda: _int("RELAY_GLOBAL_DAILY_QUOTA", 50000))
    max_body_bytes: int = field(default_factory=lambda: _int("RELAY_MAX_BODY_BYTES", 262144))  # 256 KiB

    # Verification link/token TTL.
    verify_ttl_seconds: int = field(default_factory=lambda: _int("RELAY_VERIFY_TTL_SECONDS", 86400))

    # Public base URL (used only to build verification links in emails).
    public_url: str = field(default_factory=lambda: os.getenv("RELAY_PUBLIC_URL", "https://relay.sentinelcore.app"))


settings = Settings()
