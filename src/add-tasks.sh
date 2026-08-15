#!/bin/bash
set -e

source cxn.sh

r() { redis-cli "$@"; }

cat tasks.redis | r >/dev/null
