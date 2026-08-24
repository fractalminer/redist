#!/bin/bash
set -eo pipefail

this_dir="$(dirname "$0")"
cd "$this_dir"

workarea=/tmp/farm/workarea
mkdir -p "$workarea"

lua worker.lua \
  --workarea="$workarea" \
  --verbosity=trace \
  --fail-on-meta-error \
  --listen=both \
  --mode=drain \
  --wait