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
# back (containers, volumes it created, units, install dir); a failed UPGRADE
# returns to the previous images + a pre-upgrade DB snapshot. Redacted log at
# /var/log/sentinelcore-install.log (mode 600). An existing install offers
# Repair / Upgrade / Abort and never overwrites .env or data. No curl|bash, no
# telemetry. Outbound: the email relay (if enabled), Docker's apt repo (only if
# Docker is missing), ET Open (only if you choose to update rules now).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ORIG_ARGS=("$@")

# The package root (templates/, images/, rules/, docs/). In the dev tree, fall
# back to build/overlay so --dry-run works from a checkout.
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
UPGRADE_STARTED=0        # an upgrade began replacing containers
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
        -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
        *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
    esac
done

# Real installs run as root (one sudo prompt up front, not one per step).
if [ "$DRY_RUN" = 0 ] && [ "$(id -u)" -ne 0 ]; then
    command -v sudo >/dev/null 2>&1 || { echo "run as root (sudo not found)" >&2; exit 1; }
    exec sudo --preserve-env=SENTINELCORE_ALLOW_TEST_BUILD -- "$0" "${ORIG_ARGS[@]}"
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
# shellcheck source=lib/rules.sh
. "$LIB/rules.sh"
# shellcheck source=lib/backup.sh
. "$LIB/backup.sh"
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
            dc down -v --remove-orphans >/dev/null 2>&1 || true
        fi
    fi
    remove_promisc_unit >/dev/null 2>&1 || true
    remove_backup_timer >/dev/null 2>&1 || true
    as_root rm -f "$SYSTEMD_UNIT" 2>/dev/null || true
    as_root systemctl daemon-reload 2>/dev/null || true
    [ -f "$INSTALL_DIR/.env" ] && { as_root shred -u "$INSTALL_DIR/.env" 2>/dev/null || true; }
    as_root find "$INSTALL_DIR" -name '*.key' -type f -exec shred -u {} + 2>/dev/null || true
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
    elif [ "$UPGRADE_STARTED" = 1 ]; then
        rollback_upgrade || true
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
    local have want; have="$(cat "$INSTALL_DIR/VERSION" 2>/dev/null || echo '?')"; want="$(pkg_version)"
    warn "existing install detected at $INSTALL_DIR (installed: $have, this package: $want)"
    choice=repair; [ "$have" != "$want" ] && choice=upgrade
    ask_menu choice "SentinelCore $have is already installed. What would you like to do?" \
        repair "Repair — re-apply config & restart services (keeps .env, data, certificates)" \
        upgrade "Upgrade to $want — DB snapshot, new images, migrations; automatic rollback on failure" \
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
    # Older packages: add keys this version needs (never changing an existing
    # value) and drop keys that would now be wrong (1.0.0 set SSL_CERT_FILE
    # unconditionally, and used WEB_PORT / COMPOSE_PROFILES).
    local k v f="$INSTALL_DIR/.env"
    for k in TLS_MODE HTTP_PORT HTTPS_PORT RELAY_URL TZ; do
        grep -q "^$k=" "$f" && continue
        case "$k" in
            TLS_MODE) v="$TLS_MODE" ;;
            HTTP_PORT) v="$HTTP_PORT" ;;
            HTTPS_PORT) v="$HTTPS_PORT" ;;
            RELAY_URL) v="$RELAY_URL" ;;
            TZ) v="${TIMEZONE:-UTC}" ;;
        esac
        if [ "$DRY_RUN" = 1 ]; then info "[dry-run] add missing $k to .env"; else set_env_value "$f" "$k" "$v"; info "added $k=$v to .env"; fi
    done
    for k in WEB_PORT COMPOSE_PROFILES SSL_CERT_FILE REQUESTS_CA_BUNDLE CURL_CA_BUNDLE; do
        grep -q "^$k=" "$f" || continue
        if [ "$DRY_RUN" = 1 ]; then info "[dry-run] remove obsolete $k from .env"; else del_env_value "$f" "$k"; info "removed obsolete $k from .env"; fi
    done
}

mark_complete() {
    [ "$DRY_RUN" = 1 ] && return 0
    printf 'version=%s\ncompleted=%s\n' "$(pkg_version)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" | as_root tee "$INSTALL_DIR/$MARKER" >/dev/null
}

email_material() {
    # Email on but the shim cert is missing (e.g. 1.0.0 upgrade): issue it.
    [ "${EMAIL_MODE:-off}" = brevo ] || return 0
    [ -f "$INSTALL_DIR/tls/api.brevo.com.crt" ] && [ -f "$INSTALL_DIR/ca-bundle.pem" ] && return 0
    gen_install_ca
}

detection_steps() {
    load_bundled_rules
    start_sensor || warn "continuing without a running sensor — start it from the UI (Sensor → Start)"
    maybe_update_rules_online
}

repair_flow() {
    load_existing_env "$INSTALL_DIR/.env"
    backfill_env
    stage_install_dir
    setup_web_tls
    email_material
    load_images
    compose_up
    wait_healthy
    detection_steps
    install_systemd_unit
    mark_complete
    final_screen
}

check_new_tls_port() {
    # 1.0.0 had no HTTPS; upgrading turns it on, so the HTTPS port must be free.
    [ "${TLS_MODE:-}" != http-local ] || return 0
    [ -f "$INSTALL_DIR/docker-compose.tls.yml" ] && return 0
    [ "$DRY_RUN" = 1 ] && { info "[dry-run] check that HTTPS port $HTTPS_PORT is free (HTTPS is new in this version)"; return 0; }
    if port_in_use "$HTTPS_PORT"; then
        err "this version serves the UI over HTTPS on port $HTTPS_PORT, which is already in use."
        err "free it, or set HTTPS_PORT=<free port> in $INSTALL_DIR/.env, then re-run the upgrade. Nothing was changed."
        return 1
    fi
    good "HTTPS port $HTTPS_PORT is free"
}

upgrade_flow() {
    load_existing_env "$INSTALL_DIR/.env"
    check_disk_for_upgrade
    check_new_tls_port
    snapshot_for_upgrade
    UPGRADE_STARTED=1
    backfill_env
    stage_install_dir
    setup_web_tls
    email_material
    load_images
    compose_up      # the backend entrypoint runs `alembic upgrade head`
    wait_healthy
    detection_steps
    install_systemd_unit
    UPGRADE_STARTED=0
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
    setup_web_tls
    gen_install_ca
    start_datastores
    bootstrap_admin
    compose_up
    wait_healthy
    verify_login
    detection_steps
    install_systemd_unit
    maybe_backup_timer
    mark_complete
    FRESH_STARTED=0
    final_screen
}

final_screen() {
    local url; url="$(ui_url "${BIND_ADDRESS:-127.0.0.1}" "${TLS_MODE:-self-signed}" "${HTTP_PORT:-80}" "${HTTPS_PORT:-443}")"
    step "Installation complete"
    cat <<EOF
  SentinelCore $(pkg_version) is installed.

  ✓ dependencies   Docker Engine + compose
  ✓ database       PostgreSQL (container, loopback 127.0.0.1:5433 only)
  ✓ sensors        Suricata + helper on ${CAPTURE_INTERFACE:-?}
  ✓ environment    $INSTALL_DIR/.env (mode 600)
  ✓ services       all healthy
  web UI           $url  (TLS: ${TLS_MODE:-?}, bound to ${BIND_ADDRESS:-?})
  email            ${EMAIL_MODE:-off}

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
    print_trust_help
    cat <<EOF

  Email on/off    :  sudo $INSTALL_DIR/enable-email.sh  |  sudo $INSTALL_DIR/disable-email.sh
  Backup / restore:  sudo $INSTALL_DIR/bin/backup.sh    |  sudo $INSTALL_DIR/bin/restore.sh <archive>
  Logs            :  $LOG_FILE  and  sudo docker compose -f $INSTALL_DIR/docker-compose.yml logs
  Upgrade         :  unzip the new release and run its sudo ./install.sh  (choose Upgrade)
  Uninstall       :  sudo $INSTALL_DIR/uninstall.sh   (add --purge to remove data)
EOF
    if [ "${BIND_ADDRESS:-}" = 0.0.0.0 ]; then
        warn "the UI listens on all interfaces — restrict it with a host firewall to your admin network."
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
    case "$MODE_EXISTING" in
        repair) repair_flow ;;
        upgrade) upgrade_flow ;;
        *) fresh_flow ;;
    esac
}

main
