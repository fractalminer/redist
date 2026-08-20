redist_host() {
  LUA_PATH="$HOME/dev/?.lua;$LUA_PATH" lua -e 'print( require( "redist.src.config" ).general.HOST )'
}

redist_port() {
  LUA_PATH="$HOME/dev/?.lua;$LUA_PATH" lua -e 'print( require( "redist.src.config" ).general.PORT )'
}

redis-cli() {
  local host
  local port
  host="$(redist_host)" || return 1
  port="$(redist_port)" || return 1
  command redis-cli -h "$host" -p "$port" "$@"
}
