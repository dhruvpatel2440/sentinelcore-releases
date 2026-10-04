# SentinelCore — System Requirements

| Resource | Minimum | Recommended |
|---|---|---|
| OS | Ubuntu 22.04 LTS x86_64 | Ubuntu 24.04 LTS x86_64 |
| CPU | 4 cores | 8+ cores |
| RAM | 8 GB | 16 GB |
| Disk (free) | 40 GB | 100+ GB SSD |
| NIC | 1 management + 1 capture | dedicated SPAN/mirror capture port |
| Container runtime | Docker Engine + Compose v2 | current stable |
| Privilege | root/sudo for install | same |
| Host ports | 1 free TCP port for the UI (default 80, chosen at install) | same |

## Why these
- Suricata inspects live traffic (af-packet) and its memory scales with the
  volume on the monitored segment.
- Postgres retains events for 90 days by default; PCAP uploads can be up to
  500 MB each; reports are retained 30 days.
- Report rendering (PDF) is bursty on CPU.

## Networking
- The capture interface must see the traffic you intend to monitor. On a
  switch, use a mirror/SPAN port. Capturing on the management NIC only sees
  host-local traffic.
- Linux host networking is required for the privileged sensor/helper. Docker
  Desktop on macOS/Windows is **not** supported.

## Outbound
- The only outbound dependency is the SentinelCore email relay over HTTPS
  (optional; only if you enable notifications).
