# shellcheck shell=bash
# services.sh — verify the package, load + verify images, render runtime config
# into the install dir, bring the stack up, wait until EVERY service reports
# healthy, systemd units, and the upgrade snapshot/rollback.

INSTALL_DIR="${INSTALL_DIR:-/opt/sentinelcore}"
SYSTEMD_UNIT="/etc/systemd/system/sentinelcore.service"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-300}"

compose_files() {
    # The compose -f list for the deployed install: base + optional overlays
    # (present in the install dir only when the feature is on).
    printf '%s\n' -f "$INSTALL_DIR/docker-compose.yml"
    [ -f "$INSTALL_DIR/docker-compose.tls.yml" ] && printf '%s\n' -f "$INSTALL_DIR/docker-compose.tls.yml"
    [ -f "$INSTALL_DIR/docker-compose.email.yml" ] && printf '%s\n' -f "$INSTALL_DIR/docker-compose.email.yml"
    return 0
}

dc() {
    # docker compose bound to the deployed project (compose files + .env).
    local files; mapfile -t files < <(compose_files)
    as_root docker compose "${files[@]}" --env-file "$INSTALL_DIR/.env" "$@"
}

pkg_version() {
    local v; v="$(head -1 "$PKG_DIR/VERSION" 2>/dev/null | tr -d '\r')"
    printf '%s' "${v:-dev}"
}

verify_package() {
    step "Verify package"
    if [ -f "$PKG_DIR/images/NO_IMAGES.txt" ]; then
        if [ "${DRY_RUN:-0}" = 1 ]; then warn "[dry-run] TEST BUILD without images — a real install would stop here"
        else err "this is a TEST BUILD without images (images/NO_IMAGES.txt) — it cannot be installed"; return 1; fi
    fi
    if [ "${RELEASE_FLAVOR:-dev}" = test ]; then
        if [ "${SENTINELCORE_ALLOW_TEST_BUILD:-0}" = 1 ] || [ "${DRY_RUN:-0}" = 1 ]; then
            warn "TEST BUILD package (see README.md) — not for production use"
        else
            err "this is a TEST BUILD — not for customers. Testers: re-run with SENTINELCORE_ALLOW_TEST_BUILD=1"; return 1
        fi
    fi
    if [ ! -f "$PKG_DIR/SHA256SUMS" ]; then warn "no SHA256SUMS (dev tree) — skipping integrity check"; return 0; fi
    if [ "${DRY_RUN:-0}" = 1 ]; then info "[dry-run] (cd $PKG_DIR && sha256sum -c --quiet SHA256SUMS)"; return 0; fi
    if ( cd "$PKG_DIR" && sha256sum -c --quiet SHA256SUMS ); then
        good "package checksums verified ($(wc -l < "$PKG_DIR/SHA256SUMS" | tr -d ' ') files incl. images, frontend, rules)"
    else
        err "package checksum mismatch — re-download the release and verify the .zip.sha256"; return 1
    fi
}

compose_images() {
    # Images the RENDERED compose files reference (one per line).
    sed -n -E 's/^[[:space:]]*image:[[:space:]]*"?([^"[:space:]]+)"?.*/\1/p' "$@" | sort -u
}

render_suricata() {
    # render_suricata <template> <cidr> <iface> -> rendered YAML on stdout.
    # Inputs are validated first, so they are safe inside the sed expressions.
    local tmpl="$1" cidr="$2" iface="$3" out
    valid_cidr "$cidr" || { err "invalid HOME_NET CIDR: $cidr"; return 1; }
    valid_iface "$iface" || { err "invalid capture interface: $iface"; return 1; }
    out="$(sed -e "s|__HOME_NET__|$cidr|g" -e "s|__CAPTURE_INTERFACE__|$iface|g" "$tmpl")" || return 1
    if printf '%s' "$out" | grep -q '__[A-Z_]*__'; then err "suricata.yaml has unrendered placeholders"; return 1; fi
    printf '%s\n' "$out"
}

render_nginx() {
    # render_nginx <templates-dir> <tls_mode> <https_port> -> nginx.conf on stdout.
    local dir="$1" mode="$2" sp="$3" out suffix="" hsts=""
    valid_tls_mode "$mode" || { err "invalid TLS_MODE: $mode"; return 1; }
    valid_port "$sp" || { err "invalid HTTPS port: $sp"; return 1; }
    if [ "$mode" = http-local ]; then
        out="$(cat "$dir/nginx-http.conf.template")" || return 1
    else
        [ "$sp" = 443 ] || suffix=":$sp"
        # HSTS only with a trusted (operator) certificate; never for self-signed.
        [ "$mode" = custom ] && hsts='    add_header Strict-Transport-Security "max-age=31536000" always;'
        out="$(sed -e "s|__HTTPS_REDIRECT_SUFFIX__|$suffix|g" -e "s|^__HSTS_LINE__\$|$hsts|" "$dir/nginx-tls.conf.template")" || return 1
    fi
    if printf '%s\n' "$out" | grep -v '^[[:space:]]*#' | grep -q '__[A-Z_]*__'; then err "nginx.conf has unrendered placeholders"; return 1; fi
    printf '%s\n' "$out"
}

render_compose() {
    # render_compose <template> <version> -> compose YAML with the image tag.
    sed "s/__VERSION__/$2/g" "$1"
}

stage_install_dir() {
    step "Stage install directory ($INSTALL_DIR)"
    local version; version="$(pkg_version)"
    printf '%s' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.]+)?$|^dev$' \
        || { err "bad VERSION file: '$version'"; return 1; }

    valid_cidr "$MONITORED_NETWORK" || { err "invalid monitored network: $MONITORED_NETWORK"; return 1; }
    if ! iface_exists "$CAPTURE_INTERFACE"; then
        if [ "${DRY_RUN:-0}" = 1 ]; then warn "[dry-run] capture interface '$CAPTURE_INTERFACE' not present here"
        else err "capture interface '$CAPTURE_INTERFACE' does not exist (ip link show '$CAPTURE_INTERFACE')"; return 1; fi
    fi
    local T="$PKG_DIR/templates" nginx suri
    nginx="$(render_nginx "$T" "$TLS_MODE" "$HTTPS_PORT")" || return 1
    if [ ! -f "$T/suricata.yaml.template" ] && [ "${DRY_RUN:-0}" = 1 ]; then
        info "[dry-run] (dev tree: suricata.yaml.template is generated from main's suricata.yaml by build-release.sh)"
        suri=""
    else
        suri="$(render_suricata "$T/suricata.yaml.template" "$MONITORED_NETWORK" "$CAPTURE_INTERFACE")" || return 1
    fi

    if [ "${DRY_RUN:-0}" = 1 ]; then
        info "[dry-run] mkdir -p $INSTALL_DIR (0755)"
        info "[dry-run] docker-compose.yml (image tag :$version from VERSION)"
        [ "$TLS_MODE" != http-local ] && info "[dry-run] + docker-compose.tls.yml (${BIND_ADDRESS}:${HTTPS_PORT}->443, tls-web/ mount)"
        [ "${EMAIL_MODE:-off}" = brevo ] && info "[dry-run] + docker-compose.email.yml (relay-shim, ca-bundle.pem, SSL_CERT_FILE)"
        [ "${EMAIL_MODE:-off}" = brevo ] || info "[dry-run] email off: NO email overlay, NO ca-bundle.pem, NO SSL_CERT_FILE"
        info "[dry-run] nginx.conf from $([ "$TLS_MODE" = http-local ] && echo nginx-http || echo nginx-tls).conf.template (TLS_MODE=$TLS_MODE)"
        info "[dry-run] suricata.yaml: HOME_NET=[$MONITORED_NETWORK], af-packet interface=$CAPTURE_INTERFACE"
        info "[dry-run] copy frontend-dist/, rules/, bin/, lib/, uninstall.sh, enable-email.sh, disable-email.sh"
        return 0
    fi

    as_root install -d -m 0755 "$INSTALL_DIR"
    render_compose "$T/docker-compose.release.yml" "$version" | as_root tee "$INSTALL_DIR/docker-compose.yml" >/dev/null
    if [ "$TLS_MODE" != http-local ]; then
        render_compose "$T/docker-compose.tls.yml" "$version" | as_root tee "$INSTALL_DIR/docker-compose.tls.yml" >/dev/null
    else
        as_root rm -f "$INSTALL_DIR/docker-compose.tls.yml"
    fi
    if [ "${EMAIL_MODE:-off}" = brevo ]; then
        render_compose "$T/docker-compose.email.yml" "$version" | as_root tee "$INSTALL_DIR/docker-compose.email.yml" >/dev/null
    else
        as_root rm -f "$INSTALL_DIR/docker-compose.email.yml" "$INSTALL_DIR/ca-bundle.pem"
    fi
    # Keep the email template so enable-email.sh can add it later.
    as_root install -d -m 0755 "$INSTALL_DIR/templates"
    render_compose "$T/docker-compose.email.yml" "$version" | as_root tee "$INSTALL_DIR/templates/docker-compose.email.yml" >/dev/null

    printf '%s\n' "$nginx" | as_root tee "$INSTALL_DIR/nginx.conf" >/dev/null
    printf '%s\n' "$suri" | as_root tee "$INSTALL_DIR/suricata.yaml" >/dev/null
    as_root chmod 0644 "$INSTALL_DIR/nginx.conf" "$INSTALL_DIR/suricata.yaml" "$INSTALL_DIR"/docker-compose*.yml
    good "nginx.conf ($TLS_MODE), suricata.yaml (HOME_NET=[$MONITORED_NETWORK], af-packet on $CAPTURE_INTERFACE)"

    [ -d "$T/frontend-dist" ] || { err "frontend-dist missing from package"; return 1; }
    as_root rm -rf "$INSTALL_DIR/frontend-dist"
    as_root cp -a "$T/frontend-dist" "$INSTALL_DIR/frontend-dist"
    if [ -d "$PKG_DIR/rules" ]; then
        as_root rm -rf "$INSTALL_DIR/rules"
        as_root cp -a "$PKG_DIR/rules" "$INSTALL_DIR/rules"
    fi

    as_root install -m 0755 "$HERE/uninstall.sh" "$INSTALL_DIR/uninstall.sh"
    as_root install -m 0755 "$HERE/enable-email.sh" "$INSTALL_DIR/enable-email.sh"
    as_root install -m 0755 "$HERE/disable-email.sh" "$INSTALL_DIR/disable-email.sh"
    as_root rm -rf "$INSTALL_DIR/lib" "$INSTALL_DIR/bin"
    as_root cp -a "$LIB" "$INSTALL_DIR/lib"
    as_root cp -a "$HERE/bin" "$INSTALL_DIR/bin"
    as_root chmod 0755 "$INSTALL_DIR"/bin/*.sh
    printf '%s\n' "$version" | as_root tee "$INSTALL_DIR/VERSION" >/dev/null
    good "install directory staged (images tagged :$version)"
}

load_images() {
    step "Load Docker images"
    local tar; tar="$(find "$PKG_DIR/images" -maxdepth 1 -name 'sentinelcore-images-*.tar.gz' 2>/dev/null | head -1 || true)"
    if [ "${DRY_RUN:-0}" = 1 ]; then
        info "[dry-run] docker load -i ${tar:-images/sentinelcore-images-$(pkg_version).tar.gz}"
        info "[dry-run] verify every image id against images/IMAGES.txt and every compose image is present"
        return 0
    fi
    [ -n "$tar" ] || { err "no image tarball in $PKG_DIR/images — cannot start"; return 1; }
    info "loading $(basename "$tar") (this can take a few minutes)..."
    as_root docker load -i "$tar" | sed 's/^/  /'
    local img want have missing=0
    if [ -f "$PKG_DIR/images/IMAGES.txt" ]; then
        while read -r img want; do
            [ -n "$img" ] || continue
            have="$(as_root docker image inspect -f '{{.Id}}' "$img" 2>/dev/null || true)"
            if [ "$have" = "$want" ]; then good "image $img (${want:7:12})"
            else err "image $img id mismatch (want ${want:-?}, have ${have:-missing})"; missing=1; fi
        done < "$PKG_DIR/images/IMAGES.txt"
    fi
    local files; mapfile -t files < <(find "$INSTALL_DIR" -maxdepth 2 -name 'docker-compose*.yml' 2>/dev/null)
    while IFS= read -r img; do
        [ -n "$img" ] || continue
        as_root docker image inspect "$img" >/dev/null 2>&1 || { err "image missing after load: $img"; missing=1; }
    done < <(compose_images "${files[@]}")
    [ "$missing" = 0 ] || return 1
    good "all images available and verified"
}

start_datastores() {
    step "Start database + cache"
    xrun dc up -d db redis
    wait_healthy db redis
}

compose_up() {
    step "Start services"
    xrun dc up -d --remove-orphans
}

service_health() {
    # service_health <service> -> healthy|unhealthy|starting|<state>|missing
    local cid
    cid="$(dc ps -a -q "$1" 2>/dev/null | head -1)"
    [ -n "$cid" ] || { printf 'missing'; return 0; }
    as_root docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck:{{.State.Status}}{{end}}' "$cid" 2>/dev/null || printf 'missing'
}

expected_services() {
    printf '%s\n' db redis helper backend worker nginx
    if [ -f "$INSTALL_DIR/docker-compose.email.yml" ] || { [ "${DRY_RUN:-0}" = 1 ] && [ "${EMAIL_MODE:-off}" = brevo ]; }; then
        printf '%s\n' relay-shim
    fi
    return 0
}

wait_healthy() {
    # wait_healthy [service...] — default: every expected service. ALL must be
    # exactly "healthy" (no substring matching). On timeout, show which are
    # not and the last 30 log lines of each.
    step "Wait for healthchecks"
    local svcs=("$@")
    [ "${#svcs[@]}" -gt 0 ] || mapfile -t svcs < <(expected_services)
    if [ "${DRY_RUN:-0}" = 1 ]; then
        info "[dry-run] poll docker inspect .State.Health.Status for: ${svcs[*]} (all must be 'healthy', timeout ${HEALTH_TIMEOUT}s)"
        return 0
    fi
    local deadline=$(( $(date +%s) + HEALTH_TIMEOUT )) s st pending last=""
    while :; do
        pending=()
        for s in "${svcs[@]}"; do
            st="$(service_health "$s")"
            [ "$st" = healthy ] || pending+=("$s=$st")
        done
        if [ "${#pending[@]}" -eq 0 ]; then good "healthy: ${svcs[*]}"; return 0; fi
        if [ "${pending[*]}" != "$last" ]; then info "  waiting for: ${pending[*]}"; last="${pending[*]}"; fi
        [ "$(date +%s)" -lt "$deadline" ] || break
        sleep 5
    done
    err "timed out after ${HEALTH_TIMEOUT}s; not ready: ${pending[*]}"
    local p l
    for p in "${pending[@]}"; do
        s="${p%%=*}"
        warn "---- last 30 log lines: $s ----"
        dc logs --no-color --tail 30 "$s" 2>&1 | while IFS= read -r l; do
            log INFO "[$s] $l"; printf '    %s\n' "$(_redact "$l")" >&2
        done
    done
    return 1
}

systemd_unit_body() {
    # The unit always lists the base compose file explicitly plus whichever
    # overlays are deployed; enable/disable-email rewrite it.
    local docker_bin stop_cmd files dcmd
    docker_bin="$(command -v docker 2>/dev/null || echo /usr/bin/docker)"
    stop_cmd=stop; [ "${SC_SYSTEMD_STOP:-stop}" = down ] && stop_cmd=down
    files="$(compose_files | paste -sd' ' -)"
    if [ "${DRY_RUN:-0}" = 1 ]; then
        files="-f $INSTALL_DIR/docker-compose.yml"
        [ "${TLS_MODE:-self-signed}" != http-local ] && files="$files -f $INSTALL_DIR/docker-compose.tls.yml"
        [ "${EMAIL_MODE:-off}" = brevo ] && files="$files -f $INSTALL_DIR/docker-compose.email.yml"
    fi
    dcmd="$docker_bin compose $files --env-file $INSTALL_DIR/.env"
    cat <<EOF
[Unit]
Description=SentinelCore stack
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$INSTALL_DIR
ExecStart=$dcmd up -d
# Start the Suricata sensor once the helper is healthy (non-fatal).
ExecStartPost=-$INSTALL_DIR/bin/sensor-start.sh --wait
ExecStop=$dcmd $stop_cmd
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF
}

install_systemd_unit() {
    step "Enable on boot (systemd)"
    local body; body="$(systemd_unit_body)"
    if [ "${DRY_RUN:-0}" = 1 ]; then
        info "[dry-run] write $SYSTEMD_UNIT and 'systemctl enable sentinelcore.service'"
        printf '%s\n' "$body" | sed 's/^/    /'
        return 0
    fi
    printf '%s\n' "$body" | as_root tee "$SYSTEMD_UNIT" >/dev/null
    xrun as_root systemctl daemon-reload
    xrun as_root systemctl enable sentinelcore.service
    good "systemd unit installed (ExecStop: compose ${SC_SYSTEMD_STOP:-stop})"
}

# ---- upgrade: snapshot + rollback -----------------------------------------
UPGRADE_SNAPSHOT=""
ROLLBACK_DIR="$INSTALL_DIR/.rollback"

snapshot_for_upgrade() {
    # pg_dump (custom format) of the live DB + a copy of the deployed compose
    # files / VERSION, so a failed upgrade can return to the previous images.
    step "Snapshot before upgrade"
    local old ts
    old="$(cat "$INSTALL_DIR/VERSION" 2>/dev/null || echo unknown)"
    ts="$(date -u +%Y%m%dT%H%M%SZ)"
    UPGRADE_SNAPSHOT="$INSTALL_DIR/backups/pre-upgrade-$old-$ts.dump"
    if [ "${DRY_RUN:-0}" = 1 ]; then
        info "[dry-run] pg_dump -Fc (db container) -> $UPGRADE_SNAPSHOT (mode 600)"
        info "[dry-run] copy docker-compose*.yml, nginx.conf, VERSION -> $ROLLBACK_DIR/"
        return 0
    fi
    as_root install -d -m 0700 "$INSTALL_DIR/backups"
    xrun dc up -d db
    wait_healthy db
    # shellcheck disable=SC2016
    if ! dc exec -T db sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc' | as_root sh -c "umask 077; cat > '$UPGRADE_SNAPSHOT'"; then
        err "database snapshot failed — upgrade aborted, nothing changed"; return 1
    fi
    [ -s "$UPGRADE_SNAPSHOT" ] || { err "database snapshot is empty — upgrade aborted"; return 1; }
    as_root rm -rf "$ROLLBACK_DIR"; as_root install -d -m 0700 "$ROLLBACK_DIR"
    as_root cp -a "$INSTALL_DIR"/docker-compose*.yml "$INSTALL_DIR/nginx.conf" "$INSTALL_DIR/VERSION" "$ROLLBACK_DIR/" 2>/dev/null || true
    good "snapshot: $UPGRADE_SNAPSHOT ($(as_root du -h "$UPGRADE_SNAPSHOT" | cut -f1)); previous version $old kept for rollback"
}

rollback_upgrade() {
    # Previous images are still loaded (never deleted on upgrade). Restore the
    # previous compose files and the DB snapshot taken before migrations ran.
    warn "upgrade failed — rolling back to $(cat "$ROLLBACK_DIR/VERSION" 2>/dev/null || echo 'the previous version')"
    [ -d "$ROLLBACK_DIR" ] && [ -s "$UPGRADE_SNAPSHOT" ] || { err "no rollback data — manual recovery: $INSTALL_DIR/bin/restore.sh"; return 1; }
    dc down --remove-orphans >/dev/null 2>&1 || true
    as_root rm -f "$INSTALL_DIR"/docker-compose*.yml
    as_root cp -a "$ROLLBACK_DIR"/. "$INSTALL_DIR/"
    xrun dc up -d db
    wait_healthy db || return 1
    # shellcheck disable=SC2016
    as_root cat "$UPGRADE_SNAPSHOT" | dc exec -T db sh -c 'pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean --if-exists --no-owner' \
        || warn "pg_restore reported warnings (see log)"
    xrun dc up -d --remove-orphans
    if wait_healthy; then good "rolled back to $(cat "$INSTALL_DIR/VERSION")"; return 0; fi
    err "rollback did not become healthy — restore manually: sudo $INSTALL_DIR/bin/restore.sh <archive>"
    return 1
}
