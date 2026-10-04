#!/usr/bin/env bash
# Aggregate test runner — the evidence source for the release checklist.
# Runs what can run on the current host; clearly skips what needs
# docker/VMs/shellcheck/bats when those are absent.
# Override tool paths with SHELLCHECK=… BATS=… when not on PATH.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
SHELLCHECK="${SHELLCHECK:-$(command -v shellcheck || true)}"
BATS="${BATS:-$(command -v bats || true)}"
rc=0
hr() { printf '\n========== %s ==========\n' "$*"; }
step_ok() { echo "PASS: $*"; }
step_bad() { echo "FAIL: $*"; rc=1; }

hr "shellcheck -S warning"
if [ -n "$SHELLCHECK" ]; then
    if ( cd "$REPO/installer" && "$SHELLCHECK" -f gcc -x -S warning ./*.sh lib/*.sh ../build/*.sh ../tests/*.sh ../tests/vm/*.sh ) \
       && "$SHELLCHECK" -f gcc -S warning -s bash "$HERE/installer.bats"; then step_ok "shellcheck clean"; else step_bad "shellcheck"; fi
else echo "SKIP: shellcheck not installed"; fi

hr "bats tests/"
if [ -n "$BATS" ]; then "$BATS" "$HERE" && step_ok "bats" || step_bad "bats"; else echo "SKIP: bats not installed"; fi

hr "selftest (dependency-free mirror)"
bash "$HERE/validate-selftest.sh" >/dev/null && step_ok "selftest" || step_bad "selftest"

hr "installer dry-run (non-interactive)"
LOG_FILE="${TMPDIR:-/tmp}/sc-dryrun.log" bash "$REPO/installer/install.sh" --dry-run --non-interactive \
    --config "$HERE/sample-install.conf" >/dev/null 2>&1 && step_ok "dry-run" || step_bad "dry-run"

hr "relay tests (pytest)"
PY="$REPO/relay/.venv/bin/python"; [ -x "$PY" ] || PY="$REPO/relay/.venv/Scripts/python.exe"
if [ -x "$PY" ]; then
    ( cd "$REPO/relay" && PYTHONPATH=. "$PY" -m pytest -q -p no:warnings ) && step_ok "relay pytest" || step_bad "relay pytest"
    hr "relay local smoke (real HTTP)"
    bash "$HERE/relay-local-smoke.sh" && step_ok "relay smoke" || step_bad "relay smoke"
else echo "SKIP: relay venv not created (see relay/README.md)"; fi

hr "package audit (latest dist zip)"
zip="$(find "$REPO/dist" -maxdepth 1 -name 'sentinelcore-*.zip' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)"
if [ -n "$zip" ]; then
    bash "$HERE/audit-package.sh" "$zip" >/dev/null && step_ok "audit $(basename "$zip")" || step_bad "audit $(basename "$zip")"
else echo "SKIP: no dist zip (run build/build-release.sh)"; fi

hr "website link check (if built)"
if [ -d "$REPO/website/dist" ]; then ( cd "$REPO/website" && node scripts/check-links.mjs ) && step_ok "links" || step_bad "links"
else echo "SKIP: website not built"; fi

hr "RESULT"
[ "$rc" -eq 0 ] && echo "ALL RUNNABLE CHECKS PASSED" || echo "SOME CHECKS FAILED"
exit "$rc"
