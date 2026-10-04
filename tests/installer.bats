#!/usr/bin/env bats
# bats tests for the installer libs (Phase 12 quality gate): validators,
# allowlist config loader, .env rendering, suricata + nginx rendering, compose
# overlays (email on/off, TLS), health wait, admin password transport + login,
# TLS certificates, Docker repo detection, systemd units, backup helpers and
# log redaction.
# Run: bats tests/
# shellcheck disable=SC2034,SC1091

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    TMP="$(mktemp -d)"
    DRY_RUN=0 NON_INTERACTIVE=1
    LOG_FILE="$TMP/install.log"
    . "$REPO/installer/lib/product.sh"
    . "$REPO/installer/lib/ui.sh"
    init_log "$LOG_FILE"
    . "$REPO/installer/lib/checks.sh"
    . "$REPO/installer/lib/secrets.sh"
    . "$REPO/installer/lib/config.sh"
    . "$REPO/installer/lib/sensors.sh"
    . "$REPO/installer/lib/deps.sh"
    . "$REPO/installer/lib/services.sh"
    . "$REPO/installer/lib/admin.sh"
    . "$REPO/installer/lib/tls.sh"
    . "$REPO/installer/lib/rules.sh"
    . "$REPO/installer/lib/backup.sh"
    T="$REPO/build/overlay/templates"
    TEMPLATE="$T/.env.template"
    # Passwords that break naive quoting: ' " $ \ space | & and friends.
    TRICKY=(
        "It's-a-Pass1word"
        'Quote"Double2Pass'
        'Dollar$HOME$(id)3Xx'
        'Back\slash\\n4Xxxx'
        'Space and | pipe & amp 5X'
        "Mix'\"\$\\ |&;<>*?\`X6y"
    )
    case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) WINDOWS=1 ;; *) WINDOWS=0 ;; esac
}

teardown() { rm -rf "$TMP"; }

base_answers() {
    ADMIN_EMAIL="admin@example.org"; ADMIN_USERNAME="admin"
    MONITORED_NETWORK="10.20.0.0/24"; PROTECTED_IPS="10.20.0.1"
    CAPTURE_INTERFACE="enp0s9"; EMAIL_MODE="off"; APP_BASE_URL="https://10.20.0.5:8443"
    TLS_MODE="self-signed"; BIND_ADDRESS="0.0.0.0"; HTTP_PORT="8080"; HTTPS_PORT="8443"; TIMEZONE="UTC"
    RELAY_URL="https://relay.example.org"; RELAY_INSTALL_ID="sc-abc-123"
    ADMIN_PASSWORD="Abcdefgh1234"
}

openssl_ok() {
    command -v openssl >/dev/null 2>&1 || return 1
    export MSYS2_ARG_CONV_EXCL="/CN=;/O="   # Git-Bash only: keep -subj intact, still convert file paths
}

fake_install() {
    # `install` without -o/-g (no root in tests); NTFS cannot express modes.
    install() {
        local a=()
        while [ $# -gt 0 ]; do
            case "$1" in
                -o|-g) shift 2 ;;
                -m) if [ "$WINDOWS" = 1 ]; then shift 2; else a+=("$1" "$2"); shift 2; fi ;;
                *) a+=("$1"); shift ;;
            esac
        done
        command install "${a[@]}"
    }
    as_root() { "$@"; }
}

# ---------------------------------------------------------------- validators
@test "valid_email accepts normal addresses, rejects junk" {
    valid_email "admin@example.org"
    valid_email "a.b+tag@sub.example.co.uk"
    run valid_email "not-an-email"; [ "$status" -ne 0 ]
    run valid_email "a@b"; [ "$status" -ne 0 ]
    run valid_email ""; [ "$status" -ne 0 ]
}

@test "valid_username enforces rules" {
    valid_username "admin"; valid_username "net_ops-1"
    run valid_username "Ab"; [ "$status" -ne 0 ]
    run valid_username "1abc"; [ "$status" -ne 0 ]
}

@test "strong_password: 12+ mixed classes; any symbol allowed" {
    strong_password "Sentinel1Core2!"
    run strong_password "short1A"; [ "$status" -ne 0 ]
    run strong_password "alllowercase123"; [ "$status" -ne 0 ]
    run strong_password "ALLUPPERCASE123"; [ "$status" -ne 0 ]
    run strong_password "NoDigitsHereXx"; [ "$status" -ne 0 ]
    for p in "${TRICKY[@]}"; do strong_password "$p"; done
}

@test "ipv4 / cidr / port / tls-mode / timezone validators are strict" {
    valid_ipv4 "192.168.1.1"
    run valid_ipv4 "999.1.1.1"; [ "$status" -ne 0 ]
    run valid_ipv4 "1.2.3"; [ "$status" -ne 0 ]
    valid_cidr "10.20.0.0/24"
    run valid_cidr "10.20.0.0"; [ "$status" -ne 0 ]
    run valid_cidr "10.20.0.0/33"; [ "$status" -ne 0 ]
    valid_port 80; valid_port 65535
    run valid_port 0; [ "$status" -ne 0 ]
    run valid_port 70000; [ "$status" -ne 0 ]
    run valid_port abc; [ "$status" -ne 0 ]
    valid_tls_mode self-signed; valid_tls_mode custom; valid_tls_mode http-local
    run valid_tls_mode http; [ "$status" -ne 0 ]
    valid_timezone UTC
    run valid_timezone 'Europe/../etc'; [ "$status" -ne 0 ]
    run valid_timezone '$(id)'; [ "$status" -ne 0 ]
}

@test "bind_address_ok accepts loopback/any, rejects foreign addresses" {
    bind_address_ok 127.0.0.1
    bind_address_ok 0.0.0.0
    host_ipv4s() { printf '10.0.2.15\n192.168.56.10\n'; }
    bind_address_ok 192.168.56.10
    run bind_address_ok 8.8.8.8; [ "$status" -ne 0 ]
    run bind_address_ok 300.1.1.1; [ "$status" -ne 0 ]
}

@test "port check: busy port is rejected, free port accepted" {
    port_in_use() { [ "$1" = 8443 ]; }
    command() { [ "$2" = ss ] && return 0; builtin command "$@"; }
    run check_port_free 8443; [ "$status" -ne 0 ]
    run check_port_free 9443; [ "$status" -eq 0 ]
}

@test "ui_host / ui_url follow bind, TLS mode and ports" {
    [ "$(ui_host 0.0.0.0)" = 127.0.0.1 ]
    [ "$(ui_host 192.168.56.10)" = 192.168.56.10 ]
    [ "$(ui_url 192.168.56.10 self-signed 80 443)" = "https://192.168.56.10" ]
    [ "$(ui_url 192.168.56.10 custom 80 8443)" = "https://192.168.56.10:8443" ]
    [ "$(ui_url 127.0.0.1 http-local 8080 443)" = "http://127.0.0.1:8080" ]
    [ "$(ui_url 127.0.0.1 http-local 80 443)" = "http://127.0.0.1" ]
}

# --------------------------------------- HTTP on a LAN address is blocked
@test "tls_bind_ok: plain HTTP only on loopback" {
    tls_bind_ok http-local 127.0.0.1
    tls_bind_ok self-signed 0.0.0.0
    tls_bind_ok custom 192.168.56.10
    run tls_bind_ok http-local 0.0.0.0; [ "$status" -ne 0 ]
    run tls_bind_ok http-local 192.168.56.10; [ "$status" -ne 0 ]
}

@test "validate_config: refuses http-local on a LAN bind (login refresh would break)" {
    base_answers
    port_in_use() { return 1; }
    TLS_MODE=http-local BIND_ADDRESS=0.0.0.0
    run validate_config
    [ "$status" -ne 0 ]
    [[ "$output" == *"http-local requires BIND_ADDRESS=127.0.0.1"* ]]
    TLS_MODE=http-local BIND_ADDRESS=127.0.0.1
    run validate_config
    [ "$status" -eq 0 ]
}

@test "validate_config: HTTP and HTTPS ports must differ; custom needs readable files" {
    base_answers
    port_in_use() { return 1; }
    HTTPS_PORT=8080
    run validate_config; [ "$status" -ne 0 ]; [[ "$output" == *"must differ"* ]]
    base_answers; TLS_MODE=custom TLS_CERT_FILE="$TMP/nope.crt" TLS_KEY_FILE="$TMP/nope.key"
    run validate_config; [ "$status" -ne 0 ]; [[ "$output" == *"TLS_CERT_FILE not readable"* ]]
}

# ------------------------------------------------- allowlist config loader
@test "load_config_file: allowlisted keys load, quotes stripped" {
    cat > "$TMP/c.conf" <<'EOF'
# comment
ADMIN_EMAIL=admin@example.org
ADMIN_PASSWORD='It''s"weird$1Aa xx'
HTTPS_PORT="8443"
HTTP_PORT=8080
TLS_MODE=self-signed
BIND_ADDRESS = 0.0.0.0
EMAIL_MODE=off
TIMEZONE=Europe/Berlin
UPDATE_RULES=no
NIGHTLY_BACKUP=yes
EOF
    chmod 600 "$TMP/c.conf"
    load_config_file "$TMP/c.conf"
    [ "$ADMIN_EMAIL" = admin@example.org ]
    [ "$HTTPS_PORT" = 8443 ] && [ "$HTTP_PORT" = 8080 ] && [ "$TLS_MODE" = self-signed ]
    [ "$BIND_ADDRESS" = 0.0.0.0 ]
    [ "$TIMEZONE" = Europe/Berlin ] && [ "$NIGHTLY_BACKUP" = yes ]
    [ "$ADMIN_PASSWORD" = "It''s\"weird\$1Aa xx" ]
}

@test "load_config_file: rejects unknown keys and command-injection keys" {
    marker="$TMP/pwned"
    printf 'a[$(touch %s)]=x\n' "$marker" > "$TMP/evil.conf"
    run load_config_file "$TMP/evil.conf"
    [ "$status" -ne 0 ]
    [ ! -e "$marker" ]
    printf 'PATH=/tmp\n' > "$TMP/evil2.conf"
    run load_config_file "$TMP/evil2.conf"
    [ "$status" -ne 0 ]
    printf 'X=$(touch %s)\n' "$marker" > "$TMP/evil3.conf"
    run load_config_file "$TMP/evil3.conf"
    [ "$status" -ne 0 ]
    [ ! -e "$marker" ]
    printf 'ADMIN_EMAIL=$(touch %s)\n' "$marker" > "$TMP/evil4.conf"
    load_config_file "$TMP/evil4.conf"
    [ ! -e "$marker" ]
    [ "$ADMIN_EMAIL" = "\$(touch $marker)" ]
    printf 'WEB_PORT=80\n' > "$TMP/old.conf"   # 1.0.0 key: no longer accepted
    run load_config_file "$TMP/old.conf"; [ "$status" -ne 0 ]
}

@test "load_config_file: warns when world-readable" {
    printf 'ADMIN_EMAIL=a@example.org\n' > "$TMP/w.conf"
    chmod 644 "$TMP/w.conf"
    stat() { echo 644; }   # Windows/NTFS test hosts can't express modes
    run load_config_file "$TMP/w.conf"
    [ "$status" -eq 0 ]
    [[ "$output" == *"world-readable"* ]]
}

# --------------------------------------------------------- .env rendering
@test "render_env: every placeholder filled; TLS/ports/TZ rendered; no password; no CA vars" {
    base_answers
    ADMIN_PASSWORD='Secret$Pass1word'
    render_env "$TEMPLATE" "$TMP/.env"
    run bash -c "grep -vE '^[[:space:]]*#' '$TMP/.env' | grep -E '__[A-Z_]+__'"; [ "$status" -ne 0 ]
    grep -qx "TLS_MODE=self-signed" "$TMP/.env"
    grep -qx "BIND_ADDRESS=0.0.0.0" "$TMP/.env"
    grep -qx "HTTP_PORT=8080" "$TMP/.env"
    grep -qx "HTTPS_PORT=8443" "$TMP/.env"
    grep -qx "TZ=UTC" "$TMP/.env"
    grep -qx "APP_BASE_URL=https://10.20.0.5:8443" "$TMP/.env"
    grep -qx "ENVIRONMENT=production" "$TMP/.env"
    grep -qx "EMAIL_MODE=off" "$TMP/.env"
    grep -qx "RELAY_URL=https://relay.example.org" "$TMP/.env"
    grep -qx "CAPTURE_INTERFACE=enp0s9" "$TMP/.env"
    grep -Eq "^SECRET_KEY=[0-9a-f]{64}$" "$TMP/.env"
    run grep -E '^(SSL_CERT_FILE|REQUESTS_CA_BUNDLE|CURL_CA_BUNDLE|COMPOSE_PROFILES|WEB_PORT)=' "$TMP/.env"; [ "$status" -ne 0 ]
    run grep -F 'Secret$Pass1word' "$TMP/.env"; [ "$status" -ne 0 ]
    run grep -E '^SEED_ADMIN_PASSWORD=' "$TMP/.env"; [ "$status" -ne 0 ]
}

@test "render_env: email on stores the relay token (never a Brevo key)" {
    base_answers
    EMAIL_MODE=brevo RELAY_TOKEN="relaytok-0123456789" EMAIL_SENDER_ADDRESS="notify@example.org"
    render_env "$TEMPLATE" "$TMP/.env"
    grep -qx "EMAIL_MODE=brevo" "$TMP/.env"
    grep -qx "BREVO_API_KEY=relaytok-0123456789" "$TMP/.env"
    grep -qx "EMAIL_SENDER_ADDRESS=notify@example.org" "$TMP/.env"
}

@test "render_env: file mode is 600 (on POSIX filesystems)" {
    base_answers
    render_env "$TEMPLATE" "$TMP/.env"
    [ "$WINDOWS" = 0 ] || skip "NTFS cannot express mode 600"
    [ "$(stat -c '%a' "$TMP/.env")" = 600 ]
}

@test "set_env_value / del_env_value change one key and keep the rest" {
    printf 'A=1\nEMAIL_MODE=off\nB=2\nSSL_CERT_FILE=/x\n' > "$TMP/e"
    set_env_value "$TMP/e" EMAIL_MODE brevo
    set_env_value "$TMP/e" NEWKEY 'v$x'
    del_env_value "$TMP/e" SSL_CERT_FILE
    [ "$(cat "$TMP/e")" = "$(printf 'A=1\nEMAIL_MODE=brevo\nB=2\nNEWKEY=v$x')" ]
}

@test "load_existing_env: 1.0.0 .env (WEB_PORT, no TLS_MODE) maps to the new model" {
    printf 'BIND_ADDRESS=0.0.0.0\nWEB_PORT=8081\nEMAIL_MODE=off\nTZ=Asia/Kolkata\n' > "$TMP/old.env"
    load_existing_env "$TMP/old.env"
    [ "$HTTP_PORT" = 8081 ] && [ "$HTTPS_PORT" = 443 ] && [ "$TLS_MODE" = self-signed ] && [ "$TIMEZONE" = Asia/Kolkata ]
    printf 'BIND_ADDRESS=127.0.0.1\nWEB_PORT=80\n' > "$TMP/old2.env"
    load_existing_env "$TMP/old2.env"
    [ "$TLS_MODE" = http-local ]
}

# ------------------------------------------------------ suricata rendering
@test "render_suricata renders HOME_NET and the chosen capture NIC" {
    cat > "$TMP/s.tmpl" <<'EOF'
vars:
  address-groups:
    HOME_NET: "[__HOME_NET__]"
af-packet:
  - interface: __CAPTURE_INTERFACE__
    cluster-id: 99
  - interface: default
    threads: auto
EOF
    out="$(render_suricata "$TMP/s.tmpl" 10.20.0.0/24 enp0s9)"
    [[ "$out" == *'HOME_NET: "[10.20.0.0/24]"'* ]]
    [[ "$out" == *"- interface: enp0s9"* ]]
    [[ "$out" == *"- interface: default"* ]]
    run render_suricata "$TMP/s.tmpl" 10.20.0.0/24 'eth0;rm'; [ "$status" -ne 0 ]
    run render_suricata "$TMP/s.tmpl" nope enp0s9; [ "$status" -ne 0 ]
}

# --------------------------------------------------------- nginx rendering
@test "render_nginx self-signed: TLS server, redirect with port, no HSTS, headers, upload limit" {
    out="$(render_nginx "$T" self-signed 8443)"
    [[ "$out" == *"listen 443 ssl;"* ]]
    [[ "$out" == *'return 301 https://$host:8443$request_uri;'* ]]
    [[ "$out" != *"Strict-Transport-Security"* ]]
    [[ "$out" == *"Content-Security-Policy"* ]] && [[ "$out" == *"X-Frame-Options"* ]] && [[ "$out" == *"X-Content-Type-Options"* ]]
    [[ "$out" == *"client_max_body_size 501m;"* ]] && [[ "$out" == *"proxy_request_buffering off;"* ]]
    [[ "$out" == *"location = /api/auth/login"* ]] && [[ "$out" == *"limit_req zone=sc_login"* ]]
    [[ "$out" == *"proxy_pass http://backend_upstream;"* ]]
    run bash -c "printf '%s\n' \"\$1\" | grep -v '^[[:space:]]*#' | grep -q '__[A-Z_]*__'" _ "$out"; [ "$status" -ne 0 ]
    [ "$(render_nginx "$T" self-signed 443 | grep -c 'return 301 https://$host$request_uri;')" = 1 ]
}

@test "render_nginx custom adds HSTS; http-local has no TLS; bad input rejected" {
    out="$(render_nginx "$T" custom 443)"
    [[ "$out" == *'Strict-Transport-Security "max-age=31536000" always;'* ]]
    out="$(render_nginx "$T" http-local 443)"
    [[ "$out" != *"ssl_certificate"* ]] && [[ "$out" != *"Strict-Transport-Security"* ]]
    [[ "$out" == *"listen 80;"* ]] && [[ "$out" == *"client_max_body_size 501m;"* ]]
    run render_nginx "$T" https 443; [ "$status" -ne 0 ]
    run render_nginx "$T" self-signed 0; [ "$status" -ne 0 ]
}

# ------------------------------------------------------- compose overlays
@test "compose: base has no email/CA bits; email overlay adds shim + SSL_CERT_FILE; TLS overlay adds 443" {
    base="$(render_compose "$T/docker-compose.release.yml" 1.2.3)"
    email="$(render_compose "$T/docker-compose.email.yml" 1.2.3)"
    tls="$(render_compose "$T/docker-compose.tls.yml" 1.2.3)"
    for y in "$base" "$email" "$tls"; do
        run bash -c "printf '%s' \"\$1\" | grep -q '__VERSION__'" _ "$y"; [ "$status" -ne 0 ]
    done
    base_nc="$(printf '%s\n' "$base" | grep -v '^[[:space:]]*#')"   # config lines only
    [[ "$base_nc" != *"ca-bundle"* ]] && [[ "$base_nc" != *"SSL_CERT_FILE"* ]] && [[ "$base_nc" != *"relay-shim"* ]]
    [[ "$base" == *"image: sentinelcore/backend:1.2.3"* ]]
    [[ "$base" == *'${BIND_ADDRESS:?'*':${HTTP_PORT:?'* ]]
    [[ "$email" == *"relay-shim:"* ]] && [[ "$email" == *"SSL_CERT_FILE: /etc/sentinelcore/ca-bundle.pem"* ]]
    [[ "$email" == *"./ca-bundle.pem:/etc/sentinelcore/ca-bundle.pem:ro"* ]] && [[ "$email" == *"- api.brevo.com"* ]]
    [[ "$tls" == *'${HTTPS_PORT:?'*':443"'* ]] && [[ "$tls" == *"./tls-web:/etc/nginx/tls:ro"* ]]
}

@test "compose: every service has a healthcheck and log rotation (python yaml)" {
    PY=""; for c in python3 python; do "$c" -c 'import yaml' >/dev/null 2>&1 && { PY="$c"; break; }; done
    [ -n "$PY" ] || skip "python3 + PyYAML needed"
    render_compose "$T/docker-compose.release.yml" 1.2.3 > "$TMP/base.yml"
    render_compose "$T/docker-compose.email.yml" 1.2.3 > "$TMP/email.yml"
    "$PY" - "$TMP/base.yml" "$TMP/email.yml" <<'PY'
import sys, yaml
base = yaml.safe_load(open(sys.argv[1])); email = yaml.safe_load(open(sys.argv[2]))
svcs = dict(base["services"]); svcs["relay-shim"] = email["services"]["relay-shim"]
for name, s in svcs.items():
    assert "healthcheck" in s, f"{name}: no healthcheck"
    assert s.get("logging", {}).get("options", {}).get("max-size"), f"{name}: no log rotation"
assert base["services"]["helper"]["cap_drop"] == ["ALL"]
assert set(base["services"]["helper"]["cap_add"]) == {"NET_ADMIN", "NET_RAW", "SYS_NICE", "CHOWN"}
for n in ("backend", "worker"):
    assert base["services"][n]["cap_drop"] == ["ALL"]
    assert "no-new-privileges:true" in base["services"][n]["security_opt"]
    assert "--reload" not in " ".join(base["services"][n]["command"])
assert base["services"]["db"]["ports"] == ["127.0.0.1:5433:5432"]
for n in ("redis", "backend", "worker", "helper"):
    assert "ports" not in base["services"][n], f"{n} publishes a port"
PY
}

@test "compose: docker compose config -q passes for email off and on (needs docker)" {
    command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1 || skip "docker compose not installed here"
    base_answers; render_env "$TEMPLATE" "$TMP/.env" >/dev/null
    render_compose "$T/docker-compose.release.yml" 1.2.3 > "$TMP/docker-compose.yml"
    render_compose "$T/docker-compose.tls.yml" 1.2.3 > "$TMP/docker-compose.tls.yml"
    render_compose "$T/docker-compose.email.yml" 1.2.3 > "$TMP/docker-compose.email.yml"
    docker compose -f "$TMP/docker-compose.yml" -f "$TMP/docker-compose.tls.yml" --env-file "$TMP/.env" config -q
    docker compose -f "$TMP/docker-compose.yml" -f "$TMP/docker-compose.tls.yml" -f "$TMP/docker-compose.email.yml" --env-file "$TMP/.env" config -q
}

@test "compose_files: overlays are used only when deployed" {
    INSTALL_DIR="$TMP"; : > "$TMP/docker-compose.yml"
    [ "$(compose_files | paste -sd' ' -)" = "-f $TMP/docker-compose.yml" ]
    : > "$TMP/docker-compose.tls.yml"; : > "$TMP/docker-compose.email.yml"
    [ "$(compose_files | paste -sd' ' -)" = "-f $TMP/docker-compose.yml -f $TMP/docker-compose.tls.yml -f $TMP/docker-compose.email.yml" ]
}

# ---------------------------------------------------------------- health wait
fake_docker_health() {
    # $1 = "svc=status ..." map. Fakes `docker compose ps -q` + `docker inspect`.
    mkdir -p "$TMP/bin"
    printf '%s\n' "$1" | tr ' ' '\n' > "$TMP/health.map"
    cat > "$TMP/bin/docker" <<EOF
#!/usr/bin/env bash
if [ "\$1" = compose ]; then
    for a in "\$@"; do last="\$a"; done
    echo "cid-\$last"; exit 0
fi
if [ "\$1" = inspect ]; then
    for a in "\$@"; do last="\$a"; done
    svc="\${last#cid-}"
    grep "^\$svc=" "$TMP/health.map" | cut -d= -f2; exit 0
fi
exit 0
EOF
    chmod +x "$TMP/bin/docker"
    PATH="$TMP/bin:$PATH"
    as_root() { "$@"; }
    INSTALL_DIR="$TMP"
}

@test "wait_healthy: 'unhealthy' is NOT healthy (no substring match)" {
    fake_docker_health "db=healthy redis=healthy helper=healthy backend=unhealthy worker=healthy nginx=healthy"
    HEALTH_TIMEOUT=1
    run wait_healthy
    [ "$status" -ne 0 ]
    [[ "$output" == *"backend=unhealthy"* ]]
}

@test "wait_healthy: passes only when every service is healthy" {
    fake_docker_health "db=healthy redis=healthy helper=healthy backend=healthy worker=healthy nginx=healthy"
    HEALTH_TIMEOUT=1
    run wait_healthy
    [ "$status" -eq 0 ]
}

@test "wait_healthy: relay-shim is required when the email overlay is deployed" {
    fake_docker_health "db=healthy redis=healthy helper=healthy backend=healthy worker=healthy nginx=healthy relay-shim=starting"
    HEALTH_TIMEOUT=1
    run wait_healthy; [ "$status" -eq 0 ]          # email off: shim not expected
    : > "$TMP/docker-compose.email.yml"
    run wait_healthy
    [ "$status" -ne 0 ]
    [[ "$output" == *"relay-shim=starting"* ]]
}

# ------------------------------------------------- admin password transport
@test "seed: tricky passwords reach the container env byte-for-byte, never argv; seed runs once" {
    mkdir -p "$TMP/bin"
    cat > "$TMP/bin/docker" <<EOF
#!/usr/bin/env bash
printf '%s' "\$SEED_ADMIN_PASSWORD" > "$TMP/seen.env"
printf '%s\n' "\$@" > "$TMP/seen.argv"
echo "Created admin user 'admin'."
EOF
    chmod +x "$TMP/bin/docker"
    PATH="$TMP/bin:$PATH"
    id() { echo 0; }
    INSTALL_DIR="$TMP" ADMIN_USERNAME=admin
    for pw in "${TRICKY[@]}"; do
        ADMIN_PASSWORD="$pw"
        bootstrap_admin >/dev/null
        [ "$(cat "$TMP/seen.env")" = "$pw" ]
        run grep -F -- "$pw" "$TMP/seen.argv"; [ "$status" -ne 0 ]
        grep -qx -- "-e" "$TMP/seen.argv"
        grep -qx -- "SEED_ADMIN_PASSWORD" "$TMP/seen.argv"
        run grep -qx -- "scripts.seed_admin" "$TMP/seen.argv"; [ "$status" -ne 0 ]   # entrypoint seeds; CMD is a no-op
    done
}

@test "seed: fails loudly if the app generated its own password" {
    mkdir -p "$TMP/bin"
    printf '#!/usr/bin/env bash\necho "  GENERATED PASSWORD: zzz"\n' > "$TMP/bin/docker"
    chmod +x "$TMP/bin/docker"; PATH="$TMP/bin:$PATH"
    id() { echo 0; }
    INSTALL_DIR="$TMP" ADMIN_USERNAME=admin ADMIN_PASSWORD="Abcdefgh1234"
    run bootstrap_admin
    [ "$status" -ne 0 ]
}

fake_curl_login() {
    # $1 = HTTP code, $2 = Set-Cookie line (optional)
    mkdir -p "$TMP/bin"
    cat > "$TMP/bin/curl" <<EOF
#!/usr/bin/env bash
cat > "$TMP/body.json"
printf '%s\n' "\$@" > "$TMP/curl.argv"
while [ \$# -gt 0 ]; do [ "\$1" = -D ] && { printf 'HTTP/1.1 $1\r\n%s\r\n' "$2" > "\$2"; }; shift; done
printf '$1'
EOF
    chmod +x "$TMP/bin/curl"; PATH="$TMP/bin:$PATH"
}

@test "verify_login: JSON body on stdin decodes to the exact password; argv clean (http-local)" {
    PY=""
    for c in python3 python; do "$c" -c 'import json' >/dev/null 2>&1 && { PY="$c"; break; }; done
    [ -n "$PY" ] || skip "python needed to decode JSON"
    fake_curl_login 200 "set-cookie: sc_refresh=x; HttpOnly; Path=/api/auth; SameSite=lax; Secure"
    TLS_MODE=http-local BIND_ADDRESS=127.0.0.1 HTTP_PORT=8080 ADMIN_USERNAME=admin
    for pw in "${TRICKY[@]}"; do
        ADMIN_PASSWORD="$pw"
        verify_login >/dev/null
        decoded="$("$PY" -c 'import json,sys; sys.stdout.write(json.load(open(sys.argv[1]))["password"])' "$TMP/body.json")"
        [ "$decoded" = "$pw" ]
        run grep -F -- "$pw" "$TMP/curl.argv"; [ "$status" -ne 0 ]
        grep -q "http://127.0.0.1:8080/api/auth/login" "$TMP/curl.argv"
    done
}

@test "verify_login: self-signed uses https + the install CA, and checks the Secure refresh cookie" {
    fake_curl_login 200 "set-cookie: sc_refresh=x; HttpOnly; Path=/api/auth; SameSite=lax; Secure"
    INSTALL_DIR="$TMP" TLS_MODE=self-signed BIND_ADDRESS=0.0.0.0 HTTPS_PORT=8443 ADMIN_USERNAME=admin ADMIN_PASSWORD="Abcdefgh1234"
    run verify_login
    [ "$status" -eq 0 ]
    grep -q "https://127.0.0.1:8443/api/auth/login" "$TMP/curl.argv"
    grep -qx -- "--cacert" "$TMP/curl.argv"
    [[ "$output" == *"refresh cookie is Secure + HttpOnly"* ]]
}

@test "refresh_cookie_ok: requires Secure, HttpOnly and Path=/api/auth" {
    refresh_cookie_ok "set-cookie: r=1; HttpOnly; Path=/api/auth; Secure"
    run refresh_cookie_ok "set-cookie: r=1; HttpOnly; Path=/api/auth"; [ "$status" -ne 0 ]
    run refresh_cookie_ok "set-cookie: r=1; Path=/api/auth; Secure"; [ "$status" -ne 0 ]
    run refresh_cookie_ok "set-cookie: r=1; HttpOnly; Path=/; Secure"; [ "$status" -ne 0 ]
}

@test "verify_login: non-interactive hard-fails on 401 after one re-apply" {
    fake_curl_login 401 ""
    set_admin_password() { echo reapplied >> "$TMP/reapply"; }
    TLS_MODE=http-local BIND_ADDRESS=127.0.0.1 HTTP_PORT=8080 ADMIN_USERNAME=admin ADMIN_PASSWORD="Abcdefgh1234"
    run verify_login
    [ "$status" -ne 0 ]
    [ "$(wc -l < "$TMP/reapply" | tr -d ' ')" = 1 ]
}

@test "gen_admin_password always satisfies strong_password" {
    for _ in 1 2 3 4 5 6 7 8 9 10; do strong_password "$(gen_admin_password)"; done
}

# ---------------------------------------------------------------- log redaction
@test "log: no secret value ever reaches the install log" {
    base_answers
    EMAIL_MODE=brevo RELAY_TOKEN="relay-token-ABCDEFGH-123456"
    add_secret relay_token "$RELAY_TOKEN"
    for pw in "${TRICKY[@]}"; do add_secret "pw$RANDOM" "$pw"; done
    ADMIN_PASSWORD="${TRICKY[5]}"; add_secret admin_password "$ADMIN_PASSWORD"
    render_env "$TEMPLATE" "$TMP/.env" >/dev/null
    info "registering with token $RELAY_TOKEN and password $ADMIN_PASSWORD"
    warn "db pw ${SECRETS[postgres_password]}"
    run_sh "true ${SECRETS[secret_key]}" >/dev/null
    DRY_RUN=1 xrun echo "${SECRETS[webhook_secret]}" >/dev/null
    for v in "${SECRETS[@]}"; do
        run grep -F -- "$v" "$LOG_FILE"; [ "$status" -ne 0 ]
    done
    grep -q "<redacted>" "$LOG_FILE"
}

# ------------------------------------------------ TLS material hygiene
@test "gen_install_ca: leaf for api.brevo.com issued, CA key destroyed, bundle has CA" {
    openssl_ok || skip "openssl needed"
    fake_install
    INSTALL_DIR="$TMP/opt"; mkdir -p "$INSTALL_DIR"
    printf -- '-----BEGIN CERTIFICATE-----\nsystemroot\n-----END CERTIFICATE-----\n' > "$TMP/roots.pem"
    SYSTEM_CA_BUNDLE="$TMP/roots.pem" EMAIL_MODE=brevo
    gen_install_ca
    [ -s "$INSTALL_DIR/tls/api.brevo.com.crt" ]
    [ -s "$INSTALL_DIR/tls/api.brevo.com.key" ]
    [ -s "$INSTALL_DIR/ca.crt" ]
    [ -z "$(find "$INSTALL_DIR" -name '*ca.key*')" ]
    [ "$(ls "$INSTALL_DIR/tls" | sort | tr '\n' ' ')" = "api.brevo.com.crt api.brevo.com.key " ]
    openssl verify -CAfile "$INSTALL_DIR/ca.crt" "$INSTALL_DIR/tls/api.brevo.com.crt"
    openssl x509 -in "$INSTALL_DIR/tls/api.brevo.com.crt" -noout -text | grep -q "DNS:api.brevo.com"
    grep -q systemroot "$INSTALL_DIR/ca-bundle.pem"
    grep -c "BEGIN CERTIFICATE" "$INSTALL_DIR/ca-bundle.pem" | grep -qx 2
    if [ "$WINDOWS" = 0 ]; then
        [ "$(stat -c '%a' "$INSTALL_DIR/tls")" = 700 ]
        [ "$(stat -c '%a' "$INSTALL_DIR/tls/api.brevo.com.key")" = 600 ]
    fi
}

@test "gen_install_ca: no-op when email is off" {
    INSTALL_DIR="$TMP/opt2"; mkdir -p "$INSTALL_DIR"; EMAIL_MODE=off
    gen_install_ca
    [ ! -e "$INSTALL_DIR/tls" ]
}

@test "gen_web_selfsigned: SAN covers localhost + host IPs, chain verifies, Web CA key destroyed" {
    openssl_ok || skip "openssl needed"
    fake_install
    host_ipv4s() { printf '192.168.56.10\n10.0.2.15\n'; }
    INSTALL_DIR="$TMP/opt3"; mkdir -p "$INSTALL_DIR"; BIND_ADDRESS=0.0.0.0
    gen_web_selfsigned
    [ -s "$INSTALL_DIR/tls-web/server.crt" ] && [ -s "$INSTALL_DIR/tls-web/server.key" ] && [ -s "$INSTALL_DIR/tls-web-ca.crt" ]
    [ -z "$(find "$INSTALL_DIR" -name '*ca.key*')" ]
    openssl verify -CAfile "$INSTALL_DIR/tls-web-ca.crt" "$INSTALL_DIR/tls-web/server.crt"
    san="$(openssl x509 -in "$INSTALL_DIR/tls-web/server.crt" -noout -text | grep -A1 'Subject Alternative Name' | tail -1)"
    [[ "$san" == *"DNS:localhost"* ]] && [[ "$san" == *"IP Address:127.0.0.1"* ]]
    [[ "$san" == *"IP Address:192.168.56.10"* ]] && [[ "$san" == *"IP Address:10.0.2.15"* ]]
    openssl x509 -in "$INSTALL_DIR/tls-web/server.crt" -noout -text | grep -q "TLS Web Server Authentication"
    openssl x509 -in "$INSTALL_DIR/tls-web/server.crt" -noout -checkend $((800 * 86400))
}

@test "custom_cert_check: accepts a matching pair, rejects a mismatched key and junk" {
    openssl_ok || skip "openssl needed"
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/a.key" -out "$TMP/a.crt" -days 30 -subj "/CN=sc.example.org" 2>/dev/null
    openssl genrsa -out "$TMP/b.key" 2048 2>/dev/null
    custom_cert_check "$TMP/a.crt" "$TMP/a.key"
    run custom_cert_check "$TMP/a.crt" "$TMP/b.key"; [ "$status" -ne 0 ]; [[ "$output" == *"does not match"* ]]
    printf 'junk\n' > "$TMP/j.crt"
    run custom_cert_check "$TMP/j.crt" "$TMP/a.key"; [ "$status" -ne 0 ]
}

# ---------------------------------------------------------- Docker repo pick
@test "docker_repo_distro: ubuntu/debian/derivatives map to Docker's repos; others refused" {
    printf 'ID=ubuntu\nVERSION_CODENAME=noble\n' > "$TMP/os1"
    [ "$(docker_repo_distro "$TMP/os1")" = "ubuntu noble" ]
    printf 'ID=debian\nVERSION_CODENAME=bookworm\n' > "$TMP/os2"
    [ "$(docker_repo_distro "$TMP/os2")" = "debian bookworm" ]
    printf 'ID=linuxmint\nID_LIKE="ubuntu debian"\nVERSION_CODENAME=wilma\nUBUNTU_CODENAME=noble\n' > "$TMP/os3"
    [ "$(docker_repo_distro "$TMP/os3")" = "ubuntu noble" ]
    printf 'ID=fedora\nVERSION_CODENAME=\n' > "$TMP/os4"
    run docker_repo_distro "$TMP/os4"; [ "$status" -ne 0 ]
    printf 'ID=ubuntu\nVERSION_CODENAME=$(id)\n' > "$TMP/os5"
    run docker_repo_distro "$TMP/os5"; [ "$status" -ne 0 ]
}

# ------------------------------------------------------------- systemd units
@test "systemd unit: explicit base compose file, overlays, stop (not down), sensor start" {
    INSTALL_DIR="$TMP"; : > "$TMP/docker-compose.yml"; : > "$TMP/docker-compose.tls.yml"
    body="$(systemd_unit_body)"
    [[ "$body" == *"-f $TMP/docker-compose.yml -f $TMP/docker-compose.tls.yml --env-file $TMP/.env up -d"* ]]
    [[ "$body" == *"ExecStop="*" stop"* ]]
    [[ "$body" != *" down"* ]]
    [[ "$body" == *"ExecStartPost=-$TMP/bin/sensor-start.sh --wait"* ]]
    : > "$TMP/docker-compose.email.yml"
    [[ "$(systemd_unit_body)" == *"-f $TMP/docker-compose.email.yml"* ]]
}

@test "backup timer units are well-formed; prune keeps the newest N" {
    INSTALL_DIR="$TMP"
    units="$(backup_timer_units)"
    [[ "$units" == *"ExecStart=$TMP/bin/backup.sh --quiet --keep 7"* ]]
    [[ "$units" == *"OnCalendar=*-*-* 02:30:00"* ]] && [[ "$units" == *"Persistent=true"* ]]
    as_root() { "$@"; }
    for i in 1 2 3 4 5; do : > "$TMP/sentinelcore-backup-1.0.1-2026010${i}T000000Z.tar.gz"; touch -d "2026-01-0$i" "$TMP/sentinelcore-backup-1.0.1-2026010${i}T000000Z.tar.gz"; done
    prune_backups "$TMP" 2 >/dev/null
    [ "$(find "$TMP" -maxdepth 1 -name 'sentinelcore-backup-*.tar.gz' | wc -l | tr -d ' ')" = 2 ]
    [ -e "$TMP/sentinelcore-backup-1.0.1-20260105T000000Z.tar.gz" ]
}

# ------------------------------------------------------------- rules helpers
@test "json_num reads helper status fields" {
    js='{"running":true,"pid":42,"rule_count":51234,"eve_log_age_seconds":1.5,"version":"7.0.10"}'
    [ "$(json_num "$js" rule_count)" = 51234 ]
    [ "$(json_num "$js" pid)" = 42 ]
    [ "$(json_num "$js" running)" = true ]
    [ "$(json_num "$js" eve_log_age_seconds)" = 1.5 ]
    [ "$(json_num '{"eve_log_age_seconds":null}' eve_log_age_seconds)" = null ]
}

@test "load_bundled_rules: no bundle -> warns and continues (dev tree)" {
    INSTALL_DIR="$TMP"
    run load_bundled_rules
    [ "$status" -eq 0 ]
    [[ "$output" == *"EMPTY ruleset"* ]]
}
