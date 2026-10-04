# Cookies, ENVIRONMENT and why the release serves HTTPS (Phase 11.1)

Read-only analysis of main (`../SentinelCore/Sentinelcore-main`).

## What main does

| Item | Value | Evidence |
|---|---|---|
| Access token | JWT in the JSON body, sent as `Authorization: Bearer`, 15 min (`ACCESS_TOKEN_EXPIRE_MINUTES`) | `backend/app/core/config.py:13` |
| Refresh token | HttpOnly cookie `REFRESH_COOKIE`, 7 days, `SameSite=Lax`, `Path=/api/auth` | `backend/app/api/routes/auth.py:106-114` |
| `Secure` flag | `secure=settings.cookie_secure` | `auth.py:111,122` |
| `cookie_secure` | `== is_production` (`ENVIRONMENT` in `{production, prod}`); **no separate override variable exists** | `config.py:113-120` |
| `/api/docs`, `/api/openapi.json` | disabled when `is_production` | `backend/app/main.py:36-38` |
| Cookie path vs nginx | nginx `proxy_pass http://backend_upstream;` (no trailing slash) keeps the `/api` prefix, so the browser's `/api/auth/refresh` matches `Path=/api/auth` | `docker/nginx/nginx.conf:15-26` |

## The release problem (1.0.0)

`ENVIRONMENT=production` (correct for a shipped product: hides the API docs) ⇒ refresh cookie is `Secure`.
1.0.0 served the UI over plain HTTP. Browsers only accept/send `Secure` cookies over HTTPS — with one exception:
`http://localhost` / `127.0.0.1` are "potentially trustworthy" origins in Chrome/Firefox, so it *seemed* to work
locally. From any LAN IP the refresh cookie is dropped → user silently logged out after 15 minutes.

## Release fix (configuration only, no code change)

1. nginx terminates TLS (`listen 443 ssl`), HTTP port only redirects to HTTPS. `X-Forwarded-Proto` is forwarded.
2. Installer TLS modes (`TLS_MODE` in `.env`):
   - `self-signed` (default): install-local CA → server cert (SAN = hostname, host IPs, localhost, 127.0.0.1;
     825 days). CA key destroyed after signing; `ca.crt` kept so users can trust it.
   - `custom`: operator-supplied cert + key (validated: parse, key matches cert, not expired).
   - `http-local`: plain HTTP, **forced to bind 127.0.0.1** (loopback is a trustworthy origin, so the Secure
     refresh cookie still works). HTTP on a LAN/0.0.0.0 bind is refused by the installer — there is no way to keep
     `ENVIRONMENT=production` *and* a working refresh cookie over plain HTTP on a LAN, and setting
     `ENVIRONMENT=development` would re-expose `/api/docs`. Never ship a silently broken login.
3. HSTS only for `custom` (a trusted certificate); never for self-signed (would pin users to an untrusted cert).

## Verification (tests/web/)

- `tests/web/curl-checks.sh <host> <https_port> <http_port>`: 443 serves UI, 80→301 https, `/api/health` 200,
  security headers present, `/api/docs` 404, refresh cookie carries `Secure; HttpOnly; Path=/api/auth`.
- `tests/web/refresh.spec.mjs` (Playwright): login over HTTPS with `ACCESS_TOKEN_EXPIRE_MINUTES=1`, wait 75 s,
  navigate → still logged in (silent refresh), logout → login works.
