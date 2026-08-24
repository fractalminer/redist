#!/bin/bash
set -eo pipefail

this_dir="$(dirname "$0")"
cd "$this_dir"

lua -e 'require( "cluster" ).print_cluster_state()'