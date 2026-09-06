#!/bin/bash
set -eo pipefail

this_dir="$(realpath $(dirname "$0"))"
cd "$this_dir"

source cxn.sh

ssh "$(redist_host)" -t 'fish -c farm'