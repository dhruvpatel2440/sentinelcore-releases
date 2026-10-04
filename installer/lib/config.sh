# shellcheck shell=bash
# config.sh — load/collect operator answers, validate them, and render .env
# from templates/.env.template. The admin password is NEVER written to .env;
# it is passed once to the bootstrap step (admin.sh) and hashed by the app.
#
# Validation functions are pure (no I/O, no globals) so they can be unit-tested
# with bats. They echo nothing and return 0/1.
#
# Globals set here and read by install.sh / admin.sh / tls.sh: ADMIN_*,
# EMAIL_MODE, TLS_MODE, BIND_ADDRESS, HTTP_PORT, HTTPS_PORT, TIMEZONE, ...
# shellcheck disable=SC2034

# ---- pure validators -----------------------------------------------------
valid_email()   { printf '%s' "$1" | grep -Eq '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'; }
valid_username(){ printf '%s' "$1" | grep -Eq '^[a-z_][a-z0-9_-]{2,31}$'; }
valid_port()    { case "$1" in ''|*[!0-9]*) return 1 ;; esac; [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
valid_iface()   { printf '%s' "$1" | grep -Eq '^[A-Za-z0-9._-]{1,15}$'; }
valid_email_mode() { case "$1" in off|brevo) return 0 ;; *) return 1 ;; esac; }
valid_tls_mode()   { case "$1" in self-signed|custom|http-local) return 0 ;; *) return 1 ;; esac; }
valid_base_url(){ printf '%s' "$1" | grep -Eq '^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?$'; }
valid_yesno()   { case "$1" in yes|no) return 0 ;; *) return 1 ;; esac; }

valid_timezone() {
    # Area/City style names (or UTC); checked against zoneinfo when present.
    printf '%s' "$1" | grep -Eq '^(UTC|[A-Za-z]+(/[A-Za-z0-9_+-]+){1,2})$' || return 1
    [ -d /usr/share/zoneinfo ] || return 0
    [ "$1" = UTC ] || [ -f "/usr/share/zoneinfo/$1" ]
}

valid_ipv4() {
    local ip="$1" o IFS=.
    printf '%s' "$ip" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || return 1
    for o in $ip; do [ "$o" -le 255 ] || return 1; done
    return 0
}

valid_cidr() {
    local ip="${1%/*}" bits="${1##*/}"
    case "$1" in */*) ;; *) return 1 ;; esac
    valid_ipv4 "$ip" || return 1
    case "$bits" in ''|*[!0-9]*) return 1 ;; esac
    [ "$bits" -ge 0 ] && [ "$bits" -le 32 ]
}

strong_password() {
    # >=12 chars, with at least one lower, upper, and digit. Any other
    # character (' " $ \ | & space ...) is allowed and must survive intact.
    local p="$1"
    [ "${#p}" -ge 12 ] || return 1
    [ "${#p}" -le 256 ] || return 1
    case "$p" in *[a-z]*) ;; *) return 1 ;; esac
    case "$p" in *[A-Z]*) ;; *) return 1 ;; esac
    case "$p" in *[0-9]*) ;; *) return 1 ;; esac
    case "$p" in *$'\n'*|*$'\r'*) return 1 ;; esac
    return 0
}

valid_protected_ips() {
    # comma-separated list of IPv4 addresses (non-empty).
    local list="$1" ip IFS=,
    [ -n "$list" ] || return 1
    for ip in $list; do valid_ipv4 "${ip// /}" || return 1; done
    return 0
}

tls_bind_ok() {
    # tls_bind_ok <tls_mode> <bind> — plain HTTP is only allowed on loopback:
    # the refresh cookie is Secure (ENVIRONMENT=production) and browsers keep
    # Secure cookies over HTTP only for 127.0.0.1/localhost.
    [ "$1" != http-local ] || [ "$2" = 127.0.0.1 ]
}

# ---- host checks (read-only) ---------------------------------------------
port_in_use() {
    # port_in_use <port> -> 0 if something listens on TCP <port>.
    command -v ss >/dev/null 2>&1 || return 1
    ss -Hltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]$1\$"
}

host_ipv4s() {
    command -v ip >/dev/null 2>&1 || return 0
    ip -o -4 addr show 2>/dev/null | awk '$2 !~ /^(docker|br-|veth|virbr)/ {print $4}' | cut -d/ -f1
}

bind_address_ok() {
    # 127.0.0.1 / 0.0.0.0, or an IPv4 address configured on this host.
    case "$1" in 127.0.0.1|0.0.0.0) return 0 ;; esac
    valid_ipv4 "$1" || return 1
    host_ipv4s | grep -qxF -- "$1"
}

primary_ipv4() {
    local dev=""
    command -v ip >/dev/null 2>&1 && dev="$(ip route 2>/dev/null | awk '/^default/{print $5; exit}')"
    [ -n "$dev" ] && ip -o -4 addr show "$dev" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1
}

ui_host() {
    # ui_host <bind> -> host to reach the UI from THIS machine (checks/login).
    case "$1" in 0.0.0.0|127.0.0.1|'') printf '127.0.0.1' ;; *) printf '%s' "$1" ;; esac
}

ui_url() {
    # ui_url <bind> <tls_mode> <http_port> <https_port> -> URL shown to humans
    # (the host's primary LAN IP when bound to all interfaces).
    local host="$1" mode="$2" hp="$3" sp="$4"
    if [ "$host" = 0.0.0.0 ]; then host="$(primary_ipv4)"; host="${host:-127.0.0.1}"; fi
    if [ "$mode" = http-local ]; then
        if [ "$hp" = 80 ]; then printf 'http://%s' "$host"; else printf 'http://%s:%s' "$host" "$hp"; fi
    else
        if [ "$sp" = 443 ]; then printf 'https://%s' "$host"; else printf 'https://%s:%s' "$host" "$sp"; fi
    fi
}

check_port_free() {
    # check_port_free <port> — hard check unless we are re-using our own install.
    if [ -n "${MODE_EXISTING:-}" ]; then return 0; fi
    if ! command -v ss >/dev/null 2>&1; then warn "ss not found — cannot check whether port $1 is free"; return 0; fi
    if port_in_use "$1"; then err "port $1 is already in use (see: sudo ss -ltnp 'sport = :$1')"; return 1; fi
    good "port $1 is free"
}

# ---- config files (allowlist, never executed) ------------------------------
CONFIG_KEYS="ADMIN_EMAIL ADMIN_USERNAME ADMIN_PASSWORD MONITORED_NETWORK PROTECTED_IPS CAPTURE_INTERFACE BIND_ADDRESS HTTP_PORT HTTPS_PORT TLS_MODE TLS_CERT_FILE TLS_KEY_FILE EMAIL_MODE TIMEZONE APP_BASE_URL UPDATE_RULES NIGHTLY_BACKUP"

_strip_quotes() {
    local v="$1"
    case "$v" in
        \"*\") v="${v#\"}"; v="${v%\"}" ;;
        \'*\') v="${v#\'}"; v="${v%\'}" ;;
    esac
    printf '%s' "$v"
}

load_config_file() {
    # load_config_file <file> — KEY=VALUE lines for an allowlist of keys.
    # Unknown keys or malformed lines are errors. Nothing is evaluated and no
    # variable name is ever taken from the file (explicit case per key).
    local file="$1" line key val n=0 bad=0
    [ -f "$file" ] || { err "config file not found: $file"; return 2; }
    local mode; mode="$(stat -c '%a' "$file" 2>/dev/null || echo '')"
    case "$mode" in *[1-7]) warn "config file $file is world-readable (mode $mode) and may hold the admin password — chmod 600 it" ;; esac
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        line="${line%$'\r'}"
        case "$line" in ''|\#*|[[:space:]]\#*) continue ;; esac
        if [[ ! "$line" =~ ^[[:space:]]*([A-Z_][A-Z0-9_]*)[[:space:]]*=(.*)$ ]]; then
            err "config line $n: not KEY=VALUE"; bad=1; continue
        fi
        key="${BASH_REMATCH[1]}"
        val="${BASH_REMATCH[2]}"
        val="${val#"${val%%[![:space:]]*}"}"; val="${val%"${val##*[![:space:]]}"}"
        val="$(_strip_quotes "$val")"
        case "$key" in
            ADMIN_EMAIL)       ADMIN_EMAIL="$val" ;;
            ADMIN_USERNAME)    ADMIN_USERNAME="$val" ;;
            ADMIN_PASSWORD)    ADMIN_PASSWORD="$val"; add_secret admin_password "$val" ;;
            MONITORED_NETWORK) MONITORED_NETWORK="$val" ;;
            PROTECTED_IPS)     PROTECTED_IPS="$val" ;;
            CAPTURE_INTERFACE) CAPTURE_INTERFACE="$val" ;;
            BIND_ADDRESS)      BIND_ADDRESS="$val" ;;
            HTTP_PORT)         HTTP_PORT="$val" ;;
            HTTPS_PORT)        HTTPS_PORT="$val" ;;
            TLS_MODE)          TLS_MODE="$val" ;;
            TLS_CERT_FILE)     TLS_CERT_FILE="$val" ;;
            TLS_KEY_FILE)      TLS_KEY_FILE="$val" ;;
            EMAIL_MODE)        EMAIL_MODE="$val" ;;
            TIMEZONE)          TIMEZONE="$val" ;;
            APP_BASE_URL)      APP_BASE_URL="$val" ;;
            UPDATE_RULES)      UPDATE_RULES="$val" ;;
            NIGHTLY_BACKUP)    NIGHTLY_BACKUP="$val" ;;
            *) err "config line $n: unknown key '$key' (allowed: $CONFIG_KEYS)"; bad=1 ;;
        esac
    done < "$file"
    [ "$bad" = 0 ] || return 2
    good "loaded config: $file"
}

env_get() {
    # env_get <file> <KEY> -> value of KEY in a dotenv file (read-only).
    [ -f "$1" ] || return 0
    sed -n "s/^$2=//p" "$1" | tail -1 | tr -d '\r'
}

set_env_value() {
    # set_env_value <file> <KEY> <value> — replace (or append) one key in a
    # dotenv file, preserving mode 600. Pure bash: values are never parsed.
    local file="$1" key="$2" val="$3" line out="" found=0
    while IFS= read -r line || [ -n "$line" ]; do
        if [ "${line%%=*}" = "$key" ] && [ "$line" != "${line#*=}" ]; then
            line="$key=$val"; found=1
        fi
        out+="$line"$'\n'
    done < "$file"
    [ "$found" = 1 ] || out+="$key=$val"$'\n'
    ( umask 077; printf '%s' "$out" > "$file.tmp" ) && chmod 600 "$file.tmp" && mv -f "$file.tmp" "$file"
}

del_env_value() {
    # del_env_value <file> <KEY> — drop one key from a dotenv file (mode 600).
    local file="$1" key="$2" line out=""
    while IFS= read -r line || [ -n "$line" ]; do
        if [ "${line%%=*}" = "$key" ] && [ "$line" != "${line#*=}" ]; then continue; fi
        out+="$line"$'\n'
    done < "$file"
    ( umask 077; printf '%s' "$out" > "$file.tmp" ) && chmod 600 "$file.tmp" && mv -f "$file.tmp" "$file"
}

load_existing_env() {
    # Repair/upgrade: recover the operator's choices from the deployed .env.
    # 1.0.0 installs had WEB_PORT and no TLS_MODE (plain HTTP).
    local f="$1" legacy_port
    BIND_ADDRESS="$(env_get "$f" BIND_ADDRESS)"; BIND_ADDRESS="${BIND_ADDRESS:-127.0.0.1}"
    legacy_port="$(env_get "$f" WEB_PORT)"
    HTTP_PORT="$(env_get "$f" HTTP_PORT)"; HTTP_PORT="${HTTP_PORT:-${legacy_port:-80}}"
    HTTPS_PORT="$(env_get "$f" HTTPS_PORT)"; HTTPS_PORT="${HTTPS_PORT:-443}"
    TLS_MODE="$(env_get "$f" TLS_MODE)"
    if [ -z "$TLS_MODE" ]; then
        if [ "$BIND_ADDRESS" = 127.0.0.1 ]; then TLS_MODE=http-local; else TLS_MODE=self-signed; fi
    fi
    CAPTURE_INTERFACE="$(env_get "$f" CAPTURE_INTERFACE)"
    MONITORED_NETWORK="$(env_get "$f" MONITORED_NETWORK)"
    EMAIL_MODE="$(env_get "$f" EMAIL_MODE)"; EMAIL_MODE="${EMAIL_MODE:-off}"
    ADMIN_USERNAME="$(env_get "$f" SEED_ADMIN_USERNAME)"
    ADMIN_EMAIL="$(env_get "$f" SEED_ADMIN_EMAIL)"
    APP_BASE_URL="$(env_get "$f" APP_BASE_URL)"
    TIMEZONE="$(env_get "$f" TZ)"; TIMEZONE="${TIMEZONE:-UTC}"
}

# ---- collection ----------------------------------------------------------
_interactive() { [ "${NON_INTERACTIVE:-0}" != 1 ] && [ "${DRY_RUN:-0}" != 1 ]; }

ask_valid() {
    # ask_valid <var> <prompt> <default> <validator> <error> — re-ask until the
    # validator passes (interactive); validated once later otherwise.
    local __v="$1" prompt="$2" def="$3" check="$4" msg="$5"
    while :; do
        ask_input "$__v" "$prompt" "$def"
        _interactive || return 0
        "$check" "${!__v}" && return 0
        warn "$msg"
        def="${!__v}"
    done
}

collect_admin_password() {
    if _interactive; then
        while :; do
            ask_secret ADMIN_PASSWORD "Administrator password (>=12 chars, upper+lower+digit; any symbols allowed)" || { err "cancelled"; return 1; }
            strong_password "$ADMIN_PASSWORD" && break
            warn "password too weak: needs >=12 characters with upper, lower and a digit"
        done
        ADMIN_PASSWORD_GENERATED=0
    elif [ -n "${ADMIN_PASSWORD:-}" ]; then
        ADMIN_PASSWORD_GENERATED=0
    else
        # Non-interactive without a password: generate locally, show once.
        if [ "${DRY_RUN:-0}" = 1 ]; then
            ADMIN_PASSWORD="DryRun-Placeholder-0000"
        else
            ADMIN_PASSWORD="$(gen_admin_password)" || { err "could not generate an admin password"; return 1; }
        fi
        ADMIN_PASSWORD_GENERATED=1
        info "no admin password supplied — generated one locally (shown once at the end)"
    fi
    add_secret admin_password "$ADMIN_PASSWORD"
}

collect_email_choice() {
    local def=y
    [ "${EMAIL_MODE:-}" = off ] && def=n
    if ask_yesno "Enable email notifications via the SentinelCore relay? (y/n)" "$def"; then
        EMAIL_MODE=brevo
    else
        EMAIL_MODE=off
    fi
    info "email notifications: $([ "$EMAIL_MODE" = brevo ] && echo "enabled (via relay ${RELAY_URL:-?})" || echo disabled)"
}

collect_tls_choice() {
    TLS_MODE="${TLS_MODE:-self-signed}"
    ask_menu TLS_MODE "How should the web UI be served?" \
        self-signed "HTTPS with a certificate generated for this host (recommended)" \
        custom      "HTTPS with my own certificate + key (files on this host)" \
        http-local  "Plain HTTP on 127.0.0.1 only (this machine only, no LAN access)" || { err "cancelled"; return 1; }
    if [ "$TLS_MODE" = custom ]; then
        ask_valid TLS_CERT_FILE "Path to the certificate (PEM, full chain)" "${TLS_CERT_FILE:-}" test_readable_file "file not found or not readable"
        ask_valid TLS_KEY_FILE "Path to the private key (PEM, unencrypted)" "${TLS_KEY_FILE:-}" test_readable_file "file not found or not readable"
    fi
    if [ "$TLS_MODE" = http-local ]; then
        if [ -n "${BIND_ADDRESS:-}" ] && [ "$BIND_ADDRESS" != 127.0.0.1 ]; then
            warn "plain HTTP on $BIND_ADDRESS would break login refresh (Secure cookie) — HTTP is loopback-only"
            _interactive || return 0   # non-interactive: validate_config blocks it
        fi
        BIND_ADDRESS=127.0.0.1
        info "plain HTTP: the UI will listen on 127.0.0.1 only"
    fi
}

test_readable_file() { [ -n "$1" ] && [ -r "$1" ] && [ -f "$1" ]; }

collect_ports() {
    if [ "$TLS_MODE" != http-local ]; then
        ask_valid BIND_ADDRESS "Bind address (0.0.0.0 = all interfaces, 127.0.0.1 = this machine only, or one host IP)" "${BIND_ADDRESS:-0.0.0.0}" bind_address_ok \
            "use 127.0.0.1, 0.0.0.0, or an IPv4 address of this host ($(host_ipv4s | tr '\n' ' '))"
        while :; do
            ask_valid HTTPS_PORT "HTTPS port" "${HTTPS_PORT:-443}" valid_port "port must be 1-65535"
            _interactive || break
            check_port_free "$HTTPS_PORT" && break
        done
    fi
    while :; do
        ask_valid HTTP_PORT "$([ "$TLS_MODE" = http-local ] && echo 'Web (HTTP) port' || echo 'HTTP port (redirects to HTTPS)')" "${HTTP_PORT:-80}" valid_port "port must be 1-65535"
        _interactive || break
        if [ "$TLS_MODE" != http-local ] && [ "$HTTP_PORT" = "${HTTPS_PORT:-}" ]; then warn "HTTP and HTTPS ports must differ"; continue; fi
        check_port_free "$HTTP_PORT" && break
    done
}

collect_config() {
    step "Configuration"
    ask_valid ADMIN_EMAIL "Administrator email" "${ADMIN_EMAIL:-}" valid_email "invalid email address"
    ask_valid ADMIN_USERNAME "Administrator username" "${ADMIN_USERNAME:-admin}" valid_username \
        "username: 3-32 chars of a-z 0-9 _ -, starting with a letter or _"
    collect_admin_password || return 1
    ask_valid MONITORED_NETWORK "Monitored network (CIDR)" "${MONITORED_NETWORK:-${SUGGEST_MONITORED_NETWORK:-}}" valid_cidr "invalid CIDR (e.g. 192.168.1.0/24)"
    ask_valid PROTECTED_IPS "Protected IPs (gateway,DNS,self — never blocked)" "${PROTECTED_IPS:-${SUGGEST_PROTECTED_IPS:-}}" valid_protected_ips "comma-separated IPv4 list required"
    collect_tls_choice || return 1
    collect_ports
    HTTP_PORT="${HTTP_PORT:-80}"; HTTPS_PORT="${HTTPS_PORT:-443}"
    ask_valid APP_BASE_URL "App base URL (used in email links)" "${APP_BASE_URL:-$(ui_url "$BIND_ADDRESS" "$TLS_MODE" "$HTTP_PORT" "$HTTPS_PORT")}" valid_base_url "must look like http(s)://host[:port][/path]"
    ask_valid TIMEZONE "Timezone (e.g. UTC, Europe/Berlin, Asia/Kolkata)" "${TIMEZONE:-$(cat /etc/timezone 2>/dev/null || echo UTC)}" valid_timezone "unknown timezone (see: timedatectl list-timezones)"
    collect_email_choice
    if [ "$BIND_ADDRESS" = "0.0.0.0" ]; then
        warn "bind 0.0.0.0 exposes the web UI on ALL interfaces."
        warn "recommended: restrict it, e.g. 'sudo ufw allow from <admin-subnet> to any port $HTTPS_PORT proto tcp'."
    fi
}

validate_config() {
    step "Validate inputs"
    local rc=0
    valid_email "$ADMIN_EMAIL"            || { err "invalid admin email: $ADMIN_EMAIL"; rc=1; }
    valid_username "$ADMIN_USERNAME"      || { err "invalid username (3-32, [a-z0-9_-], must start a-z/_)"; rc=1; }
    strong_password "${ADMIN_PASSWORD:-}" || { err "admin password too weak (>=12, upper+lower+digit)"; rc=1; }
    valid_cidr "$MONITORED_NETWORK"       || { err "invalid monitored network CIDR: $MONITORED_NETWORK"; rc=1; }
    valid_protected_ips "$PROTECTED_IPS"  || { err "invalid protected IPs: $PROTECTED_IPS"; rc=1; }
    valid_tls_mode "${TLS_MODE:-}"        || { err "TLS_MODE must be self-signed, custom or http-local (got '${TLS_MODE:-}')"; rc=1; }
    valid_port "${HTTP_PORT:-}"           || { err "invalid HTTP port: ${HTTP_PORT:-}"; rc=1; }
    valid_port "${HTTPS_PORT:-}"          || { err "invalid HTTPS port: ${HTTPS_PORT:-}"; rc=1; }
    valid_ipv4 "$BIND_ADDRESS"            || { err "invalid bind address: $BIND_ADDRESS"; rc=1; }
    valid_iface "${CAPTURE_INTERFACE:-}"  || { err "invalid capture interface: ${CAPTURE_INTERFACE:-}"; rc=1; }
    valid_email_mode "${EMAIL_MODE:-}"    || { err "EMAIL_MODE must be off or brevo (got '${EMAIL_MODE:-}')"; rc=1; }
    valid_base_url "${APP_BASE_URL:-}"    || { err "invalid APP_BASE_URL: ${APP_BASE_URL:-}"; rc=1; }
    valid_timezone "${TIMEZONE:-UTC}"     || { err "unknown timezone: ${TIMEZONE:-}"; rc=1; }
    valid_yesno "${UPDATE_RULES:-no}"     || { err "UPDATE_RULES must be yes or no"; rc=1; }
    valid_yesno "${NIGHTLY_BACKUP:-no}"   || { err "NIGHTLY_BACKUP must be yes or no"; rc=1; }
    if ! tls_bind_ok "${TLS_MODE:-}" "$BIND_ADDRESS"; then
        err "TLS_MODE=http-local requires BIND_ADDRESS=127.0.0.1: over plain HTTP on a LAN address browsers drop the Secure refresh cookie and users are logged out every 15 minutes. Use self-signed or custom TLS for LAN access."
        rc=1
    fi
    if [ "${TLS_MODE:-}" = custom ]; then
        test_readable_file "${TLS_CERT_FILE:-}" || { err "TLS_CERT_FILE not readable: ${TLS_CERT_FILE:-<unset>}"; rc=1; }
        test_readable_file "${TLS_KEY_FILE:-}"  || { err "TLS_KEY_FILE not readable: ${TLS_KEY_FILE:-<unset>}"; rc=1; }
    fi
    if [ "${TLS_MODE:-}" != http-local ] && [ "${HTTP_PORT:-}" = "${HTTPS_PORT:-}" ]; then
        err "HTTP_PORT and HTTPS_PORT must differ"; rc=1
    fi
    if valid_ipv4 "$BIND_ADDRESS" && ! bind_address_ok "$BIND_ADDRESS"; then
        if [ "${DRY_RUN:-0}" = 1 ]; then warn "[dry-run] bind address $BIND_ADDRESS is not configured on this host"
        else err "bind address $BIND_ADDRESS is not an address of this host (use 127.0.0.1, 0.0.0.0, or one of: $(host_ipv4s | tr '\n' ' '))"; rc=1; fi
    fi
    local p ports=("$HTTP_PORT"); [ "${TLS_MODE:-}" != http-local ] && ports+=("$HTTPS_PORT")
    for p in "${ports[@]}"; do
        if valid_port "$p" && ! check_port_free "$p"; then
            if [ "${DRY_RUN:-0}" = 1 ]; then warn "[dry-run] a real install would stop here: port $p busy"; else rc=1; fi
        fi
    done
    [ "$rc" = 0 ] && good "inputs valid"
    return "$rc"
}

# ---- .env rendering ------------------------------------------------------
render_env() {
    # render_env <template> <out-path> — fill KEY= lines from the operator's
    # answers + generated secrets (pure bash, no sed on values), mode 600.
    local tmpl="$1" out="$2"
    [ -f "$tmpl" ] || { err "template not found: $tmpl"; return 1; }
    generate_secrets

    local -A V=(
        [POSTGRES_PASSWORD]="${SECRETS[postgres_password]}"
        [DATABASE_URL]="postgresql+asyncpg://sentinelcore:${SECRETS[postgres_password]}@localhost:5433/sentinelcore"
        [SECRET_KEY]="${SECRETS[secret_key]}"
        [BREVO_WEBHOOK_SECRET]="${SECRETS[webhook_secret]}"
        [SEED_ADMIN_USERNAME]="$ADMIN_USERNAME"
        [SEED_ADMIN_EMAIL]="$ADMIN_EMAIL"
        [CAPTURE_INTERFACE]="$CAPTURE_INTERFACE"
        [MONITORED_NETWORK]="$MONITORED_NETWORK"
        [PROTECTED_IPS]="$PROTECTED_IPS"
        [TLS_MODE]="$TLS_MODE"
        [BIND_ADDRESS]="$BIND_ADDRESS"
        [HTTP_PORT]="$HTTP_PORT"
        [HTTPS_PORT]="$HTTPS_PORT"
        [TZ]="${TIMEZONE:-UTC}"
        [EMAIL_MODE]="${EMAIL_MODE:-off}"
        [RELAY_URL]="${RELAY_URL:-}"
        [RELAY_INSTALL_ID]="${RELAY_INSTALL_ID:-}"
        [BREVO_API_KEY]="${RELAY_TOKEN:-}"
        [EMAIL_SENDER_ADDRESS]="${EMAIL_SENDER_ADDRESS:-}"
        [APP_BASE_URL]="$APP_BASE_URL"
    )

    local line key content=""
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        case "$line" in
            [A-Z]*=*)
                key="${line%%=*}"
                if [[ -v V[$key] ]]; then line="$key=${V[$key]}"; fi
                ;;
        esac
        content+="$line"$'\n'
    done < "$tmpl"

    if printf '%s' "$content" | grep -vE '^[[:space:]]*#' | grep -Eq '__[A-Z_]+__'; then
        err "unrendered placeholder(s) left in .env: $(printf '%s' "$content" | grep -vE '^[[:space:]]*#' | grep -Eo '__[A-Z_]+__' | sort -u | tr '\n' ' ')"
        return 1
    fi

    if [ "${DRY_RUN:-0}" = 1 ]; then
        info "[dry-run] would write $out (mode 600). Rendered keys:"
        printf '%s' "$content" | grep -E '^[A-Z_]+=' | sed -E 's/=(.*)/=<set>/' | sed 's/^/    /'
        return 0
    fi
    ( umask 077; printf '%s' "$content" > "$out" )
    chmod 600 "$out"
    good "wrote $out (mode 600)"
}
