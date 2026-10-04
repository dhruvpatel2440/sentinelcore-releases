# SentinelCore — Operations

All commands run on the SentinelCore host. `SC` below is shorthand for:
```bash
SC="sudo docker compose -f /opt/sentinelcore/docker-compose.yml --env-file /opt/sentinelcore/.env"
```
(add `-f /opt/sentinelcore/docker-compose.tls.yml` and, with email on,
`-f /opt/sentinelcore/docker-compose.email.yml` for commands that recreate
containers; read-only commands like `ps`/`logs` work with the base file.)

## Status, health, logs
```bash
sudo systemctl status sentinelcore          # boot unit (starts the stack + sensor)
$SC ps                                      # every service should be "healthy"
$SC logs --tail 100 backend                 # also: worker helper nginx db redis relay-shim
sudo tail -n 100 /var/log/sentinelcore-install.log   # installer log (secrets redacted)
```
Healthchecks: db (`pg_isready`), redis (`PING`), helper (socket bound + server
running), backend (`/api/health`), worker (pipeline process), nginx, relay-shim
(email only).

## Sensor and detection rules
- The sensor (Suricata) starts automatically after install and after every
  boot. Start/stop/status also from the UI: **Sensor**.
- The bundled ET Open ruleset is loaded at install. Update it online any time:
  **Sensor → Rules → Update** (validated with `suricata -T`; a bad update is
  rolled back and the previous rules stay live). Per-rule overrides (disable /
  threshold) are under **Sensor → Rules → Overrides**.
- No alerts? Check the capture NIC sees traffic (`sudo tcpdump -i <nic> -c 20`),
  promiscuous mode (`ip link show <nic>` shows `PROMISC`), and that
  `/var/log/suricata/eve.json` grows (Sensor page: "eve.json age").

## Backup and restore
```bash
sudo /opt/sentinelcore/bin/backup.sh                    # -> /opt/sentinelcore/backups/*.tar.gz (+ .sha256)
sudo /opt/sentinelcore/bin/backup.sh --with-pcaps       # include uploaded captures (large)
sudo /opt/sentinelcore/bin/restore.sh /path/to/sentinelcore-backup-<ver>-<ts>.tar.gz
```
A backup holds the database (`pg_dump`), `.env`, certificates, reports and the
live ruleset. **It contains secrets** — keep it offline and access-controlled.
Restore works on the same host or after a purge + fresh install: the database,
reports, ruleset, certificates and data-bound secrets (SECRET_KEY, relay
token) come from the backup; the new install's DB password, ports, NIC and TLS
mode are kept. Log in afterwards with the accounts from the backup.

Nightly backups (02:30, 7 kept, no PCAPs) can be enabled at install or later:
```bash
sudo systemctl enable --now sentinelcore-backup.timer   # if installed
systemctl list-timers sentinelcore-backup.timer
```

## Upgrade
Unzip the new release and run its installer; choose **Upgrade**:
```bash
sha256sum -c sentinelcore-<new>.zip.sha256 && unzip sentinelcore-<new>.zip
cd sentinelcore-<new> && sudo ./install.sh
```
The upgrade snapshots the database to `/opt/sentinelcore/backups/pre-upgrade-*.dump`,
loads the new images, applies migrations (the backend runs `alembic upgrade
head`), and waits for every healthcheck. If anything fails it restores the
previous compose files and the snapshot automatically. `.env`, data volumes and
certificates are kept.

## Email on/off
```bash
sudo /opt/sentinelcore/enable-email.sh    # registers with the relay, starts relay-shim
sudo /opt/sentinelcore/disable-email.sh   # stops relay-shim, removes the relay token
```
If the relay is down, SentinelCore keeps working; failed sends are logged and retried.

## Uninstall
```bash
sudo /opt/sentinelcore/uninstall.sh            # containers + units gone; data, .env, certs kept
sudo /opt/sentinelcore/uninstall.sh --purge    # also data volumes, .env, certificates, /opt/sentinelcore
```
Both remove SentinelCore's firewall rules and the `SENTINELCORE` iptables chain,
revert promiscuous mode and remove the boot units. `--purge` asks before
deleting backups (otherwise they are moved to `/root/sentinelcore-backups-*`).

## Troubleshooting

| Symptom | Check |
|---|---|
| Installer stops at "Wait for healthchecks" | It prints the last 30 log lines of the failing service; `$SC logs <service>` |
| Port already in use | `sudo ss -ltnp 'sport = :443'`; pick another port (wizard or `HTTPS_PORT` in `.env` + Repair) |
| Browser certificate warning | Trust the CA — `HTTPS.md` |
| Logged out every 15 minutes | You are on plain HTTP over a LAN address — use the HTTPS URL |
| Login rejected after restore | Use the passwords from the backup's accounts |
| PCAP upload rejected (413) | Files above 500 MB are refused by design |
| No email | Did you click the relay's verification link? `$SC logs relay-shim backend` |
| Disk filling | Retention: events 90 d, reports/PCAPs 30 d; Docker logs and eve.json are rotated |
