-----------------------------------------------------------------
-- General redis-lua utilities.
-----------------------------------------------------------------
local config = require( 'config' )
local network = require( 'network' )

local logger = require( 'moon.logger' )
local mcleanup = require( 'moon.cleanup' )

local redis = require( 'redis' )
local socket = require( 'socket' )

-----------------------------------------------------------------
-- Aliases.
-----------------------------------------------------------------
local cleaned = assert( mcleanup.cleaned )
local cleanup = assert( mcleanup.cleanup )
local machine_label = assert( network.machine_label )

local debug = assert( logger.debug )
local trace = assert( logger.trace )
local fatal = assert( logger.fatal )

local insert = assert( table.insert )
local unpack = assert( table.unpack )

-----------------------------------------------------------------
-- Config Fields.
-----------------------------------------------------------------
local EXPIRE_APPROX_COUNT_SECS = config.worker
                                     .EXPIRE_APPROX_COUNT_SECS

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

-- Since this returns a cleanup object, that means that:
--   1. You should store it in a to-be-closed variable.
--   2. You can call release() on it to avoid it closing.
--   3. You can call cleanup_now() on it to run the closing func-
--      tion immediately and not again.
local function scoped_inc( cxn, key, expiry, condition )
  if condition == false then return cleaned() end
  cxn:incr( key )
  if expiry then cxn:expire( key, expiry ) end
  return cleanup( function() cxn:decr( key ) end )
end

local function scoped_node_inc( cxn, label, condition )
  local key = ('farm:node:%s:count:%s'):format( machine_label(),
                                                label )
  return scoped_inc( cxn, key, EXPIRE_APPROX_COUNT_SECS,
                     condition )
end

-----------------------------------------------------------------
-- Module.
-----------------------------------------------------------------
return {
  connect=connect, --
  set_hash=set_hash, --
  scoped_inc=scoped_inc, --
  scoped_node_inc=scoped_node_inc, --
}
