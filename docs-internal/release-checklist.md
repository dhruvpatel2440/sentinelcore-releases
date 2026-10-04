# SentinelCore — Release Checklist

Status legend: ✅ done + evidence · ⏳ requires a Linux/Docker host or VM (scripts ready) · ⚠️ owner decision.

Evidence is reproducible via `bash tests/run-all.sh`.

| # | Item | Status | Evidence / note |
|---|------|--------|-----------------|
| 1 | Source repo untouched | ✅ | SOURCE_DIR (`../Sentinelcore/Sentinelcore-main`) is read-only in this workflow; nothing was written there. It is **not** a git repo (no `.git`), so `git -C SOURCE_DIR status` is N/A; the equivalent guarantee is that the pipeline only ever **copies** from it into `build/work/`. |
| 2 | Build from a clean copy; audit passes | ✅ | `build/build-release.sh` wipes `build/work/` each run, copies via allow/deny lists, and aborts on audit findings. Audit PASSED on `dist/sentinelcore-1.0.0.zip` (`tests/audit-package.sh`). |
| 3 | Checksum (+ optional GPG) published with the ZIP | ✅ (checksum) / ⚠️ (GPG) | `dist/sentinelcore-1.0.0.zip.sha256` produced; `SHA256SUMS` inside the package. GPG signing is wired (`--sign`) but requires the owner's key at build time. |
| 4 | Relay deployed; provider key only on relay; test mail delivered | ⏳ | Relay built + tested (10/10, incl. e2e register→verify→send→revoke→rejected). Actual deploy + real provider key + live mail is an owner step — see `relay/DEPLOY.md`. |
| 5 | Website points to correct DOWNLOAD_URL; checksum matches | ✅ | `website/scripts/sync-release.mjs` pulled the **real** sha256 from `dist/*.sha256` into the download page; `DOWNLOAD_URL` is build-time env. Link check: 153 links, 0 broken. Set the production `DOWNLOAD_URL`/`SITE_URL` at deploy. |
| 6 | Fresh-VM install on all matrix targets; clean uninstall | ⏳ | `tests/vm-test-plan.md` has exact steps + pass/fail table for Ubuntu 24.04/22.04 Server + 24.04 Desktop, incl. sensor alert smoke test and failure injection. Requires Linux/VirtualBox host. Installer `--dry-run` verified here. |
| 7 | Docs match installer behavior; version + changelog updated | ✅ | Website docs + `build/overlay/docs/*` describe the actual wizard flow; `VERSION`=1.0.0; changelog on the download page. Re-verify wording after a real VM run. |
| 8 | Rotate any secret exposed during development | ✅ (n/a) | No real secret was created or read in this workflow. `.env` was never opened (names only). `.env.template` is placeholders. The source `.env.example` lab values are denied by the audit, so they can never ship; rotate those on the owner side if they were ever real. |

## Automated test evidence (this host)

From `bash tests/run-all.sh`:
- Installer validators + `.env` render + secret length/entropy: **23 passed, 0 failed** (`tests/validate-selftest.sh`).
- Installer dry-run (non-interactive): **OK**.
- Relay unit + e2e: **10 passed** (`relay/tests/`).
- Package audit on `sentinelcore-1.0.0.zip`: **PASSED**.
- Website internal links: **153 checked, 0 broken**.
- Audit negative test: AWS/GitHub/JWT/private-key/dev-path patterns all detected (build aborts).

## Still requiring a Linux/Docker host (scripts ready, cannot run on Windows authoring box)
- `shellcheck` on all scripts — wired into `tests/run-all.sh` (SKIP here; run in CI/target).
- `bats tests/installer.bats` — present; mirrored by the no-bats selftest which passes.
- `docker build` of the three images + `docker save` tarball; `docker history` +
  filesystem secret scan (automatic in `audit-package.sh` when docker is present).
- The full VM matrix in `tests/vm-test-plan.md`.

## Owner decisions outstanding (from analysis)
- ⚠️ Front-door TLS for a `production`-flagged box (gaps item 12 / runtime review §8).
- ⚠️ Suricata ruleset: bundle offline vs. `suricata-update` (gaps item 6).
- ⚠️ GPG signing key for release artifacts (checklist #3).
- ⚠️ Relay production deploy + provider key (checklist #4).

## Not currently failing
No runnable check is failing. All ⏳ items are blocked only by the absence of a
Linux/Docker/VM environment on the authoring machine, not by defects.
