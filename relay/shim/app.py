"""Brevo-compatible shim sidecar.

The unmodified SentinelCore backend POSTs to https://api.brevo.com/v3/smtp/email
with header `api-key: <token>`. In the release compose this host name resolves
(network alias) to THIS shim, which:
  * reads the per-install relay token from the `api-key` header,
  * extracts the E## email type from the Brevo `tags` array,
  * forwards to the relay's /v1/send_rendered over HTTPS,
  * returns a Brevo-shaped {messageId} so the app's client parses it unchanged.

No Brevo key ever lives on the box — only the revocable relay token. The shim
forwards pre-rendered content; the relay still enforces token, recipient,
tag-allowlist, size caps and quota.

Config (env):
  RELAY_URL            base URL of the relay (e.g. https://relay.sentinelcore.app)
  The relay token arrives per-request in the `api-key` header (BREVO_API_KEY on
  the box), so the shim holds no standing secret.
"""

from __future__ import annotations

import os

import httpx
from fastapi import FastAPI, Header, Request
from fastapi.responses import JSONResponse

RELAY_URL = os.getenv("RELAY_URL", "https://relay.sentinelcore.app")

# Tests can inject an in-process transport (ASGITransport over the relay app).
_TEST_TRANSPORT: httpx.BaseTransport | None = None


def set_test_transport(transport: httpx.BaseTransport | None) -> None:
    global _TEST_TRANSPORT
    _TEST_TRANSPORT = transport


app = FastAPI(title="SentinelCore Brevo shim", version="1.0.0")


def _extract_tag(tags) -> str:
    if isinstance(tags, list):
        for t in tags:
            if isinstance(t, str) and len(t) == 3 and t[0] == "E" and t[1:].isdigit():
                return t
    return "E00"


@app.post("/v3/smtp/email")
async def brevo_compat(request: Request, api_key: str | None = Header(default=None)) -> JSONResponse:
    if not api_key:
        return JSONResponse(status_code=401, content={"message": "api-key required"})
    body = await request.json()

    to_list = body.get("to") or []
    to = to_list[0].get("email") if to_list and isinstance(to_list[0], dict) else None
    if not to:
        return JSONResponse(status_code=400, content={"message": "missing recipient"})

    payload = {
        "to": to,
        "subject": body.get("subject", ""),
        "text": body.get("textContent", ""),
        "html": body.get("htmlContent", ""),
        "tag": _extract_tag(body.get("tags")),
    }
    headers = {"authorization": f"Bearer {api_key}", "content-type": "application/json"}

    client_kwargs = {"base_url": RELAY_URL, "timeout": httpx.Timeout(20.0)}
    if _TEST_TRANSPORT is not None:
        client_kwargs["transport"] = _TEST_TRANSPORT
    async with httpx.AsyncClient(**client_kwargs) as client:
        try:
            resp = await client.post("/v1/send_rendered", json=payload, headers=headers)
        except httpx.HTTPError:
            return JSONResponse(status_code=502, content={"message": "relay unreachable"})

    if resp.status_code == 200:
        data = resp.json()
        # Brevo returns 201 {messageId}; mirror that shape for the app client.
        return JSONResponse(status_code=201, content={"messageId": data.get("message_id", "relayed")})
    # Map relay errors to Brevo-ish statuses the app client understands.
    try:
        detail = resp.json().get("error", "relay error")
    except ValueError:
        detail = "relay error"
    return JSONResponse(status_code=resp.status_code, content={"message": detail})
