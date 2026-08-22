#!/bin/bash
set -eo pipefail

# echo cmd: "$@" 1>&2

redist="$HOME/dev/redist"

export LUA_PATH="$redist/src/?.lua;$LUA_PATH"

# NOTE: ccache does not like it when the prefix command writes
# anything at all to stdout, so we need to redirect everything to
# stderr. This command tries its best to not write anything to
# stdout, but sometimes it happens e.g. during debugging.
#
# NOTE: be sure not to change the CWD before running this.
lua "$redist/src/builder.lua" "$@" 1>&2
