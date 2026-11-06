#!/bin/bash
set -eo pipefail

this_dir="$(dirname "$0")"
cd "$this_dir"

source waiter.sh

listen="${1:-remote}"

waiter lua worker.lua \
  --verbosity=info \
  --listen="$listen"