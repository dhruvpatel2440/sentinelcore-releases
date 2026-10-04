# shellcheck shell=bash
# rules.sh — detection out of the box. The bundled ET Open ruleset (rules/,
# composed at build time by main's own ruleset code) is deployed through
# main's normal path: backend `ruleset.stage()` → helper `suricata_write_rules`
# (sha256 check → backup → move → `suricata -T` → rollback on failure). Then the
# sensor is started with the helper's `suricata_start` op, exactly what
# POST /api/sensor/start does. Online updates reuse main's run_rules_update.
#
# Everything runs inside the backend container with main's helper_client —
# the installer never talks to the privileged socket itself.

# shellcheck disable=SC2034
RULES_VERIFY_TIMEOUT=1200   # main's ruleset.deploy() waits up to 1200 s (suricata -T: 900 s)

_backend_py() {
    # _backend_py <python-code> — run code in the backend container (stdin passes through).
    dc exec -T backend python -c "$1"
}

helper_op_json() {
    # helper_op_json <op> [timeout] -> JSON result of a parameterless helper op.
    local op="$1" t="${2:-60}"
    _backend_py "import asyncio, json
from app.services import helper_client
print(json.dumps(asyncio.run(helper_client.call('$op', timeout=$t))))"
}

json_num() {
    # json_num <json> <key> -> integer/float/null value of a top-level key.
    printf '%s' "$1" | grep -o "\"$2\"[[:space:]]*:[[:space:]]*[-0-9.a-z]*" | head -1 | sed 's/.*:[[:space:]]*//'
}

load_bundled_rules() {
    step "Load detection rules (bundled ET Open)"
    local bundle="$INSTALL_DIR/rules/sentinelcore.rules"
    if [ "${DRY_RUN:-0}" = 1 ]; then
        info "[dry-run] sha256sum -c rules/sentinelcore.rules.sha256"
        info "[dry-run] backend: app.services.ruleset.deploy(<bundle>) = main's stage -> helper suricata_write_rules (suricata -T, up to ${RULES_VERIFY_TIMEOUT}s; rollback on failure) -> reload"
        return 0
    fi
    if [ ! -s "$bundle" ]; then
        warn "no bundled ruleset in this package — the sensor starts with an EMPTY ruleset (no alerts) until an admin runs Sensor → Rules → Update"
        return 0
    fi
    ( cd "$INSTALL_DIR/rules" && sha256sum -c --quiet sentinelcore.rules.sha256 ) || { err "bundled ruleset checksum mismatch"; return 1; }

    local status count
    status="$(helper_op_json suricata_status 60 2>/dev/null || true)"
    count="$(json_num "$status" rule_count)"
    if [ -n "${MODE_EXISTING:-}" ] && [ "${count:-0}" -gt 0 ] 2>/dev/null; then
        good "keeping the live ruleset ($count rules) — update it from the UI (Sensor → Rules → Update)"
        return 0
    fi

    local n; n="$(grep -cvE '^[[:space:]]*(#|$)' "$bundle" || true)"
    info "validating $n rules with suricata -T inside the helper (can take several minutes)..."
    local out rc=0
    # ruleset.deploy() is main's own stage → write (suricata -T) → reload path.
    out="$(as_root cat "$bundle" | _backend_py "import asyncio, json, sys
from app.services import helper_client, ruleset
content = sys.stdin.buffer.read()
try:
    res = asyncio.run(ruleset.deploy(content))
except helper_client.HelperError as exc:
    print('RULES_FAILED', type(exc).__name__, getattr(exc, 'message', str(exc))[-1500:])
    sys.exit(3)
print(json.dumps({k: res.get(k) for k in ('written', 'rule_count', 'ruleset_sha256')}))" 2>&1)" || rc=$?
    if [ "$rc" -ne 0 ]; then
        err "the bundled ruleset was rejected; the previous ruleset was kept and the sensor NOT started"
        printf '%s\n' "$out" | tail -n 20 | while IFS= read -r l; do log ERROR "  $l"; printf '    %s\n' "$l" >&2; done
        return 1
    fi
    good "ruleset deployed: $(json_num "$out" rule_count) rules (validated by suricata -T)"
}

start_sensor() {
    # start_sensor — helper suricata_start (idempotent), then wait for eve.json.
    step "Start the Suricata sensor on ${CAPTURE_INTERFACE:-the capture NIC}"
    if [ "${DRY_RUN:-0}" = 1 ]; then
        info "[dry-run] backend: helper_client.call('suricata_start') — same op as POST /api/sensor/start"
        info "[dry-run] wait up to 90 s for eve.json (suricata_status.eve_log_age_seconds)"
        return 0
    fi
    local out i age
    out="$(helper_op_json suricata_start 120 2>&1)" || { warn "sensor did not start: $(printf '%s' "$out" | tail -n 3 | tr '\n' ' ')"; warn "start it later from the UI (Sensor → Start)"; return 1; }
    for i in $(seq 1 18); do
        out="$(helper_op_json suricata_status 30 2>/dev/null || true)"
        age="$(json_num "$out" eve_log_age_seconds)"
        if [ -n "$age" ] && [ "$age" != null ]; then
            good "sensor running (pid $(json_num "$out" pid), $(json_num "$out" rule_count) rules); eve.json is being written"
            return 0
        fi
        sleep 5; : "$i"
    done
    if [ "$(json_num "$out" running)" = true ]; then
        warn "sensor is running but eve.json has not appeared yet (no traffic on ${CAPTURE_INTERFACE:-the NIC}?)"
        return 0
    fi
    warn "sensor is not running — check: sudo docker compose -f $INSTALL_DIR/docker-compose.yml logs helper"
    return 1
}

internet_for_rules() {
    curl -fsS --max-time 8 -o /dev/null -I https://rules.emergingthreats.net/ 2>/dev/null
}

maybe_update_rules_online() {
    # Optional: refresh to today's ET Open via main's own pipeline. Never
    # blocks the install; failures keep the bundled ruleset (main's behaviour).
    local want="${UPDATE_RULES:-}"
    if [ -z "$want" ]; then
        if ask_yesno "Update the detection rules from the internet now (Emerging Threats Open)?" n; then want=yes; else want=no; fi
    fi
    [ "$want" = yes ] || { info "rules update skipped — admins can update any time: Sensor → Rules → Update"; return 0; }
    step "Update detection rules online"
    if [ "${DRY_RUN:-0}" = 1 ]; then info "[dry-run] backend: app.api.routes.sensor.run_rules_update(None) (fetch → compose → deploy → reload)"; return 0; fi
    if ! internet_for_rules; then warn "rules.emergingthreats.net not reachable — keeping the bundled ruleset"; return 0; fi
    info "downloading and validating the current ET Open ruleset (several minutes)..."
    if _backend_py "import asyncio
from app.api.routes.sensor import run_rules_update
asyncio.run(run_rules_update(None))" >/dev/null 2>&1; then
        local out; out="$(helper_op_json suricata_status 60 2>/dev/null || true)"
        good "rules update finished: $(json_num "$out" rule_count) rules live (details: Sensor page)"
    else
        warn "online rules update failed — the bundled ruleset stays live"
    fi
}
