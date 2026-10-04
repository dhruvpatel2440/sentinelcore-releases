# SentinelCore — Env Variable Inventory

Sources read: `.env.example` (NAMES only policy observed; `.env` not opened), `backend/app/core/config.py` (`pydantic_settings.BaseSettings`), `helper/helper/config.py`, `backend/entrypoint.sh`, `backend/scripts/seed_admin.py`, `docker-compose.yml`, `docker/suricata/suricata.yaml`.

Columns: **supplier** = `installer-generated` (random on install), `user-entered` (installer prompt), `product-level` (ship with a fixed default), `default` (code default, no need to supply).

## Core / database

| NAME | Purpose | Required | Secret | Supplier |
|---|---|---|---|---|
| `POSTGRES_USER` | DB user. | yes | no | installer-generated (default `sentinelcore`) |
| `POSTGRES_PASSWORD` | DB password. | yes | **yes** | installer-generated (32-char) |
| `POSTGRES_DB` | DB name. | yes | no | product-level (`sentinelcore`) |
| `DATABASE_URL` | asyncpg URL. Compose overrides for containers; `.env` value only used by host tools. | yes | **yes** (contains password) | installer-generated from the three above |

## Auth

| NAME | Purpose | Required | Secret | Supplier |
|---|---|---|---|---|
| `SECRET_KEY` | JWT signing. Must be ≥32 chars (code uses `openssl rand -hex 32`). | yes | **yes** | installer-generated |
| `ACCESS_TOKEN_EXPIRE_MINUTES` | Access-token TTL. | no | no | default `15` |
| `REFRESH_TOKEN_EXPIRE_DAYS` | Refresh TTL. | no | no | default `7` |
| `LOGIN_MAX_ATTEMPTS` | Login throttling (M1). | no | no | default `5` |
| `LOGIN_LOCKOUT_SECONDS` | Lockout window. | no | no | default `300` |

## Bootstrap admin (first-run seed)

The admin is created by `scripts/seed_admin.py`, invoked unconditionally from `backend/entrypoint.sh` right after `alembic upgrade head`. It is **idempotent** (keyed on `username`). This is the mechanism the installer should rely on — **no separate CLI call needed**.

| NAME | Purpose | Required | Secret | Supplier |
|---|---|---|---|---|
| `SEED_ADMIN_USERNAME` | Admin login name. | no | no | user-entered (default `admin`) |
| `SEED_ADMIN_PASSWORD` | Admin password. **If unset, a 24-char random one is generated and printed to the backend container logs exactly once.** Must be ≥12 chars when supplied. | no | **yes** | user-entered OR generated+printed |
| `SEED_ADMIN_EMAIL` | Admin's email (used by email notifications). | yes if emails used | no | user-entered |

Installer design note: for v1 we should run with `SEED_ADMIN_PASSWORD` **unset** on first boot and surface the printed password at the end of `install.sh` by `docker compose logs backend | grep -A2 'GENERATED PASSWORD'`.

## Network scope / sensor targeting

| NAME | Purpose | Required | Secret | Supplier |
|---|---|---|---|---|
| `CAPTURE_INTERFACE` | NIC Suricata reads (also helper default). | yes | no | user-entered (detected list) |
| `MONITORED_NETWORK` | IPv4 CIDR Suricata+helper treat as HOME. | yes | no | user-entered |
| `PROTECTED_IPS` | Comma list that may never be firewall-blocked (gateway/DNS/self). | yes | no | user-entered (auto-prefilled) |
| `DNS_SERVERS` | Resolver IPs (helper reads). | no | no | user-entered |

**Important mismatch to overlay for release:** `docker/suricata/suricata.yaml` hard-codes `HOME_NET: "[192.168.56.0/24]"`. Suricata does not expand env vars. The installer must `sed`-substitute HOME_NET at install time (overlay-only; no edit of source).

## Suricata paths

| NAME | Purpose | Required | Secret | Supplier |
|---|---|---|---|---|
| `SURICATA_EVE_LOG` | eve.json path (default `/var/log/suricata/eve.json`). | no | no | default |
| `SURICATA_CONFIG` | Config path. | no | no | default |
| `SURICATA_PID_FILE` | Pid path. | no | no | default |
| `SURICATA_RULES_DIR` | Final rules dir. | no | no | default |
| `SURICATA_COMMAND_SOCKET` | Unix socket to Suricata. | no | no | default |
| `SURICATA_PATH` / `SURICATASC_PATH` | Explicit binaries (helper resolves if unset). | no | no | default |

## Redis / pipeline

| NAME | Purpose | Required | Secret | Supplier |
|---|---|---|---|---|
| `REDIS_URL` | Pipeline/queues. | yes | no | product-level (`redis://redis:6379/0`) |
| `EVENT_RETENTION_DAYS` | Event retention. | no | no | default `90` |

## Deployment flag

| NAME | Purpose | Required | Secret | Supplier |
|---|---|---|---|---|
| `ENVIRONMENT` | `development` | `production`. Prod hides `/api/docs` and marks refresh cookie `Secure`. | yes | no | installer sets `production` |

## Helper internals (optional overrides)

Defaults are fine for a release. Listed for completeness.

| NAME | Default | Purpose |
|---|---|---|
| `HELPER_SOCKET_PATH` | `/run/sentinelcore/helper.sock` | Socket path. |
| `HELPER_SOCKET_GROUP` | `sentinelcore` | Group that owns the socket. |
| `HELPER_LOG_LEVEL` | `INFO` | Log verbosity. |
| `HELPER_ARP_TIMEOUT` | `120` | ARP sweep timeout. |
| `HELPER_OP_TIMEOUT` | `60` | Default op timeout. |
| `HELPER_NMAP_TIMEOUT` | `900` | Nmap scan timeout. |
| `HELPER_FIREWALL_TIMEOUT` | `15` | iptables op timeout. |
| `HELPER_SURICATA_TEST_TIMEOUT` | `900` | `suricata -T` timeout. |
| `FIREWALL_CHAIN` | `SENTINELCORE` | Dedicated chain name. |
| `IPTABLES_PATH`, `IP_PATH`, `NMAP_PATH` | PATH lookup | Explicit binary overrides. |

## U10 — Email (Brevo)

| NAME | Purpose | Required | Secret | Supplier |
|---|---|---|---|---|
| `EMAIL_MODE` | `off` \| `dry_run` \| `brevo`. | no | no | **product-level: force `brevo` → `relay` in release** (see email-analysis.md) |
| `BREVO_API_KEY` | Brevo transactional key. | yes if `brevo` | **yes** | **MUST NOT ship.** Lives on the SentinelCore-run relay only. |
| `EMAIL_SENDER_ADDRESS` | Verified Brevo sender. | yes | no | product-level (set by relay, not user) |
| `EMAIL_SENDER_NAME` | Display name. | no | no | default `SentinelCore` |
| `EMAIL_REPLY_TO` | Reply-to. | no | no | default empty |
| `APP_BASE_URL` | Base URL in email links. | no | no | user-entered (default `https://sentinel.lab`) |
| `EMAIL_ALLOWED_RECIPIENT_DOMAINS` | Comma allow-list; empty = any registered user email. | no | no | user-entered |
| `EMAIL_DAILY_CAP_PER_RECIPIENT` | Rate cap per recipient. | no | no | default `50` |
| `EMAIL_GLOBAL_DAILY_CAP` | Global cap. | no | no | default `250` |
| `EMAIL_MAX_ATTACHMENT_MB` | Attachment ceiling. | no | no | default `5` |
| `BREVO_WEBHOOK_SECRET` | Shared secret for Brevo events webhook. | no | **yes** | **not shipped.** Relay signs its own webhooks to the installed box. |
| `INCIDENT_SLA_MINUTES_CRITICAL/HIGH/MEDIUM` | SLA minutes. | no | no | defaults 15/60/240 |
| `EMAIL_OUTBOX_DRAIN_INTERVAL_SECONDS`, `_REAPER_STUCK_MINUTES`, `_HEALTH_SCAN_INTERVAL_SECONDS`, `_RETENTION_SENT_DAYS`, `_RETENTION_FAILED_DAYS`, `EMAIL_SEND_EMPTY_DIGEST` | Outbox worker tuning. | no | no | defaults |

## Module tuning (all have defaults — none required)

M6/M7/M8/M9/M10/M11/M12 configuration keys from `backend/app/core/config.py` all carry safe defaults (search window, correlation interval, auto-promote score 70, incident merge window 60min, report storage path, max pcap size 500 MB, intel feed caps, etc.). None need prompting at install.

## Admin bootstrap — one-paragraph summary

The app's **own** mechanism (`backend/scripts/seed_admin.py`, invoked by `backend/entrypoint.sh`) creates the first admin from `SEED_ADMIN_USERNAME` / `SEED_ADMIN_EMAIL` and either a user-supplied `SEED_ADMIN_PASSWORD` or an in-container random generation that is printed once to stdout. The installer should set username/email, leave the password unset, and surface the generated password from `docker compose logs backend` at the end of installation. No source edit required.
