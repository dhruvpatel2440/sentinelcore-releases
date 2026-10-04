#!/usr/bin/env bash
# SentinelCore — enable email notifications after install (A6).
#
# Use when the relay was unreachable at install time, or email was declined.
# Registers this install with the SentinelCore relay, issues the install-local
# api.brevo.com certificate (CA key destroyed afterwards), switches .env to
# EMAIL_MODE=brevo and restarts the stack with the relay-shim.
#
# Usage:
#   sudo /opt/sentinelcore/enable-email.sh [--admin-email you@example.org]
#   /opt/sentinelcore/enable-email.sh --dry-run
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ORIG_ARGS=("$@")
LIB="$HERE/lib"; [ -d "$LIB" ] || LIB="$HERE/../installer/lib"
INSTALL_DIR="${INSTALL_DIR:-/opt/sentinelcore}"
PKG_DIR="$INSTALL_DIR"
LOG_FILE="${LOG_FILE:-/var/log/sentinelcore-install.log}"
DRY_RUN=0; NON_INTERACTIVE=0; ADMIN_EMAIL_ARG=""

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --admin-email) ADMIN_EMAIL_ARG="${2:?}"; shift 2 ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done
if [ "$DRY_RUN" = 0 ] && [ "$(id -u)" -ne 0 ]; then exec sudo -- "$0" "${ORIG_ARGS[@]}"; fi

# shellcheck source=lib/product.sh
. "$LIB/product.sh"
# shellcheck source=lib/ui.sh
. "$LIB/ui.sh"
# shellcheck source=lib/secrets.sh
. "$LIB/secrets.sh"
# shellcheck source=lib/config.sh
. "$LIB/config.sh"
# shellcheck source=lib/sensors.sh
. "$LIB/sensors.sh"
# shellcheck source=lib/relay.sh
. "$LIB/relay.sh"
# shellcheck source=lib/tls.sh
. "$LIB/tls.sh"
# shellcheck source=lib/services.sh
. "$LIB/services.sh"
init_log "$LOG_FILE"

step "Enable SentinelCore email notifications"
ENV_FILE="$INSTALL_DIR/.env"
if [ ! -f "$ENV_FILE" ]; then
    if [ "$DRY_RUN" = 1 ]; then warn "[dry-run] no $ENV_FILE — showing steps only"; else err "no install found ($ENV_FILE missing)"; exit 1; fi
fi

if [ "$(env_get "$ENV_FILE" EMAIL_MODE)" = brevo ] && [ -n "$(env_get "$ENV_FILE" BREVO_API_KEY)" ]; then
    good "email is already enabled (EMAIL_MODE=brevo)"; exit 0
fi

ADMIN_EMAIL="${ADMIN_EMAIL_ARG:-$(env_get "$ENV_FILE" SEED_ADMIN_EMAIL)}"
valid_email "$ADMIN_EMAIL" || { err "admin email unknown/invalid — pass --admin-email you@example.org"; exit 1; }
RELAY_URL="$(env_get "$ENV_FILE" RELAY_URL)"; RELAY_URL="${RELAY_URL:-$(. "$LIB/product.sh"; printf '%s' "$RELAY_URL")}"

EMAIL_MODE=brevo
relay_register
if [ "$EMAIL_MODE" != brevo ]; then err "email could not be enabled (relay unreachable or refused) — nothing changed"; exit 1; fi

gen_install_ca
if [ "$DRY_RUN" = 1 ]; then
    info "[dry-run] set EMAIL_MODE=brevo, COMPOSE_PROFILES=email, BREVO_API_KEY=<relay token>, EMAIL_SENDER_ADDRESS, RELAY_URL, RELAY_INSTALL_ID in .env"
    info "[dry-run] docker compose up -d (recreates backend/worker, starts relay-shim)"
    exit 0
fi
set_env_value "$ENV_FILE" EMAIL_MODE brevo
set_env_value "$ENV_FILE" COMPOSE_PROFILES email
set_env_value "$ENV_FILE" RELAY_URL "$RELAY_URL"
set_env_value "$ENV_FILE" RELAY_INSTALL_ID "$RELAY_INSTALL_ID"
set_env_value "$ENV_FILE" BREVO_API_KEY "$RELAY_TOKEN"
set_env_value "$ENV_FILE" EMAIL_SENDER_ADDRESS "$EMAIL_SENDER_ADDRESS"
good "updated $ENV_FILE (mode 600)"

xrun dc up -d --remove-orphans
wait_healthy
good "email enabled. Click the verification link sent to $ADMIN_EMAIL to activate sending."
