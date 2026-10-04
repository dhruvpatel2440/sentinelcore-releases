#!/usr/bin/env bash
# Start the Suricata sensor through main's own helper op (suricata_start, the
# same op POST /api/sensor/start uses). Run by the systemd unit after boot so
# the sensor comes back without a manual click; idempotent if already running.
#
# Usage:
#   sudo /opt/sentinelcore/bin/sensor-start.sh [--wait]   (--wait: up to 5 min for backend+helper health)
set -euo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="${INSTALL_DIR:-$(cd "$BIN/.." && pwd)}"
LIB="$INSTALL_DIR/lib"; [ -d "$LIB" ] || LIB="$BIN/../lib"
LOG_FILE="${LOG_FILE:-/var/log/sentinelcore-install.log}"
WAIT=0
[ "${1:-}" = --wait ] && WAIT=1
[ "$(id -u)" -eq 0 ] || exec sudo -- "$0" "$@"

# shellcheck source=../lib/ui.sh
. "$LIB/ui.sh"
# shellcheck source=../lib/config.sh
. "$LIB/config.sh"
# shellcheck source=../lib/services.sh
. "$LIB/services.sh"
# shellcheck source=../lib/rules.sh
. "$LIB/rules.sh"
init_log "$LOG_FILE"

# shellcheck disable=SC2034  # read by rules.sh start_sensor
CAPTURE_INTERFACE="$(env_get "$INSTALL_DIR/.env" CAPTURE_INTERFACE)"
if [ "$WAIT" = 1 ]; then
    HEALTH_TIMEOUT=300 wait_healthy helper backend || exit 1
fi
start_sensor
