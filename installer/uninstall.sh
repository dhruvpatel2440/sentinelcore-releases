#!/usr/bin/env bash
# SentinelCore uninstaller. Stops the stack and removes the boot units, the
# promiscuous-mode unit (reverting promisc) and the SENTINELCORE firewall
# chain. With --purge it also removes data volumes, .env, the TLS material
# and the whole install dir. Always asks before anything destructive.
#
# Usage:
#   sudo ./uninstall.sh                  stop + remove containers (keep data)
#   sudo ./uninstall.sh --purge          also remove volumes, .env, CA/tls, install dir
#   sudo ./uninstall.sh --purge --yes    no prompts (automation)
#   ./uninstall.sh --dry-run             print actions, change nothing
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ORIG_ARGS=("$@")
LIB="$HERE/lib"; [ -d "$LIB" ] || LIB="$HERE/../installer/lib"
INSTALL_DIR="${INSTALL_DIR:-/opt/sentinelcore}"
LOG_FILE="${LOG_FILE:-/var/log/sentinelcore-install.log}"
DRY_RUN=0; PURGE=0; NON_INTERACTIVE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --purge) PURGE=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --yes|-y|--non-interactive) NON_INTERACTIVE=1; shift ;;
        -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

if [ "$DRY_RUN" = 0 ] && [ "$(id -u)" -ne 0 ]; then exec sudo -- "$0" "${ORIG_ARGS[@]}"; fi

# shellcheck source=lib/ui.sh
. "$LIB/ui.sh"
# shellcheck source=lib/config.sh
. "$LIB/config.sh"
# shellcheck source=lib/sensors.sh
. "$LIB/sensors.sh"
# shellcheck source=lib/services.sh
. "$LIB/services.sh"
init_log "$LOG_FILE"

step "SentinelCore uninstall"
[ -d "$INSTALL_DIR" ] || warn "no install directory at $INSTALL_DIR (cleaning up leftovers only)"

ask_default=y
if ! ask_yesno "Stop and remove SentinelCore containers$([ "$PURGE" = 1 ] && echo ' AND DELETE ALL DATA')?" "$ask_default"; then
    info "aborted — nothing changed"; exit 0
fi
if [ "$PURGE" = 1 ] && [ "$NON_INTERACTIVE" = 0 ] && [ "$DRY_RUN" = 0 ]; then
    warn "PURGE permanently deletes SentinelCore data (DB, pcaps, reports), .env and TLS material."
    ask_yesno "Really delete everything under $INSTALL_DIR and all data volumes?" n || { info "purge cancelled — nothing changed"; exit 0; }
fi

# 1) Boot unit first so systemd does not restart the stack mid-teardown.
if [ -f "$SYSTEMD_UNIT" ] || [ "$DRY_RUN" = 1 ]; then
    xrun as_root systemctl disable --now sentinelcore.service || true
    xrun as_root rm -f "$SYSTEMD_UNIT"
fi

# 2) Containers (+ volumes on purge). --profile email also catches relay-shim.
if [ -f "$INSTALL_DIR/docker-compose.yml" ] && command -v docker >/dev/null 2>&1; then
    if [ "$PURGE" = 1 ]; then xrun dc --profile email down -v --remove-orphans || true
    else xrun dc --profile email down --remove-orphans || true; fi
else
    warn "no compose file — skipping container teardown"
fi
if [ "$PURGE" = 1 ] && command -v docker >/dev/null 2>&1; then
    # Volumes left behind by an earlier, differently-located install.
    for v in $(as_root docker volume ls -q --filter label=com.docker.compose.project=sentinelcore 2>/dev/null); do
        xrun as_root docker volume rm "$v" || true
    done
fi

# 3) Promiscuous mode: ExecStop of the unit turns promisc off, then remove it.
remove_promisc_unit
iface="$(env_get "$INSTALL_DIR/.env" CAPTURE_INTERFACE)"
if [ -n "$iface" ] && command -v ip >/dev/null 2>&1 && ip link show "$iface" 2>/dev/null | grep -q PROMISC; then
    xrun as_root ip link set dev "$iface" promisc off || true
fi

# 4) Firewall chain. The helper has no teardown op (it rebuilds the chain on
#    start), so remove its jumps from INPUT/FORWARD, then flush + delete.
if command -v iptables >/dev/null 2>&1; then
    info "removing iptables chain SENTINELCORE (if present)"
    if [ "$DRY_RUN" = 1 ]; then
        info "[dry-run] iptables -D INPUT/FORWARD -j SENTINELCORE (repeat); iptables -F SENTINELCORE; iptables -X SENTINELCORE"
    else
        for parent in INPUT FORWARD OUTPUT; do
            while as_root iptables -D "$parent" -j SENTINELCORE 2>/dev/null; do :; done
        done
        as_root iptables -F SENTINELCORE 2>/dev/null || true
        as_root iptables -X SENTINELCORE 2>/dev/null || true
        if as_root iptables -S SENTINELCORE >/dev/null 2>&1; then warn "SENTINELCORE chain still present"; else good "firewall chain removed"; fi
    fi
fi
xrun as_root systemctl daemon-reload || true

# 5) Files.
if [ "$PURGE" = 1 ]; then
    if [ -d "$INSTALL_DIR" ] || [ "$DRY_RUN" = 1 ]; then
        run_sh "shred -u '$INSTALL_DIR/.env' 2>/dev/null || rm -f '$INSTALL_DIR/.env'"
        run_sh "find '$INSTALL_DIR/tls' -type f -name '*.key' -exec shred -u {} + 2>/dev/null || true"
        xrun as_root rm -rf "$INSTALL_DIR/tls" "$INSTALL_DIR/ca.crt" "$INSTALL_DIR/ca-bundle.pem"
        xrun as_root rm -rf "$INSTALL_DIR"
    fi
    good "purged: containers, volumes, units, promisc, firewall chain, .env, CA/tls, $INSTALL_DIR"
else
    good "containers stopped and units removed; data volumes and $INSTALL_DIR/.env kept"
    info "bring it back with ./install.sh -> Repair (keeps data), or remove everything with --purge"
fi
good "uninstall complete"
