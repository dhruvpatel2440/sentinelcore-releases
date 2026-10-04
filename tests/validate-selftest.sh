#!/usr/bin/env bash
# Dependency-free smoke mirror of installer.bats (for hosts without bats).
# shellcheck disable=SC2034,SC1091
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
DRY_RUN=0; NON_INTERACTIVE=1
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
LOG_FILE="$TMP/install.log"
. "$REPO/installer/lib/product.sh"
. "$REPO/installer/lib/ui.sh"
init_log "$LOG_FILE"
. "$REPO/installer/lib/secrets.sh"
. "$REPO/installer/lib/config.sh"

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
yes()  { if "$@" >/dev/null 2>&1; then ok "$*"; else bad "$*"; fi; }
no()   { if "$@" >/dev/null 2>&1; then bad "NOT($*)"; else ok "NOT($*)"; fi; }

echo "validators:"
yes valid_email "admin@example.org"
no  valid_email "not-an-email"
yes valid_username "net_ops-1"
no  valid_username "1abc"
yes strong_password "Sentinel1Core2!"
yes strong_password "Mix'\"\$\\ |&X6yzzz"
no  strong_password "short1A"
yes valid_cidr "10.20.0.0/24"
no  valid_cidr "10.20.0.0"
no  valid_ipv4 "999.1.1.1"
yes valid_port "8080"
no  valid_port "70000"
yes valid_protected_ips "10.0.0.1,10.0.0.2"
no  valid_protected_ips "10.0.0.1,nope"

echo "config loader (A8):"
printf 'a[$(touch %s/pwned)]=x\n' "$TMP" > "$TMP/evil.conf"
no load_config_file "$TMP/evil.conf"
[ ! -e "$TMP/pwned" ] && ok "injection key not executed" || bad "injection key executed"

echo "render_env:"
ADMIN_EMAIL="admin@example.org"; ADMIN_USERNAME="admin"
MONITORED_NETWORK="10.20.0.0/24"; PROTECTED_IPS="10.20.0.1"; CAPTURE_INTERFACE="eth1"
EMAIL_MODE="off"; APP_BASE_URL="http://127.0.0.1:8080"; BIND_ADDRESS="127.0.0.1"; WEB_PORT="8080"
RELAY_URL="https://relay.example.org"
render_env "$REPO/build/overlay/templates/.env.template" "$TMP/.env" >/dev/null 2>&1
[ -f "$TMP/.env" ] && ok "wrote .env" || bad "wrote .env"
grep -vE '^\s*#' "$TMP/.env" | grep -Eq '__[A-Z_]+__' && bad "placeholders remain" || ok "no placeholders remain"
grep -qx "WEB_PORT=8080" "$TMP/.env" && ok "WEB_PORT rendered" || bad "WEB_PORT rendered"
grep -qx "BIND_ADDRESS=127.0.0.1" "$TMP/.env" && ok "BIND_ADDRESS rendered" || bad "BIND_ADDRESS rendered"
grep -Eq "SECRET_KEY=[0-9a-f]{64}" "$TMP/.env" && ok "SECRET_KEY generated" || bad "SECRET_KEY generated"
grep -Eq '^SEED_ADMIN_PASSWORD=' "$TMP/.env" && bad "admin password leaked to .env" || ok "admin password NOT in .env"

echo "redaction:"
for v in "${SECRETS[@]}"; do grep -qF -- "$v" "$LOG_FILE" && bad "secret in log"; done
ok "no generated secret in log"

echo
printf 'RESULT: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
