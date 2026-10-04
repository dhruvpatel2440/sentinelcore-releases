# shellcheck shell=bash
# ui.sh — TUI (whiptail) with plain-text fallback, logging with secret
# redaction, progress, and the dry-run-aware command runner. Sourced by
# install.sh / uninstall.sh / enable-email.sh; relies on globals: DRY_RUN,
# NON_INTERACTIVE, LOG_FILE, and the SECRETS associative array.
#
# Logging contract: init_log() picks the ONE log path, and log() is the ONLY
# function that writes to it. Every write goes through _redact(), which strips
# every value registered with add_secret(). Nothing else touches $LOG_FILE.

set -o pipefail

# Shared secret registry (values redacted from all output). Declared here so
# every entry point gets the same associative array.
declare -gA SECRETS 2>/dev/null || true

HAVE_WHIPTAIL=0
command -v whiptail >/dev/null 2>&1 && HAVE_WHIPTAIL=1

# Colors only when stdout is a tty.
if [ -t 1 ]; then
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_BLU=$'\033[34m'; C_RST=$'\033[0m'; C_BLD=$'\033[1m'
else
    C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_RST=''; C_BLD=''
fi

# ---- logging -------------------------------------------------------------
init_log() {
    # init_log [preferred-path] — choose the log file once (mode 600). Falls
    # back to a private temp file when the system path is not writable (e.g.
    # dry-run as a normal user).
    local want="${1:-${LOG_FILE:-/var/log/sentinelcore-install.log}}"
    if ( umask 077; : >>"$want" ) 2>/dev/null; then
        LOG_FILE="$want"
    else
        LOG_FILE="${TMPDIR:-/tmp}/sentinelcore-install.$(id -u 2>/dev/null || echo 0).log"
        ( umask 077; : >>"$LOG_FILE" ) 2>/dev/null || LOG_FILE="/dev/null"
    fi
    [ "$LOG_FILE" = /dev/null ] || chmod 600 "$LOG_FILE" 2>/dev/null || true
}

add_secret() {
    # add_secret <name> <value> — register a value for redaction everywhere.
    [ -n "${2:-}" ] || return 0
    SECRETS[$1]="$2"
}

_redact() {
    # Redact every known secret VALUE from a string before it is logged/shown.
    local s="$1" v
    for v in "${SECRETS[@]}"; do
        # Only redact genuine secret values; skip short/sentinel strings so we
        # never mangle incidental substrings like "1" in 127.0.0.1.
        [ "${#v}" -ge 8 ] && s="${s//"$v"/<redacted>}"
    done
    printf '%s' "$s"
}

log() {
    # log <level> <message...>  -> timestamped, redacted line to LOG_FILE.
    local level="$1"; shift
    [ -n "${LOG_FILE:-}" ] || return 0
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$level" "$(_redact "$*")" >>"$LOG_FILE" 2>/dev/null || true
}

info()  { log INFO  "$*"; printf '%s\n' "${C_BLU}$(_redact "$*")${C_RST}"; }
good()  { log INFO  "$*"; printf '%s\n' "${C_GRN}✓ $(_redact "$*")${C_RST}"; }
warn()  { log WARN  "$*"; printf '%s\n' "${C_YEL}! $(_redact "$*")${C_RST}" >&2; }
err()   { log ERROR "$*"; printf '%s\n' "${C_RED}✗ $(_redact "$*")${C_RST}" >&2; }
step()  { log INFO  "STEP: $*"; printf '\n%s\n' "${C_BLD}== $* ==${C_RST}"; }

# ---- small helpers ---------------------------------------------------------
json_escape() {
    # json_escape <string> -> JSON string body (no surrounding quotes). Handles
    # backslash, double quote and control characters; everything else
    # (including ' $ | & spaces) is literal in JSON.
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    printf '%s' "$s"
}

as_root() {
    # as_root <cmd...> — run directly when root, else via sudo.
    if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi
}

# ---- dry-run-aware runner ------------------------------------------------
xrun() {
    # Execute a state-changing command, or just print it in dry-run.
    log INFO "RUN: $*"
    if [ "${DRY_RUN:-0}" = 1 ]; then
        printf '%s\n' "${C_YEL}[dry-run]${C_RST} $(_redact "$*")"
        return 0
    fi
    "$@"
}

run_sh() {
    # Like xrun(), for a shell pipeline passed as a single string. Never put a
    # secret in this string — use the environment (see admin.sh).
    log INFO "RUN(sh): $*"
    if [ "${DRY_RUN:-0}" = 1 ]; then
        printf '%s\n' "${C_YEL}[dry-run]${C_RST} $(_redact "$*")"
        return 0
    fi
    bash -c "$*"
}

# ---- prompts (whiptail | plain | non-interactive default) ---------------
ask_input() {
    # ask_input <varname> <prompt> <default>
    local __var="$1" prompt="$2" def="${3:-}" ans=""
    if [ "${NON_INTERACTIVE:-0}" = 1 ] || [ "${DRY_RUN:-0}" = 1 ]; then
        ans="$def"
    elif [ "$HAVE_WHIPTAIL" = 1 ]; then
        ans="$(whiptail --inputbox "$prompt" 10 70 "$def" 3>&1 1>&2 2>&3)" || ans="$def"
    else
        read -r -p "$prompt [$def]: " ans || true
        [ -z "$ans" ] && ans="$def"
    fi
    printf -v "$__var" '%s' "$ans"
}

ask_secret() {
    # ask_secret <varname> <prompt>  (hidden, confirmed, never echoed/logged)
    local __var="$1" prompt="$2" a="" b=""
    if [ "${NON_INTERACTIVE:-0}" = 1 ] || [ "${DRY_RUN:-0}" = 1 ]; then
        printf -v "$__var" '%s' "${!__var:-}"; return 0
    fi
    while :; do
        if [ "$HAVE_WHIPTAIL" = 1 ]; then
            a="$(whiptail --passwordbox "$prompt" 10 70 3>&1 1>&2 2>&3)" || return 1
            b="$(whiptail --passwordbox "Confirm: $prompt" 10 70 3>&1 1>&2 2>&3)" || return 1
        else
            IFS= read -r -s -p "$prompt: " a; echo
            IFS= read -r -s -p "Confirm: " b; echo
        fi
        [ "$a" = "$b" ] && { printf -v "$__var" '%s' "$a"; return 0; }
        warn "passwords did not match — try again"
    done
}

ask_yesno() {
    # ask_yesno <prompt> <default y|n> -> returns 0 for yes
    local prompt="$1" def="${2:-n}"
    if [ "${NON_INTERACTIVE:-0}" = 1 ] || [ "${DRY_RUN:-0}" = 1 ]; then
        [ "$def" = y ]; return
    fi
    if [ "$HAVE_WHIPTAIL" = 1 ]; then
        if [ "$def" = y ]; then whiptail --yesno "$prompt" 10 70; else whiptail --yesno --defaultno "$prompt" 10 70; fi
    else
        local a; read -r -p "$prompt [$([ "$def" = y ] && echo Y/n || echo y/N)]: " a || true
        a="${a:-$def}"; case "$a" in y|Y|yes) return 0 ;; *) return 1 ;; esac
    fi
}

ask_menu() {
    # ask_menu <varname> <prompt> <tag1> <label1> [<tag2> <label2> ...]
    local __var="$1" prompt="$2"; shift 2
    if [ "${NON_INTERACTIVE:-0}" = 1 ] || [ "${DRY_RUN:-0}" = 1 ]; then
        printf -v "$__var" '%s' "${!__var:-$1}"; return 0
    fi
    if [ "$HAVE_WHIPTAIL" = 1 ]; then
        local sel; sel="$(whiptail --menu "$prompt" 20 76 10 "$@" 3>&1 1>&2 2>&3)" || return 1
        printf -v "$__var" '%s' "$sel"
    else
        echo "$prompt"; local i=1; local tags=()
        while [ $# -gt 0 ]; do tags+=("$1"); printf '  %d) %s — %s\n' "$i" "$1" "$2"; i=$((i+1)); shift 2; done
        local n
        while :; do
            read -r -p "choose [1]: " n || true; n="${n:-1}"
            case "$n" in *[!0-9]*|0) ;; *) [ "$n" -le "${#tags[@]}" ] && break ;; esac
            warn "enter a number between 1 and ${#tags[@]}"
        done
        printf -v "$__var" '%s' "${tags[$((n-1))]}"
    fi
}

msgbox() {
    local text="$1"
    log INFO "MSG: $text"
    if [ "${NON_INTERACTIVE:-0}" = 1 ] || [ "${DRY_RUN:-0}" = 1 ] || [ "$HAVE_WHIPTAIL" = 0 ]; then
        printf '%s\n' "$(_redact "$text")"
    else
        whiptail --msgbox "$text" 16 72
    fi
}
