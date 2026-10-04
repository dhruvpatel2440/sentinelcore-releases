# SentinelCore — Email Analysis & Relay Routing

Sources: `backend/app/email/` (`client.py`, `service.py`, `worker.py`, `render.py`, `recipients.py`, `types.py`, `templates/`), `core/config.py`, `.env.example`.

## How email is sent today

- **Transport: HTTP API, not SMTP.** `app/email/client.py` POSTs JSON to a hardcoded module constant `BREVO_URL = "https://api.brevo.com/v3/smtp/email"` using `httpx`, auth via header `api-key: <BREVO_API_KEY>`. `verify=True`, `follow_redirects=False`, connect 5s / read 15s.
- **Single write path:** everything calls `app/email/service.py::enqueue()`, which inserts into the `email_outbox` table. Preferences, caps, suppression, dedupe, domain allow-list are enforced there exactly once.
- **Drain:** `app/email/worker.py` runs inside the pipeline **worker** container (no separate email container). It drains the outbox in batches, calls `BrevoClient.send()`, applies a 5-attempt retry schedule (30s/2m/10m/1h/6h) and a 15-min circuit breaker on 401/403.
- **Modes (`EMAIL_MODE`):** `off` (nothing sent), `dry_run` (render + store, no send), `brevo` (live). `email_mode_resolved` auto-falls back to `off` if `brevo` is selected but key/sender is missing — so a misconfig never crashes the app.
- **Delivery events:** Brevo posts back to a webhook authenticated by `BREVO_WEBHOOK_SECRET`.
- **Templates:** `templates/e01..e14` (`.html` + `.txt`), each an email feature (E01–E14), plus `base.html/.txt`. Rendered by `render.py`.

## Which features need the admin email

- `SEED_ADMIN_EMAIL` is the admin recipient. Email types that target the admin/operators (circuit-breaker trip alert, sensor-down/recovered, outbox-backlog alert, SLA breach, and admin digests — the E-series admin notifications and `worker.py` scanners) require a valid admin email. End-user/incident notifications go to the relevant registered users' emails.
- If no admin email is set, those operational alerts have nowhere to go; everything else still functions.

## The routing problem

Goal (per Phase 05): **ship no Brevo key to customers.** All mail should flow through a central SentinelCore-run relay over HTTPS; the relay holds the real Brevo key.

Constraint discovered: the Brevo endpoint URL is a **hardcoded constant** in `client.py`, not env-driven. We cannot change the destination URL by env alone, and CLAUDE.md forbids editing source.

## Recommendation — option (b): local HTTP-compatible shim + CA redirect (no source edit)

Because the app speaks Brevo's HTTP API (not SMTP), the SMTP-bridge sidecar (option a) does not apply. Use an **HTTP shim** that is indistinguishable from `api.brevo.com` to the backend:

1. **Compose network alias.** In the release compose, give a small `relay-shim` sidecar the network alias `api.brevo.com` on `sentinelcore-network`, so the backend's DNS for `api.brevo.com` resolves to the sidecar, never the internet.
2. **TLS the backend already trusts.** The shim presents a certificate for CN/SAN `api.brevo.com` signed by a SentinelCore install-local CA. Inject that CA into the backend/worker **by env only** — set `SSL_CERT_FILE=/etc/sentinelcore/ca-bundle.pem` (Python's default `ssl` context, which httpx `verify=True` uses, honors `SSL_CERT_FILE`/`SSL_CERT_DIR`). Mount the bundle as a read-only overlay volume. **No source edit, no image rebuild of the app logic.**
3. **Shim behavior.** Accept the exact Brevo request shape (`POST /v3/smtp/email`, `api-key` header, JSON body), authenticate the box using a **per-install relay token** placed in `BREVO_API_KEY` (this token is NOT a Brevo key — it is a SentinelCore relay credential, safe-ish but still generated per install), then forward over real HTTPS to the central relay (`https://relay.sentinelcore.<domain>/v3/smtp/email`) which injects the real Brevo key and calls Brevo. Return Brevo's `201 {messageId}` shape so the client's `SendResult` parsing is unaffected.
4. **Webhooks.** The central relay forwards Brevo delivery events to each box signed with that box's `BREVO_WEBHOOK_SECRET` (install-generated), so the app's existing webhook verification works unchanged.

Net effect: the customer box holds only a per-install relay token + webhook secret; the real Brevo key never leaves SentinelCore infrastructure.

### Alternatives considered
- **(a) SMTP sidecar** — N/A; app uses HTTP API, not SMTP.
- **(c) Minimal source overlay** — only if the shim/CA route is rejected: a tiny overlay could monkeypatch `BREVO_URL` at import via a `sitecustomize.py`/`PYTHONSTARTUP` shim (still "overlay, not source edit"). Keep as fallback; the CA-redirect route is cleaner and avoids touching Python import behavior.

## Owner decisions needed
1. Approve the shim + `SSL_CERT_FILE` CA-injection approach (vs. the `sitecustomize` monkeypatch fallback).
2. Confirm the central relay is Brevo-backed and will mint per-install relay tokens + per-install webhook secrets.
3. Decide default `EMAIL_MODE` shipped: recommend `brevo` (→ shim) when the user opts into email at install, else `off`.
4. Confirm sender identity (`EMAIL_SENDER_ADDRESS`) is owned/verified by SentinelCore, not the customer.
