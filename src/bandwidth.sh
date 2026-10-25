#!/bin/bash
set -euo pipefail

this_dir="$(dirname "$0")"
cd "$this_dir"

source cxn.sh

SIZE_MIB="${SIZE_MIB:-1}"
KEY="bandwidth-test-$$"

BYTES=$((SIZE_MIB * 1024 * 1024))

DEFAULT_PORT=$(redist_port)
PORT=${PORT:-$DEFAULT_PORT}

redis-cli() {
  command redis-cli -h $(redist_host) -p "$PORT" "$@"
}

cleanup() {
  redis-cli DEL "$KEY" >/dev/null 2>&1 || true
}
trap cleanup EXIT

elapsed() {
  awk -v start="$1" -v end="$2" 'BEGIN { printf "%.6f", end - start }'
}

report() {
  local direction="$1"
  local seconds="$2"

  awk \
    -v direction="$direction" \
    -v bytes="$BYTES" \
    -v seconds="$seconds" \
    'BEGIN {
      mibps = bytes / 1024 / 1024 / seconds
      mbps  = bytes * 8 / 1000000 / seconds

      printf "%-8s %7.2f Mbps  (%6.2f MiB/s)  %.3f sec\n",
             direction, mbps, mibps, seconds
    }'
}

report_json() {
  local seconds="$1"
  awk \
    -v bytes="$BYTES" \
    -v seconds="$seconds" \
    'BEGIN {
      mibps = bytes / 1024 / 1024 / seconds
      mbps  = bytes * 8 / 1000000 / seconds

      printf "{ \"bandwidth_mbps\": %.2f, \"bandwidth_mibs\": %.2f, \"time_secs\": %.3f }", mbps, mibps, seconds
    }'
}

echo "Size:  ${SIZE_MIB} MiB"
echo

echo "Testing upload [$PORT] (SET)..."
start=$(date +%s.%N)

head -c "$BYTES" /dev/zero |
  redis-cli -x SET "$KEY" >/dev/null

end=$(date +%s.%N)
upload_seconds=$(elapsed "$start" "$end")

echo "Testing download [$PORT] (GET)..."
start=$(date +%s.%N)

redis-cli --raw GET "$KEY" >/dev/null

end=$(date +%s.%N)
download_seconds=$(elapsed "$start" "$end")

echo
report "Upload:   " "$upload_seconds"
report "Download: " "$download_seconds"

up_json=/tmp/redis-up-bandwidth.$PORT.json
dn_json=/tmp/redis-dn-bandwidth.$PORT.json

report_json "$upload_seconds"   >"$up_json"
report_json "$download_seconds" >"$dn_json"

# echo
# echo "Upload ($PORT):"
# cat "$up_json" | jq
# echo "Download ($PORT):"
# cat "$dn_json" | jq