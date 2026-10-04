# shellcheck shell=bash
# relay.sh — register this install with the central email relay, receive a
# per-install token + sender address, and trigger the verification email to
# the admin. The real provider key never touches this box. No hidden calls:
# the ONLY endpoint contacted is $RELAY_URL/* (product.sh, fixed per build).
#
# Failure policy: if the relay is unreachable or refuses, the install
# CONTINUES with email off and prints how to enable it later
# (sudo $INSTALL_DIR/enable-email.sh).

RELAY_URL="${RELAY_URL:-https://relay.sentinelcore.app}"

relay_install_id() {
    # Unique per install, not reversible to the machine-id: a hash prefix of
    # the machine-id (groups re-installs of one host) + a random suffix (so a
    # re-install never collides with a previous registration).
    local mid h
    mid="$(cat /etc/machine-id 2>/dev/null || hostname 2>/dev/null || echo host)"
    h="$(printf '%s' "$mid" | sha256sum | cut -c1-12)"
    printf 'sc-%s-%s' "$h" "$(openssl rand -hex 4)"
}

relay_reachable() {
    curl -fsS --max-time 8 -o /dev/null "$RELAY_URL/v1/health" 2>/dev/null
}

_json_field() {
    # _json_field <json> <key> -> string value (flat JSON objects only).
    printf '%s' "$1" | grep -o "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 | sed 's/.*"\([^"]*\)"$/\1/'
}

email_disabled_notice() {
    warn "email notifications are OFF. To enable later (after fixing connectivity):"
    warn "    sudo $INSTALL_DIR/enable-email.sh"
}

relay_register() {
    step "Email relay registration"
    if [ "${EMAIL_MODE:-off}" != brevo ]; then
        good "email disabled — skipping relay registration"
        return 0
    fi
    RELAY_INSTALL_ID="${RELAY_INSTALL_ID:-$(relay_install_id)}"
    info "registering with relay $RELAY_URL (admin: $ADMIN_EMAIL, install: $RELAY_INSTALL_ID)"

    if [ "${DRY_RUN:-0}" = 1 ]; then
        info "[dry-run] GET  $RELAY_URL/v1/health (unreachable -> continue with email off)"
        info "[dry-run] POST $RELAY_URL/v1/register {admin_email, install_id, version} -> {token, sender_address}"
        info "[dry-run] relay emails a verification link to $ADMIN_EMAIL; sending is refused until it is clicked"
        RELAY_TOKEN="dryrun-relay-token-placeholder"; EMAIL_SENDER_ADDRESS="notify@example.invalid"
        add_secret relay_token "$RELAY_TOKEN"
        return 0
    fi

    if ! relay_reachable; then
        warn "relay $RELAY_URL is not reachable from this host"
        EMAIL_MODE=off; email_disabled_notice; return 0
    fi

    local body resp code
    body="{\"admin_email\":\"$(json_escape "$ADMIN_EMAIL")\",\"install_id\":\"$(json_escape "$RELAY_INSTALL_ID")\",\"version\":\"$(json_escape "$(pkg_version)")\"}"
    resp="$(printf '%s' "$body" | curl -sS --max-time 20 -w '\n%{http_code}' -X POST "$RELAY_URL/v1/register" \
        -H 'content-type: application/json' --data-binary @- 2>/dev/null || printf '\n000')"
    code="${resp##*$'\n'}"; resp="${resp%$'\n'*}"
    if [ "$code" != 200 ]; then
        warn "relay registration failed (HTTP $code: $(_json_field "$resp" error))"
        EMAIL_MODE=off; email_disabled_notice; return 0
    fi

    RELAY_TOKEN="$(_json_field "$resp" token)"
    EMAIL_SENDER_ADDRESS="$(_json_field "$resp" sender_address)"
    if [ -z "$RELAY_TOKEN" ] || [ -z "$EMAIL_SENDER_ADDRESS" ]; then
        warn "relay returned no token/sender"; EMAIL_MODE=off; email_disabled_notice; return 0
    fi
    add_secret relay_token "$RELAY_TOKEN"
    good "registered; per-install relay token stored in .env (redacted here)"
    warn "ACTION REQUIRED: open the verification link emailed to $ADMIN_EMAIL."
    warn "the relay refuses to send this install's mail until that link is clicked."
}
