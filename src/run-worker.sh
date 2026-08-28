#!/bin/bash
set -eo pipefail

this_dir="$(dirname "$0")"
cd "$this_dir"

source waiter.sh

listen="${1:-both}"

workarea=/tmp/farm/workarea
mkdir -p "$workarea"

waiter lua worker.lua    \
  --workarea="$workarea" \
  --verbosity=debug      \
  --fail-on-meta-error   \
  --listen="$listen"     \
  --mode=drain           \
  --wait