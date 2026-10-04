# SentinelCore __VERSION__

Network detection & incident-response platform: Suricata IDS, asset discovery,
event search, correlation, incidents, reports, firewall containment, PCAP
analysis and threat intelligence — one `docker compose` stack on a single
Linux host, served over HTTPS.

## Install (Ubuntu 22.04 / 24.04, x86_64)
```bash
sha256sum -c sentinelcore-__VERSION__.zip.sha256
unzip sentinelcore-__VERSION__.zip
cd sentinelcore-__VERSION__
sudo ./install.sh
```
Read `docs/QUICKSTART.md` first. Everything runs locally; see `docs/NETWORK.md`
for the complete list of outbound connections (all optional).

## What's in this package
- `install.sh` — guided installer (also Repair / Upgrade of an existing install)
- `uninstall.sh` — teardown (`--purge` also removes data)
- `enable-email.sh`, `disable-email.sh` — switch relay email on/off later
- `bin/` — `backup.sh`, `restore.sh`, `sensor-start.sh` (copied to `/opt/sentinelcore/bin/`)
- `templates/` — `.env.template`, compose files (base + TLS + email overlays), nginx and Suricata templates, the static web UI (`frontend-dist/`)
- `images/` — offline Docker images (SentinelCore + pinned postgres/redis/nginx) and `IMAGES.txt` (image ids the installer verifies)
- `rules/` — bundled Emerging Threats Open ruleset (detection works out of the box, offline)
- `docs/` — quick start, requirements, HTTPS, network, operations, SBOM
- `VERSION`, `SHA256SUMS` (every file), optionally `SHA256SUMS.asc`

## Integrity
```bash
sha256sum -c SHA256SUMS                    # inside the unzipped folder
gpg --verify SHA256SUMS.asc SHA256SUMS     # when the release is signed
```
All secrets are generated locally at install time. No credentials ship in this package.

## Lab / authorized use only
SentinelCore actively scans and can actively block hosts. Only run asset
discovery or firewall containment against networks and hosts you own or have
explicit written authorization to test. `MONITORED_NETWORK` scopes what the
platform acts on — never point it at third-party infrastructure.

## Licence
All Rights Reserved by the SentinelCore authors until a licence is published.
The bundled ET Open ruleset is distributed under its own terms (`rules/NOTICE.txt`).
