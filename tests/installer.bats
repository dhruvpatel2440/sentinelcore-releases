#!/usr/bin/env bats
# bats tests for the installer libs: validators, config loader (A8), .env
# rendering (A5/A6), suricata rendering (A2), health wait (A3), admin
# password transport + login JSON (A4), and log redaction (A10).
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
    . "$REPO/installer/lib/secrets.sh"
    . "$REPO/installer/lib/config.sh"
    . "$REPO/installer/lib/sensors.sh"
    . "$REPO/installer/lib/services.sh"
    . "$REPO/installer/lib/admin.sh"
    . "$REPO/installer/lib/tls.sh"
    TEMPLATE="$REPO/build/overlay/templates/.env.template"
    # Passwords that break naive quoting: ' " $ \ space | & and friends.
    TRICKY=(
        "It's-a-Pass1word"
        'Quote"Double2Pass'
        'Dollar$HOME$(id)3Xx'
        'Back\slash\\n4Xxxx'
        'Space and | pipe & amp 5X'
        "Mix'\"\$\\ |&;<>*?\`X6y"
    )
}

teardown() { rm -rf "$TMP"; }

base_answers() {
    ADMIN_EMAIL="admin@example.org"; ADMIN_USERNAME="admin"
    MONITORED_NETWORK="10.20.0.0/24"; PROTECTED_IPS="10.20.0.1"
    CAPTURE_INTERFACE="enp0s9"; EMAIL_MODE="off"; APP_BASE_URL="http://127.0.0.1:8080"
    BIND_ADDRESS="127.0.0.1"; WEB_PORT="8080"; TIMEZONE="UTC"
    RELAY_URL="https://relay.example.org"; RELAY_INSTALL_ID="sc-abc-123"
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

@test "ipv4 / cidr / port validators are strict" {
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
    port_in_use() { [ "$1" = 8080 ]; }
    command() { [ "$2" = ss ] && return 0; builtin command "$@"; }
    run check_web_port_free 8080; [ "$status" -ne 0 ]
    run check_web_port_free 9090; [ "$status" -eq 0 ]
}

@test "ui_host / ui_url use the chosen bind + port" {
    [ "$(ui_host 0.0.0.0)" = 127.0.0.1 ]
    [ "$(ui_host 192.168.56.10)" = 192.168.56.10 ]
    [ "$(ui_url 127.0.0.1 8080)" = "http://127.0.0.1:8080" ]
    [ "$(ui_url 127.0.0.1 80)" = "http://127.0.0.1" ]
}

# ------------------------------------------------------- A8: config loader
@test "load_config_file: allowlisted keys load, quotes stripped" {
    cat > "$TMP/c.conf" <<'EOF'
# comment
ADMIN_EMAIL=admin@example.org
ADMIN_PASSWORD='It''s"weird$1Aa xx'
WEB_PORT="8080"
BIND_ADDRESS = 127.0.0.1
EMAIL_MODE=off
EOF
    chmod 600 "$TMP/c.conf"
    load_config_file "$TMP/c.conf"
    [ "$ADMIN_EMAIL" = admin@example.org ]
    [ "$WEB_PORT" = 8080 ]
    [ "$BIND_ADDRESS" = 127.0.0.1 ]
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
@test "render_env: all placeholders filled, A5/A6 keys rendered, no password" {
    base_answers
    ADMIN_PASSWORD='Secret$Pass1word'
    render_env "$TEMPLATE" "$TMP/.env"
    run bash -c "grep -vE '^[[:space:]]*#' '$TMP/.env' | grep -E '__[A-Z_]+__'"; [ "$status" -ne 0 ]
    grep -qx "BIND_ADDRESS=127.0.0.1" "$TMP/.env"
    grep -qx "WEB_PORT=8080" "$TMP/.env"
    grep -qx "EMAIL_MODE=off" "$TMP/.env"
    grep -qx "COMPOSE_PROFILES=" "$TMP/.env"
    grep -qx "RELAY_URL=https://relay.example.org" "$TMP/.env"
    grep -qx "CAPTURE_INTERFACE=enp0s9" "$TMP/.env"
    grep -qx "REQUESTS_CA_BUNDLE=/etc/sentinelcore/ca-bundle.pem" "$TMP/.env"
    grep -Eq "^SECRET_KEY=[0-9a-f]{64}$" "$TMP/.env"
    run grep -F 'Secret$Pass1word' "$TMP/.env"; [ "$status" -ne 0 ]
    run grep -E '^SEED_ADMIN_PASSWORD=' "$TMP/.env"; [ "$status" -ne 0 ]
}

@test "render_env: email on sets profile + relay token" {
    base_answers
    EMAIL_MODE=brevo RELAY_TOKEN="relaytok-0123456789" EMAIL_SENDER_ADDRESS="notify@example.org"
    render_env "$TEMPLATE" "$TMP/.env"
    grep -qx "EMAIL_MODE=brevo" "$TMP/.env"
    grep -qx "COMPOSE_PROFILES=email" "$TMP/.env"
    grep -qx "BREVO_API_KEY=relaytok-0123456789" "$TMP/.env"
}

@test "render_env: file mode is 600 (on POSIX filesystems)" {
    base_answers
    render_env "$TEMPLATE" "$TMP/.env"
    perm="$(stat -c '%a' "$TMP/.env")"
    case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) skip "NTFS cannot express mode 600" ;; esac
    [ "$perm" = 600 ]
}

@test "set_env_value replaces one key and keeps the rest" {
    printf 'A=1\nEMAIL_MODE=off\nB=2\n' > "$TMP/e"
    set_env_value "$TMP/e" EMAIL_MODE brevo
    set_env_value "$TMP/e" NEWKEY 'v$x'
    [ "$(cat "$TMP/e")" = "$(printf 'A=1\nEMAIL_MODE=brevo\nB=2\nNEWKEY=v$x')" ]
}

# ------------------------------------------------------ A2: suricata render
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

# ---------------------------------------------------------- A3: health wait
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

@test "wait_healthy: relay-shim is required when email is on" {
    fake_docker_health "db=healthy redis=healthy helper=healthy backend=healthy worker=healthy nginx=healthy relay-shim=starting"
    HEALTH_TIMEOUT=1 EMAIL_MODE=brevo
    run wait_healthy
    [ "$status" -ne 0 ]
    [[ "$output" == *"relay-shim=starting"* ]]
}

# -------------------------------------------- A4: admin password transport
@test "seed: tricky passwords reach the container env byte-for-byte, never argv" {
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

@test "verify_login: JSON body on stdin decodes to the exact password; argv clean" {
    PY=""
    for c in python3 python; do "$c" -c 'import json' >/dev/null 2>&1 && { PY="$c"; break; }; done
    [ -n "$PY" ] || skip "python needed to decode JSON"
    mkdir -p "$TMP/bin"
    cat > "$TMP/bin/curl" <<EOF
#!/usr/bin/env bash
cat > "$TMP/body.json"
printf '%s\n' "\$@" > "$TMP/curl.argv"
printf '200'
EOF
    chmod +x "$TMP/bin/curl"; PATH="$TMP/bin:$PATH"
    BIND_ADDRESS=127.0.0.1 WEB_PORT=8080 ADMIN_USERNAME=admin
    for pw in "${TRICKY[@]}"; do
        ADMIN_PASSWORD="$pw"
        verify_login >/dev/null
        decoded="$("$PY" -c 'import json,sys; sys.stdout.write(json.load(open(sys.argv[1]))["password"])' "$TMP/body.json")"
        [ "$decoded" = "$pw" ]
        run grep -F -- "$pw" "$TMP/curl.argv"; [ "$status" -ne 0 ]
        grep -q "http://127.0.0.1:8080/api/auth/login" "$TMP/curl.argv"
    done
}

@test "verify_login: non-interactive hard-fails on 401 after one re-apply" {
    mkdir -p "$TMP/bin"
    printf '#!/usr/bin/env bash\ncat >/dev/null\nprintf 401\n' > "$TMP/bin/curl"
    chmod +x "$TMP/bin/curl"; PATH="$TMP/bin:$PATH"
    set_admin_password() { echo reapplied >> "$TMP/reapply"; }
    BIND_ADDRESS=127.0.0.1 WEB_PORT=8080 ADMIN_USERNAME=admin ADMIN_PASSWORD="Abcdefgh1234"
    run verify_login
    [ "$status" -ne 0 ]
    [ "$(wc -l < "$TMP/reapply" | tr -d ' ')" = 1 ]
}

@test "gen_admin_password always satisfies strong_password" {
    for _ in 1 2 3 4 5 6 7 8 9 10; do strong_password "$(gen_admin_password)"; done
}

# -------------------------------------------------- A10: log redaction
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

# ------------------------------------------------- A7: CA key never persists
@test "gen_install_ca: leaf for api.brevo.com issued, CA key destroyed, bundle has CA" {
    command -v openssl >/dev/null 2>&1 || skip "openssl needed"
    as_root() { "$@"; }
    install() {   # drop -o/-g (no root in tests); keep modes
        local a=()
        local win=0; case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) win=1 ;; esac
        while [ $# -gt 0 ]; do
            case "$1" in
                -o|-g) shift 2 ;;
                -m) if [ "$win" = 1 ]; then shift 2; else a+=("$1" "$2"); shift 2; fi ;;   # NTFS: no modes
                *) a+=("$1"); shift ;;
            esac
        done
        command install "${a[@]}"
    }
    export MSYS2_ARG_CONV_EXCL="/CN="   # Git-Bash only: keep -subj intact
    INSTALL_DIR="$TMP/opt"; mkdir -p "$INSTALL_DIR"
    printf -- '-----BEGIN CERTIFICATE-----
systemroot
-----END CERTIFICATE-----
' > "$TMP/roots.pem"
    SYSTEM_CA_BUNDLE="$TMP/roots.pem" EMAIL_MODE=brevo
    gen_install_ca
    [ -s "$INSTALL_DIR/tls/api.brevo.com.crt" ]
    [ -s "$INSTALL_DIR/tls/api.brevo.com.key" ]
    [ -s "$INSTALL_DIR/ca.crt" ]
    [ -z "$(find "$INSTALL_DIR" -name '*ca.key*')" ]
    [ "$(ls "$INSTALL_DIR/tls" | sort | tr '
' ' ')" = "api.brevo.com.crt api.brevo.com.key " ]
    openssl verify -CAfile "$INSTALL_DIR/ca.crt" "$INSTALL_DIR/tls/api.brevo.com.crt"
    openssl x509 -in "$INSTALL_DIR/tls/api.brevo.com.crt" -noout -text | grep -q "DNS:api.brevo.com"
    grep -q systemroot "$INSTALL_DIR/ca-bundle.pem"
    grep -c "BEGIN CERTIFICATE" "$INSTALL_DIR/ca-bundle.pem" | grep -qx 2
    case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) ;; *)
        [ "$(stat -c '%a' "$INSTALL_DIR/tls")" = 700 ]
        [ "$(stat -c '%a' "$INSTALL_DIR/tls/api.brevo.com.key")" = 600 ] ;;
    esac
}

@test "gen_install_ca: no-op when email is off" {
    INSTALL_DIR="$TMP/opt2"; mkdir -p "$INSTALL_DIR"; EMAIL_MODE=off
    gen_install_ca
    [ ! -e "$INSTALL_DIR/tls" ]
}
