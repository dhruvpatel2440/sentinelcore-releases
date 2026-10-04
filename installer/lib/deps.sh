# shellcheck shell=bash
# deps.sh — ensure Docker Engine + compose plugin. If missing, explain and ask
# consent, then install from Docker's OFFICIAL apt repo for this distro
# (ubuntu or debian; never curl|bash). Docker group membership is NOT granted:
# SentinelCore is managed with sudo only.

docker_present() { command -v docker >/dev/null 2>&1 && as_root docker compose version >/dev/null 2>&1; }

docker_repo_distro() {
    # docker_repo_distro <os-release-file> -> "ubuntu <codename>" | "debian <codename>"
    # (return 1 for anything Docker's ubuntu/debian repos do not cover).
    local f="${1:-/etc/os-release}" id="" like="" code=""
    [ -r "$f" ] || return 1
    id="$(sed -n 's/^ID=//p' "$f" | tr -d '"' | head -1)"
    like="$(sed -n 's/^ID_LIKE=//p' "$f" | tr -d '"' | head -1)"
    code="$(sed -n 's/^VERSION_CODENAME=//p' "$f" | tr -d '"' | head -1)"
    case "$id" in
        ubuntu|debian) ;;
        *) case " $like " in
               *" ubuntu "*) id=ubuntu; code="$(sed -n 's/^UBUNTU_CODENAME=//p' "$f" | tr -d '"' | head -1)" ;;
               *) return 1 ;;
           esac ;;
    esac
    printf '%s' "$code" | grep -Eq '^[a-z]+$' || return 1
    printf '%s %s' "$id" "$code"
}

ensure_docker() {
    step "Dependencies"
    if docker_present; then
        if as_root docker info >/dev/null 2>&1; then good "Docker Engine + compose plugin present ($(as_root docker version -f '{{.Server.Version}}' 2>/dev/null || echo '?'))"; return 0; fi
        warn "Docker is installed but the daemon is not running — starting it"
        xrun as_root systemctl enable --now docker || { err "could not start docker (systemctl status docker)"; return 1; }
        return 0
    fi

    local dist distro codename arch
    if ! dist="$(docker_repo_distro /etc/os-release)" && [ "${DRY_RUN:-0}" = 1 ]; then
        warn "[dry-run] distribution not detected here — previewing the Ubuntu 24.04 (noble) steps"
        dist="ubuntu noble"
    fi
    if [ -z "$dist" ]; then
        err "Docker is not installed and this distribution is not supported by the automatic install (Ubuntu/Debian only)."
        err "install Docker Engine + the compose plugin yourself (https://docs.docker.com/engine/install/) and re-run."
        return 1
    fi
    distro="${dist% *}"; codename="${dist#* }"
    arch="$(dpkg --print-architecture 2>/dev/null || echo amd64)"
    [ "$arch" = amd64 ] || { err "Docker install: unsupported architecture '$arch' (amd64 only)"; return 1; }

    warn "Docker Engine and/or the compose plugin are not installed."
    info "SentinelCore runs entirely as Docker containers; this is required."
    if ! ask_yesno "Install Docker from Docker's official apt repository ($distro $codename) now? (needs internet)" y; then
        err "Docker is required — aborting. Install it (https://docs.docker.com/engine/install/$distro/) and re-run."
        return 1
    fi
    if [ "${DRY_RUN:-0}" != 1 ] && ! curl -fsS --max-time 8 -o /dev/null "https://download.docker.com/linux/$distro/" 2>/dev/null; then
        err "cannot reach download.docker.com — Docker cannot be installed offline."
        err "connect this host to the internet (or install Docker manually) and re-run. Nothing was changed."
        return 1
    fi

    xrun as_root install -m 0755 -d /etc/apt/keyrings
    xrun as_root curl -fsSL "https://download.docker.com/linux/$distro/gpg" -o /etc/apt/keyrings/docker.asc
    xrun as_root chmod a+r /etc/apt/keyrings/docker.asc
    local line="deb [arch=$arch signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$distro $codename stable"
    if [ "${DRY_RUN:-0}" = 1 ]; then
        info "[dry-run] write /etc/apt/sources.list.d/docker.list: $line"
    else
        printf '%s\n' "$line" | as_root tee /etc/apt/sources.list.d/docker.list >/dev/null
    fi
    xrun as_root apt-get update || { err "apt-get update failed"; return 1; }
    xrun as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
        || { err "Docker package install failed (see apt output above)"; return 1; }
    xrun as_root systemctl enable --now docker

    if [ "${DRY_RUN:-0}" = 1 ]; then good "[dry-run] Docker install steps printed"; return 0; fi
    if docker_present; then good "Docker installed"; else err "Docker install did not complete"; return 1; fi
}
