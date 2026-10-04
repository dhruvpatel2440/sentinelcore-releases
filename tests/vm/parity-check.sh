#!/usr/bin/env bash
# parity-check.sh — "does the installed stack behave like the dev project?"
# Runs the dev project's own M1–M12 end-to-end suite (scripts/e2e_test.py)
# against the INSTALLED stack. The e2e scripts are deliberately NOT shipped
# in the image (denylisted), so this copies them from a COPY of the source
# into the running backend container's /tmp, runs them there (BASE is
# http://localhost:8000/api inside the container), then removes them.
#
# Run ONLY on a test VM: it creates t_admin/t_analyst/t_viewer accounts and
# e2e- prefixed data (the suite cleans its data; the t_ accounts remain).
#
# Usage: sudo tests/vm/parity-check.sh <path-to-COPY-of-SentinelCore-source>
set -euo pipefail
SRC="${1:?usage: parity-check.sh <copy-of-source-dir>}"
INSTALL_DIR="${INSTALL_DIR:-/opt/sentinelcore}"
DC=(docker compose -f "$INSTALL_DIR/docker-compose.yml" --env-file "$INSTALL_DIR/.env")
for f in e2e_test.py e2e_fixtures.py; do [ -f "$SRC/backend/scripts/$f" ] || { echo "missing $SRC/backend/scripts/$f"; exit 2; }; done

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"; "${DC[@]}" exec -T -u 0 backend rm -rf /tmp/sc-e2e >/dev/null 2>&1 || true' EXIT
mkdir -p "$WORK/sc-e2e/sc_e2e"
cp "$SRC/backend/scripts/e2e_test.py" "$SRC/backend/scripts/e2e_fixtures.py" "$WORK/sc-e2e/sc_e2e/"
: > "$WORK/sc-e2e/sc_e2e/__init__.py"
"${DC[@]}" cp "$WORK/sc-e2e" backend:/tmp/sc-e2e

run_py() { "${DC[@]}" exec -T -w /app -e PYTHONPATH=/app:/tmp/sc-e2e backend python -m "$@"; }
echo "== fixtures (t_admin / t_analyst / t_viewer) =="
run_py sc_e2e.e2e_fixtures
echo "== e2e M1–M12 =="
set +e
run_py sc_e2e.e2e_test | tee "$WORK/e2e.out"
rc=${PIPESTATUS[0]}
set -e
"${DC[@]}" exec -T backend cat /tmp/e2e_results.json > ./e2e_results.json 2>/dev/null || true

echo
echo "== per-module summary =="
if command -v python3 >/dev/null 2>&1 && [ -s ./e2e_results.json ]; then
    python3 - <<'PY'
import json, collections
r = json.load(open("e2e_results.json"))
rows = r["results"] if isinstance(r, dict) and "results" in r else r
c = collections.OrderedDict()
for x in rows:
    m = x["module"]; c.setdefault(m, [0, 0]); c[m][0 if x["passed"] else 1] += 1
for m, (p, f) in sorted(c.items(), key=lambda kv: int(kv[0][1:]) if kv[0][1:].isdigit() else 99):
    print(f"{m:4s}  pass={p:3d}  fail={f:3d}")
PY
else
    grep -Eo '\[(PASS|FAIL)\] M[0-9]+' "$WORK/e2e.out" | sort | uniq -c
fi
echo "(full results: ./e2e_results.json)"
exit "$rc"
