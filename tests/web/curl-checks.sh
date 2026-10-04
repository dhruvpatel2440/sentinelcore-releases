#!/usr/bin/env bash
# Web-layer checks against an INSTALLED SentinelCore (Phase 11):
#   443 serves the UI, 80 redirects to HTTPS, /api/health ok, security headers,
#   /api/docs hidden (production), refresh cookie Secure+HttpOnly+Path=/api/auth,
#   upload limit only on /api/pcap/upload.
#
# Usage: tests/web/curl-checks.sh <host> [https_port=443] [http_port=80]
#   SC_USER / SC_PASS (env) enable the login + cookie check (test account).
#   CACERT=/opt/sentinelcore/tls-web-ca.crt verifies the self-signed chain
#   (default: --insecure, which only skips trust, not TLS).
set -uo pipefail

HOST="${1:?usage: curl-checks.sh <host> [https_port] [http_port]}"
SP="${2:-443}"; HP="${3:-80}"
BASE="https://$HOST:$SP"
TLS=(--insecure); [ -n "${CACERT:-}" ] && TLS=(--cacert "$CACERT")
pass=0; fail=0
ok()  { printf '  PASS  %s\n' "$*"; pass=$((pass + 1)); }
bad() { printf '  FAIL  %s\n' "$*"; fail=$((fail + 1)); }
hdrs() { curl -sS -o /dev/null -D - --max-time 10 "${TLS[@]}" "$@" | tr -d '\r'; }

echo "== web checks: $BASE (redirect from :$HP) =="

code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "${TLS[@]}" "$BASE/")"
[ "$code" = 200 ] && ok "UI over HTTPS (200)" || bad "UI over HTTPS returned $code"
curl -sS --max-time 10 "${TLS[@]}" "$BASE/" | grep -q '<div id="root">' && ok "index.html is the React app" || bad "index.html not served"

loc="$(curl -sS -o /dev/null -D - --max-time 10 "http://$HOST:$HP/some/path?x=1" | tr -d '\r' | sed -n 's/^[Ll]ocation: //p')"
exp="https://$HOST$([ "$SP" = 443 ] || printf ':%s' "$SP")/some/path?x=1"
[ "$loc" = "$exp" ] && ok "HTTP redirects to $exp" || bad "HTTP redirect went to '$loc' (want $exp)"

code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "${TLS[@]}" "$BASE/api/health")"
[ "$code" = 200 ] && ok "/api/health 200" || bad "/api/health returned $code"

code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "${TLS[@]}" "$BASE/api/docs")"
[ "$code" = 404 ] && ok "/api/docs hidden in production (404)" || bad "/api/docs returned $code (should be 404)"
code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "${TLS[@]}" "$BASE/api/openapi.json")"
[ "$code" = 404 ] && ok "/api/openapi.json hidden (404)" || bad "/api/openapi.json returned $code"

h="$(hdrs "$BASE/")"
for want in "content-security-policy: default-src 'self'" "x-frame-options: DENY" "x-content-type-options: nosniff" "referrer-policy: no-referrer"; do
    printf '%s\n' "$h" | grep -qi "^$want" && ok "header ${want%%:*}" || bad "header missing: $want"
done
printf '%s\n' "$h" | grep -qi '^server: nginx/' && bad "server version disclosed" || ok "no nginx version in Server header"

# TLS protocol floor.
if command -v openssl >/dev/null 2>&1; then
    if echo | openssl s_client -connect "$HOST:$SP" -tls1_1 >/dev/null 2>&1; then bad "TLS 1.1 accepted"; else ok "TLS 1.1 refused"; fi
    echo | openssl s_client -connect "$HOST:$SP" -tls1_2 >/dev/null 2>&1 && ok "TLS 1.2 accepted" || bad "TLS 1.2 refused"
fi

# Upload limit applies only to the PCAP endpoint: a 25 MB body elsewhere -> 413.
big="$(mktemp)"; head -c $((25 * 1024 * 1024)) /dev/zero > "$big"
code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 60 "${TLS[@]}" -X POST --data-binary @"$big" "$BASE/api/auth/login")"
[ "$code" = 413 ] && ok "25 MB body to /api/auth/login refused by nginx (413)" || bad "25 MB body to /api/auth/login returned $code"
code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 60 "${TLS[@]}" -X POST -F "file=@$big;filename=x.pcap" "$BASE/api/pcap/upload")"
[ "$code" != 413 ] && ok "25 MB body to /api/pcap/upload passes nginx (HTTP $code from the API)" || bad "/api/pcap/upload capped below 25 MB"
rm -f "$big"

if [ -n "${SC_USER:-}" ] && [ -n "${SC_PASS:-}" ]; then
    body="$(python3 -c 'import json,os; print(json.dumps({"username": os.environ["SC_USER"], "password": os.environ["SC_PASS"]}))')"
    h="$(printf '%s' "$body" | curl -sS -o /dev/null -D - --max-time 15 "${TLS[@]}" -H 'content-type: application/json' --data-binary @- "$BASE/api/auth/login" | tr -d '\r')"
    c="$(printf '%s\n' "$h" | grep -i '^set-cookie:' | grep -i 'path=/api/auth' | head -1)"
    if [ -n "$c" ] && printf '%s' "$c" | grep -qi secure && printf '%s' "$c" | grep -qi httponly; then ok "refresh cookie: Secure; HttpOnly; Path=/api/auth"
    else bad "refresh cookie flags wrong: ${c:-<none>}"; fi
fi

echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
