# SentinelCore — Architecture (read-only analysis)

Source: `../Sentinelcore/Sentinelcore-main` (read-only). Reference only; no edits.

## Services

| Service | Image / Build | Role | Privileges |
|---|---|---|---|
| `nginx` | `nginx:1.27-alpine` | Reverse proxy; `/api/*` → backend, `/` → frontend. | Unprivileged container; publishes host `:80`. |
| `frontend` | build `./frontend` (React + Vite) | Dev server on `:5173` (containers-internal, via nginx). | Unprivileged. |
| `backend` | build `./backend` (FastAPI, Py 3.11) | HTTP API, runs Alembic migrations on boot, seeds admin. | `cap_drop: ALL`, `no-new-privileges`, user `appuser` (uid 1000, gid 2000). |
| `worker` | same image as backend, cmd `python -m app.pipeline.worker` | Event-pipeline tail of `eve.json`, correlation, M10 reconciler, PCAP parser, email outbox drain. | Same drop-all as backend; `/var/log/suricata` mounted **read-only**. |
| `db` | `postgres:16-alpine` | Primary store. | Loopback-only host port `127.0.0.1:5433 → 5432`. |
| `redis` | `redis:7.4-alpine`, `--appendonly yes` | Login throttle; pipeline offsets; correlation + reports + pcap queues. | No host port. |
| `helper` (privileged-helper) | build `./helper` (Py 3.11 + nmap, suricata, suricata-update, iptables, iproute2, logrotate) | **The only privileged container.** Owns Suricata lifecycle, runs nmap SYN/ARP scans, applies/revokes iptables rules. | `cap_drop: ALL`; `cap_add: NET_ADMIN, NET_RAW, SYS_NICE, CHOWN`; `network_mode: host`; **never** `privileged: true`. |

Note: Suricata is **not** a separate compose service — it is a child process launched inside the `helper` container (helper's Dockerfile installs the `suricata` + `suricata-update` packages; helper owns its PID/socket).

## Networks

- `sentinelcore-network` (bridge) — db, redis, backend, worker, frontend, nginx.
- `helper` uses `network_mode: host` (required for nmap routing to the monitored LAN, ARP broadcast, and af-packet capture on the real interface).
- Only `nginx` publishes a port externally (`80:80`). Backend is reachable only via nginx. DB is bound to `127.0.0.1`.

## Volumes

| Volume | Owner | Mounted by | Purpose |
|---|---|---|---|
| `postgres_data` | db | db | Postgres data dir. |
| `redis_data` | redis | redis | AOF for pipeline offset persistence. |
| `helper_socket` | helper | helper, backend, worker | Unix socket `/run/sentinelcore/helper.sock` (0660 `root:sentinelcore`); the single privilege boundary. |
| `rule_staging` | helper + backend | both | Suricata rule staging (M4). |
| `suricata_rules` | helper | helper | Final rules dir. |
| `suricata_logs` | helper | helper (rw), backend (ro), worker (ro) | `eve.json` tail source. |
| `suricata_run` | helper | helper | Suricata unix socket, pid. |
| `report_storage` | backend | backend, worker | M9 generated PDFs. |
| `pcap_storage` | backend | backend, worker | M11 uploaded captures. |
| bind `./docker/suricata/suricata.yaml` | ro | helper | Config file. |
| bind `./docker/nginx/nginx.conf` | ro | nginx | Site config. |
| bind `./backend` | rw | backend, worker | Live-reload dev mount (**must be removed for release**). |
| bind `./frontend` | rw | frontend | Vite HMR mount (**must be removed for release**). |

## Container ↔ container talk

```
Browser --:80 HTTP--> nginx
nginx /api/* -> backend:8000 (asgi)
nginx /     -> frontend:5173 (vite)
backend -> db:5432 (asyncpg)
backend -> redis:6379
backend -> helper via /run/sentinelcore/helper.sock (unix, length-prefixed JSON, see helper/protocol.py)
worker  -> db, redis, helper (same socket)
helper  -> host kernel: nmap raw sockets, ip, iptables, Suricata af-packet on $CAPTURE_INTERFACE
```

## Users / roles / group membership

- `backend` Dockerfile: `groupadd -g 2000 sentinelcore`, `useradd -m -u 1000 -G sentinelcore appuser`. Runs as `appuser`.
- `helper` Dockerfile: `groupadd -g 2000 sentinelcore`. Runs as root inside the container, but with the four-capability allowlist above only.
- **The GID 2000 match is the whole authorization mechanism** for backend/worker to open the helper socket. Any installer that rebuilds images must preserve GID 2000 on both sides.

## Where host privileges are required

| Capability | Why | Which service holds it |
|---|---|---|
| `NET_RAW` | nmap SYN scan, Scapy ARP sweep (M3) | helper |
| `NET_ADMIN` | iptables-nft rules (M10), af-packet capture | helper |
| `SYS_NICE` | Suricata capture thread priority | helper |
| `CHOWN` | Set socket mode `root:sentinelcore 0660` | helper |
| `network_mode: host` | Visibility onto the monitored LAN (bridge sees only other containers) | helper |

- `backend` and `worker` deliberately hold **zero** capabilities. Every privileged operation crosses the Unix socket to helper.
- `tshark` on backend is installed with `wireshark-common/install-setuid=false` — offline PCAP read-only (`-r`), no live capture.

## Entrypoint flow

- `backend/entrypoint.sh`:
  1. Poll Postgres (`SELECT 1`) up to 30× 2s.
  2. If `RUN_MIGRATIONS=true` (default; backend only): `alembic upgrade head`, then `python -m scripts.seed_admin` (idempotent).
  3. Else (worker): wait until `public.events` exists, then start pipeline worker.
  4. Exec the CMD (`uvicorn ...` or `python -m app.pipeline.worker`).

## Ports (external)

| Port | Bind | Served by |
|---|---|---|
| `80/tcp` | `0.0.0.0` | nginx (UI + API) |
| `5433/tcp` | `127.0.0.1` | db (host tooling only) |

No other service exposes a host port. Helper publishes **no** port — it is reachable only through the socket on the shared volume (host networking gives it visibility, not reachability).

## Open items affecting a clean release

- `./backend` and `./frontend` are bind-mounted into containers for dev reload. The release compose must drop these binds and run a built (non-reload) image.
- `nginx.conf` proxies to the Vite dev server. The release needs a built frontend served statically.
- `suricata.yaml`'s `HOME_NET` is a literal `192.168.56.0/24` (Suricata does not expand env vars). The installer must substitute it per host.
