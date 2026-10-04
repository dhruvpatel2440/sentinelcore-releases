# SentinelCore — System Requirements

| Resource | Minimum | Recommended |
|---|---|---|
| OS | Ubuntu 22.04 LTS x86_64 | Ubuntu 24.04 LTS x86_64 |
| CPU | 4 cores | 8+ cores |
| RAM | 8 GB | 16 GB |
| Disk (free, Docker data root) | 40 GB (installer refuses below 15 GB) | 100+ GB SSD |
| NIC | 1 management + 1 capture | dedicated SPAN/mirror capture port |
| Container runtime | Docker Engine + Compose v2 | current stable |
| Privilege | sudo for install and operations | same |
| Host ports | HTTPS (default 443) + HTTP redirect (default 80), chosen at install | same |

Supported: Ubuntu 22.04 and 24.04 on x86_64. Debian 12/13 can install Docker
automatically but are not release-tested. Not supported: WSL, Docker Desktop
(macOS/Windows), ARM.

## Why these
- Suricata inspects live traffic (af-packet); memory grows with traffic volume
  and with the ruleset (~50k ET Open rules; `suricata -T` validation can take
  several minutes on small machines).
- Retention: events 90 days (`EVENT_RETENTION_DAYS`), reports 30 days, uploaded
  PCAPs 30 days. A single PCAP upload may be up to 500 MB.
- Docker logs are rotated (10 MB × 5 per container); `eve.json` is rotated at
  512 MB × 5 by the helper.
- Report rendering (PDF) is bursty on CPU.

## Networking
- The capture interface must see the traffic you intend to monitor. On a
  switch, use a mirror/SPAN port. Capturing on the management NIC only sees
  host-local traffic. VirtualBox: second adapter (Internal/Host-only) with
  "Promiscuous Mode: Allow All".
- Host networking is required for the privileged sensor/helper.
- Published ports: only the web UI (and PostgreSQL on 127.0.0.1:5433 for local
  tooling/backups). Redis, the API and the helper socket are never published.
- Outbound connections: see `NETWORK.md` (all optional).
