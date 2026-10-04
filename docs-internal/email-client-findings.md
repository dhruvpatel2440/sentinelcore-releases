# Email client findings (A6)

## Which HTTP client the backend uses for Brevo

- `backend/app/email/client.py` → **`httpx`** (`httpx==0.27.2` pinned in
  `backend/requirements.txt`).
  - `httpx.AsyncClient(verify=True, follow_redirects=False, timeout=…)`
  - `BREVO_URL = "https://api.brevo.com/v3/smtp/email"` (hardcoded)
  - header `api-key: <BREVO_API_KEY>`
- Other outbound httpx users: `app/intel/feeds.py`, `app/services/ruleset.py`
  (feed / ruleset downloads — real internet, must keep public roots).
- No `requests` or `aiohttp` import anywhere in `backend/app`.

## CA trust — what actually works

| Client | Honours | Notes |
|---|---|---|
| httpx 0.27.x (`verify=True`, default `trust_env=True`) | `SSL_CERT_FILE`, `SSL_CERT_DIR` | **This is what the backend uses.** |
| requests | `REQUESTS_CA_BUNDLE`, `CURL_CA_BUNDLE` (ignores `SSL_CERT_FILE`) | not used; set anyway |
| aiohttp | system/`ssl` defaults (`SSL_CERT_FILE` via OpenSSL) | not used |

Release `.env.template` sets all three to the same bundle:

```
SSL_CERT_FILE=/etc/sentinelcore/ca-bundle.pem
REQUESTS_CA_BUNDLE=/etc/sentinelcore/ca-bundle.pem
CURL_CA_BUNDLE=/etc/sentinelcore/ca-bundle.pem
```

- `ca-bundle.pem` = host system roots (`/etc/ssl/certs/ca-certificates.crt`)
  + the install CA cert (`ca.crt`) when email is on → feeds/rulesets still
  validate against public roots.
- When email is **off**, the bundle is just the system roots (always a
  file — a missing bind-mount source would otherwise become a directory and
  break every TLS call).

## Risk to watch

- httpx 0.28 reworked its SSL configuration API; I have not verified whether
  it still honours `SSL_CERT_FILE` the same way. If the backend ever bumps
  httpx past 0.27.x, re-run
  `relay/tests/test_backend_shim_integration.py` against the new source —
  the control test (`test_without_install_ca_tls_is_rejected`) plus the
  success test tell you immediately whether `SSL_CERT_FILE` is still honoured.

## Proof (integration test, no Docker)

`relay/tests/test_backend_shim_integration.py` loads the **real**
`backend/app/email/client.py` read-only from SOURCE_DIR (only
`app.core.config.settings` stubbed) and sends through the **real shim over
TLS** (uvicorn, cert signed by a throwaway install CA, CA key deleted after
signing) to the relay (fake provider):

| Test | Result |
|---|---|
| backend client uses httpx, verify=True, no requests/aiohttp | PASS |
| success: `SSL_CERT_FILE`=bundle → shim → relay → `messageId`, provider got the mail | PASS |
| control: no `SSL_CERT_FILE` → TLS rejected → `BrevoRetryableError` (token not leaked in message) | PASS |
| relay unreachable → shim 502 → `BrevoRetryableError("… 502")`; shim keeps serving | PASS |
| token revoked → 403 → `BrevoFatalError(status_code=403)` (circuit breaker, no retry storm) | PASS |

Run:

```bash
cd relay && PYTHONPATH=. .venv/bin/python -m pytest -q tests/test_backend_shim_integration.py
```

## Install-time behaviour

- Wizard step: **"Enable email notifications via the SentinelCore relay? (y/n)"**, default **yes**.
  - yes → `EMAIL_MODE=brevo`, `COMPOSE_PROFILES=email` (starts `relay-shim`)
  - no → `EMAIL_MODE=off`, `COMPOSE_PROFILES=` (shim not started)
- Relay unreachable / refuses at install → install **continues** with
  `EMAIL_MODE=off` and prints: `sudo /opt/sentinelcore/enable-email.sh`.
- `enable-email.sh` (new): registers, issues the cert, flips `.env`
  (`EMAIL_MODE`, `COMPOSE_PROFILES`, `BREVO_API_KEY`=relay token,
  `EMAIL_SENDER_ADDRESS`, `RELAY_URL`, `RELAY_INSTALL_ID`), `compose up -d`,
  waits healthy.
- `.env` holds the **relay token** in `BREVO_API_KEY`, never a Brevo provider key.

## Relay bug found and fixed

- The verification email links to `GET /v1/verify?install_id=…&code=…`, but
  the relay only had `POST /v1/verify` → clicking the link returned **405**.
- Fixed in `relay/app/main.py`: `GET /v1/verify` (HTML page), shared logic
  with POST, constant-time code compare. Test: `test_verify_link_get_works_from_email`.
