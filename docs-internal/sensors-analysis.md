# SentinelCore — Sensors Analysis

Sources: `docker-compose.yml`, `helper/Dockerfile`, `helper/helper/` (`config.py`, `ops/nmap_scan.py`, `ops/suricata.py`, `ops/firewall.py`), `docker/suricata/suricata.yaml`, `backend/requirements.txt`, `.env.example`.

## What "sensors" means here

SentinelCore has **one live network sensor plus several active probes**, all behind the privileged helper:

1. **Suricata (M4) — the passive IDS sensor.** Installed inside the `helper` image (`suricata`, `suricata-update`). Reads live traffic via **af-packet** on `$CAPTURE_INTERFACE`, writes `eve.json`. The helper owns Suricata's lifecycle directly (start/stop/reload over its unix command socket). `HOME_NET` in `suricata.yaml` must equal `MONITORED_NETWORK`.
2. **nmap discovery (M3) — active asset scan.** `helper/ops/nmap_scan.py` runs `nmap -oX - -n -T3 --open` (SYN/connect/ping modes) against validated targets in the monitored network. Needs `NET_RAW`.
3. **Scapy ARP sweep (M3) — active layer-2 discovery.** `scapy==2.5.0` in the helper; needs `NET_RAW` + the host broadcast domain (`network_mode: host`).
4. **tshark PCAP parser (M11) — offline, unprivileged.** Lives in the **backend/worker** image (`tshark`, installed `install-setuid=false`). Only reads uploaded `.pcap` with `-r`; never captures live. Not a "sensor" in the live sense.
5. **iptables firewall (M10) — active containment.** `helper/ops/firewall.py` applies/revokes rules in a dedicated `SENTINELCORE` chain via `iptables-nft`; needs `NET_ADMIN`.

The live sensing path (Suricata af-packet + nmap route + ARP broadcast) is exactly why `helper` uses `network_mode: host`.

## What the installer must detect

| Check | Why | How (installer) |
|---|---|---|
| **Network interfaces** | `CAPTURE_INTERFACE` must be a real NIC that sees the mirrored/monitored traffic. | `ip -o link show` → offer a menu; exclude `lo`, docker/veth/bridge ifaces. |
| **Promiscuous / capture capability** | af-packet capture needs the NIC able to see all frames on a mirror/SPAN port. | Detect carrier (`ip link`), warn if the chosen iface is the management NIC; recommend a dedicated mirrored iface. Optionally `ethtool` presence. |
| **Monitored network / gateway / DNS** | Populate `MONITORED_NETWORK`, `PROTECTED_IPS` (gateway, DNS, self), Suricata `HOME_NET`. | Derive defaults from `ip route`, `ip addr`, `resolv.conf`; confirm with user. |
| **CPU / RAM** | Suricata + Postgres + pipeline are the load. | `nproc`, `/proc/meminfo`; enforce minimums below. |
| **Kernel features** | af-packet, nftables backend, raw sockets. | Check kernel ≥ 4.x (Ubuntu 22.04/24.04 always OK); `nft` / `iptables-nft` reachable from the host; `/proc/sys/net` sane. |
| **Docker + Compose v2** | Whole stack is compose. | `docker --version`, `docker compose version`; must be present and daemon running. |
| **Disk space** | Images (~offline tarballs), eve.json, pcap uploads (≤500 MB each), reports, Postgres. | `df` on the Docker data root; enforce free-space minimum. |
| **Host port 80 / 5433 free** | nginx binds `:80`; db binds `127.0.0.1:5433`. | `ss -ltn`; warn on conflict (common: a host Postgres on 5432 — compose already dodges with 5433). |
| **Suricata version / rules** | Sensor self-test (`suricata -T`) must pass; a fresh stack ships an empty `sentinelcore.rules`. | Rely on the image's packaged Suricata; run the helper's built-in config test; plan `suricata-update` for rules (needs egress or an offline ruleset — owner decision). |
| **Root / sudo** | Installer configures host networking, loads images, may adjust capture iface. | Require `sudo`/root for install steps that touch Docker + NIC. |

## Minimum & recommended system requirements (evidence-based)

Evidence: Suricata af-packet IDS + Postgres 16 + Redis + FastAPI + worker + nginx + WeasyPrint/matplotlib report rendering, single host, Ubuntu 22.04/24.04 x86_64.

| Resource | Minimum | Recommended | Rationale |
|---|---|---|---|
| CPU | 4 cores | 8+ cores | Suricata capture threads (`SYS_NICE`) + Postgres + pipeline/correlation; report PDF rendering is bursty CPU. |
| RAM | 8 GB | 16 GB | Suricata flow/stream tables scale with monitored traffic; Postgres + Redis + Python workers. 4 GB risks OOM under real traffic. |
| Disk | 40 GB free | 100+ GB SSD | Offline image tarballs, Postgres (90-day event retention default), eve.json rotation, pcap uploads (≤500 MB each), 30-day report retention. |
| NICs | 1 (mgmt) + 1 mirrored capture | dedicated SPAN/mirror port | Capturing on the mgmt NIC sees only host-local traffic; a mirror/SPAN gives real segment visibility. |
| OS | Ubuntu 22.04 LTS x86_64 | Ubuntu 24.04 LTS x86_64 | Per CLAUDE.md target. Debian-family, nftables default. |
| Docker | Engine + Compose v2 | current stable | Whole stack is `docker compose`. |
| Privilege | root/sudo at install | same | Host networking + image load + NIC selection. |

## Notes / risks for the sensor path
- `suricata.yaml` `HOME_NET` is literal; installer must substitute to match `MONITORED_NETWORK` (overlay copy, not source edit).
- Fresh install ships an empty ruleset (`sentinelcore.rules` touched empty). Detection does nothing until rules are loaded — decide whether to bundle a ruleset offline or run `suricata-update` (needs internet). **Owner decision.**
- `network_mode: host` for helper means the capture iface and monitored CIDR must be correct for the host, not a container network.
