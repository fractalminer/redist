#!/bin/bash
set -eo pipefail

this_dir="$(dirname "$0")"
cd "$this_dir"

source waiter.sh

waiter lua distributor.lua \
  --verbosity=debug