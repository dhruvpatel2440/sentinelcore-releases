# SentinelCore — Quick Start

SentinelCore runs as one `docker compose` stack on a single Linux host with a
capture interface. The installer does everything; this page tells you what it
will ask and what happens after.

## 1. Before you start
- Ubuntu 22.04 or 24.04 LTS, **x86_64** (WSL, macOS and Windows are not supported)
- 4 CPU cores, 8 GB RAM, 40 GB free disk (15 GB is the hard minimum) — see `REQUIREMENTS.md`
- sudo. Docker Engine + Compose v2 (installed for you from Docker's official
  apt repository if missing — that one step needs internet)
- A capture NIC that sees the traffic you want to monitor (switch SPAN/mirror
  port, or a second host-only/internal adapter in a VM — VirtualBox: set
  "Promiscuous Mode: Allow All" on that adapter)
- Two free TCP ports for the web UI (defaults 443 for HTTPS, 80 for the redirect)

## 2. Verify, unzip, install
```bash
sha256sum -c sentinelcore-<version>.zip.sha256
unzip sentinelcore-<version>.zip
cd sentinelcore-<version>
sudo ./install.sh
```
The wizard asks for:
- the **capture interface**, and consent for promiscuous mode (persisted
  across reboots by `sentinelcore-promisc.service`, reverted on uninstall)
- admin email, username and **password** (12+ characters with upper, lower and
  a digit; any symbols allowed). This is the password you log in with — the
  installer proves it with a real login before it finishes
- monitored network (CIDR) and protected IPs (gateway, DNS, this host — never blocked)
- **how to serve the UI**:
  - `self-signed` (default): HTTPS with a certificate made for this host
  - `custom`: HTTPS with your own certificate + key
  - `http-local`: plain HTTP on 127.0.0.1 only (no LAN access)
- bind address (`0.0.0.0` = all interfaces), HTTPS port, HTTP (redirect) port
- timezone (used for report timestamps)
- email notifications via the SentinelCore relay (default yes)
- nightly backups (default no) and an optional online rules refresh (default no)

Then it verifies the package checksums and image ids, loads the bundled images
(no internet needed), creates the certificates, seeds your admin account,
starts the stack, waits until **every** service is healthy, loads the bundled
detection rules (validated with `suricata -T`), starts the sensor and enables
start-on-boot. A failed or interrupted fresh install is rolled back completely.

Automated install: `sudo ./install.sh --non-interactive --config install.conf`
(KEY=VALUE, `chmod 600`). Keys: `ADMIN_EMAIL ADMIN_USERNAME ADMIN_PASSWORD
MONITORED_NETWORK PROTECTED_IPS CAPTURE_INTERFACE BIND_ADDRESS HTTP_PORT
HTTPS_PORT TLS_MODE TLS_CERT_FILE TLS_KEY_FILE EMAIL_MODE TIMEZONE APP_BASE_URL
UPDATE_RULES NIGHTLY_BACKUP`. Unknown keys are rejected. Without
`ADMIN_PASSWORD` a strong one is generated and shown once.

## 3. First login
1. Open the URL printed at the end, e.g. `https://192.168.1.20`.
2. Self-signed mode: your browser warns until you trust this install's CA —
   see `HTTPS.md` (one command on Ubuntu, a few clicks in Chrome/Firefox).
3. Sign in with your admin username and password. Sessions refresh silently
   (15-minute access token, 7-day refresh cookie).
4. If email is on, click the verification link the relay sent to the admin
   address — sending stays disabled until you do.
5. Create analyst/viewer accounts under **Users** (roles: admin, analyst, viewer).

## 4. Everyday commands
```bash
sudo /opt/sentinelcore/bin/backup.sh               # DB + config + certs + reports (+ --with-pcaps)
sudo /opt/sentinelcore/bin/restore.sh <archive>    # restore a backup
sudo /opt/sentinelcore/enable-email.sh             # email on   (disable-email.sh: off)
sudo ./install.sh                                  # from a newer release: Upgrade (snapshot + rollback)
sudo /opt/sentinelcore/uninstall.sh                # stop + remove containers, keep data
sudo /opt/sentinelcore/uninstall.sh --purge        # remove everything incl. data (asks first)
```
More in `OPERATIONS.md` (logs, healthchecks, troubleshooting, retention).

## Notes
- All secrets are generated locally; `/opt/sentinelcore/.env` is mode 600.
- Install log (secrets redacted): `/var/log/sentinelcore-install.log`.
- Lab / authorized networks only: SentinelCore scans and can block hosts.
