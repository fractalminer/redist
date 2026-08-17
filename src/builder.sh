#!/bin/bash
set -eo pipefail

export LUA_PATH="$HOME/dev/redist/src/?.lua;$LUA_PATH"

workarea=/home/dsicilia/dev/redist/src/workarea

lua "$HOME/dev/redist/src/builder.lua" \
  --command="$*"    \
  --mode=strict     \
  --verbosity=trace \
  --workarea="$workarea"



# ret=$?
#
# if(( ret != 64 )); then exit "$ret"; fi
#
# "$@"
