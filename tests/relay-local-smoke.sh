#!/usr/bin/env bash
# relay-local-smoke.sh — run the relay as a REAL HTTP server on localhost
# (uvicorn, fake provider, throwaway DB) and drive it with curl:
#   health -> register -> verify (GET link from the email) -> send_rendered
#   -> revoke -> send rejected.
# Usage: tests/relay-local-smoke.sh [port]
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${1:-8099}"
PY="$REPO/relay/.venv/bin/python"; [ -x "$PY" ] || PY="$REPO/relay/.venv/Scripts/python.exe"
[ -x "$PY" ] || { echo "relay venv missing (see relay/README.md)"; exit 2; }

TMP="$(mktemp -d)"
ADMIN_SECRET="smoke-admin-$(openssl rand -hex 8)"
export RELAY_DB_PATH="$TMP/relay.db" RELAY_PROVIDER=fake RELAY_ADMIN_SECRET="$ADMIN_SECRET" \
       RELAY_PUBLIC_URL="http://127.0.0.1:$PORT"
( cd "$REPO/relay" && exec "$PY" -m uvicorn app.main:app --host 127.0.0.1 --port "$PORT" --log-level warning ) &
PID=$!
trap 'kill $PID 2>/dev/null || true; wait $PID 2>/dev/null || true; rm -rf "$TMP" 2>/dev/null || true' EXIT
B="http://127.0.0.1:$PORT"
for _ in $(seq 1 50); do curl -fsS "$B/v1/health" >/dev/null 2>&1 && break; sleep 0.2; done

pass=0; fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok   $1 (HTTP $2)"; else fail=$((fail+1)); echo "  FAIL $1 (HTTP $2, want $3)"; fi; }
code() { curl -s -o "$TMP/body" -w '%{http_code}' "$@"; }

echo "relay smoke against $B"
check "health" "$(code "$B/v1/health")" 200
check "register" "$(code -X POST "$B/v1/register" -H 'content-type: application/json' \
    -d '{"admin_email":"ops@example.org","install_id":"smoke-001","version":"1.0.1"}')" 200
TOKEN="$(sed -n 's/.*"token":"\([^"]*\)".*/\1/p' "$TMP/body")"
[ -n "$TOKEN" ] && { pass=$((pass+1)); echo "  ok   token issued"; } || { fail=$((fail+1)); echo "  FAIL no token"; }
send() {
    code -X POST "$B/v1/send_rendered" -H "authorization: Bearer $TOKEN" -H 'content-type: application/json' \
        -d '{"to":"ops@example.org","subject":"smoke","text":"hi","html":"<p>hi</p>","tag":"E01"}'
}
check "send before verify is refused" "$(send)" 403
# The verification code is emailed; with the fake provider read it from the DB.
VCODE="$("$PY" -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute("select verify_code from installs where install_id=?",("smoke-001",)).fetchone()[0])' "$RELAY_DB_PATH")"
check "verify via emailed GET link" "$(code "$B/v1/verify?install_id=smoke-001&code=$VCODE")" 200
check "send after verify" "$(send)" 200
check "revoke (admin)" "$(code -X POST "$B/v1/revoke" -H "x-admin-secret: $ADMIN_SECRET" -H 'content-type: application/json' -d '{"install_id":"smoke-001"}')" 200
check "send after revoke is rejected" "$(send)" 403
check "admin endpoint needs secret" "$(code "$B/v1/admin/installs")" 401
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
