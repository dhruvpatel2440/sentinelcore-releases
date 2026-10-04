# SentinelCore __VERSION__

Network detection & incident-response platform. One `docker compose` stack on
a single Linux host.

## Install
```bash
cd sentinelcore-__VERSION__
sudo ./install.sh
```
See `docs/QUICKSTART.md` and `docs/REQUIREMENTS.md`.

## What's in this package
- `install.sh`, `uninstall.sh` — guided installer / teardown
- `enable-email.sh` — turn on relay email after install (copied to `/opt/sentinelcore/`)
- `templates/` — `.env.template`, `docker-compose.release.yml`, `nginx.release.conf`, `suricata.yaml.template`
- `images/` — offline Docker image tarball (SentinelCore images + pinned postgres/redis/nginx)
- `templates/frontend-dist/` — the static web UI
- `docs/` — quick start and requirements
- `VERSION`, `SHA256SUMS`

## Integrity
Verify before install:
```bash
sha256sum -c SHA256SUMS
```

All secrets are generated locally at install time. No credentials ship in this
package.
