#!/bin/sh
# Release helper entrypoint: rotate eve.json with main's own logrotate.conf
# (copytruncate — M5's tailer handles it) every 15 minutes, then become the
# helper process (exec keeps it PID 1 so signals reach it unchanged).
set -eu

INTERVAL="${HELPER_LOGROTATE_INTERVAL:-900}"
case "$INTERVAL" in ''|*[!0-9]*) INTERVAL=900 ;; esac

(
    while :; do
        sleep "$INTERVAL"
        logrotate -s /var/lib/logrotate/status /etc/logrotate.d/suricata >/dev/null 2>&1 || true
    done
) &

exec python -m helper.server
