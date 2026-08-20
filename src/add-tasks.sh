#!/bin/bash
set -e

source cxn.sh

r() { redis-cli "$@"; }

cat local-tasks.redis | r >/dev/null

# for (( i=0; i<10; i++ )); do
cat tasks.redis | r >/dev/null
# done
