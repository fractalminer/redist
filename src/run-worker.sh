#!/bin/bash
set -eo pipefail

lua worker.lua \
  --workarea=/home/dsicilia/dev/redist/src/workarea \
  --verbosity=debug \
  --fail-on-meta-error \
  --advertise=false \
  --mode=drain \
  --wait