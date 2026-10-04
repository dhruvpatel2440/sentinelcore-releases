# SentinelCore — Release Allowlist / Denylist

Goal: produce a clean customer ZIP that contains **no source repo, no secrets, no dev cruft** — only what is needed to run the stack on an Ubuntu host. Build from a COPY in `build/work/`, never from SOURCE_DIR directly.

## Shipping model — recommendation

**Ship prebuilt Docker images as offline tarballs** (`docker save | gzip`), not a source build and not a registry pull:

- Customers get a deterministic, audited artifact; no build toolchain, no `node_modules`, no internet needed at install (except the email relay + optional `suricata-update`).
- Avoids shipping `backend/`, `frontend/`, `helper/` source at all.
- Registry pull is the fallback if image hosting is preferred later (needs a registry + auth; defer).

### Images to ship (as tarballs under `images/`)
| Image | Built from | Est. compressed size |
|---|---|---|
| `sentinelcore-backend` (also used by worker) | `./backend` | ~400–600 MB (WeasyPrint/Pango/Cairo, tshark, matplotlib) |
| `sentinelcore-helper` | `./helper` | ~300–450 MB (nmap, suricata, iptables, scapy) |
| `sentinelcore-frontend` → **replace with static build served by nginx** | `./frontend` dist | n/a (fold into nginx) |
| `postgres:16-alpine` | pulled | ~80 MB |
| `redis:7.4-alpine` | pulled | ~15 MB |
| `nginx:1.27-alpine` | pulled | ~25 MB |

**Total offline bundle estimate: ~1.0–1.6 GB compressed.** (To be confirmed empirically in Phase 03 once images are actually built.)

Release note: the dev stack runs the frontend as a Vite dev server behind nginx with `./frontend` bind-mounted. For release, build the frontend (`dist/` already exists in source) and serve it statically from nginx — drop the `frontend` service, the Vite upstream, and both bind mounts. This is an **overlay compose** change, not a source edit.

## ALLOWLIST — ships in the ZIP

```
sentinelcore-<version>/
├── install.sh              # overlay (RELEASE_DIR)
├── uninstall.sh            # overlay
├── README.md               # customer-facing, overlay (NOT the source README)
├── VERSION                 # overlay
├── SHA256SUMS              # generated
├── lib/                    # installer helpers (overlay)
├── templates/
│   ├── .env.template       # overlay, NO secret values — names + placeholders only
│   ├── docker-compose.release.yml   # overlay: no bind mounts, static frontend, relay shim
│   ├── suricata.yaml.template        # copy of docker/suricata/suricata.yaml with HOME_NET placeholder
│   └── nginx.release.conf            # overlay: serve static dist, proxy /api
├── images/                 # docker image tarballs (offline)
└── docs/                   # customer docs (overlay), e.g. quick-start, requirements
```

Content pulled from SOURCE (copied into build, then baked into images — not shipped as files):
- `backend/` (minus tests, caches) → backend image
- `helper/` (minus tests) → helper image
- `frontend/dist/` → static assets into nginx image/volume
- `docker/suricata/suricata.yaml`, `docker/suricata/logrotate.conf` → templated
- `docker/nginx/nginx.conf` → replaced by release nginx conf

## DENYLIST — never in the ZIP, never in images, never in git

- `.git/` (not present in this copy, but enforce anyway)
- `.env` and any `*.env` / real env files (**read names only, never copy values**)
- `.env.example` (ship a sanitized `.env.template` instead — see below)
- `**/tests/`, `backend/tests/`, `helper/tests/`, `pytest.ini`, `backend/scripts/smoke_*.py`, `e2e_*.py`
- `CLAUDE.md` (both source and release — internal)
- Dev notes / module specs: `Modules/`, `updates/` (U00–U09 dev notes), `validation/` (criteria, runs, perf, scripts, RESULTS.md), `TEST_REPORT.md`, `TEST_REPORT.docx`, internal `*.md`
- `node_modules/`, `.venv/`, `__pycache__/`, `*.pyc`, `.vite/`, Vite timestamp files (`vite.config.js.timestamp-*.mjs`)
- `*.pcap`, `*.log`, local DBs, `postgres_data`/volume contents
- Any key/token/credential file; the Brevo key (lives on relay only — see email-analysis.md)
- `.github/workflows/ci.yml` and other CI
- `docs/threat-model.md`, `docs/design/` if internal (confirm with owner which docs are customer-safe)

## `.env.template` policy
- Contains **variable names + safe placeholders only** (e.g. `POSTGRES_PASSWORD=__GENERATED__`, `SECRET_KEY=__GENERATED__`, `BREVO_API_KEY=__RELAY_TOKEN__`).
- No real values ever. The source `.env.example` already contains real-looking emails (`24cs040@charusat.edu.in`, `dhruvpatel2440@gmail.com`) and must **not** be shipped verbatim — scrub to placeholders.

## First admin at install — using the app's OWN mechanism

Do **not** write a custom admin-creation script. Reuse `backend/scripts/seed_admin.py`, which `backend/entrypoint.sh` already runs on first boot:

1. Installer writes `SEED_ADMIN_USERNAME` + `SEED_ADMIN_EMAIL` (user-entered) into `.env`, leaves `SEED_ADMIN_PASSWORD` **unset**.
2. `docker compose up -d` → backend entrypoint runs `alembic upgrade head` then `python -m scripts.seed_admin`, which generates a strong password and prints it once to the backend logs.
3. Installer captures it: `docker compose logs backend | sed -n '/GENERATED PASSWORD/,+1p'` and displays it to the operator at the end, with a "store this now" warning.
4. Idempotent: re-running install never clobbers an existing admin.

(Optional overlay alternative if the operator wants to choose the password: prompt for one ≥12 chars and set `SEED_ADMIN_PASSWORD` in `.env`. The script validates length and uses it.)

## Owner decisions needed
1. Confirm offline-tarball shipping (vs. registry pull).
2. Which files under `docs/` are customer-safe to ship.
3. Suricata ruleset: bundle offline rules vs. `suricata-update` at install (also in sensors-analysis.md).
4. Approve folding the frontend into nginx static serving for release.
