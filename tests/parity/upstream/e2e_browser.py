"""Real-browser UI test: drives the SPA in headless Chromium like a user.

The API suite proves the backend is correct; it cannot prove a page renders.
A React component that throws at runtime, a bad import, or a crashed render
still returns HTTP 200 for the HTML shell. This drives the real UI:

  * logs in through the actual form
  * visits every route and asserts real content rendered
  * fails on any uncaught JS exception or console error
  * captures a screenshot of every page as evidence

Run on the HOST (needs the Playwright browser):

    /tmp/scvenv/bin/python backend/scripts/e2e_browser.py

Writes /tmp/e2e_browser.json and screenshots to /tmp/e2e_shots/.
"""

from __future__ import annotations

import json
import os
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

from playwright.sync_api import sync_playwright

BASE = os.environ.get("E2E_BASE_URL", "http://localhost")
USER = os.environ.get("E2E_USER", "t_admin")
PASSWORD = os.environ.get("E2E_PASSWORD", "E2eTestPassw0rd!2026")
SHOTS = Path("/tmp/e2e_shots")

results: list[dict] = []


def record(name: str, passed: bool, detail: str = "", severity: str = "normal") -> bool:
    results.append({"module": "UI", "name": name, "passed": passed, "detail": str(detail)[:400],
                    "severity": severity})
    print(f"  [{'PASS' if passed else 'FAIL'}] UI: {name}" + (f" -- {detail}" if detail and not passed else ""))
    return passed


# Noise that is not an application defect.
_IGNORE = ("favicon", "manifest.json", "Download the React DevTools",
           "[vite] connected", "[vite] connecting")


def main() -> int:
    SHOTS.mkdir(parents=True, exist_ok=True)
    started = datetime.now(timezone.utc)

    # Every route a user can reach, with a selector proving real content rendered
    # (not just an empty shell or an error boundary).
    routes = [
        ("/", "Overview"),
        ("/events", "Events"),
        ("/assets", "Assets"),
        ("/incidents", "Incidents"),
        ("/correlation", "Correlation"),
        ("/intel", "Threat Intel"),
        ("/pcap", "PCAP"),
        ("/reports", "Reports"),
        ("/firewall", "Firewall"),
        ("/sensor", "Sensor"),
        ("/admin/users", "Users"),
    ]

    with sync_playwright() as pw:
        browser = pw.chromium.launch()
        ctx = browser.new_context(viewport={"width": 1600, "height": 1000})
        page = ctx.new_page()

        errors: list[str] = []
        page.on("pageerror", lambda e: errors.append(f"PAGEERROR: {e}"))
        page.on("console", lambda m: errors.append(f"CONSOLE.{m.type}: {m.text}")
                if m.type == "error" and not any(s in m.text for s in _IGNORE) else None)

        # ---- Login ----------------------------------------------------
        try:
            page.goto(f"{BASE}/login", wait_until="networkidle", timeout=30000)
            page.screenshot(path=str(SHOTS / "00-login.png"))
            record("login page renders a form", page.locator("input").count() >= 2,
                   f"inputs={page.locator('input').count()}")

            page.fill("input[name='username'], input[type='text']", USER)
            page.fill("input[type='password']", PASSWORD)
            errors.clear()
            page.click("button[type='submit']")
            page.wait_for_url(lambda u: "/login" not in u, timeout=20000)
            record("login with valid credentials redirects into the app", True,
                   f"landed on {page.url}", "critical")
        except Exception as exc:
            record("login with valid credentials redirects into the app", False, str(exc)[:300], "critical")
            page.screenshot(path=str(SHOTS / "00-login-FAILED.png"))
            browser.close()
            _dump(started)
            return 1

        # Sidebar proves the authenticated shell mounted.
        try:
            page.wait_for_selector("nav, aside", timeout=10000)
            record("authenticated app shell (nav sidebar) renders", True)
        except Exception as exc:
            record("authenticated app shell (nav sidebar) renders", False, str(exc)[:200], "critical")

        # ---- Every route ----------------------------------------------
        for path, expect_text in routes:
            errors.clear()
            slug = path.strip("/").replace("/", "-") or "overview"
            try:
                # 'domcontentloaded', not 'networkidle': the Vite HMR socket and
                # the events page's polling mean the network never goes idle.
                page.goto(f"{BASE}{path}", wait_until="domcontentloaded", timeout=30000)
                page.wait_for_selector("h1, table, nav", timeout=20000)
                page.wait_for_timeout(1500)  # let async data settle
                page.screenshot(path=str(SHOTS / f"{slug}.png"), full_page=True)

                body = page.inner_text("body")

                # A route still showing the M2 scaffold is an unfinished module.
                is_placeholder = "Coming in M" in body or "milestone" in body.lower()
                record(f"{path} is NOT an unimplemented placeholder", not is_placeholder,
                       "page still renders the M2 Placeholder scaffold", "critical")

                record(f"{path} renders its real heading ({expect_text!r})",
                       expect_text.lower() in body.lower(), f"body starts: {body[:120]!r}", "critical")

                # React error boundary / crash text.
                crashed = any(s in body for s in ("Something went wrong", "Unexpected Application Error",
                                                  "ChunkLoadError", "is not defined", "Cannot read properties"))
                record(f"{path} did not hit an error boundary", not crashed, body[:200], "critical")

                real_errors = [e for e in errors if not any(s in e for s in _IGNORE)]
                record(f"{path} raised no uncaught JS errors", not real_errors,
                       "; ".join(real_errors[:3])[:300], "critical")
            except Exception as exc:
                record(f"{path} loads without crashing", False, str(exc)[:300], "critical")
                try:
                    page.screenshot(path=str(SHOTS / f"{slug}-FAILED.png"))
                except Exception:
                    pass

        # ---- A real interaction: open an event detail drawer -----------
        try:
            errors.clear()
            # Widen the window: the default view is 24h and the seeded events
            # can be older, which would leave the table legitimately empty and
            # make this interaction untestable rather than failing.
            # 'Z' suffix, not isoformat()'s '+00:00': a raw '+' in a query
            # string decodes to a space and the API rejects it with 422.
            since = (datetime.now(timezone.utc) - timedelta(days=29)).strftime("%Y-%m-%dT%H:%M:%SZ")
            page.goto(f"{BASE}/events?from={since}", wait_until="domcontentloaded", timeout=30000)
            # Skeleton rows carry animate-pulse; wait for a REAL data row.
            page.wait_for_selector("table tbody tr:not(.animate-pulse)", timeout=25000)
            page.wait_for_timeout(800)
            rows = page.locator("table tbody tr:not(.animate-pulse)")
            if rows.count() > 0:
                rows.first.click()
                page.wait_for_timeout(1500)
                drawer = page.locator("[role='dialog']")
                record("clicking an event row opens the detail drawer", drawer.count() > 0,
                       f"dialogs={drawer.count()}")
                page.screenshot(path=str(SHOTS / "events-detail-drawer.png"))
                real_errors = [e for e in errors if not any(s in e for s in _IGNORE)]
                record("event detail drawer raised no JS errors", not real_errors,
                       "; ".join(real_errors[:3])[:300], "critical")
            else:
                record("events table had rows to click", False, "no rows rendered (no data?)")
        except Exception as exc:
            record("clicking an event row opens the detail drawer", False, str(exc)[:300])

        # ---- A real interaction: the M12 intel lookup bar --------------
        try:
            errors.clear()
            page.goto(f"{BASE}/intel", wait_until="networkidle", timeout=30000)
            page.wait_for_timeout(1200)
            box = page.locator("input[placeholder*='indicator' i]")
            if box.count() > 0:
                box.first.fill("hxxp://evil[.]com")
                page.keyboard.press("Enter")
                page.wait_for_timeout(2500)
                body = page.inner_text("body")
                record("intel lookup bar returns a verdict for a defanged indicator",
                       "evil.com" in body, f"body: {body[:200]!r}", "critical")
                page.screenshot(path=str(SHOTS / "intel-lookup-result.png"))
            else:
                record("intel lookup bar is present on /intel", False, "no lookup input found", "critical")
        except Exception as exc:
            record("intel lookup bar returns a verdict", False, str(exc)[:300])

        # ---- RBAC in the UI: viewer must not see admin-only nav --------
        try:
            ctx2 = browser.new_context(viewport={"width": 1600, "height": 1000})
            p2 = ctx2.new_page()
            p2.goto(f"{BASE}/login", wait_until="networkidle", timeout=30000)
            p2.fill("input[name='username'], input[type='text']", "t_viewer")
            p2.fill("input[type='password']", PASSWORD)
            p2.click("button[type='submit']")
            p2.wait_for_url(lambda u: "/login" not in u, timeout=20000)
            p2.wait_for_timeout(1500)
            nav = p2.inner_text("nav, aside")
            record("viewer does NOT see the admin-only Firewall nav item",
                   "Firewall" not in nav, f"nav={nav[:200]!r}", "critical")
            record("viewer does NOT see the admin-only Sensor nav item",
                   "Sensor" not in nav, f"nav={nav[:200]!r}", "critical")
            p2.screenshot(path=str(SHOTS / "viewer-nav.png"))

            # Hidden nav is not authorization -- the route must block too.
            # ("Firewall" still appears in the top-bar page title, so assert on
            # the denial message and the absence of the real page content.)
            p2.goto(f"{BASE}/firewall", wait_until="domcontentloaded", timeout=30000)
            p2.wait_for_timeout(2000)
            b = p2.inner_text("body")
            denied = any(s in b for s in ("Access denied", "not authorized", "does not permit", "Forbidden"))
            no_content = "Add block" not in b and "Active blocks" not in b
            record("viewer navigating directly to /firewall is blocked by the route guard",
                   denied and no_content, f"body: {b[:220]!r}", "critical")
            p2.screenshot(path=str(SHOTS / "viewer-firewall-blocked.png"))
            ctx2.close()
        except Exception as exc:
            record("viewer UI RBAC checks", False, str(exc)[:300], "critical")

        browser.close()

    return _dump(started)


def _dump(started: datetime) -> int:
    passed = sum(1 for r in results if r["passed"])
    failed = [r for r in results if not r["passed"]]
    print("\n" + "=" * 70)
    print(f"UI TOTAL {len(results)} | PASSED {passed} | FAILED {len(failed)}")
    for f in failed:
        print(f"  - [{f['severity']}] {f['name']} ({f['detail'][:160]})")
    print("=" * 70)
    with open("/tmp/e2e_browser.json", "w") as fh:
        json.dump({"started": started.isoformat(), "finished": datetime.now(timezone.utc).isoformat(),
                   "total": len(results), "passed": passed, "failed": len(failed), "results": results}, fh, indent=2)
    print(f"results -> /tmp/e2e_browser.json ; screenshots -> {SHOTS}")
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
