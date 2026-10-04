# Phase 08 — VM acceptance results (sentinelcore-1.0.1)

**Status: Part C NOT RUN yet.** The authoring machine is Windows 11 with no
Docker, no WSL, and no Ubuntu VMs/ISOs (VirtualBox 7.0.18 is installed with
one unrelated Kali VM). The real 1.0.1 build (needs Docker) and the three
fresh VMs (need ~6 GB of Ubuntu ISOs + installs) were therefore not executed.
Nothing below is marked PASS unless it was actually run.

## What WAS verified on the dev machine (evidence in `docs-internal/evidence/`)

| Check | Result | Evidence |
|---|---|---|
| `shellcheck -S warning` on installer, lib, build, tests, VM scripts | PASS (0 findings) | `run-all-1.0.1.txt` |
| `bats tests/` — 26 tests (validators, A8 injection, tricky passwords via fake docker/curl, health wait, A7 CA, log redaction) | PASS (1 skip: mode 600 not expressible on NTFS) | `run-all-1.0.1.txt` |
| relay pytest — 16 tests incl. A6 backend→TLS shim→relay integration | PASS | `run-all-1.0.1.txt` |
| relay local smoke over real HTTP: register → verify (GET link) → send → revoke → rejected | PASS 9/9 | `run-all-1.0.1.txt` |
| installer `--dry-run --non-interactive` (port 8080, bind 127.0.0.1, email on, tricky password) | PASS, exit 0; password absent from output + log | `dry-run-1.0.1.txt` |
| build refuses placeholder relay without `--allow-placeholder-relay` | PASS | (console) |
| TEST BUILD packaging + audit; audit FAILS a fake "release" with no images/frontend/placeholder relay | PASS (7 gate findings raised) | `build-1.0.1-TEST.txt` |
| `SHA256SUMS` verifies inside the staged package | PASS | (console) |

## Part B status

| # | Item | Status |
|---|---|---|
| B1 | `./build/build-release.sh 1.0.1` real build with images | **NOT RUN** — needs a Linux host with Docker, and a real `RELAY_URL` in `build/product.conf` (or `--allow-placeholder-relay` → TEST BUILD) |
| B1 | `tests/audit-package.sh` on the real zip | NOT RUN (passes on the TEST zip) |
| B2 | shellcheck clean / bats green | PASS |
| B3 | `--dry-run` output | PASS — `docs-internal/evidence/dry-run-1.0.1.txt` |

## Part C — 12 steps × 3 VMs

VMs: **V1** Ubuntu Server 24.04 · **V2** Ubuntu Server 22.04 · **V3** Ubuntu Desktop 24.04
(all: NIC1 NAT = management, NIC2 host-only/internal, Promiscuous: Allow All = capture).

| # | Step | Expected | V1 | V2 | V3 | Offline evidence so far |
|---|---|---|---|---|---|---|
| 1 | `sha256sum -c`, `unzip`, `sudo ./install.sh` | wizard starts, checks pass | NOT RUN | NOT RUN | NOT RUN | package SHA256SUMS verifies; OS gate = 22.04/24.04 |
| 2 | capture NIC = 2nd adapter, promisc yes | Suricata uses that NIC | NOT RUN | NOT RUN | NOT RUN | bats `render_suricata…`; build asserts `__CAPTURE_INTERFACE__` in template; wizard pre-selects the non-default-route NIC |
| 3 | pw with `'` and `$`, bind 127.0.0.1, port 8080 | only 127.0.0.1:8080 (`ss -ltn`) | NOT RUN | NOT RUN | NOT RUN | bats tricky-password tests; compose `${BIND_ADDRESS}:${WEB_PORT}:80`; dry-run shows 127.0.0.1:8080 |
| 4 | Email = yes | relay registered; verify mail; `.env` relay token, no provider key | NOT RUN | NOT RUN | NOT RUN | relay smoke 9/9; GET verify-link bug fixed |
| 5 | Wait | all services `healthy`, final screen | NOT RUN | NOT RUN | NOT RUN | bats: `unhealthy` ≠ healthy; relay-shim required when email on |
| 6 | browser login with CHOSEN password | works | NOT RUN | NOT RUN | NOT RUN | seed-before-first-start order (`admin-bootstrap.md`); hard `verify_login` |
| 7 | traffic from another VM (nmap / testmynids) | alert in dashboard ≤ 2 min | NOT RUN | NOT RUN | NOT RUN | — |
| 8 | trigger email; revoke → rejected | delivered; then rejected | NOT RUN | NOT RUN | NOT RUN | integration test: success, 403 → `BrevoFatalError` after revoke |
| 9 | reboot | stack back via systemd, login ok, data kept | NOT RUN | NOT RUN | NOT RUN | unit: `compose -f … up -d` / `stop`; promisc unit `Before=sentinelcore.service` |
| 10 | re-run `install.sh` | Repair/Upgrade/Abort; `.env` + data untouched | NOT RUN | NOT RUN | NOT RUN | `detect_existing` uses `.install-complete` marker |
| 11 | port busy / no internet / Docker missing / Ctrl-C | clear message, no half-broken state | NOT RUN | NOT RUN | NOT RUN | bats port check; fresh-install rollback trap |
| 12 | `sudo ./uninstall.sh --purge` | containers, volumes, unit, promisc, chain, CA removed | NOT RUN | NOT RUN | NOT RUN | dry-run prints every removal |

Post-install checks (run on each VM): `sudo tests/vm/post-install-checks.sh --expect-iface enp0s8 --expect-bind 127.0.0.1:8080`
→ `.env` 600, log 600, no secrets in log, all healthy, backend/worker non-root,
caps = dev compose (helper `[ALL]` + NET_ADMIN NET_RAW SYS_NICE CHOWN, host net;
backend/worker `[ALL]`, no-new-privileges), bind/port, af-packet NIC, PROMISC,
systemd unit. Result: **NOT RUN**.

## How to run Part C (per VM, from a clean snapshot)

```bash
# on the host: copy ONLY the zip + checksum
scp dist/sentinelcore-1.0.1.zip dist/sentinelcore-1.0.1.zip.sha256 user@vm:
# on the VM
sha256sum -c sentinelcore-1.0.1.zip.sha256
unzip sentinelcore-1.0.1.zip && cd sentinelcore-1.0.1
sudo ./install.sh
```

```bash
sudo bash post-install-checks.sh --expect-iface enp0s8 --expect-bind 127.0.0.1:8080
```

```bash
sudo bash parity-check.sh ~/sentinelcore-source-copy
```

Failure cases (step 11), each from a fresh snapshot:
- port busy: `sudo python3 -m http.server 8080 --bind 127.0.0.1 &` then install with port 8080 → wizard re-asks (interactive) / exits before changing anything (non-interactive)
- no internet + no Docker: detach NIC1 → "cannot reach download.docker.com … Nothing was changed."
- Ctrl-C during "Load Docker images" or "Wait for healthchecks" → rollback message; `docker ps -a`, `/opt/sentinelcore`, units all gone

## "Does it behave like the dev project?" — M0–M12

`scripts/e2e_test.py` / `e2e_fixtures.py` are **not** in the image
(denylisted). `tests/vm/parity-check.sh` copies them from a COPY of the source
into the running backend container's `/tmp`, runs the suite against
`http://localhost:8000/api` inside the container, prints a per-module
pass/fail table, then removes them. Run on a test VM only.

| Module | Check(s) | Source of check | Status |
|---|---|---|---|
| M0 platform | all services healthy; non-root API/worker; caps = dev compose; DB only on 127.0.0.1:5433 | `post-install-checks.sh` | NOT RUN |
| M1 auth/RBAC | 8 e2e checks (wrong pw, unknown user, lockout, role matrix…) + installer login check | `e2e_test.py` | NOT RUN |
| M2 | no M02 spec and no e2e coverage found in the source tree — **please confirm what M2 covers** | — | n/a |
| M3 asset discovery | 4 e2e checks (needs the helper socket + nmap on the capture NIC) | `e2e_test.py` | NOT RUN |
| M4 Suricata sensor | 4 e2e checks + af-packet NIC check | `e2e_test.py`, post-install | NOT RUN |
| M5 event pipeline | 3 e2e checks + step 7 live alert | `e2e_test.py`, step 7 | NOT RUN |
| M6 search | 9 e2e checks | `e2e_test.py` | NOT RUN |
| M7 correlation | 8 e2e checks | `e2e_test.py` | NOT RUN |
| M8 incidents | 12 e2e checks + step 8 incident email | `e2e_test.py` | NOT RUN |
| M9 reporting | 8 e2e checks (WeasyPrint in the release image) | `e2e_test.py` | NOT RUN |
| M10 firewall | 9 e2e checks + uninstall removes SENTINELCORE chain | `e2e_test.py`, step 12 | NOT RUN |
| M11 PCAP | 12 e2e checks (tshark in image) | `e2e_test.py` | NOT RUN |
| M12 threat intel | 15 e2e checks (feeds over real TLS — validates the system-roots half of `ca-bundle.pem`) | `e2e_test.py` | NOT RUN |

## Still open / known gaps

- Real build + all VM steps above: not executed (no Docker / VMs on this host).
- `RELAY_URL` is still the placeholder → a real (non-TEST) release cannot be built until the relay is deployed.
- Step 7 (live alert within 1–2 min) depends on the ET Open ruleset download at runtime — untested here.
