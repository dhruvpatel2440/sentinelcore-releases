#!/usr/bin/env bash
# SentinelCore uninstaller. Removes SentinelCore's firewall rules (through the
# helper's own fw_reconcile op first), the SENTINELCORE chain, the boot units
# (stack, promiscuous mode — reverting promisc —, nightly backup) and the
# containers. With --purge it also removes data volumes, .env, all TLS
# material and the install dir; it asks before deleting backups.
#
# Usage:
#   sudo ./uninstall.sh                  stop + remove containers (keep data)
#   sudo ./uninstall.sh --purge          also remove volumes, .env, certificates, install dir
#   sudo ./uninstall.sh --purge --yes    no prompts (backups are KEPT, moved aside)
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
# shellcheck source=lib/backup.sh
. "$LIB/backup.sh"
init_log "$LOG_FILE"

step "SentinelCore uninstall"
[ -d "$INSTALL_DIR" ] || warn "no install directory at $INSTALL_DIR (cleaning up leftovers only)"

if ! ask_yesno "Stop and remove SentinelCore$([ "$PURGE" = 1 ] && echo ' AND DELETE ALL DATA')?" y; then
    info "aborted — nothing changed"; exit 0
fi
if [ "$PURGE" = 1 ] && [ "$NON_INTERACTIVE" = 0 ] && [ "$DRY_RUN" = 0 ]; then
    warn "PURGE permanently deletes SentinelCore data (DB, pcaps, reports), .env and TLS material."
    ask_yesno "Really delete everything under $INSTALL_DIR and all data volumes?" n || { info "purge cancelled — nothing changed"; exit 0; }
fi

HAVE_STACK=0
[ -f "$INSTALL_DIR/docker-compose.yml" ] && command -v docker >/dev/null 2>&1 && HAVE_STACK=1
[ "$DRY_RUN" = 1 ] && HAVE_STACK=1   # preview every step
CHAIN=SENTINELCORE

# 1) Firewall: let the helper remove its own rules (fw_reconcile with an empty
#    expected set deletes every managed rule), then drop the chain from INSIDE
#    the helper so the same iptables backend (nft/legacy) is used.
if [ "$HAVE_STACK" = 1 ]; then
    step "Remove SentinelCore firewall rules"
    if [ "$DRY_RUN" = 1 ]; then
        info "[dry-run] backend: helper_client.call('fw_reconcile', {'expected': []})  (helper's own op)"
        info "[dry-run] stop worker + backend (no more expiry/reconcile loops)"
        info "[dry-run] helper: iptables -D INPUT/FORWARD -j $CHAIN (repeat); iptables -F $CHAIN; iptables -X $CHAIN"
    else
        if dc exec -T backend python -c "import asyncio
from app.services import helper_client
r = asyncio.run(helper_client.call('fw_reconcile', {'expected': []}, timeout=60))
print('removed', len(r.get('orphans_removed', [])), 'managed rule set(s)')" 2>/dev/null; then
            good "helper removed its firewall rules"
        else
            warn "helper not reachable — falling back to iptables"
        fi
        dc stop worker backend >/dev/null 2>&1 || true
        # shellcheck disable=SC2016
        dc exec -T helper sh -c 'for p in INPUT FORWARD OUTPUT; do while iptables -D "$p" -j SENTINELCORE 2>/dev/null; do :; done; done; iptables -F SENTINELCORE 2>/dev/null; iptables -X SENTINELCORE 2>/dev/null; true' \
            >/dev/null 2>&1 || true
    fi
fi

# 2) Boot units first so systemd does not restart the stack mid-teardown.
if [ -f "$SYSTEMD_UNIT" ] || [ "$DRY_RUN" = 1 ]; then
    xrun as_root systemctl disable --now sentinelcore.service || true
    xrun as_root rm -f "$SYSTEMD_UNIT"
fi
remove_backup_timer

# 3) Containers (+ volumes on purge). The overlays are picked up by dc().
if [ "$HAVE_STACK" = 1 ]; then
    if [ "$PURGE" = 1 ]; then xrun dc down -v --remove-orphans || true
    else xrun dc down --remove-orphans || true; fi
else
    warn "no compose file — skipping container teardown"
fi
if [ "$PURGE" = 1 ] && command -v docker >/dev/null 2>&1; then
    for v in $(as_root docker volume ls -q --filter label=com.docker.compose.project=sentinelcore 2>/dev/null); do
        xrun as_root docker volume rm "$v" || true
    done
fi

# 4) Promiscuous mode: ExecStop of the unit turns promisc off, then remove it.
remove_promisc_unit
iface="$(env_get "$INSTALL_DIR/.env" CAPTURE_INTERFACE)"
if [ -n "$iface" ] && command -v ip >/dev/null 2>&1 && ip link show "$iface" 2>/dev/null | grep -q PROMISC; then
    xrun as_root ip link set dev "$iface" promisc off || true
fi

# 5) Host-side fallback for the chain (all iptables front-ends present).
if [ "$DRY_RUN" = 1 ]; then
    info "[dry-run] fallback on the host: iptables / iptables-nft / iptables-legacy -D/-F/-X $CHAIN"
else
    for ipt in iptables iptables-nft iptables-legacy; do
        command -v "$ipt" >/dev/null 2>&1 || continue
        for parent in INPUT FORWARD OUTPUT; do
            while as_root "$ipt" -D "$parent" -j "$CHAIN" 2>/dev/null; do :; done
        done
        as_root "$ipt" -F "$CHAIN" 2>/dev/null || true
        as_root "$ipt" -X "$CHAIN" 2>/dev/null || true
    done
    left=0
    for ipt in iptables iptables-nft iptables-legacy; do
        command -v "$ipt" >/dev/null 2>&1 && as_root "$ipt" -S "$CHAIN" >/dev/null 2>&1 && left=1
    done
    if [ "$left" = 1 ]; then warn "chain $CHAIN still present — check: sudo iptables -S $CHAIN"; else good "firewall chain $CHAIN removed"; fi
fi
xrun as_root systemctl daemon-reload || true

# 6) Files.
if [ "$PURGE" = 1 ]; then
    if [ -d "$INSTALL_DIR/backups" ] && [ -n "$(ls -A "$INSTALL_DIR/backups" 2>/dev/null)" ]; then
        keep_to="/root/sentinelcore-backups-$(date -u +%Y%m%dT%H%M%SZ)"
        if [ "$NON_INTERACTIVE" = 0 ] && [ "$DRY_RUN" = 0 ] && ask_yesno "Also DELETE the backups in $INSTALL_DIR/backups?" n; then
            xrun as_root rm -rf "$INSTALL_DIR/backups"
        else
            xrun as_root mv "$INSTALL_DIR/backups" "$keep_to"
            info "backups kept at $keep_to (they contain secrets — store them safely)"
        fi
    fi
    if [ -d "$INSTALL_DIR" ] || [ "$DRY_RUN" = 1 ]; then
        run_sh "shred -u '$INSTALL_DIR/.env' 2>/dev/null || rm -f '$INSTALL_DIR/.env'"
        run_sh "find '$INSTALL_DIR' -type f -name '*.key' -exec shred -u {} + 2>/dev/null || true"
        xrun as_root rm -rf "$INSTALL_DIR/tls" "$INSTALL_DIR/tls-web" "$INSTALL_DIR/ca.crt" "$INSTALL_DIR/tls-web-ca.crt" "$INSTALL_DIR/ca-bundle.pem"
        xrun as_root rm -rf "$INSTALL_DIR"
    fi
    good "purged: containers, volumes, units, promisc, firewall chain, .env, certificates, $INSTALL_DIR"
else
    good "containers stopped and units removed; data volumes, certificates and $INSTALL_DIR/.env kept"
    info "bring it back with ./install.sh -> Repair (keeps data), or remove everything with --purge"
fi
good "uninstall complete"
