#!/usr/bin/env bash
# SentinelCore guided installer.
#
# Usage:
#   sudo ./install.sh                      guided TUI (whiptail, or plain-text)
#   ./install.sh --dry-run                 print every action, change nothing
#   sudo ./install.sh --non-interactive --config FILE   automated install
#   sudo ./install.sh --uninstall [--purge]             delegate to uninstall.sh
#   ./install.sh --help
#
# Safety: set -euo pipefail; a failed or interrupted FRESH install is rolled
# back (containers, volumes it created, units, install dir). Redacted log at
# /var/log/sentinelcore-install.log (mode 600). An existing install offers
# Repair / Upgrade / Abort and never overwrites .env or data. No curl|bash,
# no telemetry; the only outbound call is the SentinelCore email relay.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ORIG_ARGS=("$@")

# The package root (templates/, images/, docs/). In the dev tree, fall back to
# build/overlay so --dry-run works from a checkout.
if [ -d "$HERE/templates" ]; then PKG_DIR="$HERE"; else PKG_DIR="$HERE/../build/overlay"; fi
LIB="$HERE/lib"
TEMPLATE_ENV="$PKG_DIR/templates/.env.template"
INSTALL_DIR="${INSTALL_DIR:-/opt/sentinelcore}"
LOG_FILE="${LOG_FILE:-/var/log/sentinelcore-install.log}"
MARKER=".install-complete"

DRY_RUN=0
NON_INTERACTIVE=0
CONFIG_FILE=""
EMAIL_MODE=""            # empty = not chosen yet (wizard default: yes)
MODE_EXISTING=""         # repair | upgrade (existing install)
FRESH_STARTED=0          # a fresh install began changing the system
VOLUMES_PREEXISTED=0
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
ADMIN_PASSWORD_GENERATED=0
PROMISC_CONSENT=0

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --non-interactive) NON_INTERACTIVE=1; shift ;;
        --config) CONFIG_FILE="${2:?--config needs a file}"; shift 2 ;;
        --uninstall) shift; exec "$HERE/uninstall.sh" "$@" ;;
        -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
        *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
    esac
done

# Real installs run as root (one sudo prompt up front, not one per step).
if [ "$DRY_RUN" = 0 ] && [ "$(id -u)" -ne 0 ]; then
    command -v sudo >/dev/null 2>&1 || { echo "run as root (sudo not found)" >&2; exit 1; }
    exec sudo -- "$0" "${ORIG_ARGS[@]}"
fi

# shellcheck source=lib/product.sh
. "$LIB/product.sh"
# shellcheck source=lib/ui.sh
. "$LIB/ui.sh"
# shellcheck source=lib/checks.sh
. "$LIB/checks.sh"
# shellcheck source=lib/secrets.sh
. "$LIB/secrets.sh"
# shellcheck source=lib/config.sh
. "$LIB/config.sh"
# shellcheck source=lib/sensors.sh
. "$LIB/sensors.sh"
# shellcheck source=lib/deps.sh
. "$LIB/deps.sh"
# shellcheck source=lib/relay.sh
. "$LIB/relay.sh"
# shellcheck source=lib/tls.sh
. "$LIB/tls.sh"
# shellcheck source=lib/services.sh
. "$LIB/services.sh"
# shellcheck source=lib/admin.sh
. "$LIB/admin.sh"
init_log "$LOG_FILE"

on_interrupt() { echo; err "interrupted by user"; exit 130; }
trap on_interrupt INT TERM

rollback_fresh_install() {
    warn "rolling back the incomplete install..."
    if [ -f "$INSTALL_DIR/docker-compose.yml" ] && [ -f "$INSTALL_DIR/.env" ]; then
        if [ "$VOLUMES_PREEXISTED" = 1 ]; then
            dc down --remove-orphans >/dev/null 2>&1 || true
            warn "kept pre-existing data volumes (they belonged to an earlier install)"
        else
            dc --profile email down -v --remove-orphans >/dev/null 2>&1 || true
        fi
    fi
    remove_promisc_unit >/dev/null 2>&1 || true
    as_root rm -f "$SYSTEMD_UNIT" 2>/dev/null || true
    as_root systemctl daemon-reload 2>/dev/null || true
    [ -f "$INSTALL_DIR/.env" ] && { as_root shred -u "$INSTALL_DIR/.env" 2>/dev/null || true; }
    as_root rm -rf "$INSTALL_DIR"
    good "rolled back: no containers, units or files from this attempt remain"
}

cleanup() {
    local rc=$?
    trap - INT TERM
    [ "$rc" -eq 0 ] && return 0
    [ "$DRY_RUN" = 1 ] && return 0
    err "install did not complete (exit $rc). Log: $LOG_FILE"
    if [ "$FRESH_STARTED" = 1 ]; then
        rollback_fresh_install || true
        info "fix the problem above and re-run: sudo ./install.sh"
    elif [ -n "$MODE_EXISTING" ]; then
        warn "existing install kept as-is (.env and data untouched). Re-run and choose Repair."
    else
        info "nothing was changed on this system."
    fi
}
trap cleanup EXIT

if [ -n "$CONFIG_FILE" ]; then load_config_file "$CONFIG_FILE" || exit 2; fi
if [ -n "$EMAIL_MODE" ] && ! valid_email_mode "$EMAIL_MODE"; then err "EMAIL_MODE must be off or brevo"; exit 2; fi

welcome() {
    step "SentinelCore installer"
    info "version: $(pkg_version)$([ "${RELEASE_FLAVOR:-dev}" = release ] || printf ' (%s build)' "${RELEASE_FLAVOR:-dev}")"
    info "This installs the SentinelCore stack (Docker Compose) on this host."
    info "Notice: lab/authorized-network use only. No telemetry. Log: $LOG_FILE"
    verify_package
}

detect_existing() {
    [ -f "$INSTALL_DIR/.env" ] || return 0
    local choice
    if [ ! -f "$INSTALL_DIR/$MARKER" ]; then
        warn "an earlier install at $INSTALL_DIR did not complete"
        choice=fresh
        ask_menu choice "A previous installation attempt did not finish. What would you like to do?" \
            fresh "Start over — remove the incomplete install and install fresh" \
            abort "Abort — make no changes" || choice=abort
        [ "$choice" = abort ] && { info "aborting at operator request"; exit 0; }
        if [ "$DRY_RUN" = 1 ]; then info "[dry-run] would remove the incomplete install"; return 0; fi
        FRESH_STARTED=1; VOLUMES_PREEXISTED=0
        rollback_fresh_install
        FRESH_STARTED=0
        return 0
    fi
    warn "existing install detected at $INSTALL_DIR (version $(cat "$INSTALL_DIR/VERSION" 2>/dev/null || echo '?'))"
    choice=repair
    ask_menu choice "SentinelCore is already installed. What would you like to do?" \
        repair "Repair — re-apply config & restart services (keeps .env + data)" \
        upgrade "Upgrade — load this package's images & recreate containers (keeps .env + data)" \
        abort "Abort — make no changes" || choice=abort
    case "$choice" in
        repair)  MODE_EXISTING=repair ;;
        upgrade) MODE_EXISTING=upgrade ;;
        *) info "aborting at operator request"; exit 0 ;;
    esac
    warn "$MODE_EXISTING mode: .env and data volumes are kept"
}

check_stale_volumes() {
    [ "$DRY_RUN" = 1 ] && return 0
    if as_root docker volume inspect sentinelcore_postgres_data >/dev/null 2>&1; then
        warn "a SentinelCore database volume from an earlier install exists (sentinelcore_postgres_data)"
        if ask_yesno "Re-use it (keeps old data; the admin password will be set to the one you choose)?" y; then
            VOLUMES_PREEXISTED=1
        else
            err "remove it first with: sudo docker volume rm sentinelcore_postgres_data (DELETES old data)"; exit 1
        fi
    fi
}

backfill_env() {
    # Upgrades from older packages: add keys this version's compose needs,
    # never changing an existing value.
    local k v
    for k in RELAY_URL BIND_ADDRESS WEB_PORT COMPOSE_PROFILES; do
        grep -q "^$k=" "$INSTALL_DIR/.env" && continue
        case "$k" in
            RELAY_URL) v="$RELAY_URL" ;;
            BIND_ADDRESS) v="127.0.0.1" ;;
            WEB_PORT) v="80" ;;
            COMPOSE_PROFILES) v="$([ "$(env_get "$INSTALL_DIR/.env" EMAIL_MODE)" = brevo ] && echo email)" ;;
        esac
        if [ "$DRY_RUN" = 1 ]; then info "[dry-run] add missing $k to .env"; else set_env_value "$INSTALL_DIR/.env" "$k" "$v"; info "added missing $k to .env"; fi
    done
}

mark_complete() {
    [ "$DRY_RUN" = 1 ] && return 0
    printf 'version=%s\ncompleted=%s\n' "$(pkg_version)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" | as_root tee "$INSTALL_DIR/$MARKER" >/dev/null
}

existing_flow() {
    load_existing_env "$INSTALL_DIR/.env"
    backfill_env
    stage_install_dir
    load_images
    compose_up
    wait_healthy
    install_systemd_unit
    mark_complete
    final_screen
}

fresh_flow() {
    check_stale_volumes
    sensor_step
    collect_config
    validate_config || { err "please correct the inputs and re-run"; exit 1; }
    relay_register

    FRESH_STARTED=1
    xrun as_root install -d -m 0755 "$INSTALL_DIR"
    render_env "$TEMPLATE_ENV" "$INSTALL_DIR/.env"
    stage_install_dir
    load_images
    if [ "$PROMISC_CONSENT" = 1 ]; then install_promisc_unit "$CAPTURE_INTERFACE"; fi
    gen_install_ca
    start_datastores
    bootstrap_admin
    compose_up
    wait_healthy
    verify_login
    install_systemd_unit
    mark_complete
    FRESH_STARTED=0
    final_screen
}

final_screen() {
    local url; url="$(ui_url "${BIND_ADDRESS:-127.0.0.1}" "${WEB_PORT:-80}")"
    step "Installation complete"
    cat <<EOF
  SentinelCore $(pkg_version) is installed.

  ✓ dependencies   Docker Engine + compose
  ✓ database       PostgreSQL (container)
  ✓ sensors        Suricata + helper on ${CAPTURE_INTERFACE:-?}
  ✓ environment    $INSTALL_DIR/.env (mode 600)
  ✓ services       all healthy
  email            ${EMAIL_MODE:-off}
  web UI bound to  ${BIND_ADDRESS:-127.0.0.1}:${WEB_PORT:-80}

  Admin user  : ${ADMIN_USERNAME:-admin}
EOF
    if [ "$ADMIN_PASSWORD_GENERATED" = 1 ] && [ "$DRY_RUN" = 0 ]; then
        # Shown ONCE on the terminal; never logged (bypasses log()).
        printf '  Admin password (generated — store it now, it is shown only once):\n      %s\n' "$ADMIN_PASSWORD"
    elif [ -n "$MODE_EXISTING" ]; then
        echo "  Admin password : unchanged"
    else
        echo "  Admin password : the one you chose (verified by a test login)"
    fi
    if [ "${EMAIL_MODE:-off}" = off ]; then
        echo "  Enable email   : sudo $INSTALL_DIR/enable-email.sh"
    fi
    cat <<EOF

  Open SentinelCore:  $url
  Logs            :  $LOG_FILE  and  sudo docker compose -f $INSTALL_DIR/docker-compose.yml logs
  Uninstall       :  sudo $INSTALL_DIR/uninstall.sh   (add --purge to remove data)
EOF
    if [ "${BIND_ADDRESS:-}" = 0.0.0.0 ]; then
        warn "the UI listens on all interfaces over plain HTTP — firewall it and/or put TLS in front."
    fi
    if command -v xdg-open >/dev/null 2>&1 && [ "$DRY_RUN" = 0 ] && [ -n "${DISPLAY:-}" ] && [ -n "${SUDO_USER:-}" ]; then
        sudo -u "$SUDO_USER" xdg-open "$url" >/dev/null 2>&1 || true
    fi
}

main() {
    welcome
    detect_existing
    run_system_checks || { err "system checks failed"; exit 1; }
    ensure_docker || exit 1
    if [ -n "$MODE_EXISTING" ]; then existing_flow; else fresh_flow; fi
}

main
