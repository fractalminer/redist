redist_host() {
  LUA_PATH="$HOME/dev/?.lua;$LUA_PATH" lua -e '
    local ru = require( "redist.src.redis-util" )
    local host, _ = ru.resolve_host()
    print( host )
  '
}
export -f redist_host

redist_port() {
  LUA_PATH="$HOME/dev/?.lua;$LUA_PATH" lua -e '
    local config = require( "redist.src.config" )
    print( config.redis.PORT )
  '
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
