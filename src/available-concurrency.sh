#!/bin/bash
set -eo pipefail

this_dir="$(dirname "$0")"
cd "$this_dir"

workers="$(./cluster-state.sh | jq .worker_count)"

# It's important not to allow this script to ever return zero be-
# cause ninja's -j0 means "infinite concurrency".
if (( workers == 0 )); then exit 1; fi

echo "$workers"
exit 0