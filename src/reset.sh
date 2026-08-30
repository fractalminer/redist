#!/bin/bash
set -eo pipefail

this_dir="$(dirname "$0")"
cd "$this_dir"

source cxn.sh

del_pattern() {
  local pattern="$1"
  [[ -n "$pattern" ]]
  echo "DEL $pattern"
  ./redis-cli.sh KEYS "$pattern" | xargs ./redis-cli.sh DEL >/dev/null
}

./redis-cli.sh PING >/dev/null

del_pattern "farm:blob:*"
del_pattern "farm:compile:*"
del_pattern "farm:local:*"
del_pattern "farm:log:*"
