// Playwright: login over HTTPS and prove the silent token refresh works
// (Phase 11). Run against a TEST install whose .env has
// ACCESS_TOKEN_EXPIRE_MINUTES=1 (then Repair/restart backend):
//
//   SC_URL=https://192.168.56.10 SC_USER=t_admin SC_PASS=... \
//     npx playwright test tests/web/refresh.spec.mjs
//
// ignoreHTTPSErrors only skips trust of the self-signed CA in this test copy.
import { test, expect } from "@playwright/test";

const URL = process.env.SC_URL;
const USER = process.env.SC_USER;
const PASS = process.env.SC_PASS;

test.use({ ignoreHTTPSErrors: true });
test.setTimeout(240_000);

test("session survives access-token expiry via the Secure refresh cookie", async ({ page, context }) => {
  test.skip(!URL || !USER || !PASS, "set SC_URL, SC_USER, SC_PASS");
  const consoleErrors = [];
  page.on("console", (m) => { if (m.type() === "error") consoleErrors.push(m.text()); });

  await page.goto(`${URL}/login`);
  await page.getByLabel(/username/i).fill(USER);
  await page.getByLabel(/password/i).fill(PASS);
  await page.getByRole("button", { name: /^sign in$/i }).click();
  await expect(page).not.toHaveURL(/\/login/);

  const cookie = (await context.cookies()).find((c) => c.path === "/api/auth");
  expect(cookie, "refresh cookie present").toBeTruthy();
  expect(cookie.secure).toBe(true);
  expect(cookie.httpOnly).toBe(true);

  // Access token lives 60 s in the test install; wait past it.
  await page.waitForTimeout(75_000);
  const refreshed = page.waitForResponse((r) => r.url().includes("/api/auth/refresh") && r.status() === 200, { timeout: 60_000 });
  await page.reload();
  await refreshed;
  await expect(page).not.toHaveURL(/\/login/);

  // Logout, then a fresh login still works.
  await page.locator('button[aria-haspopup="menu"]').click();   // UserMenu toggle
  await page.getByRole("button", { name: /^sign out$/i }).click();
  await expect(page).toHaveURL(/\/login/);
  await page.getByLabel(/username/i).fill(USER);
  await page.getByLabel(/password/i).fill(PASS);
  await page.getByRole("button", { name: /^sign in$/i }).click();
  await expect(page).not.toHaveURL(/\/login/);

  expect(consoleErrors.filter((e) => /Content Security Policy|Refused to/i.test(e)), "no CSP violations").toEqual([]);
});
