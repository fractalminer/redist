-----------------------------------------------------------------
-- General redis-lua utilities.
-----------------------------------------------------------------
local config = require( 'config' )
local network = require( 'network' )

local logger = require( 'moon.logger' )
local file = require( 'moon.file' )
local time = require( 'moon.time' )

local redis = require( 'redis' )
local socket = require( 'socket' )

-----------------------------------------------------------------
-- Aliases.
-----------------------------------------------------------------
local hostname = assert( network.hostname )

local debug = assert( logger.debug )
local err = assert( logger.err )
local trace = assert( logger.trace )
local sleep = assert( time.sleep )

local insert = assert( table.insert )
local unpack = assert( table.unpack )
local format = assert( string.format )
local traceback = assert( require( 'debug' ).traceback )

-----------------------------------------------------------------
-- Methods.
-----------------------------------------------------------------
local function tcp()
  local sock = assert( socket.tcp() )
  return setmetatable( { sock=sock }, {
    __index=sock,
    __close=function( self )
      trace( 'closing tcp socket' )
      self.sock:close()
    end,
  } )
end

local function tcp_reachable( host, port, timeout )
  local sock<close> = assert( tcp() )
  sock.sock:settimeout( timeout )
  return sock.sock:connect( host, port ) ~= nil
end

local function connect_impl( host, port )
  assert( host )
  assert( port )
  if config.redis.CONNECT_TIMEOUT_SECS > 0 then
    -- Test if the server is reachable first because then other-
    -- wise redis.connect can hang for a long period of time, and
    -- we don't want to put a timeout on its underlying socket
    -- because we generally want to be able to block on it while
    -- waiting to read data from redis.
    if not tcp_reachable( host, port,
                          config.redis.CONNECT_TIMEOUT_SECS ) then
      error( format( 'redis server at %s:%s is not reachable.',
                     host, port ) )
    end
  end
  local cxn = assert( redis.connect{
    host=host,
    port=port,
    -- Disables buffering. On by default when not specified, but
    -- we have it here since it may be worth trying to turn it
    -- off when we are latency bound.
    tcp_nodelay=true,
  } )
  return setmetatable( {}, {
    __index=cxn,
    __close=function( self )
      debug( 'closing redis connection' )
      self:quit()
    end,
  } )
end

-- Returns two values:
--   * resolved host (could be name or ip address)
--   * boolean indicating whether we are running on the same host
--     as the redis server or not.
local function resolve_host()
  local host = assert( config.redis.host.NAME )
  if host == 'tunnel' then
    return '127.0.0.1', false
  elseif host == hostname() then
    -- This is to support the case where we are running locally
    -- outside of the network (e.g. on public wifi) where the
    -- redis server (for security) will not be listening on the
    -- LAN IP address but instead will only be exposed on loop-
    -- back. And it should work in other cases as well.
    return '127.0.0.1', true
  else
    local ip = assert( config.redis.host.IP )
    return ip, false
  end
end

local function connect()
  local host = assert( resolve_host() )
  local port = assert( config.redis.PORT )
  return connect_impl( host, port )
end

local function connect_local()
  if config.redis.ENABLE_LOCAL then
    local host = assert( '127.0.0.1' )
    local port = assert( config.redis.PORT_LOCAL )
    return connect_impl( host, port )
  else
    return connect()
  end
end

local function wait_redis_available( stop_fn )
  stop_fn = stop_fn or function() return false end
  local host = assert( resolve_host() )
  local port = assert( config.redis.PORT )
  local delay_secs = config.redis.INITIAL_CONNECT_WAIT_SECS
  while true do
    if stop_fn() then return end
    local ok, res = xpcall( connect_impl, traceback, host, port )
    if ok then
      local cxn<close> = res
      debug( 'redis connection available' )
      return
    end
    err( 'cannot connect to redis [%s:%s]: %s', host, port,
         tostring( res ) )
    sleep( delay_secs )
  end
end

local function set_hash( cxn, key, tbl, expiry )
  assert( type( tbl ) == 'table' )
  local kvs = {}
  for k, v in pairs( tbl ) do
    insert( kvs, k )
    insert( kvs, v )
  end
  cxn:transaction( function( t )
    t:del( key )
    t:hset( key, unpack( kvs ) )
    if expiry then t:expire( key, expiry ) end
  end )
end

local function redis_script( source )
  local sha
  -- This will auto reload the script if redis forgot about it.
  return function( cxn, nkeys, ... )
    if not sha then
      debug( 'reloading script...' )
      sha = cxn:script( 'load', source )
    end
    local ok, res = xpcall( cxn.evalsha, traceback, cxn, sha,
                            nkeys, ... )
    if ok then return res end
    if tostring( res ):find( 'NOSCRIPT', 1, true ) then
      sha = cxn:script( 'load', source )
      return cxn:evalsha( sha, nkeys, ... )
    end
    error( tostring( res ) )
  end
end

local function run_redis_script( cxn, info, ... )
  if not info.stored then
    debug( 'reading script file %s', info.script )
    local body = assert( file.read_file( info.script ) )
    assert( #body > 0 )
    info.stored = assert( redis_script( body ) )
  end
  local nkeys = assert( info.nkeys )
  assert( #{ ... } >= nkeys )
  return info.stored( cxn, nkeys, ... )
end

local DEC_IF_POSITIVE<const> = {
  script=config.scripts.dec_if_positive,
  nkeys=1,
  stored=nil,
}

local function dec_if_positive( cxn, key )
  return run_redis_script( cxn, DEC_IF_POSITIVE, key )
end

-----------------------------------------------------------------
-- Module.
-----------------------------------------------------------------
return {
  resolve_host=resolve_host,
  connect=connect,
  connect_local=connect_local,
  wait_redis_available=wait_redis_available,
  set_hash=set_hash,
  redis_script=redis_script,
  run_redis_script=run_redis_script,
  dec_if_positive=dec_if_positive,
}
