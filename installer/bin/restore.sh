#!/usr/bin/env bash
# SentinelCore restore from a bin/backup.sh archive: verifies checksums, stops
# the app containers, recreates + restores the database, reports, ruleset,
# PCAPs (if present), certificates and the data-bound .env keys, then starts
# everything and waits until all services are healthy.
#
# Usage:
#   sudo /opt/sentinelcore/bin/restore.sh <archive.tar.gz> [--yes] [--keep-current-certs]
#
# Works on the same host or on a fresh install (backup → purge → reinstall →
# restore). This install's DB password, ports, NIC and TLS mode are kept.
set -euo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
ORIG_ARGS=("$@")
INSTALL_DIR="${INSTALL_DIR:-$(cd "$BIN/.." && pwd)}"
LIB="$INSTALL_DIR/lib"; [ -d "$LIB" ] || LIB="$BIN/../lib"
LOG_FILE="${LOG_FILE:-/var/log/sentinelcore-install.log}"
ARCHIVE=""; YES=0; RESTORE_CERTS=1

while [ $# -gt 0 ]; do
    case "$1" in
        --yes|-y) YES=1; shift ;;
        --keep-current-certs) RESTORE_CERTS=0; shift ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        -*) echo "unknown option: $1" >&2; exit 2 ;;
        *) ARCHIVE="$1"; shift ;;
    esac
done
[ -n "$ARCHIVE" ] || { echo "usage: restore.sh <archive.tar.gz> [--yes]" >&2; exit 2; }
[ "$(id -u)" -eq 0 ] || exec sudo -- "$0" "${ORIG_ARGS[@]}"
ARCHIVE="$(cd "$(dirname "$ARCHIVE")" && pwd)/$(basename "$ARCHIVE")"
# shellcheck disable=SC2034  # read by the sourced ui.sh prompts
NON_INTERACTIVE=$YES
export RESTORE_CERTS

# shellcheck source=../lib/ui.sh
. "$LIB/ui.sh"
# shellcheck source=../lib/config.sh
. "$LIB/config.sh"
# shellcheck source=../lib/services.sh
. "$LIB/services.sh"
# shellcheck source=../lib/rules.sh
. "$LIB/rules.sh"
# shellcheck source=../lib/backup.sh
. "$LIB/backup.sh"
init_log "$LOG_FILE"

[ -f "$INSTALL_DIR/.env" ] || { err "no SentinelCore install at $INSTALL_DIR — install first, then restore"; exit 1; }
# shellcheck disable=SC2034  # read by rules.sh start_sensor
CAPTURE_INTERFACE="$(env_get "$INSTALL_DIR/.env" CAPTURE_INTERFACE)"
step "SentinelCore restore"
warn "this REPLACES the current database, reports and ruleset with the backup's contents."
if [ "$YES" = 0 ]; then
    ask_yesno "Restore $ARCHIVE now?" n || { info "cancelled — nothing changed"; exit 0; }
fi
do_restore "$ARCHIVE"
