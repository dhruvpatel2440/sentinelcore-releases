#!/usr/bin/env bash
# post-install-checks.sh — run ON THE TEST VM after `sudo ./install.sh`.
# Automates the Phase 08 "also check after install" list and the observable
# parts of steps 2/3/5. Prints PASS/FAIL lines to paste into
# tests/vm-test-results.md.
#
# Usage: sudo tests/vm/post-install-checks.sh [--expect-iface enp0s8] [--expect-bind 127.0.0.1:8080]
# It asks for the admin password (hidden) only to grep the log for it.
set -uo pipefail
INSTALL_DIR="${INSTALL_DIR:-/opt/sentinelcore}"
LOG="${LOG_FILE:-/var/log/sentinelcore-install.log}"
EXPECT_IFACE=""; EXPECT_BIND=""
while [ $# -gt 0 ]; do
    case "$1" in
        --expect-iface) EXPECT_IFACE="$2"; shift 2 ;;
        --expect-bind) EXPECT_BIND="$2"; shift 2 ;;
        *) echo "unknown option $1"; exit 2 ;;
    esac
done
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 2; }
DC=(docker compose -f "$INSTALL_DIR/docker-compose.yml" --env-file "$INSTALL_DIR/.env")
envv() { sed -n "s/^$1=//p" "$INSTALL_DIR/.env" | tail -1; }
pass=0; fail=0
P() { pass=$((pass+1)); printf 'PASS  %s\n' "$*"; }
F() { fail=$((fail+1)); printf 'FAIL  %s\n' "$*"; }
t() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then P "$d"; else F "$d"; fi; }

echo "== files =="
[ "$(stat -c '%a' "$INSTALL_DIR/.env")" = 600 ] && P ".env mode 600" || F ".env mode $(stat -c '%a' "$INSTALL_DIR/.env")"
[ "$(stat -c '%a' "$LOG")" = 600 ] && P "install log mode 600" || F "install log mode $(stat -c '%a' "$LOG")"
if [ "$(envv EMAIL_MODE)" = brevo ]; then
    [ "$(stat -c '%a' "$INSTALL_DIR/tls")" = 700 ] && P "tls/ mode 700" || F "tls/ mode"
    [ "$(stat -c '%a' "$INSTALL_DIR/tls/api.brevo.com.key")" = 600 ] && P "leaf key mode 600" || F "leaf key mode"
    [ -z "$(find / -xdev -name 'ca.key' -path '*sentinelcore*' 2>/dev/null)" ] && P "no CA private key on disk" || F "CA key found"
    grep -q '^BREVO_API_KEY=xkeysib-' "$INSTALL_DIR/.env" && F ".env holds a Brevo PROVIDER key" || P ".env holds relay token, no provider key"
fi

echo "== secrets not in log =="
read -r -s -p "admin password (for log grep only): " PW; echo
hit=0
for v in "$PW" "$(envv POSTGRES_PASSWORD)" "$(envv SECRET_KEY)" "$(envv BREVO_API_KEY)" "$(envv BREVO_WEBHOOK_SECRET)"; do
    [ "${#v}" -ge 8 ] || continue
    grep -rqF -- "$v" "$LOG" /var/log/sentinelcore* 2>/dev/null && hit=1
done
[ "$hit" = 0 ] && P "no admin password / tokens / secrets in install log" || F "secret found in install log"
unset PW

echo "== services =="
for s in db redis helper backend worker nginx $([ "$(envv EMAIL_MODE)" = brevo ] && echo relay-shim); do
    cid="$("${DC[@]}" ps -q "$s")"
    st="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null)"
    [ "$st" = healthy ] && P "$s healthy" || F "$s $st"
done
uid="$("${DC[@]}" exec -T backend id -u 2>/dev/null)"
[ -n "$uid" ] && [ "$uid" != 0 ] && P "backend runs as non-root (uid $uid)" || F "backend uid '$uid'"
uid="$("${DC[@]}" exec -T worker id -u 2>/dev/null)"
[ -n "$uid" ] && [ "$uid" != 0 ] && P "worker runs as non-root (uid $uid)" || F "worker uid '$uid'"

echo "== capabilities vs dev compose =="
caps() { docker inspect -f '{{.HostConfig.CapDrop}} {{.HostConfig.CapAdd}} priv={{.HostConfig.Privileged}} net={{.HostConfig.NetworkMode}}' "$("${DC[@]}" ps -q "$1")"; }
c="$(caps helper)";  [[ "$c" == *"[ALL]"*"NET_ADMIN"*"NET_RAW"*"SYS_NICE"*"CHOWN"*"priv=false net=host"* ]] && P "helper caps: $c" || F "helper caps: $c"
c="$(caps backend)"; [[ "$c" == "[ALL] [] priv=false"* ]] && P "backend caps: $c" || F "backend caps: $c"
c="$(caps worker)";  [[ "$c" == "[ALL] [] priv=false"* ]] && P "worker caps: $c" || F "worker caps: $c"
docker inspect -f '{{.HostConfig.SecurityOpt}}' "$("${DC[@]}" ps -q backend)" | grep -q no-new-privileges && P "backend no-new-privileges" || F "backend no-new-privileges"

echo "== bind / port (A5) =="
want="${EXPECT_BIND:-$(envv BIND_ADDRESS):$(envv WEB_PORT)}"
ss -Hltn | awk '{print $4}' | grep -qx -- "$want" && P "listening on $want" || F "not listening on $want"
port="${want##*:}"
others="$(ss -Hltn | awk '{print $4}' | grep -E ":$port\$" | grep -vx -- "$want" || true)"
[ -z "$others" ] && P "port $port bound ONLY on $want" || F "port $port also on: $others"

echo "== sensor (A2) =="
iface="${EXPECT_IFACE:-$(envv CAPTURE_INTERFACE)}"
"${DC[@]}" exec -T helper grep -A2 af-packet /etc/suricata/suricata.yaml | tee /dev/stderr | grep -q "interface: $iface" \
    && P "suricata af-packet interface = $iface" || F "suricata af-packet interface != $iface"
if systemctl is-enabled sentinelcore-promisc.service >/dev/null 2>&1; then
    ip link show "$iface" | grep -q PROMISC && P "$iface PROMISC (persistent unit enabled)" || F "$iface not PROMISC"
else
    echo "INFO  promisc unit not installed (consent declined?)"
fi

echo "== boot =="
t "sentinelcore.service enabled" systemctl is-enabled sentinelcore.service
grep -q "compose -f $INSTALL_DIR/docker-compose.yml" /etc/systemd/system/sentinelcore.service && P "unit uses compose -f" || F "unit compose -f"
grep -q '^ExecStop=.* stop$' /etc/systemd/system/sentinelcore.service && P "ExecStop = stop (not down)" || F "ExecStop not 'stop'"

echo
echo "RESULT: $pass PASS, $fail FAIL"
[ "$fail" -eq 0 ]
