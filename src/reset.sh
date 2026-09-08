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
del_pattern "farm:queue:*"
del_pattern "farm:task:*"
del_pattern "farm:events:*"
