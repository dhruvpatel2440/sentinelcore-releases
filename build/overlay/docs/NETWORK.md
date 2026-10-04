# SentinelCore — Network exposure and outbound connections

SentinelCore has no telemetry and no background "phone home". Every outbound
connection is listed here, with when it happens and how to avoid it.

## Outbound (egress)

| Destination | When | Who | Optional? |
|---|---|---|---|
| `download.docker.com` (+ Ubuntu/Debian apt mirrors) | Install only, and only if Docker is not installed | installer | Yes — install Docker yourself first |
| SentinelCore email relay (`RELAY_URL`, HTTPS) | Install (registration) and whenever a notification email is sent | installer, relay-shim | Yes — answer "no" to email, or `disable-email.sh` |
| `rules.emergingthreats.net` (HTTPS) | Only when you choose "Update rules now" at install, or an admin clicks Sensor → Rules → Update | backend | Yes — the bundled ruleset works offline |
| Threat-intel feed URLs you configure (HTTPS) | On the feed schedule, only for feeds an admin adds/enables | backend | Yes — no feeds are enabled by default |
| Hosts in `MONITORED_NETWORK` | Asset discovery scans (nmap/ARP) started by an admin/analyst | helper | Yes — only when you run a scan |

Nothing else leaves the machine. An offline install (no internet) works fully:
detection uses the bundled rules, email stays off, feeds show their last error.

## What the email relay receives
The rendered notification (recipient, subject, body, optional small
attachment) and this install's relay token. Your mail-provider credentials
never exist on your machine; the relay holds them. Turning email off stops all
relay traffic.

## Inbound (listening ports on the host)

| Port | Bound to | Purpose |
|---|---|---|
| `HTTPS_PORT` (default 443) | `BIND_ADDRESS` | Web UI + API (nginx) |
| `HTTP_PORT` (default 80) | `BIND_ADDRESS` | Redirect to HTTPS (`http-local` mode: the UI, 127.0.0.1 only) |
| 5433 | 127.0.0.1 only | PostgreSQL for local tooling and `backup.sh` |

Redis, the API (8000), the relay-shim and the privileged helper socket are
internal to the Docker network and never published. Check with:
```bash
sudo ss -ltnp | grep -E 'docker-proxy|nginx'
```

When `BIND_ADDRESS=0.0.0.0`, restrict the UI to your admin network, e.g.:
```bash
sudo ufw allow from 192.0.2.0/24 to any port 443 proto tcp
```
