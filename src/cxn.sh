redist_host() {
  LUA_PATH="$HOME/dev/?.lua;$LUA_PATH" lua -e 'print( require( "redist.src.config" ).general.HOST )'
}
export -f redist_host

redist_port() {
  LUA_PATH="$HOME/dev/?.lua;$LUA_PATH" lua -e 'print( require( "redist.src.config" ).general.PORT )'
}
export -f redist_port

redis-cli() {
  local host
  local port
  host="$(redist_host)" || return 1
  port="$(redist_port)" || return 1
  command redis-cli -h "$host" -p "$port" "$@"
}
export -f redis-cli
