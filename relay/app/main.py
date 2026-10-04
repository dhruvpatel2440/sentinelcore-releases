"""SentinelCore email relay.

Endpoints:
  POST /v1/register       {admin_email, install_id, version} -> {token, from_name}
                          rate-limited per IP; sends a verification email;
                          token is inactive until /v1/verify.
  POST /v1/verify         {install_id, code} -> activates the token.
  GET  /v1/verify?install_id=&code=   same, for the link in the verification
                          email (returns a small HTML page).
  POST /v1/send           Bearer token; {template_id, variables, to?}
                          strict: renders an APPROVED template server-side.
  POST /v1/send_rendered  Bearer token; {to, subject, text, html, tag}
                          used by the Brevo-compatible shim for the unmodified
                          app; same auth/quota/recipient gating + size cap +
                          E## tag allowlist. No arbitrary recipients.
  POST /v1/revoke         admin-only (X-Admin-Secret); {install_id}
  GET  /v1/admin/installs admin-only; list installs (hashes, never tokens)
  GET  /v1/health, /healthz

Structured logs carry metadata only — never bodies, never secrets.
"""

from __future__ import annotations

import hmac
import html as html_lib
import logging
import time
import uuid

from fastapi import FastAPI, Header, Request
from fastapi.responses import HTMLResponse, JSONResponse
from pydantic import BaseModel, EmailStr, Field

from app import auth
from app.config import settings
from app.db import Install, Store
from app.providers import get_provider
from app.providers.base import Outgoing, ProviderError
from app.quota import SlidingWindow
from app import templates

logger = logging.getLogger("relay")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")

app = FastAPI(title="SentinelCore Email Relay", version="1.0.0")

store = Store(settings.db_path)
provider = get_provider()
register_limiter = SlidingWindow(settings.register_rate_per_ip_hour, 3600)
send_limiter = SlidingWindow(settings.send_rate_per_token_min, 60)


def _client_ip(request: Request) -> str:
    fwd = request.headers.get("x-forwarded-for")
    if fwd:
        return fwd.split(",")[0].strip()
    return request.client.host if request.client else "unknown"


def _err(status: int, detail: str) -> JSONResponse:
    return JSONResponse(status_code=status, content={"error": detail})


# --------------------------------------------------------------------------
# Models
# --------------------------------------------------------------------------
class RegisterIn(BaseModel):
    admin_email: EmailStr
    install_id: str = Field(min_length=4, max_length=128)
    version: str = Field(default="", max_length=32)


class VerifyIn(BaseModel):
    install_id: str
    code: str


class SendIn(BaseModel):
    template_id: str
    variables: dict = Field(default_factory=dict)
    to: EmailStr | None = None


class SendRenderedIn(BaseModel):
    to: EmailStr
    subject: str = Field(max_length=512)
    text: str = Field(default="")
    html: str = Field(default="")
    tag: str = Field(max_length=16)


class RevokeIn(BaseModel):
    install_id: str


# --------------------------------------------------------------------------
# Health
# --------------------------------------------------------------------------
@app.get("/healthz")
@app.get("/v1/health")
def health() -> dict:
    return {"status": "ok", "provider": provider.name}


# --------------------------------------------------------------------------
# Registration + verification
# --------------------------------------------------------------------------
@app.post("/v1/register")
def register(body: RegisterIn, request: Request) -> JSONResponse:
    ip = _client_ip(request)
    if not register_limiter.allow(ip):
        logger.warning("register rate-limited ip=%s", ip)
        return _err(429, "registration rate limit exceeded")

    if store.get_by_install_id(body.install_id):
        # Idempotent-ish: do not leak whether it existed; ask them to revoke first.
        logger.info("register duplicate install_id")
        return _err(409, "install_id already registered")

    token = auth.new_token()
    code = auth.new_verify_code()
    inst = Install(
        install_id=body.install_id,
        admin_email=str(body.admin_email).lower(),
        token_hash=auth.hash_token(token),
        verified=0,
        revoked=0,
        verify_code=code,
        verify_expires=int(time.time()) + settings.verify_ttl_seconds,
        version=body.version,
        created_at=int(time.time()),
    )
    store.create_install(inst)

    # Send the verification email through the provider (fake in dev).
    link = f"{settings.public_url}/v1/verify?install_id={body.install_id}&code={code}"
    try:
        provider.send(Outgoing(
            to=inst.admin_email,
            subject="Verify your SentinelCore email relay registration",
            text=f"Confirm this install can send mail:\n{link}\ncode: {code}",
            html=f'<p>Confirm this install can send mail:</p><p><a href="{link}">Verify</a></p>',
            tag="VERIFY",
        ))
    except ProviderError as exc:
        logger.error("verification send failed: %s", exc)

    logger.info("registered install_id=%s ip=%s (pending verification)", body.install_id, ip)
    return JSONResponse({"token": token, "from_name": settings.from_name, "sender_address": settings.from_address})


def _do_verify(install_id: str, code: str) -> tuple[int, dict]:
    inst = store.get_by_install_id(install_id)
    if not inst or inst.revoked:
        return 404, {"error": "unknown install"}
    if inst.verified:
        return 200, {"status": "already-verified"}
    if not inst.verify_code or not hmac.compare_digest(inst.verify_code, code):
        return 400, {"error": "bad verification code"}
    if inst.verify_expires < int(time.time()):
        return 400, {"error": "verification code expired"}
    store.mark_verified(install_id)
    logger.info("verified install_id=%s", install_id)
    return 200, {"status": "verified"}


@app.post("/v1/verify")
def verify(body: VerifyIn) -> JSONResponse:
    status, payload = _do_verify(body.install_id, body.code)
    return JSONResponse(payload, status_code=status)


@app.get("/v1/verify")
def verify_link(install_id: str = "", code: str = "") -> HTMLResponse:
    """Target of the link in the verification email (a browser GET)."""
    status, payload = _do_verify(install_id, code) if install_id and code else (400, {"error": "missing parameters"})
    if status == 200:
        title, msg = "Email relay verified", "This SentinelCore install can now send notification email. You can close this tab."
    else:
        title, msg = "Verification failed", payload.get("error", "error")
    page = (
        "<!doctype html><html><head><meta charset='utf-8'><title>{t}</title></head>"
        "<body style='font-family:sans-serif;max-width:36rem;margin:4rem auto'>"
        "<h1>{t}</h1><p>{m}</p></body></html>"
    ).format(t=html_lib.escape(title), m=html_lib.escape(msg))
    return HTMLResponse(page, status_code=status)


# --------------------------------------------------------------------------
# Send gating
# --------------------------------------------------------------------------
def _authorize(authorization: str | None) -> tuple[Install | None, JSONResponse | None]:
    token = auth.parse_bearer(authorization)
    if not token:
        return None, _err(401, "missing bearer token")
    inst = store.get_by_token_hash(auth.hash_token(token))
    if not inst:
        return None, _err(401, "invalid token")
    if inst.revoked:
        return None, _err(403, "token revoked")
    if not inst.verified:
        return None, _err(403, "install not verified")
    if not send_limiter.allow(inst.token_hash):
        return None, _err(429, "send rate limit exceeded")
    return inst, None


def _check_quota_and_recipient(inst: Install, to: str) -> JSONResponse | None:
    if to.lower() != inst.admin_email:
        logger.warning("recipient rejected install_id=%s", inst.install_id)
        return _err(403, "recipient not allowed for this install")
    tok_today, glob_today = store.incr_daily(inst.token_hash)
    if tok_today > settings.daily_quota_per_token:
        return _err(429, "daily per-install quota exceeded")
    if glob_today > settings.global_daily_quota:
        return _err(503, "relay global daily quota exceeded")
    return None


def _deliver(inst: Install, out: Outgoing) -> JSONResponse:
    try:
        mid = provider.send(out)
    except ProviderError as exc:
        status = 502 if exc.retryable else 400
        logger.error("provider send failed install_id=%s retryable=%s", inst.install_id, exc.retryable)
        return _err(status, "provider send failed")
    logger.info("sent install_id=%s tag=%s mid=%s", inst.install_id, out.tag, mid)
    return JSONResponse({"status": "sent", "message_id": mid})


@app.post("/v1/send")
def send(body: SendIn, authorization: str | None = Header(default=None)) -> JSONResponse:
    inst, errr = _authorize(authorization)
    if errr:
        return errr
    if not templates.is_allowed_id(body.template_id):
        return _err(400, "unknown or disallowed template_id")
    to = (str(body.to).lower() if body.to else inst.admin_email)
    q = _check_quota_and_recipient(inst, to)
    if q:
        return q
    subject, text, html_body = templates.render(body.template_id, body.variables)
    return _deliver(inst, Outgoing(to=to, subject=subject, text=text, html=html_body, tag=body.template_id))


@app.post("/v1/send_rendered")
def send_rendered(body: SendRenderedIn, authorization: str | None = Header(default=None)) -> JSONResponse:
    inst, errr = _authorize(authorization)
    if errr:
        return errr
    if not templates.is_allowed_tag(body.tag):
        return _err(400, "tag not in allowlist (expected E## type)")
    total = len(body.subject) + len(body.text) + len(body.html)
    if total > settings.max_body_bytes:
        return _err(413, "message exceeds size limit")
    q = _check_quota_and_recipient(inst, str(body.to))
    if q:
        return q
    return _deliver(inst, Outgoing(to=str(body.to).lower(), subject=body.subject,
                                   text=body.text, html=body.html, tag=body.tag))


# --------------------------------------------------------------------------
# Admin
# --------------------------------------------------------------------------
@app.post("/v1/revoke")
def revoke(body: RevokeIn, x_admin_secret: str | None = Header(default=None)) -> JSONResponse:
    if not auth.check_admin_secret(x_admin_secret or "", settings.admin_secret):
        return _err(401, "admin auth required")
    n = store.revoke(body.install_id)
    if n == 0:
        return _err(404, "unknown install")
    logger.info("revoked install_id=%s", body.install_id)
    return JSONResponse({"status": "revoked"})


@app.get("/v1/admin/installs")
def admin_installs(x_admin_secret: str | None = Header(default=None)) -> JSONResponse:
    if not auth.check_admin_secret(x_admin_secret or "", settings.admin_secret):
        return _err(401, "admin auth required")
    out = [
        {
            "install_id": i.install_id,
            "admin_email": i.admin_email,
            "verified": bool(i.verified),
            "revoked": bool(i.revoked),
            "version": i.version,
            "created_at": i.created_at,
            "sent_today": store.daily_count(i.token_hash),
        }
        for i in store.list_installs()
    ]
    return JSONResponse({"installs": out})
