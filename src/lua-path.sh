# NOTE: this file is supposed to be sourced.

if [[ -z "$LUA_PATH" ]]; then
  # We are likely running in a blank environment as part of a
  # systemd startup, so we need these.
  export LUA_INIT="@$HOME/.config/lua/startup.lua"
  eval "$(luarocks path --bin)"
fi
