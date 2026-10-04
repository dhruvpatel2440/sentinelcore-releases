"""End-to-end: register -> verify -> send template mail via the Brevo shim ->
revoke -> send rejected. Uses the fake provider and an in-process transport so
the shim talks to the relay with no network/sockets."""

import httpx
from starlette.testclient import TestClient

from app.main import app as relay_app, store
from app.providers import fake
from shim import app as shim_module


ADMIN = "ops@example.org"
INSTALL = "install-e2e-001"


def _brevo_payload(to=ADMIN, tag="E01"):
    return {
        "sender": {"email": "notify@sentinelcore.app", "name": "SentinelCore"},
        "to": [{"email": to}],
        "subject": "New incident: port scan",
        "htmlContent": "<p>A new incident was raised.</p>",
        "textContent": "A new incident was raised.",
        "tags": ["sentinelcore", tag],
    }


def test_e2e_register_verify_send_revoke():
    relay = TestClient(relay_app)
    # Point the shim's internal httpx client at the relay, in-process.
    shim_module.set_test_transport(httpx.ASGITransport(app=relay_app))
    shim = TestClient(shim_module.app)
    fake.SENT.clear()

    # 1) register -> get token (inactive until verified)
    r = relay.post("/v1/register", json={"admin_email": ADMIN, "install_id": INSTALL, "version": "1.0.0"})
    assert r.status_code == 200, r.text
    token = r.json()["token"]
    assert token

    # sending before verification is refused
    pre = shim.post("/v3/smtp/email", json=_brevo_payload(), headers={"api-key": token})
    assert pre.status_code == 403, pre.text

    # 2) verify using the code the relay stored
    inst = store.get_by_install_id(INSTALL)
    assert inst and not inst.verified
    v = relay.post("/v1/verify", json={"install_id": INSTALL, "code": inst.verify_code})
    assert v.status_code == 200 and v.json()["status"] == "verified"

    # 3) send a template mail THROUGH THE BRIDGE (Brevo-shaped request)
    before = len(fake.SENT)
    s = shim.post("/v3/smtp/email", json=_brevo_payload(tag="E01"), headers={"api-key": token})
    assert s.status_code == 201, s.text          # Brevo-shaped success
    assert "messageId" in s.json()
    assert len(fake.SENT) == before + 1
    assert fake.SENT[-1]["to"] == ADMIN and fake.SENT[-1]["tag"] == "E01"

    # recipient not belonging to the install is rejected
    bad_rcpt = shim.post("/v3/smtp/email", json=_brevo_payload(to="stranger@notmine.org"), headers={"api-key": token})
    assert bad_rcpt.status_code == 403

    # 4) revoke (admin-only)
    rv = relay.post("/v1/revoke", json={"install_id": INSTALL}, headers={"x-admin-secret": "test-admin-secret"})
    assert rv.status_code == 200 and rv.json()["status"] == "revoked"

    # 5) send after revoke is rejected
    after = shim.post("/v3/smtp/email", json=_brevo_payload(), headers={"api-key": token})
    assert after.status_code == 403, after.text

    shim_module.set_test_transport(None)


def test_admin_requires_secret():
    relay = TestClient(relay_app)
    r = relay.post("/v1/revoke", json={"install_id": "whatever"}, headers={"x-admin-secret": "nope"})
    assert r.status_code == 401
    r2 = relay.get("/v1/admin/installs")
    assert r2.status_code == 401


def test_verify_link_get_works_from_email():
    """The verification email contains a GET link; clicking it must verify."""
    relay = TestClient(relay_app)
    r = relay.post("/v1/register", json={"admin_email": ADMIN, "install_id": "install-link-001", "version": "1.0.1"})
    assert r.status_code == 200
    inst = store.get_by_install_id("install-link-001")
    bad = relay.get("/v1/verify", params={"install_id": "install-link-001", "code": "wrong"})
    assert bad.status_code == 400 and "failed" in bad.text.lower()
    ok = relay.get("/v1/verify", params={"install_id": "install-link-001", "code": inst.verify_code})
    assert ok.status_code == 200 and "verified" in ok.text.lower()
    assert store.get_by_install_id("install-link-001").verified
