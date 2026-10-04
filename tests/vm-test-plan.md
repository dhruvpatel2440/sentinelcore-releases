# SentinelCore — VM Test Plan

Fresh VirtualBox snapshots, reverted before each run. These steps require a
Linux host with Docker and cannot be executed on the build/dev machine used to
author the release (Windows). Run them on the target matrix before publishing.

## Matrix

| VM | OS | Mode | Adapter |
|----|----|------|---------|
| VM1 | Ubuntu Server 24.04 | headless, TUI wizard | NAT (mgmt) + bridged/promiscuous (capture) |
| VM2 | Ubuntu Server 22.04 | headless, non-interactive `--config` | NAT + bridged/promiscuous |
| VM3 | Ubuntu Desktop 24.04 | GUI wizard + `[Open SentinelCore]` | NAT + bridged/promiscuous |

VirtualBox capture adapter: set Adapter 2 to **Bridged**, Advanced →
**Promiscuous Mode: Allow All**, so Suricata and the helper can see LAN traffic.

## Per-VM procedure

### 0. Snapshot
- Revert to a clean snapshot with Docker NOT installed (to exercise `deps.sh`),
  or installed (to exercise the skip path) — run both variants across the matrix.

### 1. Transfer + verify
```bash
scp sentinelcore-<version>.zip user@vm:
ssh user@vm
echo "<sha256>  sentinelcore-<version>.zip" | sha256sum -c   # expect: OK
unzip sentinelcore-<version>.zip && cd sentinelcore-<version>
```
**Expected:** checksum OK; unzip yields install.sh, uninstall.sh, lib/, templates/, images/, docs/, VERSION, README.md, SHA256SUMS.

### 2. Dry run
```bash
sudo ./install.sh --dry-run            # VM1/VM3
sudo ./install.sh --dry-run --non-interactive --config install.conf   # VM2
```
**Expected:** every action printed with `[dry-run]`; no system change; exit 0.

### 3. Real install
- VM1/VM3: run `sudo ./install.sh`, complete the wizard (admin email/username/
  password, capture interface = the bridged adapter, confirm promiscuous).
- VM2: `sudo ./install.sh --non-interactive --config install.conf`.
**Expected:** system checks ✓; Docker present or installed with consent; images
loaded; stack up; healthchecks pass; admin created; systemd unit enabled; final
screen shows URL and (if generated) the one-time admin password.

### 4. Verify services
```bash
docker compose -f /opt/sentinelcore/docker-compose.yml ps     # all healthy
curl -fsS http://127.0.0.1/api/health                         # {"status":...}
ls -l /opt/sentinelcore/.env                                  # mode 600
```
**Expected:** db, redis, backend, worker, nginx healthy; helper running; `.env` is `-rw-------`.

### 5. Admin login (RBAC)
```bash
curl -fsS -X POST http://127.0.0.1/api/auth/login \
  -H 'content-type: application/json' \
  -d '{"username":"admin","password":"<admin-pw>"}' -i | head -1   # 200
```
**Expected:** 200 + auth cookie. Default/blank credentials must NOT work.

### 6. Sensor smoke test (Suricata alert)
From another host on the bridged segment, trigger a rule, e.g. the classic test:
```bash
curl -s http://testmynids.org/uid/index.html >/dev/null   # emits a known IDS test signature
# or run an nmap scan of the monitored range to generate scan alerts
```
Then confirm an event/incident appears:
```bash
docker compose -f /opt/sentinelcore/docker-compose.yml logs worker | grep -i event
# and/or check the UI incidents view
```
**Expected:** eve.json grows; the pipeline ingests at least one event; UI shows it.

### 7. Email (optional, if relay reachable)
**Expected:** registration prompts a verification email; after clicking the link,
a test notification is delivered to the admin address. The box holds only the
per-install token, never a provider key.

### 8. Idempotency
```bash
sudo ./install.sh         # second run
```
**Expected:** "existing install detected" → Repair / Upgrade / Abort menu; no
overwrite of `.env` or data.

### 9. Uninstall
```bash
sudo /opt/sentinelcore/uninstall.sh            # keep data
sudo /opt/sentinelcore/uninstall.sh --purge    # remove data (confirm twice)
```
**Expected:** containers stopped; firewall chain cleaned; with `--purge`, volumes
+ `.env` removed and systemd unit disabled. System left clean.

### 10. Failure injection (run individually, revert between)
| Injection | How | Expected |
|---|---|---|
| No internet | detach NAT before install (Docker preinstalled) | internet/relay checks warn; install proceeds offline from bundled images |
| Port 80 in use | `sudo python3 -m http.server 80 &` | port check fails with clear message; no partial stack |
| Low RAM | boot VM with 2 GB | RAM check warns (non-fatal) and recommends 8 GB |
| Docker missing | fresh snapshot | deps step explains, asks consent, installs from official repo |
| Interrupted install | Ctrl-C mid-run | trap prints failure + log path; re-run offers Repair; no data loss |

## Pass/fail table (fill per run)

| Step | VM1 (24.04) | VM2 (22.04) | VM3 (Desktop) |
|------|-------------|-------------|---------------|
| 1 transfer+verify | ☐ | ☐ | ☐ |
| 2 dry run | ☐ | ☐ | ☐ |
| 3 install | ☐ | ☐ | ☐ |
| 4 services | ☐ | ☐ | ☐ |
| 5 login/RBAC | ☐ | ☐ | ☐ |
| 6 sensor alert | ☐ | ☐ | ☐ |
| 7 email (opt) | ☐ | ☐ | ☐ |
| 8 idempotency | ☐ | ☐ | ☐ |
| 9 uninstall | ☐ | ☐ | ☐ |
| 10 failure injection | ☐ | ☐ | ☐ |

Record actual output snippets under each VM. Any ☐ that fails blocks release.
