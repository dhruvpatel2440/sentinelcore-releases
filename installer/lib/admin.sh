# shellcheck shell=bash
# admin.sh — create the first admin with the OPERATOR'S password using the
# app's own mechanism, then prove it by logging in. See
# docs-internal/admin-bootstrap.md for why the order matters.
#
# How the password travels (never argv, never a file, never .env):
#   SEED_ADMIN_PASSWORD="$pw" docker compose run --rm -e SEED_ADMIN_PASSWORD backend ...
# `-e NAME` without a value makes compose copy NAME from its own process
# environment into the one-shot container, so `ps` only ever shows the
# variable NAME. No shell re-parsing happens, so ' " $ \ | & and spaces are
# passed byte-for-byte. Under sudo, --preserve-env=SEED_ADMIN_PASSWORD carries it.
# Why not a temporary --env-file: it would put the password on disk, and
# `shred` is not reliable on journaling/CoW filesystems or SSDs. The process
# environment is root-only (/proc/<pid>/environ is 0400) and never persists.
#
# The one-shot container's ENTRYPOINT (main's entrypoint.sh) waits for the DB,
# runs `alembic upgrade head`, then `python -m scripts.seed_admin` with the
# password from the environment. The CMD is a no-op print so the seed runs
# exactly once.

INSTALL_DIR="${INSTALL_DIR:-/opt/sentinelcore}"
LOGIN_CURL_TLS=()

_dc_with_pw() {
    # _dc_with_pw <compose args...> — run docker compose with ONLY this
    # process carrying SEED_ADMIN_PASSWORD / SEED_ADMIN_USERNAME.
    local f; mapfile -t f < <(compose_files); f+=(--env-file "$INSTALL_DIR/.env")
    if [ "$(id -u)" -eq 0 ]; then
        SEED_ADMIN_PASSWORD="$ADMIN_PASSWORD" SEED_ADMIN_USERNAME="$ADMIN_USERNAME" \
            docker compose "${f[@]}" "$@"
    else
        SEED_ADMIN_PASSWORD="$ADMIN_PASSWORD" SEED_ADMIN_USERNAME="$ADMIN_USERNAME" \
            sudo --preserve-env=SEED_ADMIN_PASSWORD,SEED_ADMIN_USERNAME docker compose "${f[@]}" "$@"
    fi
}

_show_redacted() { local l; while IFS= read -r l; do log INFO "  $l"; printf '  %s\n' "$(_redact "$l")"; done; }

bootstrap_admin() {
    # Runs ONCE on a fresh install, after db/redis are healthy and BEFORE the
    # first normal backend start (whose entrypoint would otherwise seed the
    # admin with a random password first).
    step "Create administrator (one-time seed, before first backend start)"
    add_secret admin_password "$ADMIN_PASSWORD"
    if [ "${DRY_RUN:-0}" = 1 ]; then
        info "[dry-run] SEED_ADMIN_PASSWORD=<redacted> docker compose run --rm --no-deps -e SEED_ADMIN_PASSWORD -e SEED_ADMIN_USERNAME backend python -c 'print(\"[bootstrap] done\")'"
        info "[dry-run]   (entrypoint: wait for db -> alembic upgrade head -> seed admin '$ADMIN_USERNAME')"
        return 0
    fi
    local out rc=0
    out="$(_dc_with_pw run --rm --no-deps -e SEED_ADMIN_PASSWORD -e SEED_ADMIN_USERNAME backend python -c 'print("[bootstrap] done")' 2>&1)" || rc=$?
    printf '%s\n' "$out" | grep -v '^\s*$' | tail -n 15 | _show_redacted
    if [ "$rc" -ne 0 ]; then err "admin seed failed (exit $rc)"; return 1; fi
    if printf '%s' "$out" | grep -q 'GENERATED PASSWORD'; then
        err "the app generated its own password — SEED_ADMIN_PASSWORD did not reach the container"; return 1
    fi
    if printf '%s' "$out" | grep -q 'already exists'; then
        warn "an admin '$ADMIN_USERNAME' already existed in the database (left-over data volume?)"
        set_admin_password || return 1
    fi
    good "administrator '$ADMIN_USERNAME' created with the chosen password"
}

set_admin_password() {
    # Force the existing admin's password to $ADMIN_PASSWORD using the app's
    # own hash_password (no source change; one-shot container).
    info "setting the password of '$ADMIN_USERNAME' to the chosen one"
    [ "${DRY_RUN:-0}" = 1 ] && { info "[dry-run] one-shot: app.core.security.hash_password -> users.password_hash"; return 0; }
    local py out rc=0
    py='import asyncio, os
from sqlalchemy import select
from app.core.security import hash_password
from app.db.session import SessionLocal, engine
from app.models.user import User

async def main():
    try:
        async with SessionLocal() as db:
            user = await db.scalar(select(User).where(User.username == os.environ["SEED_ADMIN_USERNAME"]))
            if user is None:
                print("admin user not found")
                return 1
            user.password_hash = hash_password(os.environ["SEED_ADMIN_PASSWORD"])
            user.is_active = True
            await db.commit()
            print("admin password set")
            return 0
    finally:
        await engine.dispose()

raise SystemExit(asyncio.run(main()))'
    out="$(_dc_with_pw run --rm --no-deps -e SEED_ADMIN_PASSWORD -e SEED_ADMIN_USERNAME backend python -c "$py" 2>&1)" || rc=$?
    printf '%s\n' "$out" | tail -n 3 | _show_redacted
    [ "$rc" -eq 0 ] || { err "could not set the admin password (exit $rc)"; return 1; }
}

LOGIN_HEADERS=""

LOGIN_CODE=""

_login_code() {
    # POST the credentials as JSON on stdin (never on the command line). Sets
    # LOGIN_CODE and LOGIN_HEADERS (globals — call it directly, not in $(...)).
    local url="$1" body hdr
    body="{\"username\":\"$(json_escape "$ADMIN_USERNAME")\",\"password\":\"$(json_escape "$ADMIN_PASSWORD")\"}"
    hdr="$(mktemp)"
    LOGIN_CODE="$(printf '%s' "$body" | curl -sS -o /dev/null -D "$hdr" -w '%{http_code}' --max-time 15 "${LOGIN_CURL_TLS[@]}" \
        -X POST "$url" -H 'content-type: application/json' --data-binary @- 2>/dev/null || printf '000')"
    LOGIN_HEADERS="$(tr -d '\r' < "$hdr")"; rm -f "$hdr"
}

login_url() {
    # The URL the installer uses to prove login works, through nginx.
    local host; host="$(ui_host "$BIND_ADDRESS")"
    if [ "${TLS_MODE:-}" = http-local ]; then printf 'http://%s:%s/api/auth/login' "$host" "$HTTP_PORT"
    else printf 'https://%s:%s/api/auth/login' "$host" "$HTTPS_PORT"; fi
}

refresh_cookie_ok() {
    # refresh_cookie_ok <headers> -> the refresh cookie is Secure, HttpOnly, Path=/api/auth.
    local c; c="$(printf '%s\n' "$1" | grep -i '^set-cookie:' | grep -i 'path=/api/auth' | head -1)"
    [ -n "$c" ] || return 1
    printf '%s' "$c" | grep -qi 'secure' && printf '%s' "$c" | grep -qi 'httponly'
}

verify_login() {
    # Hard check: the chosen password must log in through nginx on the chosen
    # bind address/port, and the refresh cookie must be usable (Secure over
    # HTTPS or loopback). Interactive: offer retry / re-set / abort.
    step "Verify admin login"
    local url; url="$(login_url)"
    LOGIN_CURL_TLS=()
    case "${TLS_MODE:-}" in
        self-signed) LOGIN_CURL_TLS=(--cacert "$INSTALL_DIR/tls-web-ca.crt") ;;
        custom) LOGIN_CURL_TLS=(--insecure) ;;   # cert is for the public name, we connect by IP
    esac
    if [ "${DRY_RUN:-0}" = 1 ]; then
        info "[dry-run] POST $url (JSON on stdin) — expect HTTP 200 and a Secure; HttpOnly; Path=/api/auth refresh cookie"
        return 0
    fi
    local code tries=0 reset_done=0 choice
    while :; do
        tries=$((tries + 1))
        _login_code "$url"; code="$LOGIN_CODE"
        case "$code" in
            200|204)
                good "admin login verified at $url (HTTP $code)"
                if refresh_cookie_ok "$LOGIN_HEADERS"; then good "refresh cookie is Secure + HttpOnly, Path=/api/auth (session refresh will work)"
                else warn "refresh cookie not seen with Secure/HttpOnly/Path=/api/auth — check the backend log"; fi
                return 0 ;;
            000|502|503|504)
                if [ "$tries" -lt 12 ]; then sleep 5; continue; fi
                err "login endpoint not reachable at $url (HTTP $code)" ;;
            401)
                if [ "$reset_done" = 0 ]; then
                    warn "login rejected (401) — enforcing the chosen password and retrying"
                    set_admin_password || true; reset_done=1; continue
                fi
                err "login with the chosen password was rejected (HTTP 401)" ;;
            429) err "login temporarily locked out (HTTP 429) after failed attempts — wait 5 minutes" ;;
            *)   err "unexpected HTTP $code from $url" ;;
        esac
        if [ "${NON_INTERACTIVE:-0}" = 1 ]; then return 1; fi
        choice=retry
        ask_menu choice "Admin login check failed (HTTP $code). What now?" \
            retry "Retry the login check" \
            reset "Enter the admin password again and re-apply it" \
            abort "Abort the installation" || choice=abort
        case "$choice" in
            retry) tries=0 ;;
            reset) collect_admin_password && set_admin_password; tries=0; reset_done=1 ;;
            *) return 1 ;;
        esac
    done
}
