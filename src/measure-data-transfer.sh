#!/usr/bin/env bash
# ---------------------------------------------------------------
# Data Transfer measuring tool.
# ---------------------------------------------------------------
# This tool will set up some network rules that measure data
# transfer to/from the redis host and then will run a build of rn
# to measure total data sent/recv during the build, then will
# clean up the rules.
set -euo pipefail

this_dir="$(realpath $(dirname "$0"))"
cd "$this_dir"

# ---------------------------------------------------------------
# Imports.
# ---------------------------------------------------------------
source cxn.sh

# ---------------------------------------------------------------
# Constants.
# ---------------------------------------------------------------
redis_host="$(redist_host)"
redis_port="$(redist_port)"

table=redis_monitor

# ---------------------------------------------------------------
# Helpers.
# ---------------------------------------------------------------
cleanup() {
  sudo nft delete table inet "$table" 2>/dev/null || true
  echo 'cleaned up nft tables.'
}
trap cleanup EXIT

# ---------------------------------------------------------------
# Clean Build.
# ---------------------------------------------------------------
cd ~/dev/revolution-now
# TODO: uncomment which of these you want.
# ccache --clear
# make clean
# ./reset.sh

# ---------------------------------------------------------------
# Create Rules.
# ---------------------------------------------------------------
# Create table and chains.
sudo nft add table inet "$table"
sudo nft 'add chain inet redis_monitor output { type filter hook output priority 0; policy accept; }'
sudo nft 'add chain inet redis_monitor input  { type filter hook input  priority 0; policy accept; }'

# Create named counters.
sudo nft add counter inet "$table" sent
sudo nft add counter inet "$table" recv

# Count all traffic between this host and Redis.
sudo nft add rule inet "$table" output \
    ip daddr "$redis_host" tcp dport "$redis_port" \
    counter name sent

sudo nft add rule inet "$table" input \
    ip saddr "$redis_host" tcp sport "$redis_port" \
    counter name recv

# Run the build.
set +e
time make all REMOTE=
status=$?
set -e

# Print results.
echo
echo "Redis network traffic:"
sudo nft -j list counters table inet "$table" |
  jq -r '
      [
        .nftables[].counter
          | select( . != null )
          | "\(.name): \(.bytes) bytes (\((.bytes / 1048576 * 100 | round) / 100) MiB)"
      ]
      | .[]
  '

exit "$status"