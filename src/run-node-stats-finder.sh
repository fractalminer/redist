#!/bin/bash
set -eo pipefail

this_dir="$(dirname "$0")"
cd "$this_dir"

# lua node-stats-finder.lua
while true; do
  echo 'node-stats-finder running...'
  sleep 1
done