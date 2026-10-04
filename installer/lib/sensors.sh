# shellcheck shell=bash
# sensors.sh — network interface detection, capture-interface choice, and the
# persistent promiscuous-mode unit. The operator confirms the monitoring
# interface; promiscuous mode requires explicit consent.
#
# Globals set here for config.sh / install.sh: SUGGEST_MONITORED_NETWORK,
# SUGGEST_PROTECTED_IPS, SUGGEST_MGMT_IFACE, CAPTURE_INTERFACE, PROMISC_CONSENT.
# shellcheck disable=SC2034

PROMISC_UNIT="/etc/systemd/system/sentinelcore-promisc.service"

list_interfaces() {
    # Emit "name state ipv4" lines, excluding loopback and container ifaces.
    command -v ip >/dev/null 2>&1 || return 0
    local n st ip4
    ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | sed 's/@.*//' | while read -r n; do
        case "$n" in lo|docker*|veth*|br-*|virbr*) continue ;; esac
        st="$(ip -o link show "$n" 2>/dev/null | grep -o 'state [A-Z]*' | awk '{print $2}')"
        ip4="$(ip -o -4 addr show "$n" 2>/dev/null | awk '{print $4}' | head -1)"
        printf '%s %s %s\n' "$n" "${st:-?}" "${ip4:-none}"
    done
}

iface_exists() {
    # iface_exists <name> — the interface is present on this host right now.
    valid_iface "$1" || return 1
    command -v ip >/dev/null 2>&1 || return 1
    ip link show "$1" >/dev/null 2>&1
}

suggest_network() {
    # Derive a default MONITORED_NETWORK and PROTECTED_IPS from routes.
    local gw="" dev="" cidr="" dns="" self="" net=""
    if command -v ip >/dev/null 2>&1; then
        gw="$(ip route 2>/dev/null | awk '/^default/{print $3; exit}' || true)"
        dev="$(ip route 2>/dev/null | awk '/^default/{print $5; exit}' || true)"
        cidr="$(ip -o -4 addr show "$dev" 2>/dev/null | awk '{print $4}' | head -1 || true)"
        # Network address of the route (e.g. 10.0.2.0/24), not the host IP.
        [ -n "$dev" ] && net="$(ip -o -4 route show dev "$dev" scope link 2>/dev/null | awk '{print $1; exit}' || true)"
    fi
    dns="$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf 2>/dev/null || true)"
    case "$dns" in 127.*) dns="" ;; esac   # systemd-resolved stub is not a LAN host
    self="${cidr%%/*}"
    SUGGEST_MONITORED_NETWORK="${net:-${cidr:-192.168.1.0/24}}"
    SUGGEST_PROTECTED_IPS="$(printf '%s' "${gw:+$gw,}${dns:+$dns,}${self:-192.168.1.1}" | sed 's/,$//')"
    SUGGEST_MGMT_IFACE="${dev:-}"
}

suggest_capture_iface() {
    # Prefer an UP interface that is NOT the management (default-route) NIC —
    # e.g. the second (host-only/internal) VirtualBox adapter.
    local lines="$1" n s i first=""
    while read -r n s i; do
        [ -n "$n" ] || continue
        [ -z "$first" ] && first="$n"
        if [ "$n" != "${SUGGEST_MGMT_IFACE:-}" ]; then printf '%s' "$n"; return 0; fi
        : "$s$i"
    done <<<"$lines"
    printf '%s' "${first:-${SUGGEST_MGMT_IFACE:-eth0}}"
}

detect_capture_capability() {
    # Warn if the chosen iface is the one carrying the default route (mgmt NIC).
    local iface="$1"
    if [ -n "${SUGGEST_MGMT_IFACE:-}" ] && [ "$iface" = "$SUGGEST_MGMT_IFACE" ]; then
        warn "interface '$iface' carries the default route (management NIC)."
        warn "for real visibility use a dedicated mirror/SPAN or host-only capture port."
        return 1
    fi
    good "interface '$iface' is not the management NIC — suitable for capture"
}

sensor_step() {
    step "Sensor detection"
    info "detected interfaces (name / state / ipv4):"
    local lines; lines="$(list_interfaces)"
    printf '%s\n' "${lines:-(none detected)}" | sed 's/^/  /'
    suggest_network

    local args=() n s i
    while read -r n s i; do [ -n "$n" ] && args+=("$n" "state=$s ip=$i"); done <<<"$lines"
    CAPTURE_INTERFACE="${CAPTURE_INTERFACE:-$(suggest_capture_iface "$lines")}"
    [ "${#args[@]}" -eq 0 ] && args=("$CAPTURE_INTERFACE" "suggested")

    while :; do
        ask_menu CAPTURE_INTERFACE "Select the monitoring (capture) interface" "${args[@]}" || { err "cancelled"; return 1; }
        if iface_exists "$CAPTURE_INTERFACE"; then good "capture interface: $CAPTURE_INTERFACE"; break; fi
        if [ "${DRY_RUN:-0}" = 1 ]; then warn "[dry-run] interface '$CAPTURE_INTERFACE' does not exist on this host (a real install stops here)"; break; fi
        err "interface '$CAPTURE_INTERFACE' does not exist on this host (ip link show)"
        [ "${NON_INTERACTIVE:-0}" = 1 ] && return 1
    done
    detect_capture_capability "$CAPTURE_INTERFACE" || true

    info "this enables the Suricata sensor (passive IDS) and the privileged"
    info "helper (nmap discovery, firewall containment) on '$CAPTURE_INTERFACE'."
    if ask_yesno "Enable promiscuous capture on '$CAPTURE_INTERFACE' (persists across reboots)?" y; then
        PROMISC_CONSENT=1; good "promiscuous capture approved for $CAPTURE_INTERFACE"
    else
        PROMISC_CONSENT=0; warn "promiscuous capture declined — sensor will see limited traffic"
    fi
}

install_promisc_unit() {
    # Persist promiscuous mode with a systemd oneshot (netplan-agnostic): on
    # boot it runs `ip link set <iface> promisc on`; stopping it (uninstall)
    # turns promisc off again.
    local iface="$1" ipbin
    ipbin="$(command -v ip 2>/dev/null || echo /usr/sbin/ip)"
    local body
    body="$(cat <<EOF
[Unit]
Description=SentinelCore: promiscuous capture on $iface
After=network-online.target sys-subsystem-net-devices-$iface.device
Wants=network-online.target
Before=sentinelcore.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$ipbin link set dev $iface promisc on
ExecStop=$ipbin link set dev $iface promisc off

[Install]
WantedBy=multi-user.target
EOF
)"
    if [ "${DRY_RUN:-0}" = 1 ]; then
        info "[dry-run] write $PROMISC_UNIT and 'systemctl enable --now sentinelcore-promisc.service'"
        printf '%s\n' "$body" | sed 's/^/    /'
        return 0
    fi
    printf '%s\n' "$body" | as_root tee "$PROMISC_UNIT" >/dev/null
    xrun as_root systemctl daemon-reload
    xrun as_root systemctl enable --now sentinelcore-promisc.service
    if ip link show "$iface" 2>/dev/null | grep -q PROMISC; then
        good "promiscuous mode ON for $iface (persistent: sentinelcore-promisc.service)"
    else
        warn "could not confirm PROMISC flag on $iface — check: ip link show $iface"
    fi
}

remove_promisc_unit() {
    # Revert promisc (ExecStop) and remove the unit. Safe if absent.
    [ -f "$PROMISC_UNIT" ] || [ "${DRY_RUN:-0}" = 1 ] || return 0
    xrun as_root systemctl disable --now sentinelcore-promisc.service || true
    xrun as_root rm -f "$PROMISC_UNIT"
    xrun as_root systemctl daemon-reload || true
}
