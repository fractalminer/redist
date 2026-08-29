#!/bin/bash
set -eo pipefail

this_dir="$(dirname "$0")"
cd "$this_dir"

code='
  require( "cluster" ).print_cluster_state( { exclude_workers=true } )
'
workers="$(lua -e "$code" | jq '.worker_count-.local_worker_count')"

# It's important not to allow this script to ever return zero be-
# cause ninja's -j0 means "infinite concurrency".
if (( workers == 0 )); then exit 1; fi

echo "$workers"
exit 0