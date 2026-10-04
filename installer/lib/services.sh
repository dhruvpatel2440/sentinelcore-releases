# shellcheck shell=bash
# services.sh — verify the package, load images, render runtime config into
# the install dir, bring the stack up, and wait until EVERY service reports
# healthy. Installs a systemd unit so the stack starts on boot.

INSTALL_DIR="${INSTALL_DIR:-/opt/sentinelcore}"
SYSTEMD_UNIT="/etc/systemd/system/sentinelcore.service"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-300}"

dc() {
    # docker compose bound to the deployed project (compose file + .env).
    as_root docker compose -f "$INSTALL_DIR/docker-compose.yml" --env-file "$INSTALL_DIR/.env" "$@"
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
    if [ "${RELEASE_FLAVOR:-dev}" = test ]; then warn "TEST BUILD package (see README.md) — not for production use"; fi
    if [ ! -f "$PKG_DIR/SHA256SUMS" ]; then warn "no SHA256SUMS (dev tree) — skipping integrity check"; return 0; fi
    if [ "${DRY_RUN:-0}" = 1 ]; then info "[dry-run] (cd $PKG_DIR && sha256sum -c --quiet SHA256SUMS)"; return 0; fi
    if ( cd "$PKG_DIR" && sha256sum -c --quiet SHA256SUMS ); then
        good "package checksums verified ($(wc -l < "$PKG_DIR/SHA256SUMS" | tr -d ' ') files incl. images + frontend)"
    else
        err "package checksum mismatch — re-download the release and verify the .zip.sha256"; return 1
    fi
}

compose_images() {
    # Images the RENDERED compose references (one per line).
    sed -n -E 's/^[[:space:]]*image:[[:space:]]*"?([^"[:space:]]+)"?.*/\1/p' "$1" | sort -u
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

stage_install_dir() {
    step "Stage install directory ($INSTALL_DIR)"
    local version; version="$(pkg_version)"
    printf '%s' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.]+)?$|^dev$' \
        || { err "bad VERSION file: '$version'"; return 1; }

    # A2: validate the choices that get rendered into suricata.yaml.
    valid_cidr "$MONITORED_NETWORK" || { err "invalid monitored network: $MONITORED_NETWORK"; return 1; }
    if ! iface_exists "$CAPTURE_INTERFACE"; then
        if [ "${DRY_RUN:-0}" = 1 ]; then warn "[dry-run] capture interface '$CAPTURE_INTERFACE' not present here"
        else err "capture interface '$CAPTURE_INTERFACE' does not exist (ip link show '$CAPTURE_INTERFACE')"; return 1; fi
    fi

    if [ "${DRY_RUN:-0}" = 1 ]; then
        info "[dry-run] mkdir -p $INSTALL_DIR (0755)"
        info "[dry-run] render docker-compose.yml with image tag :$version (from VERSION)"
        info "[dry-run] render suricata.yaml: HOME_NET=[$MONITORED_NETWORK], af-packet interface=$CAPTURE_INTERFACE"
        info "[dry-run] copy nginx.release.conf, frontend-dist/, ca-bundle.pem (system roots), uninstall.sh, enable-email.sh, lib/"
        return 0
    fi

    as_root install -d -m 0755 "$INSTALL_DIR"
    sed "s/__VERSION__/$version/g" "$PKG_DIR/templates/docker-compose.release.yml" \
        | as_root tee "$INSTALL_DIR/docker-compose.yml" >/dev/null
    as_root install -m 0644 "$PKG_DIR/templates/nginx.release.conf" "$INSTALL_DIR/nginx.release.conf"

    local suri
    suri="$(render_suricata "$PKG_DIR/templates/suricata.yaml.template" "$MONITORED_NETWORK" "$CAPTURE_INTERFACE")" || return 1
    printf '%s\n' "$suri" | as_root tee "$INSTALL_DIR/suricata.yaml" >/dev/null
    as_root chmod 0644 "$INSTALL_DIR/suricata.yaml"
    good "suricata.yaml: HOME_NET=[$MONITORED_NETWORK], af-packet on $CAPTURE_INTERFACE"

    if [ -d "$PKG_DIR/templates/frontend-dist" ]; then
        as_root rm -rf "$INSTALL_DIR/frontend-dist"
        as_root cp -a "$PKG_DIR/templates/frontend-dist" "$INSTALL_DIR/frontend-dist"
    else
        err "frontend-dist missing from package"; return 1
    fi

    # Trust bundle: system roots now; gen_install_ca appends the install CA
    # when email is on. Always a FILE (a missing bind source becomes a dir).
    if [ ! -f "$INSTALL_DIR/ca-bundle.pem" ] || [ "${EMAIL_MODE:-off}" != brevo ]; then
        as_root install -m 0644 "${SYSTEM_CA_BUNDLE:-/etc/ssl/certs/ca-certificates.crt}" "$INSTALL_DIR/ca-bundle.pem"
    fi

    # Operator tools live with the install.
    as_root install -m 0755 "$HERE/uninstall.sh" "$INSTALL_DIR/uninstall.sh"
    as_root install -m 0755 "$HERE/enable-email.sh" "$INSTALL_DIR/enable-email.sh"
    as_root rm -rf "$INSTALL_DIR/lib"
    as_root cp -a "$LIB" "$INSTALL_DIR/lib"
    printf '%s\n' "$version" | as_root tee "$INSTALL_DIR/VERSION" >/dev/null
    good "install directory staged (images tagged :$version)"
}

load_images() {
    step "Load Docker images"
    local tar; tar="$(find "$PKG_DIR/images" -maxdepth 1 -name 'sentinelcore-images-*.tar.gz' 2>/dev/null | head -1 || true)"
    if [ "${DRY_RUN:-0}" = 1 ]; then
        info "[dry-run] docker load -i ${tar:-images/sentinelcore-images-$(pkg_version).tar.gz}"
        info "[dry-run] check every image in docker-compose.yml is present (docker image inspect)"
        return 0
    fi
    [ -n "$tar" ] || { err "no image tarball in $PKG_DIR/images — cannot start"; return 1; }
    info "loading $(basename "$tar") (this can take a few minutes)..."
    as_root docker load -i "$tar" | sed 's/^/  /'
    local img missing=0
    while IFS= read -r img; do
        [ -n "$img" ] || continue
        if as_root docker image inspect "$img" >/dev/null 2>&1; then good "image $img"
        else err "image missing after load: $img"; missing=1; fi
    done < <(compose_images "$INSTALL_DIR/docker-compose.yml")
    [ "$missing" = 0 ] || return 1
    good "all images available"
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
    [ "${EMAIL_MODE:-off}" = brevo ] && printf '%s\n' relay-shim
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

install_systemd_unit() {
    step "Enable on boot (systemd)"
    local docker_bin stop_cmd
    docker_bin="$(command -v docker 2>/dev/null || echo /usr/bin/docker)"
    # Default `stop` keeps containers + state; `down` only if explicitly asked.
    stop_cmd=stop; [ "${SC_SYSTEMD_STOP:-stop}" = down ] && stop_cmd=down
    local dcmd="$docker_bin compose -f $INSTALL_DIR/docker-compose.yml --env-file $INSTALL_DIR/.env"
    local body
    body="$(cat <<EOF
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
ExecStop=$dcmd $stop_cmd
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF
)"
    if [ "${DRY_RUN:-0}" = 1 ]; then
        info "[dry-run] write $SYSTEMD_UNIT and 'systemctl enable sentinelcore.service'"
        printf '%s\n' "$body" | sed 's/^/    /'
        return 0
    fi
    printf '%s\n' "$body" | as_root tee "$SYSTEMD_UNIT" >/dev/null
    xrun as_root systemctl daemon-reload
    xrun as_root systemctl enable sentinelcore.service
    good "systemd unit installed (ExecStop: compose $stop_cmd)"
}
