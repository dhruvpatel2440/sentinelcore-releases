"""Token + admin-secret handling. We store only token HASHES; the plaintext
token is returned to the install exactly once at registration."""

from __future__ import annotations

import hashlib
import hmac
import secrets


def new_token() -> str:
    """Opaque per-install bearer token (URL-safe, ~43 chars)."""
    return secrets.token_urlsafe(32)


def hash_token(token: str) -> str:
    """SHA-256 hex of the token. Only this is persisted."""
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def verify_token(token: str, stored_hash: str) -> bool:
    return hmac.compare_digest(hash_token(token), stored_hash)


def new_verify_code() -> str:
    return secrets.token_urlsafe(24)


def check_admin_secret(presented: str, configured: str) -> bool:
    if not configured:
        return False
    return hmac.compare_digest(presented or "", configured)


def parse_bearer(header: str | None) -> str | None:
    if not header:
        return None
    parts = header.split(" ", 1)
    if len(parts) == 2 and parts[0].lower() == "bearer" and parts[1].strip():
        return parts[1].strip()
    return None
