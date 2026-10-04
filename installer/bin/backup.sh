#!/usr/bin/env bash
# SentinelCore backup: database (pg_dump), .env, certificates, reports, live
# ruleset (+ PCAPs with --with-pcaps) into ONE tar.gz (mode 600) + .sha256.
#
# Usage:
#   sudo /opt/sentinelcore/bin/backup.sh [--with-pcaps] [--out DIR] [--keep N] [--quiet]
#
# The archive CONTAINS SECRETS (.env: DB password, SECRET_KEY, relay token;
# TLS private keys). Store it like a password: offline, encrypted, access-controlled.
set -euo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
ORIG_ARGS=("$@")
INSTALL_DIR="${INSTALL_DIR:-$(cd "$BIN/.." && pwd)}"
LIB="$INSTALL_DIR/lib"; [ -d "$LIB" ] || LIB="$BIN/../lib"
LOG_FILE="${LOG_FILE:-/var/log/sentinelcore-install.log}"
OUT=""; PCAPS=0; KEEP=""; QUIET=0

while [ $# -gt 0 ]; do
    case "$1" in
        --with-pcaps) PCAPS=1; shift ;;
        --out) OUT="${2:?}"; shift 2 ;;
        --keep) KEEP="${2:?}"; shift 2 ;;
        --quiet) QUIET=1; shift ;;
        -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done
[ "$(id -u)" -eq 0 ] || exec sudo -- "$0" "${ORIG_ARGS[@]}"

# shellcheck source=../lib/ui.sh
. "$LIB/ui.sh"
# shellcheck source=../lib/config.sh
. "$LIB/config.sh"
# shellcheck source=../lib/services.sh
. "$LIB/services.sh"
# shellcheck source=../lib/backup.sh
. "$LIB/backup.sh"
init_log "$LOG_FILE"
OUT="${OUT:-$BACKUP_DIR_DEFAULT}"

[ -f "$INSTALL_DIR/.env" ] || { err "no SentinelCore install at $INSTALL_DIR"; exit 1; }
[ "$QUIET" = 1 ] || step "SentinelCore backup"
archive="$(do_backup "$OUT" "$PCAPS")"
good "backup written: $archive ($(du -h "$archive" | cut -f1)), checksum: $archive.sha256"
[ -n "$KEEP" ] && prune_backups "$OUT" "$KEEP"
if [ "$QUIET" = 0 ]; then
    warn "this archive contains secrets (.env, TLS keys) — keep it offline and access-controlled."
    info "restore with: sudo $INSTALL_DIR/bin/restore.sh $archive"
fi
