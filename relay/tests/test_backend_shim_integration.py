"""A6 integration: the UNMODIFIED SentinelCore backend email client ->
relay-shim over real TLS -> relay (fake provider).

What this proves, without Docker:
  * the backend's `BrevoClient` (httpx 0.27, verify=True) trusts the shim's
    install-local certificate ONLY via SSL_CERT_FILE (the mechanism the
    release compose uses: SSL_CERT_FILE=/etc/sentinelcore/ca-bundle.pem);
  * the success path returns a Brevo-shaped messageId and the relay sends;
  * when the relay is unreachable, the client raises its typed
    BrevoRetryableError (the outbox reschedules) — no crash.

The backend client is loaded READ-ONLY from SOURCE_DIR
(SC_SOURCE_DIR env, else ../../SentinelCore[/<one nested checkout>]).
Only `app.core.config.settings` is stubbed. Skips when the source tree or
openssl is unavailable.
"""

from __future__ import annotations

import asyncio
import importlib.util
import os
import shutil
import socket
import subprocess
import sys
import threading
import time
import types
import uuid
from pathlib import Path

import certifi
import httpx
import pytest
from starlette.testclient import TestClient

from app.main import app as relay_app, store
from app.providers import fake
from shim import app as shim_module

RELAY_DIR = Path(__file__).resolve().parents[1]
ADMIN = "integration@example.org"


def _find_client_py() -> Path | None:
    cands = []
    if os.getenv("SC_SOURCE_DIR"):
        cands.append(Path(os.environ["SC_SOURCE_DIR"]))
    base = RELAY_DIR.parents[1] / "SentinelCore"
    cands.append(base)
    if base.is_dir():
        cands.extend(p for p in base.iterdir() if p.is_dir())
    for c in cands:
        f = c / "backend" / "app" / "email" / "client.py"
        if f.is_file():
            return f
    return None


CLIENT_PY = _find_client_py()
OPENSSL = shutil.which("openssl")
pytestmark = [
    pytest.mark.skipif(CLIENT_PY is None, reason="SentinelCore source tree not found (set SC_SOURCE_DIR)"),
    pytest.mark.skipif(OPENSSL is None, reason="openssl not installed"),
]


def _openssl(*args: str, cwd: Path) -> None:
    env = dict(os.environ, MSYS_NO_PATHCONV="1", MSYS2_ARG_CONV_EXCL="*")
    subprocess.run([OPENSSL, *args], cwd=cwd, check=True, capture_output=True, env=env)


@pytest.fixture(scope="module")
def pki(tmp_path_factory) -> dict:
    """CA + leaf the same way installer/lib/tls.sh does (plus localhost SAN,
    because this test cannot alias api.brevo.com to 127.0.0.1)."""
    d = tmp_path_factory.mktemp("pki")
    _openssl("genrsa", "-out", "ca.key", "2048", cwd=d)
    _openssl("req", "-x509", "-new", "-key", "ca.key", "-sha256", "-days", "2", "-subj", "/CN=Test Install CA",
             "-addext", "basicConstraints=critical,CA:TRUE,pathlen:0",
             "-addext", "keyUsage=critical,keyCertSign,cRLSign", "-out", "ca.crt", cwd=d)
    _openssl("genrsa", "-out", "leaf.key", "2048", cwd=d)
    _openssl("req", "-new", "-key", "leaf.key", "-subj", "/CN=api.brevo.com", "-out", "leaf.csr", cwd=d)
    (d / "leaf.ext").write_text(
        "subjectAltName=DNS:api.brevo.com,DNS:localhost\nbasicConstraints=CA:FALSE\n"
        "keyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n"
    )
    _openssl("x509", "-req", "-in", "leaf.csr", "-CA", "ca.crt", "-CAkey", "ca.key", "-set_serial", "0x1234",
             "-days", "2", "-sha256", "-extfile", "leaf.ext", "-out", "leaf.crt", cwd=d)
    (d / "ca.key").unlink()  # A7: nothing needs the CA key after signing
    bundle = d / "ca-bundle.pem"
    bundle.write_bytes(Path(certifi.where()).read_bytes() + b"\n" + (d / "ca.crt").read_bytes())
    return {"crt": str(d / "leaf.crt"), "key": str(d / "leaf.key"), "bundle": str(bundle)}


@pytest.fixture(scope="module")
def shim_url(pki):
    import uvicorn

    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
    config = uvicorn.Config(shim_module.app, host="127.0.0.1", port=port, log_level="warning",
                            ssl_certfile=pki["crt"], ssl_keyfile=pki["key"])
    server = uvicorn.Server(config)
    t = threading.Thread(target=server.run, daemon=True)
    t.start()
    deadline = time.time() + 15
    while not server.started and time.time() < deadline:
        time.sleep(0.05)
    assert server.started, "shim did not start"
    yield f"https://localhost:{port}"
    server.should_exit = True
    t.join(timeout=5)


@pytest.fixture()
def token() -> str:
    relay = TestClient(relay_app)
    install_id = f"install-int-{uuid.uuid4().hex[:8]}"
    r = relay.post("/v1/register", json={"admin_email": ADMIN, "install_id": install_id, "version": "1.0.1"})
    assert r.status_code == 200, r.text
    inst = store.get_by_install_id(install_id)
    assert relay.post("/v1/verify", json={"install_id": install_id, "code": inst.verify_code}).status_code == 200
    shim_module.set_test_transport(httpx.ASGITransport(app=relay_app))
    yield r.json()["token"]
    shim_module.set_test_transport(None)


def _load_backend_client(tok: str, url: str):
    """Import the real backend client module with a stub settings object."""
    settings = types.SimpleNamespace(
        brevo_api_key=tok, email_sender_address="notify@example.org", email_sender_name="SentinelCore"
    )
    core = types.ModuleType("app.core")
    cfg = types.ModuleType("app.core.config")
    cfg.settings = settings
    saved = {k: sys.modules.get(k) for k in ("app.core", "app.core.config")}
    sys.modules["app.core"], sys.modules["app.core.config"] = core, cfg
    try:
        spec = importlib.util.spec_from_file_location("sc_backend_email_client", CLIENT_PY)
        mod = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = mod  # dataclasses resolve annotations via sys.modules
        spec.loader.exec_module(mod)
    finally:
        for k, v in saved.items():
            if v is None:
                sys.modules.pop(k, None)
            else:
                sys.modules[k] = v
    mod.BREVO_URL = f"{url}/v3/smtp/email"
    return mod


def _send(mod):
    return asyncio.run(mod.BrevoClient().send(
        outbox_id=uuid.uuid4(), email_type="E01", recipient_email=ADMIN,
        subject="New incident", html_body="<p>x</p>", text_body="x",
    ))


def test_backend_client_uses_httpx():
    src = CLIENT_PY.read_text(encoding="utf-8")
    assert "import httpx" in src and "verify=True" in src
    assert "import requests" not in src and "import aiohttp" not in src


def test_success_through_tls_shim_trusted_via_ssl_cert_file(pki, shim_url, token, monkeypatch):
    monkeypatch.setenv("SSL_CERT_FILE", pki["bundle"])
    mod = _load_backend_client(token, shim_url)
    before = len(fake.SENT)
    result = _send(mod)
    assert result.provider_message_id
    assert len(fake.SENT) == before + 1
    assert fake.SENT[-1]["to"] == ADMIN and fake.SENT[-1]["tag"] == "E01"


def test_without_install_ca_tls_is_rejected(pki, shim_url, token, monkeypatch):
    """Control: certifi alone does not trust the shim -> SSL_CERT_FILE is what matters."""
    monkeypatch.delenv("SSL_CERT_FILE", raising=False)
    monkeypatch.delenv("SSL_CERT_DIR", raising=False)
    mod = _load_backend_client(token, shim_url)
    with pytest.raises(mod.BrevoRetryableError) as ei:
        _send(mod)
    assert "network error" in str(ei.value)
    assert token not in str(ei.value)


def test_relay_unreachable_gives_clear_retryable_error(pki, shim_url, token, monkeypatch):
    monkeypatch.setenv("SSL_CERT_FILE", pki["bundle"])
    shim_module.set_test_transport(None)
    monkeypatch.setattr(shim_module, "RELAY_URL", "http://127.0.0.1:9")
    mod = _load_backend_client(token, shim_url)
    with pytest.raises(mod.BrevoRetryableError) as ei:
        _send(mod)
    assert "502" in str(ei.value)
    # The shim keeps serving after the failure (no crash).
    r = httpx.post(f"{shim_url}/v3/smtp/email", json={}, verify=pki["bundle"])
    assert r.status_code == 401


def test_revoked_token_is_fatal_not_retried(pki, shim_url, token, monkeypatch):
    """Revoke at the relay -> 403 through the shim -> BrevoFatalError (the
    client trips its circuit breaker instead of retrying forever)."""
    from app import auth

    monkeypatch.setenv("SSL_CERT_FILE", pki["bundle"])
    inst = store.get_by_token_hash(auth.hash_token(token))
    relay = TestClient(relay_app)
    assert relay.post("/v1/revoke", json={"install_id": inst.install_id},
                      headers={"x-admin-secret": "test-admin-secret"}).status_code == 200
    mod = _load_backend_client(token, shim_url)
    with pytest.raises(mod.BrevoFatalError) as ei:
        _send(mod)
    assert ei.value.status_code == 403
