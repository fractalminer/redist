-----------------------------------------------------------------
-- General redis-lua utilities.
-----------------------------------------------------------------
local config = require( 'config' )
local network = require( 'network' )

local logger = require( 'moon.logger' )

local redis = require( 'redis' )
local socket = require( 'socket' )
local posix = require( 'posix' )

-----------------------------------------------------------------
-- Aliases.
-----------------------------------------------------------------
local machine_label = assert( network.machine_label )

local debug = assert( logger.debug )
local trace = assert( logger.trace )
local fatal = assert( logger.fatal )

local insert = assert( table.insert )
local unpack = assert( table.unpack )

-----------------------------------------------------------------
-- Config Fields.
-----------------------------------------------------------------
local EXPIRE_ADVERTISE_SECS = config.worker.EXPIRE_ADVERTISE_SECS

-----------------------------------------------------------------
-- Globals.
-----------------------------------------------------------------
local PID<const> = assert( posix.getpid().pid )

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

local function broadcast_presence( cxn, set )
  local key = 'farm:node:%s:presence:%s'
  key = key:format( machine_label(), set )
  assert( cxn:sadd( key, PID ) )
  cxn:expire( key, EXPIRE_ADVERTISE_SECS )
  trace( 'added presence: %s|%s', key, PID )
end

local function remove_presence( cxn, set )
  local key = 'farm:node:%s:presence:%s'
  key = key:format( machine_label(), set )
  -- Don't assert here just in case the set no longer exists.
  cxn:srem( key, PID )
  trace( 'removed presence: %s|%s', key, PID )
end

-----------------------------------------------------------------
-- Module.
-----------------------------------------------------------------
return {
  connect=connect, --
  set_hash=set_hash, --
  broadcast_presence=broadcast_presence, --
  remove_presence=remove_presence, --
}
