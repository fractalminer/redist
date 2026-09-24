#!/bin/bash
set -eo pipefail

this_dir="$(dirname "$0")"
cd "$this_dir"

export LUA_INIT="@$HOME/.config/lua/startup.lua"
eval "$(luarocks path --bin)"

source waiter.sh

# We generally want this service to be restarted if it exits, but
# we will let systemd do that instead of e.g. doing it here with
# a loop because systemd will make sure that all the subprocesses
# are ended first before starting another instance.

waiter lua node-manager.lua \
  --verbosity=debug