# shellcheck shell=bash
# deps.sh — ensure Docker Engine + compose plugin. If missing, explain and ask
# consent, then install from Docker's OFFICIAL apt repo (never curl|bash).

docker_present() { command -v docker >/dev/null 2>&1 && as_root docker compose version >/dev/null 2>&1; }

ensure_docker() {
    step "Dependencies"
    if docker_present; then
        if as_root docker info >/dev/null 2>&1; then good "Docker Engine + compose plugin present"; return 0; fi
        warn "Docker is installed but the daemon is not running — starting it"
        xrun as_root systemctl enable --now docker || { err "could not start docker (systemctl status docker)"; return 1; }
        return 0
    fi

    warn "Docker Engine and/or the compose plugin are not installed."
    info "SentinelCore runs entirely as Docker containers; this is required."
    if ! ask_yesno "Install Docker from Docker's official apt repository now? (needs internet + sudo)" y; then
        err "Docker is required — aborting. Install it (https://docs.docker.com/engine/install/ubuntu/) and re-run."
        return 1
    fi
    if [ "${DRY_RUN:-0}" != 1 ] && ! curl -fsS --max-time 8 -o /dev/null https://download.docker.com/ 2>/dev/null; then
        err "cannot reach download.docker.com — Docker cannot be installed offline."
        err "connect this host to the internet (or install Docker manually) and re-run. Nothing was changed."
        return 1
    fi

    local codename arch
    codename="$(. /etc/os-release 2>/dev/null && printf '%s' "${VERSION_CODENAME:-}")"
    arch="$(dpkg --print-architecture 2>/dev/null || echo amd64)"
    xrun as_root install -m 0755 -d /etc/apt/keyrings
    xrun as_root curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    xrun as_root chmod a+r /etc/apt/keyrings/docker.asc
    if [ "${DRY_RUN:-0}" = 1 ]; then
        info "[dry-run] write /etc/apt/sources.list.d/docker.list (deb [arch=$arch signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${codename:-<codename>} stable)"
    else
        printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu %s stable\n' "$arch" "$codename" \
            | as_root tee /etc/apt/sources.list.d/docker.list >/dev/null
    fi
    xrun as_root apt-get update || { err "apt-get update failed"; return 1; }
    xrun as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
        || { err "Docker package install failed (see apt output above)"; return 1; }
    xrun as_root systemctl enable --now docker

    if [ "${DRY_RUN:-0}" = 1 ]; then good "[dry-run] Docker install steps printed"; return 0; fi
    if docker_present; then good "Docker installed"; else err "Docker install did not complete"; return 1; fi
}
