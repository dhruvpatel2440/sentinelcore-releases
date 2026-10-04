"""Brevo adapter. The ONLY place the real Brevo key is used, and it is read
from the relay SERVER env (settings.brevo_api_key) — never shipped to installs,
never logged."""

from __future__ import annotations

import httpx

from app.config import settings
from app.providers.base import Outgoing, Provider, ProviderError

BREVO_URL = "https://api.brevo.com/v3/smtp/email"


class BrevoProvider(Provider):
    name = "brevo"

    def send(self, msg: Outgoing) -> str:
        if not settings.brevo_api_key:
            raise ProviderError("BREVO_API_KEY not configured on relay", retryable=False)
        body = {
            "sender": {"email": settings.from_address, "name": settings.from_name},
            "to": [{"email": msg.to}],
            "subject": msg.subject,
            "htmlContent": msg.html,
            "textContent": msg.text,
            "tags": ["sentinelcore", msg.tag],
        }
        headers = {
            "api-key": settings.brevo_api_key,
            "content-type": "application/json",
            "accept": "application/json",
        }
        try:
            with httpx.Client(timeout=httpx.Timeout(connect=5.0, read=15.0, write=15.0, pool=15.0),
                              verify=True, follow_redirects=False) as client:
                resp = client.post(BREVO_URL, json=body, headers=headers)
        except httpx.HTTPError as exc:
            raise ProviderError(f"network error contacting provider: {type(exc).__name__}", retryable=True) from exc

        if resp.status_code in (200, 201):
            try:
                return resp.json().get("messageId", "brevo-ok")
            except ValueError:
                return "brevo-ok"
        if resp.status_code in (429,) or resp.status_code >= 500:
            raise ProviderError(f"provider {resp.status_code}", retryable=True)
        raise ProviderError(f"provider rejected send ({resp.status_code})", retryable=False)
