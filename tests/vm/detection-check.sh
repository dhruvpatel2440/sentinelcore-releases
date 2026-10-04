#!/usr/bin/env bash
# Detection checks on an INSTALLED SentinelCore VM (Phase 13). Run as root on
# the SentinelCore host.
#
#   sudo tests/vm/detection-check.sh status
#       sensor running, rules loaded, eve.json fresh, worker consuming
#   sudo tests/vm/detection-check.sh alert
#       waits for a NEW Suricata alert + matching event row. Trigger it from a
#       SECOND machine whose traffic crosses the capture NIC, e.g.:
#         curl -s http://testmynids.org/uid/index.html     (ET "GPL ATTACK_RESPONSE id check")
#       or replay a pcap on the capture NIC: tcpreplay -i <nic> sample.pcap
#   sudo tests/vm/detection-check.sh corrupt
#       stages a deliberately broken ruleset through main's deploy path and
#       proves it is rejected and the previous rules stay live
#   sudo tests/vm/detection-check.sh reboot-check
#       after a reboot: stack healthy + sensor running without manual action
set -uo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/sentinelcore}"
mapfile -t F < <(for f in docker-compose.yml docker-compose.tls.yml docker-compose.email.yml; do [ -f "$INSTALL_DIR/$f" ] && printf '%s\n' -f "$INSTALL_DIR/$f"; done)
dc() { docker compose "${F[@]}" --env-file "$INSTALL_DIR/.env" "$@"; }
py() { dc exec -T backend python -c "$1"; }
status_json() { py "import asyncio, json
from app.services import helper_client
print(json.dumps(asyncio.run(helper_client.call('suricata_status', timeout=60))))"; }
field() { printf '%s' "$1" | python3 -c "import json,sys; print(json.load(sys.stdin).get('$2'))"; }
events_count() { dc exec -T db sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "select count(*) from events"' | tr -d ' \r'; }
alerts_in_eve() { dc exec -T helper sh -c 'grep -c "\"event_type\":\"alert\"" /var/log/suricata/eve.json 2>/dev/null || echo 0' | tr -d ' \r'; }
pass=0; fail=0
ok()  { printf '  PASS  %s\n' "$*"; pass=$((pass + 1)); }
bad() { printf '  FAIL  %s\n' "$*"; fail=$((fail + 1)); }

case "${1:-status}" in
status|reboot-check)
    if [ "${1:-}" = reboot-check ]; then
        systemctl is-active --quiet sentinelcore.service && ok "sentinelcore.service active after boot" || bad "sentinelcore.service not active"
        for s in db redis helper backend worker nginx; do
            st="$(docker inspect -f '{{.State.Health.Status}}' "$(dc ps -q "$s")" 2>/dev/null)"
            [ "$st" = healthy ] && ok "$s healthy" || bad "$s is '$st'"
        done
    fi
    s="$(status_json)"
    [ "$(field "$s" running)" = True ] && ok "sensor running (pid $(field "$s" pid), suricata $(field "$s" version))" || bad "sensor not running"
    n="$(field "$s" rule_count)"; [ "${n:-0}" -gt 1000 ] 2>/dev/null && ok "ruleset loaded: $n rules" || bad "ruleset has ${n:-0} rules"
    age="$(field "$s" eve_log_age_seconds)"
    if [ "$age" != None ] && python3 -c "import sys; sys.exit(0 if float('$age') < 600 else 1)"; then ok "eve.json written ${age%.*}s ago"; else bad "eve.json stale/missing (age: $age)"; fi
    c1="$(events_count)"; sleep 30; c2="$(events_count)"
    [ "${c2:-0}" -ge "${c1:-0}" ] && ok "events table readable ($c1 → $c2 in 30 s)" || bad "events count went backwards"
    ;;
alert)
    a0="$(alerts_in_eve)"; e0="$(events_count)"
    echo "  baseline: $a0 alerts in eve.json, $e0 events. Trigger traffic from a second host now (waiting up to 120 s)..."
    for _ in $(seq 1 24); do
        sleep 5
        a1="$(alerts_in_eve)"; e1="$(events_count)"
        if [ "${a1:-0}" -gt "${a0:-0}" ] && [ "${e1:-0}" -gt "${e0:-0}" ]; then
            ok "new alert in eve.json ($a0 → $a1) and new event rows ($e0 → $e1)"
            dc exec -T db sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "select ts, severity, signature from events order by ts desc limit 3"' 2>/dev/null | sed 's/^/        /'
            break
        fi
    done
    [ "$pass" -gt 0 ] || bad "no new alert/event within 120 s (does the capture NIC see the traffic? promisc on?)"
    ;;
corrupt)
    s0="$(status_json)"; before="$(field "$s0" ruleset_sha256)"
    out="$(printf 'alert tcp any any -> any any (msg:"broken"; this-is-not-a-keyword; sid:9999999;)\n' | py "import asyncio, sys
from app.services import helper_client, ruleset
try:
    asyncio.run(ruleset.deploy(sys.stdin.buffer.read()))
    print('ACCEPTED')
except helper_client.HelperError as exc:
    print('REJECTED', getattr(exc, 'code', type(exc).__name__))" 2>&1)"
    case "$out" in *REJECTED*) ok "broken ruleset rejected by suricata -T ($out)" ;; *) bad "broken ruleset was not rejected: $out" ;; esac
    s1="$(status_json)"
    [ "$(field "$s1" ruleset_sha256)" = "$before" ] && ok "previous ruleset still live (sha256 unchanged)" || bad "live ruleset changed"
    [ "$(field "$s1" running)" = True ] && ok "sensor still running" || bad "sensor stopped"
    ;;
*) sed -n '2,19p' "$0"; exit 2 ;;
esac
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
