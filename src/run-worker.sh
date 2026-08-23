#!/bin/bash
set -eo pipefail

cd ~/dev/redist/src

lua worker.lua \
  --workarea=workarea \
  --verbosity=debug \
  --fail-on-meta-error \
  --advertise=false \
  --mode=drain \
  --wait