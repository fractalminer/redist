#!/bin/bash
set -eo pipefail

export LUA_PATH="$HOME/dev/redist/src/?.lua;$LUA_PATH"

workarea=/home/dsicilia/dev/redist/src/workarea

# NOTE: ccache does not like it when the prefix command writes
# anything at all to stdout, so we need to redirect everything to
# stderr.
lua "$HOME/dev/redist/src/builder.lua" \
  --command="$*"    \
  --verbosity=error \
  --workarea="$workarea" \
  1>&2



# ret=$?
#
# if(( ret != 64 )); then exit "$ret"; fi
#
# "$@"
