#!/bin/bash
set -eo pipefail

this_dir="$(dirname "$0")"
cd "$this_dir"

lua node-manager.lua \
  --verbosity=debug