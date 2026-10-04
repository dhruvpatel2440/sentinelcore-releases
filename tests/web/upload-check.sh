#!/usr/bin/env bash
# PCAP upload through nginx on an INSTALLED SentinelCore (Phase 11.4):
#   - a >= 100 MB synthetic pcap is accepted (202)
#   - a file above the backend's 500 MB limit gets a clean JSON 413
# Needs an admin/analyst test account: SC_USER / SC_PASS (env).
#
# Usage: SC_USER=t_admin SC_PASS=... tests/web/upload-check.sh <host> [https_port=443]
set -uo pipefail

HOST="${1:?usage: upload-check.sh <host> [https_port]}"; SP="${2:-443}"
BASE="https://$HOST:$SP"
TLS=(--insecure); [ -n "${CACERT:-}" ] && TLS=(--cacert "$CACERT")
: "${SC_USER:?set SC_USER}" "${SC_PASS:?set SC_PASS}"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
fail=0

token="$(python3 -c 'import json,os; print(json.dumps({"username": os.environ["SC_USER"], "password": os.environ["SC_PASS"]}))' \
    | curl -sS --max-time 15 "${TLS[@]}" -H 'content-type: application/json' --data-binary @- "$BASE/api/auth/login" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')" || { echo "login failed"; exit 1; }

mkpcap() {
    # mkpcap <file> <MB> — classic pcap header + one big valid-looking record stream.
    python3 - "$1" "$2" <<'PY'
import struct, sys
path, mb = sys.argv[1], int(sys.argv[2])
pkt = bytes.fromhex("ffffffffffff0011223344550800") + b"\x45" + b"\x00" * 1000
with open(path, "wb") as f:
    f.write(struct.pack("<IHHiIII", 0xa1b2c3d4, 2, 4, 0, 0, 65535, 1))
    rec = struct.pack("<IIII", 0, 0, len(pkt), len(pkt)) + pkt
    for _ in range(mb * 1024 * 1024 // len(rec) + 1):
        f.write(rec)
PY
}

up() { curl -sS -o "$work/resp" -w '%{http_code}' --max-time 900 "${TLS[@]}" -H "authorization: Bearer $token" -F "file=@$1;filename=$(basename "$1")" "$BASE/api/pcap/upload"; }

mkpcap "$work/ok-120mb.pcap" 120
code="$(up "$work/ok-120mb.pcap")"
if [ "$code" = 202 ]; then echo "  PASS  120 MB pcap accepted (202)"; else echo "  FAIL  120 MB pcap -> HTTP $code: $(head -c 300 "$work/resp")"; fail=1; fi

mkpcap "$work/too-big.pcap" 520
code="$(up "$work/too-big.pcap")"
if [ "$code" = 413 ] && grep -q '500MB' "$work/resp"; then echo "  PASS  520 MB pcap refused with JSON 413: $(cat "$work/resp")"
else echo "  FAIL  520 MB pcap -> HTTP $code: $(head -c 300 "$work/resp")"; fail=1; fi

echo "(delete the uploaded test capture from the UI or via DELETE /api/pcap/<id> afterwards)"
exit "$fail"
