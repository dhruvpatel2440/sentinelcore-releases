# Build inputs (Phase 10.1) — what main's images need, with evidence

Source inspected READ-ONLY: `../SentinelCore/Sentinelcore-main` (not a git checkout; plain copy).
All line numbers refer to that tree.

## Backend image (`backend/Dockerfile`, `backend/requirements.txt`)

| Question | Answer | Evidence |
|---|---|---|
| Base / Python | `python:3.11-slim` (floating tag; today = Debian trixie) | `backend/Dockerfile:1` |
| WeasyPrint system libs | YES: `libpango-1.0-0 libpangocairo-1.0-0 libgdk-pixbuf-2.0-0 libcairo2 libffi-dev shared-mime-info fonts-dejavu-core` | `backend/Dockerfile:16-24` |
| `tshark` / `capinfos` | YES: `tshark` (pulls `wireshark-common`, which ships `capinfos`); setuid disabled via debconf | `backend/Dockerfile:14,25` |
| `pydyf==0.10.0` pinned | YES (with comment why: 0.11 breaks WeasyPrint 62.3) | `backend/requirements.txt:22` |
| build tools purged | YES, `build-essential` purged after `pip install` | `backend/Dockerfile:29-30` |
| non-root | `appuser` uid 1000, group `sentinelcore` gid 2000, `USER appuser` | `backend/Dockerfile:37-39,54` |
| storage dirs | `/var/lib/sentinelcore/{reports,pcap}` `appuser:sentinelcore` 2770 (no `staging` — the helper prepares it at runtime) | `backend/Dockerfile:49-51`, `helper/helper/server.py:111-141` |
| dev-only bits | `CMD … --reload` (dev), `COPY . .` includes tests/scripts | `backend/Dockerfile:32,59` |
| `tzdata` | NOT installed → `TZ` has no effect, reports always render UTC (`now.astimezone()`) | `backend/app/reports/render.py:101`, `backend/app/services/firewall.py:238` |
| entrypoint | waits for DB, `alembic upgrade head`, then `python -m scripts.seed_admin` (only when `RUN_MIGRATIONS=true`), then `exec "$@"` | `backend/entrypoint.sh:35-41,70` |

## Helper image (`helper/Dockerfile`, `helper/requirements.txt`)

| Question | Answer | Evidence |
|---|---|---|
| Base / Python | `python:3.11-slim` | `helper/Dockerfile:1` |
| nmap, suricata, suricata-update, iptables, iproute2, logrotate, libpcap, procps | ALL installed | `helper/Dockerfile:16-24` |
| iptables backend | Debian default `iptables` = nft (`xtables-nft-multi`); helper keeps the symlink as argv[0] on purpose | `helper/helper/config.py:31-46` |
| scapy | `scapy==2.5.0` (pure Python; uses libpcap at runtime) | `helper/requirements.txt:3` |
| group | `sentinelcore` gid 2000 (must match backend) | `helper/Dockerfile:29` |
| runs as | root, by design; caps only from compose (`NET_ADMIN NET_RAW SYS_NICE CHOWN`), `cap_drop: ALL` | `helper/Dockerfile:44-46`, `docker-compose.yml:65-76` |
| empty ruleset | creates an EMPTY `/var/lib/suricata/rules/sentinelcore.rules` | `helper/Dockerfile:33-35` |
| logrotate config | `docker/suricata/logrotate.conf` exists (copytruncate, 512M×5) but is NEVER installed or run in main — nothing mounts it and no cron/loop runs `logrotate` | `docker/suricata/logrotate.conf`, `docker-compose.yml:77-83`, `grep -rn logrotate helper/` (no runtime use) |

### How the helper picks the capture interface

- `suricata_start` runs `suricata -c /etc/suricata/suricata.yaml --af-packet -i <CAPTURE_INTERFACE> -D …`
  (`helper/helper/ops/suricata.py:189-199`). The interface comes from the `CAPTURE_INTERFACE` env var
  (`helper/helper/config.py:63`, default `eth1`). `nmap_scan` also uses it (`helper/helper/ops/nmap_scan.py:80`).
- `suricata.yaml` `af-packet:` has a per-interface entry hardcoded to `enp0s8` (`docker/suricata/suricata.yaml:95`)
  plus `- interface: default` (`:107`). With `-i X`, Suricata uses the entry whose name is X, else `default`.
- **Release rule:** both are rendered from ONE installer answer — `.env CAPTURE_INTERFACE` and the
  yaml entry (`__CAPTURE_INTERFACE__`) — so the tuned entry always applies.

### Sensor lifecycle

- Suricata is NOT started automatically in main: an admin calls `POST /api/sensor/start`
  (`backend/app/api/routes/sensor.py:160-167` → helper op `suricata_start`).
- Rules: `rule-files: [sentinelcore.rules]` only (`docker/suricata/suricata.yaml:189-191`). Main gets
  real rules from the seeded source "Emerging Threats Open"
  `https://rules.emergingthreats.net/open/suricata-7.0.3/emerging.rules.tar.gz`
  (`backend/alembic/versions/0003_m4_sensor.py:98-108`) through `POST /api/sensor/rules/update`
  → `run_rules_update` → `ruleset.fetch_feed/extract_rules/compose/deploy` → helper `suricata_write_rules`
  (stage → sha256 check → backup → move → `suricata -T` → rollback on failure) (`backend/app/services/ruleset.py`,
  `helper/helper/ops/suricata.py:308-380`). See `rules-flow.md`.

## Frontend (`frontend/`)

| Question | Answer | Evidence |
|---|---|---|
| Node | `node:20-alpine` | `frontend/Dockerfile:1` |
| static build | YES: `npm run build` = `vite build` → `dist/` | `frontend/package.json:8` |
| lockfile | `package-lock.json` present → `npm ci` reproducible | `frontend/` |
| API base URL | none — the app calls relative `/api/...` (same origin via nginx) | `frontend/src/layout/HealthDot.jsx:28` |
| build-time env | only `VITE_MONITORED_NETWORK` (default form value on the Assets page, default `192.168.10.0/24`). Main's dev compose does not set it either → same default in both | `frontend/src/pages/assets/AssetsPage.jsx:297`, `docker-compose.yml:167-178` |
| inline scripts | built `index.html` has ONE external `<script type="module" src="/assets/…js">` → strict CSP possible | `frontend/dist/index.html` |

## nginx (`docker/nginx/nginx.conf`)

- `client_max_body_size 20m` for everything (`:13`), `/api/` proxied with NO trailing slash (`:19-26`),
  `/` → Vite dev server (`:29-38`). HTTP only, port 80.
- Backend PCAP limit is **500 MB** (`backend/app/core/config.py:71 max_pcap_size_mb = 500`,
  enforced while streaming in `backend/app/api/routes/pcap.py:63-87` with a 413). nginx's 20m caps uploads
  at 20 MB in main → main-site discrepancy (recorded in `parity-report.md`).

## Scripts and migrations

- `backend/scripts/seed_admin.py` — idempotent; uses `SEED_ADMIN_PASSWORD` if set (>=12 chars) else generates and prints one.
- `backend/scripts/e2e_fixtures.py`, `e2e_test.py`, `e2e_browser.py` — main's verification suites
  (TEST_REPORT.md: 157 API + 53 browser = 210 passed).
- Alembic: `backend/alembic/versions/0001 … 0014` (M1 → U10 email links).

## Email

- Client: `httpx==0.27.2`, `verify=True`, hardcoded `BREVO_URL = "https://api.brevo.com/v3/smtp/email"`
  (`backend/app/email/client.py:18,24,103-105`). httpx honours `SSL_CERT_FILE` → that is the ONLY CA variable the
  release sets (on backend/worker, and only when email is on).
- Variables: `EMAIL_MODE, BREVO_API_KEY, EMAIL_SENDER_ADDRESS, EMAIL_SENDER_NAME, EMAIL_REPLY_TO, APP_BASE_URL,
  EMAIL_ALLOWED_RECIPIENT_DOMAINS, EMAIL_DAILY_CAP_PER_RECIPIENT, EMAIL_GLOBAL_DAILY_CAP, EMAIL_MAX_ATTACHMENT_MB,
  BREVO_WEBHOOK_SECRET` (`.env.example:42-58`). `email_mode_resolved` falls back to `off` if key/sender missing
  (`backend/app/core/config.py:135-147`).

## Cookies / ENVIRONMENT

See `cookies.md`. Summary: `Secure` is `settings.cookie_secure == is_production` — there is NO separate
override variable (`backend/app/core/config.py:113-120`, `backend/app/api/routes/auth.py:106-124`).

## Decisions for the release images (overlay, no source edits)

1. Same base as main today, made explicit: `python:3.11-slim-trixie` (backend, helper, shim); digest recorded in `docs/SBOM.txt` at build.
2. Backend: identical package set + `tzdata` (so `TZ` works) + `ca-certificates`; `/var/lib/sentinelcore/staging` added;
   no `--reload`; tests/ excluded; `scripts/seed_admin.py` + `scripts/e2e_*.py` included (verification).
3. Helper: identical package set + main's own `logrotate.conf` installed and run every 15 min by a small start
   wrapper (main ships the config but never runs it).
4. Frontend: `node:20-alpine`, `npm ci && npm run build`, no source maps shipped.
