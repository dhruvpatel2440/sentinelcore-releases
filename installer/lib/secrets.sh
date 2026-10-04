# shellcheck shell=bash
# secrets.sh — openssl-based secret generation. Generated values are
# registered with add_secret (ui.sh) so they are redacted from all output.

gen_hex()    { openssl rand -hex "${1:-32}"; }

gen_password() {
    # Alphanumeric strong password of length $1 (default 24).
    local len="${1:-24}"
    openssl rand -base64 48 | tr -d '\n' | tr -d '+/=' | cut -c1-"$len"
}

gen_admin_password() {
    # A password that always satisfies strong_password (config.sh): retry the
    # (rare) draw that lacks a lower/upper/digit.
    local p i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        p="$(gen_password 20)"
        if strong_password "$p"; then printf '%s' "$p"; return 0; fi
        : "$i"
    done
    return 1
}

generate_secrets() {
    # Populate SECRETS[...] once. Idempotent within a run.
    [ "${SECRETS_INITIALIZED:-0}" = 1 ] && return 0
    add_secret postgres_password "$(gen_password 28)"
    add_secret secret_key "$(gen_hex 32)"
    add_secret webhook_secret "$(gen_hex 32)"
    SECRETS_INITIALIZED=1
    log INFO "secrets generated (values redacted)"
}
