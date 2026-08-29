-----------------------------------------------------------------
-- General redis-lua utilities.
-----------------------------------------------------------------
local config = require( 'config' )

local logger = require( 'moon.logger' )
local file = require( 'moon.file' )

local redis = require( 'redis' )
local socket = require( 'socket' )

-----------------------------------------------------------------
-- Aliases.
-----------------------------------------------------------------
local debug = assert( logger.debug )
local trace = assert( logger.trace )
local fatal = assert( logger.fatal )

local insert = assert( table.insert )
local unpack = assert( table.unpack )

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

local function connect()
  local HOST = assert( config.general.HOST )
  local PORT = assert( config.general.PORT )
  -- Test if the server is reachable first because then otherwise
  -- redis.connect can hang for a long period of time, and we
  -- don't want to put a timeout on its underlying socket because
  -- we generally want to be able to block on it while waiting to
  -- read data from redis.
  if not tcp_reachable( HOST, PORT,
                        config.general.CONNECT_TIMEOUT_SECS ) then
    fatal( 'redis server at %s:%s is not reachable.', HOST, PORT )
  end
  local cxn = assert( redis.connect( HOST, PORT ) )
  assert( cxn:ping(), 'unable to ping redis server' )
  return setmetatable( {}, {
    __index=cxn,
    __close=function( self )
      debug( 'closing redis connection' )
      self:quit()
    end,
  } )
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
    local ok, res = pcall( cxn.evalsha, cxn, sha, nkeys, ... )
    if ok then return res end
    if tostring( res ):find( 'NOSCRIPT', 1, true ) then
      sha = cxn:script( 'load', source )
      return cxn:evalsha( sha, nkeys, ... )
    end
    error( res )
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
  connect=connect,
  set_hash=set_hash,
  redis_script=redis_script,
  run_redis_script=run_redis_script,
  dec_if_positive=dec_if_positive,
}
