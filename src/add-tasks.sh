#!/bin/bash
set -e

source cxn.sh

r() { redis-cli "$@"; }


# for (( i=0; i<10; i++ )); do
cat local-tasks.redis | r >/dev/null
cat tasks.redis | r >/dev/null
# done
