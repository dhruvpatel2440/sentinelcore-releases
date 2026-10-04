# SentinelCore — Gaps & Risks for a Clean Installer

Each item: the gap, and a **no-source-edit overlay workaround** — or flagged as **NEEDS OWNER DECISION** if no overlay suffices.

## 1. Dev bind-mounts in compose (`./backend`, `./frontend`, `/app/node_modules`)
- **Risk:** ships source into containers, enables live reload, breaks "no source repo in release."
- **Workaround:** release uses `templates/docker-compose.release.yml` (overlay) that omits all bind mounts and relies on code baked into the images. No source edit.

## 2. `uvicorn --reload` in backend Dockerfile CMD
- **Risk:** reload watcher is dev-only, higher memory, unsafe for production.
- **Workaround:** override `command:` in the release compose to run uvicorn without `--reload` (and optionally with `--workers`). Overlay-level — the Dockerfile CMD is just a default.

## 3. Frontend runs as Vite dev server behind nginx
- **Risk:** `nginx.conf` proxies `/` to `frontend:5173` (Vite). Not production serving.
- **Workaround:** `dist/` already exists in source. Release nginx conf (overlay) serves the static build and proxies only `/api`. Drop the `frontend` service. No source edit.

## 4. Hardcoded Brevo URL in `email/client.py` (`BREVO_URL = https://api.brevo.com/...`)
- **Risk:** cannot redirect mail to the central relay by env alone; blocks the "no Brevo key shipped" requirement.
- **Workaround (overlay, no source edit):** relay-shim sidecar with network alias `api.brevo.com` + install-local CA injected via `SSL_CERT_FILE` env. Full design in `email-analysis.md`. Fallback: `sitecustomize.py` monkeypatch mounted on `PYTHONPATH`. **NEEDS OWNER DECISION** on which route.

## 5. `suricata.yaml` HOME_NET is a literal `192.168.56.0/24`
- **Risk:** Suricata does not expand env vars; wrong HOME_NET = sensor blind on the customer's real network.
- **Workaround:** ship `templates/suricata.yaml.template` (copy of source) with a `__HOME_NET__` placeholder; installer substitutes to match `MONITORED_NETWORK`, mounts the result read-only. Overlay copy, not a source edit.

## 6. Empty Suricata ruleset on fresh install
- **Risk:** `helper/Dockerfile` only `touch`es an empty `sentinelcore.rules`. No detections until rules load. `suricata-update` needs internet egress.
- **Options:** (a) bundle a curated offline ruleset in the image/volume; (b) run `suricata-update` at install (requires egress). **NEEDS OWNER DECISION.**

## 7. `.env.example` contains real-looking personal values
- **Risk:** `SEED_ADMIN_EMAIL=24cs040@charusat.edu.in`, `EMAIL_SENDER_ADDRESS=dhruvpatel2440@gmail.com`, `MONITORED_NETWORK=192.168.56.0/24`. Shipping verbatim leaks PII and lab specifics.
- **Workaround:** never ship `.env.example`. Ship a scrubbed `templates/.env.template` with placeholders only. Enforced by the denylist.

## 8. `SECRET_KEY` has a dev default in code (`dev-only-placeholder-change-in-env`)
- **Risk:** if the installer forgets to set it, JWTs are signed with a known key.
- **Workaround:** installer **always** generates `SECRET_KEY` (`openssl rand -hex 32`) and writes it to `.env`; Phase 07 audit must assert it is not the placeholder.

## 9. `ENVIRONMENT` defaults to `development` (exposes `/api/docs`, non-Secure cookie)
- **Risk:** dev default leaves API docs open and refresh cookie insecure.
- **Workaround:** installer sets `ENVIRONMENT=production` in `.env`. Note: production marks the refresh cookie `Secure`, which requires HTTPS — see item 12.

## 10. Postgres / Redis / app secrets must be generated, not defaulted
- **Risk:** `.env.example` ships `POSTGRES_PASSWORD=change-me`.
- **Workaround:** installer generates `POSTGRES_PASSWORD`, `SECRET_KEY`, relay token, webhook secret; never writes `change-me`. Phase 07 audit greps the ZIP/images for `change-me`, `dev-only-placeholder`, and known lab values.

## 11. Admin password surfacing
- **Risk:** generated admin password is printed once to backend logs; easy to miss, and logs may be captured elsewhere.
- **Workaround:** installer greps it from `docker compose logs backend` and shows it once with a "store now" warning; recommends `ENVIRONMENT=production` and log hygiene. No source edit (uses the app's own seed mechanism).

## 12. No TLS in front of nginx (listens plain `:80`)
- **Risk:** `ENVIRONMENT=production` sets the refresh cookie `Secure`, which browsers drop over plain HTTP → login/refresh breaks on a production-flagged box accessed via HTTP.
- **Options:** (a) installer provisions a self-signed/LAN cert and a TLS nginx conf (overlay); (b) document that `production` requires the operator to front with HTTPS; (c) ship an HTTP profile that keeps cookies working. **NEEDS OWNER DECISION** — this is the one real friction between "production" flag and "runs locally on the user's PC on :80."

## 13. Healthchecks only on db/redis; none on backend/worker/helper/nginx
- **Risk:** compose can't gate readiness on the API/sensor being up.
- **Workaround:** release compose adds healthchecks (overlay). Backend already exposes `GET /api/health` and `/api/health/ready` — use them. Helper/worker can use a process/socket check. No source edit.

## 14. Helper requires `network_mode: host` + capabilities
- **Risk:** not a bug, but a hard constraint: install must be on Linux host networking (not Docker Desktop VM NAT), and the capture iface must exist on the host.
- **Workaround:** installer validates Linux + host iface before `up`; documents that macOS/Windows Docker Desktop is unsupported (matches CLAUDE.md Linux-only).

## 15. DB host port `127.0.0.1:5433`
- **Risk:** low — loopback only. If a host service already uses 5433, `up` fails.
- **Workaround:** installer checks `ss -ltn` for 5433; make the host mapping optional/configurable in release compose (overlay). Internal `db:5432` is unaffected.

## Summary of OWNER DECISIONS
1. Relay routing: CA-redirect shim vs. `sitecustomize` monkeypatch (item 4).
2. Suricata rules: bundle offline vs. `suricata-update` at install (item 6).
3. TLS story for a `production`-flagged local box (item 12).
4. Which `docs/` files are customer-safe (from release-allowlist.md).
5. Offline image tarballs vs. registry pull (from release-allowlist.md).
