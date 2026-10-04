# shellcheck shell=bash
# checks.sh — system preflight: OS, arch, privilege, CPU/RAM/disk, internet.
# Read-only; safe to run in dry-run. The web-port and bind-address checks run
# after the operator picks them (config.sh); relay reachability is checked in
# the email step (relay.sh).

# Minimums (see docs-internal/sensors-analysis.md).
MIN_CORES=4
MIN_RAM_MB=8000
MIN_DISK_GB=40
MIN_DISK_HARD_GB=15

check_os() {
    local id="" ver=""
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        id="$(. /etc/os-release && printf '%s' "${ID:-}")"
        ver="$(. /etc/os-release && printf '%s' "${VERSION_ID:-}")"
    fi
    case "$id:$ver" in
        ubuntu:22.04|ubuntu:24.04) good "OS: $id $ver"; return 0 ;;
        ubuntu:*|debian:*) warn "OS: $id $ver — Debian-family but untested (supported: Ubuntu 22.04/24.04)"; return 0 ;;
        *) err "unsupported OS '${id:-unknown}'. Ubuntu 22.04/24.04 required."; return 1 ;;
    esac
}

check_arch() {
    local a; a="$(uname -m 2>/dev/null || echo unknown)"
    case "$a" in
        x86_64|amd64) good "arch: $a"; return 0 ;;
        *) err "unsupported arch '$a'. x86_64 required."; return 1 ;;
    esac
}

check_privilege() {
    if [ "$(id -u)" -eq 0 ]; then good "running as root"; return 0; fi
    if command -v sudo >/dev/null 2>&1; then good "sudo available (will prompt for privileged steps)"; return 0; fi
    err "root or sudo required"; return 1
}

check_cpu() {
    local n; n="$(nproc 2>/dev/null || echo 0)"
    if [ "$n" -ge "$MIN_CORES" ]; then good "CPU: $n cores (min $MIN_CORES)"; return 0; fi
    warn "CPU: $n cores — below recommended $MIN_CORES"; return 1
}

check_ram() {
    local kb mb; kb="$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"
    mb=$(( kb / 1024 ))
    if [ "$mb" -ge "$MIN_RAM_MB" ]; then good "RAM: ${mb} MB (min ${MIN_RAM_MB})"; return 0; fi
    warn "RAM: ${mb} MB — below minimum ${MIN_RAM_MB} MB"; return 1
}

docker_root_dir() {
    # Docker's data root (where images/volumes live), else a sensible parent.
    local d=""
    command -v docker >/dev/null 2>&1 && d="$(as_root docker info -f '{{.DockerRootDir}}' 2>/dev/null || true)"
    [ -n "$d" ] && [ -d "$d" ] || d="/var/lib/docker"
    [ -d "$d" ] || d="/var/lib"
    [ -d "$d" ] || d="/"
    printf '%s' "$d"
}

free_gb() { df -BG --output=avail "$1" 2>/dev/null | awk 'NR==2{gsub("G","");print $1+0}'; }

check_disk() {
    # Warn below the recommended size; FAIL (rc 2) below the hard floor:
    # images, ruleset, DB and 90 days of events need room (docs/REQUIREMENTS.md).
    local target gb; target="$(docker_root_dir)"; gb="$(free_gb "$target")"; gb="${gb:-0}"
    if [ "$gb" -ge "$MIN_DISK_GB" ]; then good "disk: ${gb} GB free on $target (recommended ${MIN_DISK_GB})"; return 0; fi
    if [ "$gb" -lt "$MIN_DISK_HARD_GB" ]; then err "disk: only ${gb} GB free on $target — at least ${MIN_DISK_HARD_GB} GB is required"; return 2; fi
    warn "disk: ${gb} GB free on $target — below the recommended ${MIN_DISK_GB} GB (retention: events 90 d, reports/PCAPs 30 d)"; return 1
}

check_disk_for_upgrade() {
    # An upgrade keeps the previous images (rollback) and writes a DB snapshot.
    local target gb need; target="$(docker_root_dir)"; gb="$(free_gb "$target")"; gb="${gb:-0}"
    need=$(( MIN_DISK_HARD_GB / 2 + 4 ))
    if [ "${DRY_RUN:-0}" = 1 ]; then info "[dry-run] need >= ${need} GB free on $target for new images + DB snapshot (have ${gb})"; return 0; fi
    [ "$gb" -ge "$need" ] || { err "upgrade needs at least ${need} GB free on $target (new images + rollback snapshot); have ${gb} GB"; return 1; }
    good "disk: ${gb} GB free for the upgrade"
}

check_internet() {
    # Only needed if Docker must be installed or images pulled.
    if curl -fsS --max-time 6 -o /dev/null https://download.docker.com/ 2>/dev/null; then
        good "internet reachable (download.docker.com)"; return 0
    fi
    warn "no internet to download.docker.com (ok if Docker already installed and images bundled)"; return 1
}

run_system_checks() {
    step "System checks"
    local hard=0
    check_os   || hard=1
    check_arch || hard=1
    check_privilege || hard=1
    check_cpu  || true
    check_ram  || true
    local drc=0; check_disk || drc=$?
    [ "$drc" = 2 ] && hard=1
    check_internet || true
    if [ "${DRY_RUN:-0}" = 1 ]; then
        [ "$hard" = 1 ] && warn "[dry-run] one or more REQUIRED checks would fail on a real install"
        info "[dry-run] continuing to preview remaining steps"
        return 0
    fi
    if [ "$hard" = 1 ]; then
        err "one or more REQUIRED checks failed"
        return 1
    fi
    good "system checks passed"
    return 0
}
