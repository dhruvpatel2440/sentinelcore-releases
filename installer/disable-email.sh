#!/usr/bin/env bash
# SentinelCore — turn email notifications OFF without reinstalling.
#
# Removes the email overlay (relay-shim, CA bundle mount, SSL_CERT_FILE),
# shreds the shim's TLS key, clears the per-install relay token and sets
# EMAIL_MODE=off. The app keeps working fully; turn it back on with
# enable-email.sh (re-registers with the relay).
#
# Usage:
#   sudo /opt/sentinelcore/disable-email.sh [--yes]
#   /opt/sentinelcore/disable-email.sh --dry-run
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ORIG_ARGS=("$@")
LIB="$HERE/lib"; [ -d "$LIB" ] || LIB="$HERE/../installer/lib"
INSTALL_DIR="${INSTALL_DIR:-/opt/sentinelcore}"
LOG_FILE="${LOG_FILE:-/var/log/sentinelcore-install.log}"
DRY_RUN=0; NON_INTERACTIVE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --yes|-y) NON_INTERACTIVE=1; shift ;;
        -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done
if [ "$DRY_RUN" = 0 ] && [ "$(id -u)" -ne 0 ]; then exec sudo -- "$0" "${ORIG_ARGS[@]}"; fi

# shellcheck source=lib/ui.sh
. "$LIB/ui.sh"
# shellcheck source=lib/config.sh
. "$LIB/config.sh"
# shellcheck source=lib/services.sh
. "$LIB/services.sh"
init_log "$LOG_FILE"

step "Disable SentinelCore email notifications"
ENV_FILE="$INSTALL_DIR/.env"
if [ ! -f "$ENV_FILE" ] && [ "$DRY_RUN" = 0 ]; then err "no install found ($ENV_FILE missing)"; exit 1; fi
if [ "$(env_get "$ENV_FILE" EMAIL_MODE)" != brevo ] && [ ! -f "$INSTALL_DIR/docker-compose.email.yml" ] && [ "$DRY_RUN" = 0 ]; then
    good "email is already off"; exit 0
fi
ask_yesno "Turn email notifications off (relay-shim stopped, relay token removed)?" y || { info "cancelled — nothing changed"; exit 0; }

if [ "$DRY_RUN" = 1 ]; then
    info "[dry-run] set EMAIL_MODE=off and clear BREVO_API_KEY / EMAIL_SENDER_ADDRESS in .env"
    info "[dry-run] remove docker-compose.email.yml; shred tls/*.key; remove tls/, ca.crt, ca-bundle.pem"
    info "[dry-run] docker compose up -d --remove-orphans (relay-shim removed, backend/worker recreated without SSL_CERT_FILE)"
    info "[dry-run] rewrite $SYSTEMD_UNIT without the email overlay"
    exit 0
fi

set_env_value "$ENV_FILE" EMAIL_MODE off
set_env_value "$ENV_FILE" BREVO_API_KEY ""
set_env_value "$ENV_FILE" EMAIL_SENDER_ADDRESS ""
as_root rm -f "$INSTALL_DIR/docker-compose.email.yml"
as_root find "$INSTALL_DIR/tls" -type f -name '*.key' -exec shred -u {} + 2>/dev/null || true
as_root rm -rf "$INSTALL_DIR/tls" "$INSTALL_DIR/ca.crt" "$INSTALL_DIR/ca-bundle.pem"
good "email overlay, shim certificate and relay token removed"

xrun dc up -d --remove-orphans
wait_healthy
install_systemd_unit
good "email notifications are OFF. Re-enable any time: sudo $INSTALL_DIR/enable-email.sh"
