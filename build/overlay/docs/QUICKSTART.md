# SentinelCore — Quick Start

SentinelCore is a network detection & incident-response platform that runs as
a single `docker compose` stack on one Linux host with a capture interface.

## 1. Requirements (minimum)
- Ubuntu 22.04 or 24.04 LTS, x86_64
- 4 CPU cores, 8 GB RAM, 40 GB free disk (8 cores / 16 GB / 100 GB SSD recommended)
- root/sudo. Docker Engine + Compose v2 (the installer can install Docker
  from Docker's official apt repository if it is missing — needs internet)
- A capture NIC that sees the traffic you want to monitor (mirror/SPAN port,
  or a second host-only/internal adapter in a VM)
- One free TCP port for the web UI (default 80; you choose it in the wizard)

## 2. Verify and install
```bash
sha256sum -c sentinelcore-<version>.zip.sha256
unzip sentinelcore-<version>.zip
cd sentinelcore-<version>
sudo ./install.sh
```
The wizard asks for:
- the **capture interface** (and consent for promiscuous mode — persisted
  across reboots, reverted on uninstall)
- admin email, username and **password** (12+ chars with upper, lower and a
  digit; any symbols allowed) — this is the password you will log in with
- monitored network (CIDR) and protected IPs (never blocked)
- **bind address** (default `127.0.0.1` = this machine only; `0.0.0.0` = all
  interfaces — then firewall it and/or put TLS in front) and **web port**
- whether to **enable email notifications** via the SentinelCore relay (default yes)

It verifies the package checksums, loads the bundled Docker images (no
internet build needed), starts the stack, waits until every service is
healthy, and test-logs-in with your password before it reports success.
If anything fails (or you press Ctrl-C), a fresh install is rolled back.

Automated install: `sudo ./install.sh --non-interactive --config install.conf`
(KEY=VALUE file, `chmod 600`; keys: ADMIN_EMAIL ADMIN_USERNAME ADMIN_PASSWORD
MONITORED_NETWORK PROTECTED_IPS WEB_PORT BIND_ADDRESS CAPTURE_INTERFACE
EMAIL_MODE TIMEZONE APP_BASE_URL). Without ADMIN_PASSWORD a strong one is
generated and shown once.

## 3. Open the console
Browse to the URL printed at the end (e.g. `http://127.0.0.1:8080`) and sign
in with the username and password you chose.

If email is on, click the verification link the relay sends to the admin
address — sending stays disabled until you do.

## 4. Later
```bash
sudo /opt/sentinelcore/enable-email.sh       # turn email on after install
sudo ./install.sh                            # Repair / Upgrade (keeps .env + data)
sudo /opt/sentinelcore/uninstall.sh          # stop + remove containers, keep data
sudo /opt/sentinelcore/uninstall.sh --purge  # remove everything incl. data (irreversible)
```

## Notes
- All secrets are generated locally; none ship in this package.
- Email is routed through the SentinelCore relay — no mail provider key ever
  lives on your box, only a revocable per-install relay token.
- Install log (secrets redacted): `/var/log/sentinelcore-install.log`.
- See `REQUIREMENTS.md` for full system-requirement detail.
