# Release build pipeline

`build/build-release.sh <version>` produces `dist/sentinelcore-<version>.zip`
(+ `.zip.sha256`) containing only what customers need. SOURCE_DIR is treated
as read-only; images are built from a filtered copy in `build/work/src/`.

## Run

```bash
# Real release (Linux host with Docker; RELAY_URL in product.conf must be real):
build/build-release.sh 1.0.1 --source ../SentinelCore

# TEST BUILD with the placeholder relay (README marked "TEST BUILD"):
build/build-release.sh 1.0.1 --allow-placeholder-relay

# Packaging-only TEST BUILD without Docker (NOT installable):
build/build-release.sh 1.0.1 --skip-images --allow-placeholder-relay

# GPG-sign the zip (key from your gpg agent; never stored):
build/build-release.sh 1.0.1 --sign
```

- `--source` (or `$SOURCE_DIR`): default `../SentinelCore`; a single nested
  checkout such as `../SentinelCore/Sentinelcore-main` is detected.
- Test builds are written as `dist/sentinelcore-<version>-TEST.zip`.

## Product config — `build/product.conf`

- `RELAY_URL` — public HTTPS URL of the deployed relay (`relay/DEPLOY.md`).
- Rendered into the package's `lib/product.sh` (`RELEASE_FLAVOR`, `RELAY_URL`).
- The build **fails** while it is the placeholder `relay.sentinelcore.app`,
  unless `--allow-placeholder-relay` (→ TEST BUILD).

## What it does

1. Prerequisites: `zip sha256sum tar find gzip`; `docker` (daemon reachable)
   unless `--skip-images`; `rsync` optional.
2. Wipe `build/work/`, copy allowlisted source paths minus `denylist.txt`.
3. Stage: installer (`install.sh uninstall.sh enable-email.sh lib/`),
   generated `lib/product.sh`, templates (compose keeps `__VERSION__` — the
   installer fills it from `VERSION`), `suricata.yaml.template` derived from
   the copy with **both** `__HOME_NET__` and `__CAPTURE_INTERFACE__`
   (af-packet entry; `default` entry kept), docs, README, VERSION.
4. Images: build backend, helper, relay-shim (`relay/shim/Dockerfile`), static
   frontend (extracted to `templates/frontend-dist/`, no source maps); pull
   the pinned third-party images the compose references (postgres, redis,
   nginx); **fail if any compose image is missing**; `docker save | gzip` →
   `images/sentinelcore-images-<version>.tar.gz`; verify every compose image
   is in the tarball's `manifest.json`.
5. `tests/audit-package.sh` on the staging dir — aborts on findings. A real
   release additionally fails on: `NO_IMAGES.txt`, missing tarball, missing
   `frontend-dist/index.html`, placeholder relay, README marked TEST BUILD.
6. `SHA256SUMS` over **every** file (incl. images + frontend-dist), zip,
   `.sha256`, optional `.asc`, then audit the final zip again.

## Bump the version

Pass the new `X.Y.Z`. It flows into image tags, `VERSION`, the ZIP name, and
(at install time) the rendered compose. There is no version file to edit.

## Add files

- More source in image builds → `build/allowlist.txt`.
- Forbid something everywhere → `build/denylist.txt` (pruned + audited).
- Customer-facing templates/docs → `build/overlay/`.
