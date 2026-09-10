#!/bin/bash
set -euo pipefail

HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-6379}"
SIZE_MIB="${SIZE_MIB:-100}"
KEY="bandwidth-test-$$"

BYTES=$((SIZE_MIB * 1024 * 1024))

cleanup() {
  redis-cli -h "$HOST" -p "$PORT" DEL "$KEY" >/dev/null 2>&1 || true
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

echo "Redis: ${HOST}:${PORT}"
echo "Size:  ${SIZE_MIB} MiB"
echo

echo "Testing upload (SET)..."
start=$(date +%s.%N)

head -c "$BYTES" /dev/zero |
  redis-cli -h "$HOST" -p "$PORT" -x SET "$KEY" >/dev/null

end=$(date +%s.%N)
upload_seconds=$(elapsed "$start" "$end")

echo "Testing download (GET)..."
start=$(date +%s.%N)

redis-cli -h "$HOST" -p "$PORT" --raw GET "$KEY" >/dev/null

end=$(date +%s.%N)
download_seconds=$(elapsed "$start" "$end")

echo
report "Upload:"   "$upload_seconds"
report "Download:" "$download_seconds"