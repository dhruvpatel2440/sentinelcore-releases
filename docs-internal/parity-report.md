# Parity report — SentinelCore release 1.0.1 vs main

Status: IN PROGRESS (prompts 09–15). Evidence in docs-internal/evidence/.

## Done with evidence (this Windows host, no Docker)
- Static parity (14.1): `tests/parity/static_diff.py` → CLEAN: 147 PASS, 38 ALLOWED (each justified),
  61 same code default as main, 0 unexplained. See evidence/static-diff-1.0.1.md.
- Main-site discrepancy: main nginx caps uploads at 20 MB while the backend accepts 500 MB PCAPs.
- CSP check of main's built UI under the release headers: no violations (evidence/csp-browser-check.txt).
- Installer: bats 45/45 (2 skipped: NTFS modes, no docker), shellcheck clean, full dry-runs
  (evidence/dry-run-1.0.1.txt, dry-run-uninstall-1.0.1.txt).

## NOT RUN (needs Docker / Ubuntu VMs)
- Real build (10): images, smoke tests, main's unit tests in images, ET Open compose + suricata -T, SBOM.
- pip-freeze vs requirements, schema diff, runtime caps (14.1 dynamic parts).
- Main's API (157) + browser (53) e2e suites on the installed stack (14.2), module matrix M0–M12 (14.3).
- Web tests (tests/web/), detection tests (tests/vm/detection-check.sh), VM matrix + backup/restore/upgrade (15).

PARITY: NO (not yet proven — blockers: real build + VM runs above)
