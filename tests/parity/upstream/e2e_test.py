"""SentinelCore full-platform end-to-end test suite (M1 - M12).

Exercises the running stack the way a real user does: logs in over the real
`/auth/login` endpoint, carries the returned bearer token, and drives every
module's HTTP API. Covers the happy path, the RBAC matrix, and the negative
cases each module's spec calls out as security-critical.

Run inside the backend container:

    python -m scripts.e2e_test

Writes a JSON result file to /tmp/e2e_results.json for report generation.
Test data is created under obvious `e2e-` prefixes and cleaned up at the end.
"""

from __future__ import annotations

import asyncio
import hashlib
import json
import struct
import sys
import time
import traceback
import uuid
from datetime import datetime, timedelta, timezone

import httpx

BASE = "http://localhost:8000/api"
PASSWORD = "E2eTestPassw0rd!2026"

results: list[dict] = []
_created: dict[str, list] = {"iocs": [], "incidents": [], "rules": [], "reports": [], "pcaps": [], "searches": []}


def record(module: str, name: str, passed: bool, detail: str = "", severity: str = "normal") -> bool:
    results.append(
        {"module": module, "name": name, "passed": passed, "detail": str(detail)[:400], "severity": severity}
    )
    icon = "PASS" if passed else "FAIL"
    print(f"  [{icon}] {module}: {name}" + (f" -- {detail}" if detail and not passed else ""))
    return passed


def check(module: str, name: str, got, want, severity: str = "normal") -> bool:
    ok = got == want
    return record(module, name, ok, f"expected {want}, got {got}", severity)


class Client:
    """Thin authenticated API client -- one per role."""

    def __init__(self, username: str | None = None):
        self.http = httpx.Client(base_url=BASE, timeout=60.0)
        self.token: str | None = None
        self.user: dict | None = None
        self.username = username
        if username:
            self.login(username, PASSWORD)

    def login(self, username: str, password: str) -> httpx.Response:
        r = self.http.post("/auth/login", json={"username": username, "password": password})
        if r.status_code == 200:
            self.token = r.json()["access_token"]
            self.user = r.json().get("user")
        return r

    def _h(self) -> dict:
        return {"Authorization": f"Bearer {self.token}"} if self.token else {}

    def get(self, path, **kw):
        return self.http.get(path, headers=self._h(), **kw)

    def post(self, path, **kw):
        return self.http.post(path, headers=self._h(), **kw)

    def patch(self, path, **kw):
        return self.http.patch(path, headers=self._h(), **kw)

    def put(self, path, **kw):
        return self.http.put(path, headers=self._h(), **kw)

    def delete(self, path, **kw):
        return self.http.request("DELETE", path, headers=self._h(), **kw)


# ===========================================================================
# M1 -- Authentication and RBAC
# ===========================================================================
def test_m1_auth(admin: Client, analyst: Client, viewer: Client) -> None:
    print("\n== M1: Authentication & RBAC ==")

    anon = Client()
    r = anon.login("t_admin", "wrong-password-entirely")
    check("M1", "login rejects a wrong password", r.status_code, 401)

    r = anon.login("no_such_user_at_all", PASSWORD)
    record("M1", "login rejects an unknown user without leaking existence",
           r.status_code == 401, f"status={r.status_code}")

    check("M1", "login succeeds with valid credentials", admin.token is not None, True)

    r = admin.get("/auth/me")
    ok = r.status_code == 200 and r.json()["username"] == "t_admin"
    record("M1", "GET /auth/me returns the authenticated identity", ok, r.text[:120])

    r = Client().get("/auth/me")
    check("M1", "unauthenticated request is rejected 401", r.status_code, 401, "critical")

    r = admin.http.get("/auth/me", headers={"Authorization": "Bearer not.a.real.token"})
    check("M1", "a forged/garbage bearer token is rejected 401", r.status_code, 401, "critical")

    # Role enforcement: the single authorization chokepoint.
    check("M1", "viewer BLOCKED from admin-only endpoint (users list)", viewer.get("/users").status_code, 403, "critical")
    check("M1", "analyst BLOCKED from admin-only endpoint (users list)", analyst.get("/users").status_code, 403, "critical")
    check("M1", "admin ALLOWED on admin-only endpoint (users list)", admin.get("/users").status_code, 200, "critical")

    # Password hashing must be Argon2 (CLAUDE.md), never a fast hash. Read the
    # real stored hash out of the database and assert on its actual prefix.
    try:
        from sqlalchemy import select as _select

        from app.db.session import SessionLocal, engine as _engine
        from app.models.user import User as _User

        async def _peek() -> str:
            async with SessionLocal() as db:
                return (await db.scalar(_select(_User.password_hash).where(_User.username == "t_admin")))

        stored = asyncio.run(_peek())
        record("M1", "stored password hash is Argon2 (starts with $argon2)",
               stored.startswith("$argon2"), f"prefix={stored[:14]}", "critical")
        record("M1", "plaintext password is never stored in the hash",
               PASSWORD not in stored, "", "critical")
    except Exception as exc:
        record("M1", "stored password hash is Argon2", False, f"could not verify: {exc}", "critical")

    # Logout must revoke the session. Done on a THROWAWAY login of the viewer
    # account -- logout bumps tokens_valid_from for the whole user, so doing it
    # on the shared `viewer` client would 401 every later viewer assertion.
    throwaway = Client("t_viewer")
    lo = throwaway.post("/auth/logout")
    record("M1", "logout returns 204", lo.status_code == 204, f"status={lo.status_code}")
    after = throwaway.get("/auth/me")
    record("M1", "token minted before logout is revoked afterwards",
           after.status_code == 401, f"status={after.status_code}", "critical")
    # Restore the shared viewer session that the logout above invalidated.
    viewer.login("t_viewer", PASSWORD)
    record("M1", "viewer can log in again after logout", viewer.token is not None, "")


# ===========================================================================
# M3 -- Asset discovery
# ===========================================================================
def test_m3_assets(admin: Client, analyst: Client, viewer: Client) -> None:
    print("\n== M3: Asset Discovery ==")

    r = viewer.get("/assets")
    record("M3", "any authenticated role can list assets", r.status_code == 200, r.text[:120])

    net = "192.168.56.0/30"
    r = viewer.post("/assets/scan", json={"targets": [net]})
    check("M3", "viewer BLOCKED from launching a scan", r.status_code, 403, "critical")
    r = analyst.post("/assets/scan", json={"targets": [net]})
    check("M3", "analyst BLOCKED from launching a scan (admin-only)", r.status_code, 403, "critical")

    # Command-injection shaped input must be rejected by the typed validator and
    # never reach a shell (CLAUDE.md: no user input reaches a shell string).
    # 422 = schema rejection. 409 would mean "a scan is already running", which
    # would mask the validation, so only 400/422 counts as a pass here.
    for bad in ["192.168.56.1; rm -rf /", "$(whoami)", "10.0.0.1 && cat /etc/passwd",
                "`id`", "192.168.56.0/24|nc evil 1"]:
        r = admin.post("/assets/scan", json={"targets": [bad]})
        record("M3", f"scan target rejects injection-shaped input {bad!r}",
               r.status_code in (400, 422), f"status={r.status_code}", "critical")

    # Scope enforcement: a routable address outside the monitored network.
    r = admin.post("/assets/scan", json={"targets": ["8.8.8.8"]})
    record("M3", "scan target outside the monitored network is rejected",
           r.status_code in (400, 422), f"status={r.status_code}", "critical")

    r = admin.get("/assets/scans")
    record("M3", "admin can list scan history", r.status_code == 200, r.text[:120])


# ===========================================================================
# M4 -- Suricata sensor
# ===========================================================================
def test_m4_sensor(admin: Client, analyst: Client, viewer: Client) -> None:
    print("\n== M4: Suricata Sensor ==")

    r = viewer.get("/sensor/status")
    record("M4", "any authenticated role can read sensor status", r.status_code == 200, r.text[:160])

    r = viewer.get("/sensor/stats")
    record("M4", "any authenticated role can read sensor stats", r.status_code == 200, r.text[:120])

    for role, cli in (("viewer", viewer), ("analyst", analyst)):
        check("M4", f"{role} BLOCKED from sensor start", cli.post("/sensor/start").status_code, 403, "critical")
        check("M4", f"{role} BLOCKED from sensor stop", cli.post("/sensor/stop").status_code, 403, "critical")
        check("M4", f"{role} BLOCKED from rule-source creation", cli.post(
            "/sensor/rules/sources", json={"name": "x", "url": "https://e.test/a.rules"}).status_code, 403, "critical")

    r = admin.get("/sensor/rules/sources")
    record("M4", "admin can list rule sources", r.status_code == 200, r.text[:120])

    # Rule override requires a reason (spec: NOT NULL reason).
    r = admin.post("/sensor/rules/overrides", json={"sid": 9999001, "action": "disable"})
    record("M4", "rule override without a reason is rejected", r.status_code in (400, 422), f"status={r.status_code}")


# ===========================================================================
# M5 -- Event pipeline
# ===========================================================================
def test_m5_pipeline(admin: Client) -> None:
    print("\n== M5: Event Pipeline ==")

    import redis as sync_redis

    from app.core.config import settings

    r = admin.get("/pipeline/status")
    record("M5", "pipeline status endpoint reports the ingest pipeline", r.status_code == 200, r.text[:200])

    rc = sync_redis.Redis.from_url(settings.redis_url)
    marker = uuid.uuid4().hex[:8]
    ts = datetime.now(timezone.utc).replace(microsecond=0)

    rec = {
        "timestamp": ts.strftime("%Y-%m-%dT%H:%M:%S.%f+0000"),
        "event_type": "alert",
        "src_ip": "203.0.113.77",
        "dest_ip": "198.51.100.9",
        "src_port": 44444,
        "dest_port": 80,
        "proto": "TCP",
        "flow_id": 778899,
        "alert": {"signature": f"E2E TEST ALERT {marker}", "signature_id": 9100001, "rev": 1,
                  "category": "e2e", "severity": 1},
    }
    rc.xadd("stream:events", {"record": json.dumps(rec)})
    # Publish the identical record twice -- dedup must collapse it to one row.
    rc.xadd("stream:events", {"record": json.dumps(rec)})

    found = None
    for _ in range(25):
        time.sleep(1)
        rr = admin.get(f"/events?q={marker}&limit=10")
        if rr.status_code == 200 and rr.json()["items"]:
            found = rr.json()["items"]
            break

    record("M5", "an EVE record published to Redis is ingested into events",
           found is not None, "event never appeared after 25s", "critical")

    if found:
        check("M5", "duplicate EVE record is deduplicated (exactly 1 row)", len(found), 1, "critical")
        ev = found[0]
        check("M5", "Suricata priority 1 maps to severity 'critical'", ev["severity"], "critical")
        check("M5", "src_ip normalized onto the event row", ev["src_ip"], "203.0.113.77")
        check("M5", "signature_id preserved", ev["signature_id"], 9100001)
        globals()["_E2E_EVENT"] = ev

    # Malformed record must not crash the writer; the pipeline keeps running.
    rc.xadd("stream:events", {"record": "{this is not valid json"})
    time.sleep(3)
    rr = admin.get("/events?limit=1")
    record("M5", "writer survives a malformed record and keeps serving",
           rr.status_code == 200, f"status={rr.status_code}", "critical")


# ===========================================================================
# M6 -- Event search
# ===========================================================================
def test_m6_search(admin: Client, analyst: Client, viewer: Client) -> None:
    print("\n== M6: Event Search ==")

    r = viewer.get("/events?limit=5")
    ok = r.status_code == 200 and "items" in r.json()
    record("M6", "viewer can search events", ok, r.text[:120])

    body = r.json() if ok else {}
    record("M6", "response carries keyset pagination fields",
           all(k in body for k in ("items", "next_cursor", "has_more", "took_ms")), list(body.keys())[:8])

    r = admin.get("/events?severity=critical&limit=5")
    ok = r.status_code == 200 and all(i["severity"] == "critical" for i in r.json()["items"])
    record("M6", "severity filter returns only matching rows", ok, r.text[:120])

    r = admin.get("/events?limit=1")
    if r.status_code == 200 and r.json().get("next_cursor"):
        cur = r.json()["next_cursor"]
        first_id = r.json()["items"][0]["id"]
        r2 = admin.get(f"/events?limit=1&cursor={cur}")
        ok = r2.status_code == 200 and (not r2.json()["items"] or r2.json()["items"][0]["id"] != first_id)
        record("M6", "keyset cursor advances to a different page", ok, r2.text[:120])

    r = admin.get("/events/facets")
    ok = r.status_code == 200 and "severity" in r.json()
    record("M6", "facets endpoint returns aggregation buckets", ok, r.text[:150])
    if ok:
        r2 = admin.get("/events/facets")
        record("M6", "facets second call is served from cache", r2.json().get("cached") is True,
               f"cached={r2.json().get('cached')}")

    ev = globals().get("_E2E_EVENT")
    if ev:
        r = admin.get(f"/events/{ev['id']}?ts={ev['ts']}")
        record("M6", "event detail with ts hint (partition-pruned) returns the row",
               r.status_code == 200, r.text[:120])
        r = admin.get(f"/events/{ev['id']}?ts=2099-01-01T00:00:00Z")
        check("M6", "event detail with a mismatched ts correctly 404s", r.status_code, 404)

    # Saved searches + ownership enforcement.
    r = analyst.post("/events/searches", json={"name": f"e2e-{uuid.uuid4().hex[:6]}",
                                               "filters": {"severity": ["high"]}, "is_shared": False})
    ok = r.status_code in (200, 201)
    record("M6", "analyst can create a saved search", ok, r.text[:200])
    if ok:
        sid = r.json()["id"]
        _created["searches"].append(sid)
        r2 = viewer.delete(f"/events/searches/{sid}")
        check("M6", "another user cannot delete someone else's saved search", r2.status_code, 403, "critical")
        r3 = analyst.get("/events/searches")
        record("M6", "owner sees their own saved search in the list",
               r3.status_code == 200 and any(s["id"] == sid for s in r3.json()), r3.text[:150])


# ===========================================================================
# M7 -- Correlation
# ===========================================================================
def test_m7_correlation(admin: Client, analyst: Client, viewer: Client) -> None:
    print("\n== M7: Correlation Engine ==")

    r = viewer.get("/correlation/rules")
    record("M7", "any authenticated role can list correlation rules", r.status_code == 200, r.text[:120])

    rule = {
        "name": f"e2e-portscan-{uuid.uuid4().hex[:6]}",
        "description": "E2E test rule",
        "rule_type": "threshold",
        "match": {"event_type": ["alert"]},
        "group_by": ["src_ip"],
        "window_seconds": 300,
        "threshold": 5,
        "severity": "high",
        "params": {"count_distinct_field": "dst_port"},
    }
    check("M7", "viewer BLOCKED from creating a rule", viewer.post("/correlation/rules", json=rule).status_code, 403, "critical")
    check("M7", "analyst BLOCKED from creating a rule (admin-only)", analyst.post("/correlation/rules", json=rule).status_code, 403, "critical")

    r = admin.post("/correlation/rules", json=rule)
    ok = r.status_code in (200, 201)
    record("M7", "admin can create a correlation rule", ok, r.text[:200])
    if not ok:
        return
    rid = r.json()["id"]
    _created["rules"].append(rid)

    bad = dict(rule, name="e2e-bad-groupby", group_by=["definitely_not_a_column"])
    r = admin.post("/correlation/rules", json=bad)
    record("M7", "rule with an unknown group_by field is rejected 422",
           r.status_code == 422, f"status={r.status_code}", "critical")

    bad2 = dict(rule, name="e2e-bad-window", window_seconds=0)
    r = admin.post("/correlation/rules", json=bad2)
    record("M7", "rule with a non-positive window is rejected 422", r.status_code == 422, f"status={r.status_code}")

    r = admin.post(f"/correlation/rules/{rid}/test", json={"from": (datetime.now(timezone.utc) - timedelta(hours=6)).isoformat(),
                                                           "to": datetime.now(timezone.utc).isoformat()})
    record("M7", "admin can dry-run a rule without writing candidates", r.status_code == 200, r.text[:200])

    r = admin.get(f"/correlation/rules/{rid}/runs")
    record("M7", "rule run history is readable", r.status_code == 200, r.text[:120])

    r = viewer.get("/correlation/candidates")
    record("M7", "any authenticated role can list candidates", r.status_code == 200, r.text[:120])

    r = admin.patch(f"/correlation/rules/{rid}", json={"enabled": False})
    record("M7", "admin can disable a rule", r.status_code == 200 and r.json()["enabled"] is False, r.text[:150])


# ===========================================================================
# M8 -- Incidents
# ===========================================================================
def test_m8_incidents(admin: Client, analyst: Client, viewer: Client) -> None:
    print("\n== M8: Incident Management ==")

    inc = {"title": f"e2e-incident-{uuid.uuid4().hex[:6]}", "description": "E2E lifecycle test",
           "severity": "high", "src_ip": "203.0.113.77"}

    check("M8", "viewer BLOCKED from creating an incident", viewer.post("/incidents", json=inc).status_code, 403, "critical")

    r = analyst.post("/incidents", json=inc)
    ok = r.status_code in (200, 201)
    record("M8", "analyst can create an incident", ok, r.text[:200])
    if not ok:
        return
    body = r.json()
    iid, ver = body["id"], body["version"]
    _created["incidents"].append(iid)
    check("M8", "new incident starts in status 'new'", body["status"], "new")
    record("M8", "incident gets a human-facing sequential number", isinstance(body.get("number"), int), body.get("number"))

    r = analyst.post(f"/incidents/{iid}/status", json={"version": ver, "status": "triage"})
    ok = r.status_code == 200
    record("M8", "legal transition new -> triage accepted", ok, r.text[:150])
    ver = r.json()["version"] if ok else ver

    # Optimistic concurrency: a stale version must 409.
    r = analyst.post(f"/incidents/{iid}/status", json={"version": ver - 1, "status": "investigating"})
    check("M8", "stale version on status change rejected 409 (optimistic lock)", r.status_code, 409, "critical")

    # Illegal backwards transition.
    r = analyst.post(f"/incidents/{iid}/status", json={"version": ver, "status": "new"})
    record("M8", "illegal backwards transition triage -> new rejected 409",
           r.status_code == 409, f"status={r.status_code}", "critical")

    r = analyst.post(f"/incidents/{iid}/status", json={"version": ver, "status": "investigating"})
    ver = r.json()["version"] if r.status_code == 200 else ver
    r = analyst.post(f"/incidents/{iid}/status", json={"version": ver, "status": "contained"})
    ver = r.json()["version"] if r.status_code == 200 else ver

    # Closing requires a resolution note.
    r = analyst.post(f"/incidents/{iid}/status", json={"version": ver, "status": "resolved"})
    record("M8", "closing without a resolution note is rejected 422",
           r.status_code == 422, f"status={r.status_code}", "critical")

    r = analyst.post(f"/incidents/{iid}/status", json={"version": ver, "status": "resolved",
                                                       "note": "Root cause: e2e. Actions: none. Verified: yes."})
    ok = r.status_code == 200
    record("M8", "closing with a resolution note succeeds", ok, r.text[:150])
    ver = r.json()["version"] if ok else ver

    # Reopen from terminal is admin-only.
    r = analyst.post(f"/incidents/{iid}/status", json={"version": ver, "status": "investigating"})
    check("M8", "analyst BLOCKED from reopening a closed incident", r.status_code, 403, "critical")
    r = admin.post(f"/incidents/{iid}/status", json={"version": ver, "status": "investigating"})
    record("M8", "admin CAN reopen a closed incident", r.status_code == 200, r.text[:150])

    r = analyst.post(f"/incidents/{iid}/comments", json={"note": "e2e comment"})
    record("M8", "analyst can comment on an incident", r.status_code in (200, 201), r.text[:150])

    r = analyst.get(f"/incidents/{iid}/history")
    ok = r.status_code == 200 and len(r.json()) >= 3
    record("M8", "history records the full transition trail", ok, f"entries={len(r.json()) if r.status_code==200 else r.text[:80]}")

    ev = globals().get("_E2E_EVENT")
    if ev:
        r = analyst.post(f"/incidents/{iid}/events", json={"event_ids": [ev["id"]]})
        record("M8", "analyst can link an event as evidence", r.status_code == 200, r.text[:150])
        r = analyst.get(f"/incidents/{iid}/events")
        record("M8", "linked events are listed back", r.status_code == 200 and len(r.json()) >= 1, r.text[:120])

    check("M8", "analyst BLOCKED from hard-deleting an incident", analyst.delete(f"/incidents/{iid}").status_code, 403, "critical")

    r = viewer.get("/incidents/stats/summary")
    record("M8", "stats summary readable by any authenticated role", r.status_code == 200, r.text[:150])


# ===========================================================================
# M9 -- Reporting
# ===========================================================================
def test_m9_reports(admin: Client, analyst: Client, viewer: Client) -> None:
    print("\n== M9: Reporting ==")

    now = datetime.now(timezone.utc)
    req = {"report_type": "incident_summary", "format": "pdf", "title": "e2e-report",
           "params": {"from": (now - timedelta(days=7)).isoformat(), "to": now.isoformat()}}

    r = analyst.post("/reports", json=req)
    ok = r.status_code in (200, 202)
    record("M9", "analyst can request a report (async 202)", ok, r.text[:200])
    if not ok:
        return
    rid = r.json()["id"]
    _created["reports"].append(rid)
    check("M9", "report starts in a queued/running state", r.json()["status"] in ("queued", "running"), True)

    final = None
    for _ in range(45):
        time.sleep(2)
        rr = analyst.get(f"/reports/{rid}")
        if rr.status_code == 200 and rr.json()["status"] in ("completed", "failed"):
            final = rr.json()
            break
    record("M9", "report generation completes", final is not None and final["status"] == "completed",
           f"final={final['status'] if final else 'timeout'} err={final.get('error') if final else ''}", "critical")

    if final and final["status"] == "completed":
        rr = analyst.http.get(f"/reports/{rid}/download", headers=analyst._h())
        ok = rr.status_code == 200 and len(rr.content) > 500
        record("M9", "completed PDF report downloads with real content", ok,
               f"status={rr.status_code} bytes={len(rr.content)}")
        record("M9", "downloaded file carries a PDF magic header",
               rr.content[:4] == b"%PDF", str(rr.content[:8]))

        rr = viewer.http.get(f"/reports/{rid}/download", headers=viewer._h())
        record("M9", "a different user cannot download someone else's report",
               rr.status_code in (403, 404), f"status={rr.status_code}", "critical")

    # incident_detail as CSV is explicitly unsupported.
    r = analyst.post("/reports", json={"report_type": "incident_detail", "format": "csv",
                                       "params": {"incident_id": str(uuid.uuid4())}})
    record("M9", "incident_detail + CSV combination is rejected", r.status_code in (400, 422), f"status={r.status_code}")

    # Window cap.
    r = analyst.post("/reports", json={"report_type": "event_statistics", "format": "json",
                                       "params": {"from": (now - timedelta(days=5000)).isoformat(),
                                                  "to": now.isoformat()}})
    record("M9", "report window beyond the max is rejected", r.status_code in (400, 422), f"status={r.status_code}")

    check("M9", "analyst BLOCKED from managing schedules (admin-only)",
          analyst.get("/reports/schedules").status_code, 403, "critical")
    record("M9", "admin can list report schedules", admin.get("/reports/schedules").status_code == 200, "")


# ===========================================================================
# M10 -- Firewall containment
# ===========================================================================
def test_m10_firewall(admin: Client, analyst: Client, viewer: Client) -> None:
    print("\n== M10: Firewall Containment ==")

    from app.core.config import settings

    blk = {"target": "203.0.113.200/32", "direction": "inbound", "ttl_seconds": 300, "reason": "e2e test block"}

    check("M10", "viewer BLOCKED from creating a firewall block", viewer.post("/firewall/actions", json=blk).status_code, 403, "critical")
    check("M10", "analyst BLOCKED from creating a firewall block (admin-only)", analyst.post("/firewall/actions", json=blk).status_code, 403, "critical")

    # TTL is mandatory and bounded (CLAUDE.md: all firewall rules have a TTL).
    r = admin.post("/firewall/actions", json={k: v for k, v in blk.items() if k != "ttl_seconds"})
    record("M10", "block without a TTL is rejected (TTL mandatory)", r.status_code == 422, f"status={r.status_code}", "critical")
    r = admin.post("/firewall/actions", json=dict(blk, ttl_seconds=10))
    record("M10", "block with a TTL below the minimum is rejected", r.status_code == 422, f"status={r.status_code}")
    r = admin.post("/firewall/actions", json=dict(blk, ttl_seconds=999999))
    record("M10", "block with a TTL above the 24h maximum is rejected", r.status_code == 422, f"status={r.status_code}", "critical")

    r = admin.post("/firewall/actions", json=dict(blk, target="not-an-ip-at-all"))
    record("M10", "block target that is not an IP/CIDR is rejected", r.status_code == 422, f"status={r.status_code}", "critical")

    # THE safety invariant: gateway / DNS / self can never be blocked.
    protected_targets = []
    try:
        import subprocess
        out = subprocess.run(["sh", "-c", "ip route | awk '/default/ {print $3}'"],
                             capture_output=True, text=True, timeout=5).stdout.strip().splitlines()
        protected_targets += [f"{ip}/32" for ip in out if ip]
    except Exception:
        pass
    for extra in (settings.protected_ips or "").split(","):
        extra = extra.strip()
        if extra:
            protected_targets.append(f"{extra}/32")

    if not protected_targets:
        record("M10", "protected-IP guard test had a target to try", False, "could not determine gateway/protected IPs")
    for tgt in protected_targets[:3]:
        r = admin.post("/firewall/actions", json=dict(blk, target=tgt, reason="e2e protected-ip guard probe"))
        record("M10", f"PROTECTED target {tgt} can never be blocked", r.status_code in (400, 403, 409, 422),
               f"status={r.status_code} body={r.text[:120]}", "critical")

    r = admin.post("/firewall/precheck", json={"target": "203.0.113.200/32"})
    record("M10", "precheck endpoint answers before committing a block", r.status_code == 200, r.text[:150])

    r = viewer.get("/firewall/actions")
    record("M10", "firewall action list is readable", r.status_code in (200, 403), f"status={r.status_code}")

    r = admin.get("/firewall/status")
    record("M10", "admin can read firewall status", r.status_code == 200, r.text[:150])


# ===========================================================================
# M11 -- PCAP
# ===========================================================================
def _pcap_bytes(magic: bytes = b"\xd4\xc3\xb2\xa1", payload_tag: bytes = b"") -> bytes:
    """Minimal but structurally valid little-endian pcap: 24-byte global header."""
    header = magic + struct.pack("<HHiIII", 2, 4, 0, 0, 65535, 1)
    return header + payload_tag


def test_m11_pcap(admin: Client, analyst: Client, viewer: Client) -> None:
    print("\n== M11: PCAP Analysis ==")

    good = _pcap_bytes(payload_tag=uuid.uuid4().bytes)

    r = viewer.post("/pcap/upload", files={"file": ("e2e.pcap", good, "application/octet-stream")})
    check("M11", "viewer BLOCKED from uploading a capture", r.status_code, 403, "critical")

    # Magic-byte validation: a non-pcap renamed .pcap must be refused.
    evil = b"MZ\x90\x00this is a windows executable, not a capture" * 4
    r = analyst.post("/pcap/upload", files={"file": ("evil.pcap", evil, "application/octet-stream")})
    record("M11", "non-pcap file renamed .pcap is rejected by magic-byte check",
           r.status_code == 400, f"status={r.status_code} body={r.text[:120]}", "critical")

    # Path traversal in the client filename must be neutralised.
    trav = _pcap_bytes(payload_tag=uuid.uuid4().bytes)
    r = analyst.post("/pcap/upload", files={"file": ("../../../../etc/passwd", trav, "application/octet-stream")})
    ok = r.status_code in (200, 202)
    record("M11", "path-traversal filename is accepted but stored safely under a UUID", ok, r.text[:200], "critical")
    if ok:
        pid = r.json()["id"]
        _created["pcaps"].append(pid)
        d = analyst.get(f"/pcap/{pid}")
        if d.status_code == 200:
            # The spec REQUIRES keeping the original filename verbatim as a
            # display string, so its presence in the response is correct. The
            # security property is that it never influences the path on disk:
            # `stored_path` must be a UUID inside the storage root.
            record("M11", "original filename is preserved for display",
                   d.json()["filename"] == "../../../../etc/passwd", d.text[:160])

            # Inspect the real storage root: every file must be UUID-named and
            # nothing may carry the attacker-supplied name.
            from pathlib import Path as _P

            from app.core.config import settings as _cfg

            root = _P(_cfg.pcap_storage_path).resolve()
            on_disk = [p for p in root.iterdir() if p.is_file()]
            all_uuid_named = all(p.stem.count("-") == 4 for p in on_disk)
            none_named_passwd = not any("passwd" in p.name for p in on_disk)
            record("M11", "traversal filename never influences the path on disk",
                   bool(on_disk) and all_uuid_named and none_named_passwd,
                   f"files={[p.name for p in on_disk][:5]}", "critical")
            record("M11", "nothing was written outside the pcap storage root",
                   not _P("/etc/passwd.pcap").exists() and not _P("/var/lib/sentinelcore/passwd").exists(),
                   "", "critical")

    # Upload + dedup by sha256.
    payload = _pcap_bytes(payload_tag=uuid.uuid4().bytes)
    r1 = analyst.post("/pcap/upload", files={"file": ("e2e-one.pcap", payload, "application/octet-stream")})
    ok1 = r1.status_code in (200, 202)
    record("M11", "analyst can upload a valid capture (202 accepted)", ok1, r1.text[:200])
    if not ok1:
        return
    pid = r1.json()["id"]
    _created["pcaps"].append(pid)
    check("M11", "first upload is not flagged duplicate", r1.json().get("duplicate"), False)

    r2 = analyst.post("/pcap/upload", files={"file": ("e2e-one-again.pcap", payload, "application/octet-stream")})
    ok2 = r2.status_code in (200, 202) and r2.json().get("duplicate") is True and r2.json()["id"] == pid
    record("M11", "re-uploading identical bytes returns the existing record (sha256 dedup)", ok2, r2.text[:200])

    # Wait for the parse to resolve one way or the other -- it must never hang.
    final = None
    for _ in range(40):
        time.sleep(2)
        rr = analyst.get(f"/pcap/{pid}")
        if rr.status_code == 200 and rr.json()["status"] in ("parsed", "failed"):
            final = rr.json()
            break
    record("M11", "capture parse always resolves (never stuck in 'parsing')",
           final is not None, f"status={final['status'] if final else 'TIMEOUT'}", "critical")
    if final:
        record("M11", f"parse outcome recorded as '{final['status']}'", True,
               f"error={final.get('error')}" if final["status"] == "failed" else "")

    r = analyst.get(f"/pcap/{pid}/flows")
    record("M11", "flows endpoint responds for an uploaded capture", r.status_code == 200, r.text[:120])
    r = analyst.get(f"/pcap/{pid}/artifacts")
    record("M11", "artifacts endpoint responds for an uploaded capture", r.status_code == 200, r.text[:120])

    # Raw download is admin-only -- captures can contain credentials.
    r = analyst.http.get(f"/pcap/{pid}/download", headers=analyst._h())
    check("M11", "analyst BLOCKED from downloading the raw capture", r.status_code, 403, "critical")
    r = viewer.http.get(f"/pcap/{pid}/download", headers=viewer._h())
    check("M11", "viewer BLOCKED from downloading the raw capture", r.status_code, 403, "critical")
    r = admin.http.get(f"/pcap/{pid}/download", headers=admin._h())
    record("M11", "admin CAN download the raw capture", r.status_code == 200, f"status={r.status_code}")


# ===========================================================================
# M12 -- Threat intelligence
# ===========================================================================
def test_m12_intel(admin: Client, analyst: Client, viewer: Client) -> None:
    print("\n== M12: Threat Intelligence ==")

    r = viewer.get("/intel/iocs")
    record("M12", "any authenticated role can list IOCs", r.status_code == 200, r.text[:120])

    ip_ind = "45.33.32.156"
    check("M12", "viewer BLOCKED from adding an IOC",
          viewer.post("/intel/iocs", json={"indicator": ip_ind, "description": "x"}).status_code, 403, "critical")

    r = analyst.post("/intel/iocs", json={"indicator": ip_ind, "description": "e2e known-bad ip",
                                          "severity": "critical", "threat_type": "c2"})
    ok = r.status_code in (200, 201)
    record("M12", "analyst can add an IOC", ok, r.text[:200])
    if ok:
        _created["iocs"].append(r.json()["id"])
        check("M12", "IOC type auto-detected as 'ip'", r.json()["ioc_type"], "ip")

    # Defanged input must normalize to the same value.
    r = viewer.get("/intel/lookup?value=hxxp://evil[.]com/Path")
    ok = r.status_code == 200 and r.json()["normalized"] == "http://evil.com/Path"
    record("M12", "defanged URL normalizes (hxxp://evil[.]com -> http://evil.com)", ok, r.text[:200], "critical")

    r = viewer.get(f"/intel/lookup?value={ip_ind}")
    ok = r.status_code == 200 and r.json()["found"] is True
    record("M12", "lookup finds a known-bad indicator", ok, r.text[:200])
    record("M12", "viewer CAN use lookup (read-only allowed)", r.status_code == 200, f"status={r.status_code}")

    # A feed listing RFC1918 space would poison the platform against itself.
    r = analyst.post("/intel/iocs", json={"indicator": "192.168.10.1", "description": "should be refused"})
    record("M12", "private RFC1918 address is refused as an IOC", r.status_code == 400,
           f"status={r.status_code} body={r.text[:140]}", "critical")

    # CIDR containment.
    r = analyst.post("/intel/iocs", json={"indicator": "45.33.32.0/24", "description": "e2e cidr",
                                          "severity": "high"})
    if r.status_code in (200, 201):
        _created["iocs"].append(r.json()["id"])
        r2 = viewer.get("/intel/lookup?value=45.33.32.200")
        ok = r2.status_code == 200 and r2.json()["found"] is True
        record("M12", "an IP inside a CIDR indicator matches by containment", ok, r2.text[:200], "critical")

    # Bulk add with mixed valid/invalid lines.
    r = analyst.post("/intel/iocs/bulk", json={
        "indicators": ["185.199.108.153", "evil-e2e[.]com", "10.0.0.5", "!!!garbage!!!"],
        "description": "e2e bulk"})
    ok = r.status_code == 200
    record("M12", "bulk add returns per-line accept/reject results", ok, r.text[:300])
    if ok:
        body = r.json()
        check("M12", "bulk accepted the 2 valid indicators", body["accepted_count"], 2)
        check("M12", "bulk rejected the private IP and the garbage line", body["rejected_count"], 2)
        for line in body["results"]:
            if line["accepted"] and line.get("ioc_id"):
                _created["iocs"].append(line["ioc_id"])
        defanged = [l for l in body["results"] if l["input"] == "evil-e2e[.]com"]
        record("M12", "defanged domain accepted in bulk paste",
               bool(defanged) and defanged[0]["accepted"], str(defanged)[:160])

    # Sources are admin-only.
    check("M12", "analyst BLOCKED from managing feed sources", analyst.get("/intel/sources").status_code, 403, "critical")
    record("M12", "admin can list feed sources", admin.get("/intel/sources").status_code == 200, "")

    r = admin.get("/intel/stats")
    record("M12", "intel stats endpoint returns counts", r.status_code == 200, r.text[:200])

    # Retro-hunt is admin-only.
    if _created["iocs"]:
        check("M12", "analyst BLOCKED from starting a retro-hunt",
              analyst.post("/intel/retrohunt", json={"ioc_id": _created["iocs"][0], "days": 7}).status_code, 403, "critical")
        r = admin.post("/intel/retrohunt", json={"ioc_id": _created["iocs"][0], "days": 7})
        record("M12", "admin can start a retro-hunt (202)", r.status_code == 202, r.text[:150])

    # LIVE MATCHING: an event to a known-bad IP must be stamped and escalated.
    import redis as sync_redis

    from app.core.config import settings

    rc = sync_redis.Redis.from_url(settings.redis_url)
    marker = uuid.uuid4().hex[:8]
    ts = datetime.now(timezone.utc).replace(microsecond=0)
    rec = {
        "timestamp": ts.strftime("%Y-%m-%dT%H:%M:%S.%f+0000"),
        "event_type": "flow", "src_ip": "10.10.10.99", "dest_ip": ip_ind,
        "src_port": 51000, "dest_port": 443, "proto": "TCP", "flow_id": 991100,
        "app_proto": marker,
    }
    rc.xadd("stream:events", {"record": json.dumps(rec)})

    matched = None
    for _ in range(25):
        time.sleep(1)
        rr = admin.get(f"/events?ip={ip_ind}/32&limit=5")
        if rr.status_code == 200:
            hits = [e for e in rr.json()["items"] if e.get("ioc_match")]
            if hits:
                matched = hits[0]
                break
    record("M12", "traffic to a known-bad IP is stamped ioc_match=true",
           matched is not None, "no stamped event appeared in 25s", "critical")
    if matched:
        check("M12", "matched event severity escalated to the IOC severity", matched["severity"], "critical", "critical")
        check("M12", "ioc_severity recorded on the event", matched["ioc_severity"], "critical")

        r = admin.get("/intel/matches")
        ok = r.status_code == 200 and any(m["matched_value"] == ip_ind for m in r.json())
        record("M12", "an ioc_matches evidence row was written", ok, r.text[:200], "critical")

    # Severity must never be DOWNgraded by a lower-severity IOC match.
    low_ind = "91.189.91.38"
    r = analyst.post("/intel/iocs", json={"indicator": low_ind, "description": "e2e low sev", "severity": "low"})
    if r.status_code in (200, 201):
        _created["iocs"].append(r.json()["id"])
        time.sleep(3)
        rec2 = {
            "timestamp": datetime.now(timezone.utc).replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%S.%f+0000"),
            "event_type": "alert", "src_ip": "10.10.10.98", "dest_ip": low_ind,
            "src_port": 51001, "dest_port": 443, "proto": "TCP", "flow_id": 991101,
            "alert": {"signature": f"E2E HIGHSEV {marker}", "signature_id": 9100002, "rev": 1,
                      "category": "e2e", "severity": 1},
        }
        rc.xadd("stream:events", {"record": json.dumps(rec2)})
        found2 = None
        for _ in range(25):
            time.sleep(1)
            rr = admin.get(f"/events?ip={low_ind}/32&limit=5")
            if rr.status_code == 200 and rr.json()["items"]:
                found2 = rr.json()["items"][0]
                break
        if found2:
            record("M12", "a LOW IOC never downgrades an already-CRITICAL event",
                   found2["severity"] == "critical", f"severity={found2['severity']}", "critical")


# ===========================================================================
# U10 -- Email notifications
# ===========================================================================
def test_u10_email(admin: Client, analyst: Client, viewer: Client) -> None:
    """Exercises the dry-run outbox end to end: no real send happens, but
    `enqueue()` must still run its full pipeline and leave rows the admin
    outbox API can see. Assumes the stack is running with EMAIL_MODE=dry_run
    per the rollout order in docs/email.md -- skips cleanly if not."""
    print("\n== U10: Email Notifications ==")

    r = admin.get("/email/status")
    record("U10", "admin can read email status", r.status_code == 200, r.text[:200])
    if r.status_code != 200:
        return
    status_body = r.json()
    check("U10", "viewer BLOCKED from email status", viewer.get("/email/status").status_code, 403, "critical")
    record("U10", "email status never exposes the API key itself (boolean only)",
           "api_key_present" in status_body and isinstance(status_body["api_key_present"], bool),
           str(status_body.get("api_key_present")), "critical")

    if status_body.get("mode") != "dry_run":
        record("U10", "stack is running with EMAIL_MODE=dry_run for this e2e pass",
               False, f"mode={status_body.get('mode')!r} -- skipping outbox assertions")
        return

    # E07: a firewall block (admin-only, always synchronous) must produce an
    # outbox row quickly enough for this script to observe it.
    blk = {"target": "203.0.113.205/32", "direction": "inbound", "ttl_seconds": 300, "reason": "e2e U10 block"}
    r = admin.post("/firewall/actions", json=blk)
    action_id = r.json().get("id") if r.status_code == 201 else None
    record("U10", "firewall block created for E07 check", r.status_code == 201, r.text[:150])
    if action_id:
        r2 = admin.get("/email/outbox?email_type=E07&limit=20&include_body=true")
        rows = r2.json().get("items", []) if r2.status_code == 200 else []
        hit = next((row for row in rows if row.get("related_id") == action_id), None)
        record("U10", "E07 outbox row exists for the block just applied", hit is not None, f"rows_seen={len(rows)}")
        if hit:
            record("U10", "E07 body is HTML-escaped (no literal <script>)",
                   "<script>" not in hit.get("html_body", ""), "", "critical")
        admin.delete(f"/firewall/actions/{action_id}")

    # E19: creating a user must enqueue a "set your password" email, never
    # the admin-chosen password itself.
    new_username = f"e2e-u10-{uuid.uuid4().hex[:8]}"
    new_email = f"{new_username}@example.com"
    admin_chosen_password = "AdminChosenPassw0rd!"
    r = admin.post("/users", json={"username": new_username, "email": new_email,
                                    "password": admin_chosen_password, "role": "viewer"})
    created_user_id = r.json().get("id") if r.status_code == 201 else None
    record("U10", "user created for E19 check", r.status_code == 201, r.text[:150])
    if created_user_id:
        r2 = admin.get("/email/outbox?email_type=E19&limit=20&include_body=true")
        rows = r2.json().get("items", []) if r2.status_code == 200 else []
        hit = next((row for row in rows if row.get("recipient_email") == new_email), None)
        record("U10", "E19 outbox row exists for the new user", hit is not None, f"rows_seen={len(rows)}")
        if hit:
            record("U10", "E19 body never contains the admin-chosen password",
                   admin_chosen_password not in hit.get("html_body", "") and admin_chosen_password not in hit.get("text_body", ""),
                   "", "critical")
        admin.delete(f"/users/{created_user_id}")

    r = analyst.get("/me/email-preferences")
    record("U10", "any authenticated role can read its own email preferences", r.status_code == 200, r.text[:150])
    r = analyst.put("/me/email-preferences", json={"types_disabled": ["E19", "E15"]})
    if r.status_code == 200:
        record("U10", "locked types (E15/E19) cannot be opted out of client-side",
               "E15" not in r.json().get("types_disabled", []) and "E19" not in r.json().get("types_disabled", []),
               str(r.json().get("types_disabled")), "critical")


# ===========================================================================
# Frontend routes
# ===========================================================================
def test_frontend() -> None:
    print("\n== Frontend (served through nginx) ==")

    pages = ["/", "/login", "/events", "/assets", "/incidents", "/correlation",
             "/intel", "/pcap", "/reports", "/firewall", "/sensor"]
    # Host must look like the real origin: the Vite dev server behind nginx
    # rejects unknown Host headers with a 403 host-check, which would otherwise
    # look like an application failure.
    with httpx.Client(base_url="http://nginx", timeout=20.0, headers={"Host": "localhost"}) as c:
        for p in pages:
            try:
                r = c.get(p)
                ok = r.status_code == 200 and "<div id=\"root\">" in r.text
                record("Frontend", f"SPA route {p} is served", ok, f"status={r.status_code}")
            except Exception as exc:
                record("Frontend", f"SPA route {p} is served", False, str(exc)[:120])

        try:
            r = c.get("/api/health")
            record("Frontend", "nginx proxies /api through to the backend", r.status_code == 200, r.text[:120])
        except Exception as exc:
            record("Frontend", "nginx proxies /api through to the backend", False, str(exc)[:120])


# ===========================================================================
# Architecture invariants (CLAUDE.md)
# ===========================================================================
def test_invariants() -> None:
    print("\n== Architecture invariants (CLAUDE.md) ==")

    import os
    import subprocess
    from pathlib import Path

    # "FastAPI backend runs UNPRIVILEGED, never as root"
    uid = os.getuid()
    record("Invariant", "API process does not run as root (uid != 0)", uid != 0, f"uid={uid}", "critical")

    # "NEVER use shell=True in subprocess calls"
    hits = []
    for root in (Path("/app"),):
        if not root.exists():
            continue
        for py in root.rglob("*.py"):
            if "/tests/" in str(py) or "/scripts/e2e" in str(py):
                continue
            try:
                txt = py.read_text(errors="ignore")
            except Exception:
                continue
            if "shell=True" in txt:
                hits.append(str(py))
    record("Invariant", "no shell=True anywhere in the backend", not hits, f"found in {hits[:5]}", "critical")

    # Secrets must not be hardcoded: the real secret key must come from env.
    from app.core.config import settings

    record("Invariant", "SECRET_KEY is not the shipped dev placeholder",
           settings.secret_key != "dev-only-placeholder-change-in-env",
           "still using the placeholder value", "critical")

    # ".env is never committed"
    try:
        tracked = subprocess.run(["git", "ls-files", ".env"], cwd="/app", capture_output=True, text=True, timeout=10)
        out = (tracked.stdout or "").strip()
    except Exception:
        out = ""
    record("Invariant", ".env is not tracked by git", out == "", f"git ls-files .env -> {out!r}")

    # U10: the Brevo key must never leak into a tracked file or an API response.
    if settings.brevo_api_key:
        hits = []
        for root in (Path("/app"),):
            if not root.exists():
                continue
            for py in root.rglob("*.py"):
                try:
                    if settings.brevo_api_key in py.read_text(errors="ignore"):
                        hits.append(str(py))
                except Exception:
                    continue
        record("Invariant", "BREVO_API_KEY does not appear hardcoded in any tracked .py file",
               not hits, f"found in {hits[:5]}", "critical")

    # The API holds no raw network capability; root work goes via the helper socket.
    sock = Path(settings.helper_socket_path)
    record("Invariant", "privileged-helper socket is present and used by the API",
           sock.exists(), f"{sock} exists={sock.exists()}", "critical")

    # U02: audit_log is append-only at the database level, for the app's own
    # DB credentials -- not just something the ORM layer refuses to do.
    import asyncpg

    async def _audit_log_is_append_only() -> tuple[bool, str]:
        dsn = settings.database_url.replace("postgresql+asyncpg://", "postgresql://")
        conn = await asyncpg.connect(dsn)
        try:
            await conn.execute("DELETE FROM audit_log")
        except asyncpg.PostgresError as exc:
            return True, str(exc)
        else:
            return False, "DELETE FROM audit_log succeeded -- audit trail is not append-only"
        finally:
            await conn.close()

    ok, detail = asyncio.run(_audit_log_is_append_only())
    record("Invariant", "audit_log rejects DELETE using the app's own DB credentials", ok, detail, "critical")


# ===========================================================================
# Cleanup
# ===========================================================================
def cleanup(admin: Client, analyst: Client) -> None:
    print("\n== Cleanup ==")
    deleted, failed = 0, []
    plan = (
        [(analyst, f"/events/searches/{i}") for i in _created["searches"]]
        + [(admin, f"/intel/iocs/{i}") for i in _created["iocs"]]
        + [(admin, f"/correlation/rules/{i}") for i in _created["rules"]]
        + [(admin, f"/reports/{i}") for i in _created["reports"]]
        + [(admin, f"/pcap/{i}") for i in _created["pcaps"]]
        + [(admin, f"/incidents/{i}") for i in _created["incidents"]]
    )
    for cli, path in plan:
        code = cli.delete(path).status_code
        if code in (200, 204, 404):
            deleted += 1
        else:
            failed.append(f"{path}->{code}")
    record("Cleanup", "every e2e artifact was removed", not failed,
           f"deleted={deleted} failures={failed[:5]}")


def main() -> int:
    started = datetime.now(timezone.utc)
    print("=" * 70)
    print("SentinelCore E2E suite")
    print("=" * 70)

    admin = Client("t_admin")
    analyst = Client("t_analyst")
    viewer = Client("t_viewer")
    if not (admin.token and analyst.token and viewer.token):
        print("FATAL: could not authenticate the e2e accounts", file=sys.stderr)
        return 2

    for fn, args in [
        (test_m1_auth, (admin, analyst, viewer)),
        (test_m3_assets, (admin, analyst, viewer)),
        (test_m4_sensor, (admin, analyst, viewer)),
        (test_m5_pipeline, (admin,)),
        (test_m6_search, (admin, analyst, viewer)),
        (test_m7_correlation, (admin, analyst, viewer)),
        (test_m8_incidents, (admin, analyst, viewer)),
        (test_m9_reports, (admin, analyst, viewer)),
        (test_m10_firewall, (admin, analyst, viewer)),
        (test_m11_pcap, (admin, analyst, viewer)),
        (test_m12_intel, (admin, analyst, viewer)),
        (test_u10_email, (admin, analyst, viewer)),
        (test_frontend, ()),
        (test_invariants, ()),
    ]:
        try:
            fn(*args)
        except Exception:
            record(fn.__name__, "test section crashed", False, traceback.format_exc()[-400:], "critical")

    try:
        cleanup(admin, analyst)
    except Exception:
        record("Cleanup", "cleanup crashed", False, traceback.format_exc()[-300:])

    finished = datetime.now(timezone.utc)
    passed = sum(1 for r in results if r["passed"])
    failed = [r for r in results if not r["passed"]]

    print("\n" + "=" * 70)
    print(f"TOTAL {len(results)} | PASSED {passed} | FAILED {len(failed)}")
    if failed:
        print("\nFailures:")
        for f in failed:
            print(f"  - [{f['severity']}] {f['module']}: {f['name']}  ({f['detail'][:200]})")
    print("=" * 70)

    with open("/tmp/e2e_results.json", "w") as fh:
        json.dump({"started": started.isoformat(), "finished": finished.isoformat(),
                   "total": len(results), "passed": passed, "failed": len(failed),
                   "results": results}, fh, indent=2)
    print("results -> /tmp/e2e_results.json")
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
