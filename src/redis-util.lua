-----------------------------------------------------------------
-- General redis-lua utilities.
-----------------------------------------------------------------
local config = require( 'config' )
local redis = require( 'redis' )

local logger = require( 'moon.logger' )

-----------------------------------------------------------------
-- Aliases.
-----------------------------------------------------------------
local HOST = assert( config.general.HOST )
local PORT = assert( config.general.PORT )

local debug = assert( logger.debug )

local insert = assert( table.insert )
local unpack = assert( table.unpack )

-----------------------------------------------------------------
-- Methods.
-----------------------------------------------------------------
local function connect()
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

-----------------------------------------------------------------
-- Module.
-----------------------------------------------------------------
return {
  connect=connect, --
  set_hash=set_hash, --
}
